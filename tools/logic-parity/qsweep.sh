#!/bin/bash
# qsweep.sh <run> <freq> <gain> <q1..q5> [extra idx=val applied to all]
S=${PARITY_DIR:?set PARITY_DIR to the measurement folder}
run=$1 f=$2 g=$3; shift 3; q=($1 $2 $3 $4 $5); shift 5; ex="$*"
chs=(0 5 6 7 8)
args=(); for i in 0 1 2 3 4; do args+=("${chs[$i]} 17=$f 18=$g 19=${q[$i]} $ex"); done
$S/batch.sh $run "${args[@]}" >/dev/null || { echo "batch $run failed"; exit 1; }
python3 $S/bqfit.py $S $run "Audio 1" "Audio 6" "Audio 7" "Audio 8" "Audio 9" | awk -v qs="${q[*]}" -v f=$f -v g=$g 'BEGIN{split(qs,Q," ")} {match($0,/RBJ-Q=[0-9.]+/); r=substr($0,RSTART+6,RLENGTH-6); match($0,/resid +-?[0-9.]+/); print "f=" f " g=" g " Q=" Q[NR] " rbjQ=" r " " substr($0,RSTART,RLENGTH)}'
