#!/bin/bash
#
# Start/stop one node's part of an experiment run and collect its traces.
#
# usage: ran-run.sh start <core|enb|ue> [run-id]
#        ran-run.sh stop  <core|enb|ue> [run-id]
#
#   core  core network only (separate epc node)
#   enb   srsenb, plus the core if this node hosts it (enb1)
#   ue    srsue plus ping (and iperf3 if IPERF=1) toward the core gateway
#
# Use the same run-id on every node (e.g. the one printed by ric-trace.sh on
# the RIC node) so bundles line up.  Everything for a run lands in
# /local/logs/e2run/<run-id>/ and is bundled to /local/logs/e2run/<run-id>-<role>.tgz
# on stop.  E2TERM_SCTP / E2TERM_PORT override the RIC address in enb.conf.
#
# Captures: E2AP (enb), S1AP + MAC (enb), S1AP (core), MAC (ue).
#

ACTION=$1
ROLE=$2
TOP=/local/logs/e2run
RUN=${3:-`cat $TOP/current 2>/dev/null`}
[ -z "$RUN" ] && RUN=`date +%Y%m%d-%H%M%S`
D=$TOP/$RUN
SESSION=ran
CORE=`cat /local/setup/core-type 2>/dev/null`
UE_GW=`cat /local/setup/core-ue-gw 2>/dev/null`

case "$ROLE" in
    core|enb|ue) ;;
    *) echo "usage: $0 start|stop <core|enb|ue> [run-id]"; exit 1 ;;
esac

pane() {
    # Run a command in a new pane of the run's tmux session.  Panes run bash
    # explicitly: POWDER login shells are often csh.
    if tmux has-session -t $SESSION 2>/dev/null; then
        tmux split-window -v -t $SESSION /bin/bash
        tmux select-layout -t $SESSION even-vertical
    else
        tmux new-session -d -s $SESSION /bin/bash
    fi
    tmux send-keys -t $SESSION "$1" C-m
}

capture() {
    # capture <name> <filter>
    sudo nohup tcpdump -i any -s 0 -U -w $D/$1.pcap "$2" >/dev/null 2>&1 &
    echo $! >> $D/.tcpdump.pids
}

start_core() {
    if [ "$CORE" = srsepc ]; then
        pane "sudo srsepc --pcap.enable=true --pcap.filename=$D/epc-s1ap.pcap --log.filename=$D/epc.log |& tee $D/epc.out"
        sleep 3
    elif [ "$CORE" = open5gs ]; then
        capture core-s1ap 'sctp port 36412'
        # Remember where each log ends so stop copies only this run.
        for f in /var/log/open5gs/*.log; do
            echo "$f `sudo stat -c %s $f`" >> $D/.open5gs-offsets
        done
    fi
    if [ -n "$UE_GW" ]; then
        pane "iperf3 -s -B $UE_GW -i 1 |& tee $D/iperf-server.out"
    fi
}

start_enb() {
    ARGS="--pcap.enable=true --pcap.filename=$D/mac-enb.pcap"
    ARGS="$ARGS --pcap.s1ap_enable=true --pcap.s1ap_filename=$D/s1ap-enb.pcap"
    ARGS="$ARGS --log.filename=$D/enb.log --ric.agent.log_level=debug"
    E2_PORT=${E2TERM_PORT:-`crudini --get /etc/srslte/enb.conf ric agent.remote_port 2>/dev/null`}
    [ -z "$E2_PORT" ] && E2_PORT=36422
    if [ -n "$E2TERM_SCTP" ]; then
        E2_SRC=`ip -4 route get "$E2TERM_SCTP" | sed -nre 's/.* src ([0-9.]+).*/\1/p'`
        ARGS="$ARGS --ric.agent.remote_ipv4_addr=$E2TERM_SCTP --ric.agent.local_ipv4_addr=$E2_SRC"
        ARGS="$ARGS --ric.agent.remote_port=$E2_PORT"
    fi
    capture e2-enb "sctp port $E2_PORT"
    pane "sudo srsenb $ARGS |& tee $D/enb.out"
}

start_ue() {
    pane "sudo srsue --log.filename=$D/ue.log --pcap.enable=true --pcap.filename=$D/ue_mac.pcap |& tee $D/ue.out"
    # Ping the gateway once the UE has attached; the UE node has no core-type
    # marker, so derive the gateway from the UE's own address.
    pane "until ip -4 -br addr show tun_srsue 2>/dev/null | grep -q /; do sleep 1; done; GW=\`ip -4 -br addr show tun_srsue | awk '{print \$3}' | cut -d/ -f1 | sed 's/\.[0-9]*\$/.1/'\`; ping -i 0.2 \$GW |& tee $D/ping.out"
    if [ "$IPERF" = 1 ]; then
        pane "until ip -4 -br addr show tun_srsue 2>/dev/null | grep -q /; do sleep 1; done; GW=\`ip -4 -br addr show tun_srsue | awk '{print \$3}' | cut -d/ -f1 | sed 's/\.[0-9]*\$/.1/'\`; while true; do iperf3 -c \$GW -t 65536 -i 1; sleep 2; done |& tee $D/iperf.out"
    fi
}

stop_all() {
    for p in srsue srsenb srsepc iperf3 ping; do sudo pkill -INT -x $p; done
    for i in `seq 1 8`; do
        pgrep -x 'srsenb|srsue|srsepc' >/dev/null || break
        sleep 1
    done
    # srsenb ignores SIGINT while retrying S1 setup.
    for p in srsue srsenb srsepc; do sudo pkill -KILL -x $p; done
    tmux kill-session -t $SESSION 2>/dev/null
    if [ -f $D/.tcpdump.pids ]; then
        sudo kill -INT `cat $D/.tcpdump.pids` 2>/dev/null
        sleep 1
    fi
    if [ -f $D/.open5gs-offsets ]; then
        mkdir -p $D/open5gs
        while read f off; do
            sudo tail -c +$((off + 1)) $f > $D/open5gs/`basename $f`
        done < $D/.open5gs-offsets
    fi
}

case "$ACTION" in
start)
    mkdir -p $D
    echo $RUN > $TOP/current
    sudo modprobe sctp
    tmux kill-session -t $SESSION 2>/dev/null
    rm -f $D/.tcpdump.pids
    case "$ROLE" in
        core) start_core ;;
        enb) [ -n "$CORE" ] && start_core ; start_enb ;;
        ue) start_ue ;;
    esac
    echo "started $ROLE for run $RUN; tmux attach -t $SESSION"
    ;;
stop)
    stop_all
    sudo chown -R `id -un` $D
    tar -C $TOP -czf $TOP/$RUN-$ROLE.tgz --exclude='.*' $RUN
    echo "bundle: $TOP/$RUN-$ROLE.tgz"
    ;;
*)
    echo "usage: $0 start|stop <core|enb|ue> [run-id]"
    exit 1
    ;;
esac
