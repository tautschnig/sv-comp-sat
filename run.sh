#!/bin/bash

set -e

CBMC_BINARY=cbmc
CNF_CREATION_TIMEOUT=30
MINISAT_TIMEOUT=10
UNWIND_PLUS=2
MINISAT=minisat
CNF_TO_CREATE=50

# check for available tools
for tool in minisat cbmc
do
	if ! command -v $tool &> /dev/null
	then
		echo "did not find $tool, abort"
		exit 1
	fi
done

if [ ! -s reachsafe.txt ]
then
  wget http://sv-comp.sosy-lab.org/2017/results/results-verified/cbmc.2017-01-10_1721.logfiles.zip
  unzip cbmc.2017-01-10_1721.logfiles.zip
  cd cbmc.2017-01-10_1721.logfiles
  for f in *.log
  do
    head -n1 $f | tr '\n' ' '
    grep "^Unwind:" $f | awk '{print "--unwind "$2}'
  done | grep -- --unwind | grep ReachSafety.prp > ../reachsafe.txt
  cd ..
  rm -r cbmc.2017-01-10_1721.logfiles{,.zip}
fi

mkdir -p input
for b in $(cat reachsafe.txt | awk '{print $7","$4","$9}')
do
  bm=$(echo $b | cut -f1 -d, | sed 's#^\.\./\.\./##')
  bw=$(echo $b | cut -f2 -d, | sed 's/^--//')
  uw=$(echo $b | cut -f3 -d,)
  
  target=$(echo $bm | sed 's#/#__#g')
  cp $bm "input/cbmcunwind=$uw-cbmcbitwidth=$bw-$target"
done

if [ ! -d sv-benchmarks ]
then
  git clone --depth 1 --branch svcomp17 https://github.com/sosy-lab/sv-benchmarks
fi

# convert each benchmark into a CNF, delete if minisat can solve it within
# $MINISAT_TIMEOUT seconds
FORMULA=1

CFILES=$(ls input/* | shuf)

for BM in $CFILES
do
	echo "create formula attempt $FORMULA"
	FORMULA=$((FORMULA+1))
	UNWIND=
	BITWIDTH=

	mkdir -p cnfs
	BN=$(basename $BM)
	BN="$(echo $BN | tr '=' '-')"
	OUTPUTCNF=cnfs/"${BN}.cnf"

	# extract options from name
	ifs=$IFS
	IFS='-/'
	for opt in $BM
	do
	  case $(echo $opt | cut -f1 -d=) in
	    cbmcunwind) UNWIND="$(echo $opt | cut -f2 -d=)" ;;
	    cbmcbitwidth) BITWIDTH="--$(echo $opt | cut -f2 -d=)" ;;
	    *) true ;;
	  esac
	done
	IFS=$ifs

	# make the benchmark a little harder
	UNWIND=$((UNWIND_PLUS+UNWIND))

	echo "create CNF with unwind $UNWIND and bitwidth $BITWIDTH: $OUTPUTCNF"

  # create CNF
	STATUS=0
	timeout -s 9 $CNF_CREATION_TIMEOUT $CBMC_BINARY \
    --dimacs --unwind $UNWIND $BITWIDTH $BM 2> /dev/null | \
    sed -n '/p cnf /,$p' > $OUTPUTCNF || true
	STATUS=${PIPESTATUS[0]}

	# do not create a CNF if creation takes more than 180s
	if [ "$STATUS" -eq 124 ]
	then
		echo "   creation timeout"
		rm "$OUTPUTCNF"
		continue
	fi

	if ! grep -q "p cnf" "$OUTPUTCNF"
	then
		echo "   no 'p cnf' found"
		rm "$OUTPUTCNF"
		continue
	fi

	timeout $MINISAT_TIMEOUT $MINISAT $OUTPUTCNF &> /dev/null  || STATUS=$?

	# if minisat is too fast, drop the CNF
	if [ "$STATUS" -ne 124 ]
	then
		echo "    too simple for Minisat, or buggy (exit $STATUS)"
		rm "$OUTPUTCNF"
		continue
	fi

	# compress output to save some space
	gzip "$OUTPUTCNF"

	# stop creation once we have enough files
	CREATED=$(ls cnfs/*.cnf.gz | wc -l)
	echo "created/kept so far: $CREATED"
	if [ "$CREATED" -gt "$CNF_TO_CREATE" ]
	then
		break
	fi
done
