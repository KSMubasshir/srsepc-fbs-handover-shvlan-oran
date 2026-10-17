#!/bin/bash
#
# Build the mobmon xApp (E2SM-MOB handover KPI monitor) and deploy it on the
# O-RAN SC RIC node of a PowderProfiles/O-RAN experiment.  Copy xapp/mobmon
# and this script there; it is not run by this profile.
#
# usage: deploy-mobmon.sh [xapp-dir]
#
# Reports: kubectl logs -n ricxapp -l app=ricxapp-mobmon  (one JSON line per
# indication and per handover event; ric-trace.sh captures them too)
# or GET http://<mobmon pod>:8080/mobmon/v1/reports for the latest per node.
#

set -e

DIR=${1:-`dirname $0`/../xapp/mobmon}
REGISTRY=${REGISTRY:-10.10.1.1:5000}
VERSION=`python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" $DIR/config-file.json`
DMS=/local/setup/oran/dms_cli
[ -z "$KUBECONFIG" -a -f /local/setup/kubeconfig ] && export KUBECONFIG=/local/setup/kubeconfig

sudo docker build -t $REGISTRY/mobmon:$VERSION $DIR
sudo docker push $REGISTRY/mobmon:$VERSION

$DMS uninstall mobmon ricxapp >/dev/null 2>&1 || true
$DMS onboard $DIR/config-file.json /local/setup/oran/xapp-embedded-schema.json
$DMS install mobmon $VERSION ricxapp
kubectl wait -n ricxapp --for=condition=Ready pod -l app=ricxapp-mobmon --timeout=180s
kubectl logs -n ricxapp -l app=ricxapp-mobmon --tail=20
