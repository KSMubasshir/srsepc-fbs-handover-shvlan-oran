#!/bin/bash
#
# Drive a handover with the attenuator matrix (run on the ue node).
#
# usage: ho-sweep.sh <1to2|2to1|set> [run-id]
#
#   1to2   start with enb1 strong (LOW dB) and enb2 weak (HIGH dB), then step
#          both paths until enb1 is at HIGH and enb2 at LOW
#   2to1   the reverse
#   set    only set enb1 to E1 dB and enb2 to E2 dB
#
# Every attenuator id of a path is set (a path has one per direction and
# port; setting only one does not isolate the cell).  Steps are logged with
# timestamps to /local/logs/e2run/<run-id>/atten.log.
#
# Environment: LOW (20), HIGH (60), STEP (5), DWELL seconds per step (5),
# E1/E2 for "set", ENB1_IDS/ENB2_IDS (default: first and second path of
# `atten -l`, which lists the enb1 path first).
#

ATTEN=`dirname $0`/atten
TOP=/local/logs/e2run
RUN=${2:-`cat $TOP/current 2>/dev/null`}
LOW=${LOW:-20}
HIGH=${HIGH:-60}
STEP=${STEP:-5}
DWELL=${DWELL:-5}
PATHS=`$ATTEN -l`
ENB1_IDS=${ENB1_IDS:-`echo "$PATHS" | sed -n 1p | cut -d: -f1 | tr , ' '`}
ENB2_IDS=${ENB2_IDS:-`echo "$PATHS" | sed -n 2p | cut -d: -f1 | tr , ' '`}
mkdir -p $TOP/$RUN
LOG=$TOP/$RUN/atten.log

set_paths() {
    for i in $ENB1_IDS; do $ATTEN $i $1 >/dev/null; done
    for i in $ENB2_IDS; do $ATTEN $i $2 >/dev/null; done
    echo "`date +%s.%N` enb1-path=$1 enb2-path=$2 $3" | tee -a $LOG
}

case "$1" in
1to2|2to1)
    n=$(( (HIGH - LOW) / STEP ))
    for s in `seq 0 $n`; do
        up=$((LOW + s * STEP)); down=$((HIGH - s * STEP))
        if [ "$1" = 1to2 ]; then set_paths $up $down; else set_paths $down $up; fi
        sleep $DWELL
    done
    ;;
set)
    set_paths ${E1:?} ${E2:?} "(set)"
    ;;
*)
    echo "usage: $0 <1to2|2to1|set> [run-id]"
    exit 1
    ;;
esac
