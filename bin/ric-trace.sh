#!/bin/bash
#
# Collect E2 traces and RIC logs on the O-RAN SC RIC node (e.g. the node of
# a PowderProfiles/O-RAN experiment).  Copy this script there; it is not run
# by this profile.
#
# usage: ric-trace.sh start   # prints the run id to pass to ran-run.sh
#        ric-trace.sh stop    # bundles /local/logs/e2run/<run-id>.tgz
#
# Captures E2AP SCTP both as the eNodeBs send it (NodePort, default 32222)
# and as it reaches the e2term pod (36422); follows e2term, e2mgr, submgr,
# rtmgr, appmgr and xApp logs; snapshots e2mgr's NodeB state on stop.
# Decode in Wireshark with "Decode As: SCTP port 32222 -> E2AP".
#

[ -z "$KUBECONFIG" -a -f /local/setup/kubeconfig ] && export KUBECONFIG=/local/setup/kubeconfig
TOP=/local/logs/e2run
NODEPORT=${NODEPORT:-32222}
XAPP_NS=${XAPP_NS:-ricxapp}

mkdir -p $TOP

case "$1" in
start)
    RUN=`date +%Y%m%d-%H%M%S`
    D=$TOP/$RUN
    mkdir -p $D
    echo $RUN > $TOP/current
    sudo nohup tcpdump -i any -s 0 -U -w $D/e2-ric.pcap \
        "sctp and (port $NODEPORT or port 36422)" > $D/tcpdump.out 2>&1 &
    echo $! > $D/.tcpdump.pid
    for app in ricplt-e2term-alpha ricplt-e2mgr ricplt-submgr ricplt-rtmgr ricplt-appmgr; do
        nohup kubectl logs -f -n ricplt -l app=$app --tail=-1 --timestamps \
            > $D/$app.log 2>&1 &
        echo $! >> $D/.klogs.pid
    done
    for pod in `kubectl get pods -n $XAPP_NS -o name`; do
        name=`basename $pod`
        nohup kubectl logs -f -n $XAPP_NS $pod --tail=-1 --timestamps \
            > $D/xapp-$name.log 2>&1 &
        echo $! >> $D/.klogs.pid
    done
    echo "started run $RUN in $D"
    echo "on RAN nodes: ran-run.sh start <core|enb|ue> $RUN"
    ;;
stop)
    RUN=`cat $TOP/current 2>/dev/null`
    D=$TOP/$RUN
    if [ -z "$RUN" -o ! -d "$D" ]; then
        echo "no current run"
        exit 1
    fi
    sudo kill -INT `cat $D/.tcpdump.pid` 2>/dev/null
    kill `cat $D/.klogs.pid` 2>/dev/null
    E2MGR=`kubectl get svc -n ricplt service-ricplt-e2mgr-http -o jsonpath='{.spec.clusterIP}'`
    curl -s http://$E2MGR:3800/v1/nodeb/states > $D/e2mgr-nodeb-states.json
    for nb in `jq -r '.[].inventoryName' $D/e2mgr-nodeb-states.json`; do
        curl -s http://$E2MGR:3800/v1/nodeb/$nb > $D/e2mgr-nodeb-$nb.json
    done
    kubectl get pods -A -o wide > $D/pods.txt
    sleep 1
    sudo chown -R `id -un` $D
    tar -C $TOP -czf $TOP/$RUN.tgz --exclude='.*' $RUN
    echo "bundle: $TOP/$RUN.tgz"
    ;;
*)
    echo "usage: $0 start|stop"
    exit 1
    ;;
esac
