#!/bin/bash
#
# Bind srsEPC's MME and SPGW to the core address and provision subscribers.
# NB: srsEPC does not implement S1 handover; use setup-open5gs.sh for
# handover experiments.  Idempotent; safe to run on every boot.
#
# usage: configure-srsepc.sh <core_ip> <imsi,k,opc,ipaddr> [...]
#   ipaddr may be "dynamic"
#

set -x

SETUPDIR=`dirname $0`

. $SETUPDIR/setup-common.sh

CORE_IP=$1
shift

[ ! -d $OURDIR ] && mkdir -p $OURDIR

if ! which crudini >/dev/null 2>&1; then
    $SUDO apt-get -y update && $SUDO apt-get -y install crudini
fi

$SUDO cp -n /etc/srslte/epc.conf /etc/srslte/epc.conf.orig
$SUDO crudini --set /etc/srslte/epc.conf mme mme_bind_addr "$CORE_IP"
$SUDO crudini --set /etc/srslte/epc.conf spgw gtpu_bind_addr "$CORE_IP"

idx=1
for sub in "$@"; do
    imsi=`echo "$sub" | cut -d, -f1`
    k=`echo "$sub" | cut -d, -f2`
    opc=`echo "$sub" | cut -d, -f3`
    ipaddr=`echo "$sub" | cut -d, -f4`
    [ -z "$ipaddr" ] && ipaddr=dynamic
    $SUDO sed -i -re "/^#?ue${idx},/d" /etc/srslte/user_db.csv
    echo "ue${idx},mil,${imsi},${k},opc,${opc},9001,000000001234,7,${ipaddr}" \
        | $SUDO tee -a /etc/srslte/user_db.csv
    idx=`expr $idx + 1`
done

echo srsepc > $OURDIR/core-type
echo 192.168.0.1 > $OURDIR/core-ue-gw
