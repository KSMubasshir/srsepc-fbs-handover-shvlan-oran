#!/bin/bash
#
# Install and configure an Open5GS 4G core (MME, HSS, PCRF, SGW-C/U, SMF,
# UPF).  Unlike srsEPC, the Open5GS MME implements S1 handover.  The install
# runs once; configuration and subscribers are reapplied on every boot.
#
# usage: setup-open5gs.sh <core_ip> <imsi,k,opc> [<imsi,k,opc> ...]
#

set -x

SETUPDIR=`dirname $0`

. $SETUPDIR/setup-common.sh

CORE_IP=$1
shift

[ -z "$MCC" ] && MCC="001"
[ -z "$MNC" ] && MNC="01"
[ -z "$TAC" ] && TAC=7

[ ! -d $OURDIR ] && mkdir -p $OURDIR

if [ ! -f $OURDIR/setup-open5gs-done ]; then
    $SUDO apt-get -y update
    $SUDO apt-get install -y software-properties-common
    $SUDO add-apt-repository -y ppa:open5gs/latest
    $SUDO apt-get -y update
    $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y \
        mongodb open5gs iptables
    if [ $? -ne 0 ]; then
        echo "ERROR: Open5GS install failed"
        exit 1
    fi
    touch $OURDIR/setup-open5gs-done
fi

# MME S1-MME and SGW-U S1-U listen on the core address; everything else
# stays on the package's loopback defaults.
$SUDO python3 - "$CORE_IP" "$MCC" "$MNC" "$TAC" <<'PY'
import re, sys

core_ip, mcc, mnc, tac = sys.argv[1:]

def edit(path, subs):
    text = open(path).read()
    for pattern, repl in subs:
        text = re.sub(pattern, repl, text, flags=re.M)
    open(path, 'w').write(text)

server = r'(%s:\s*\n\s*server:\s*\n\s*- address:\s*)\S+'
edit('/etc/open5gs/mme.yaml', [
    (server % 's1ap', r'\g<1>' + core_ip),
    (r'^(\s*mcc:\s*)\d+', r'\g<1>' + mcc),
    (r'^(\s*mnc:\s*)\d+', r'\g<1>' + mnc),
    (r'^(\s*tac:\s*)\d+', r'\g<1>' + tac),
])
edit('/etc/open5gs/sgwu.yaml', [
    (server % 'gtpu', r'\g<1>' + core_ip),
])
PY

# UE traffic leaves via the control network.
if ! ip link show ogstun >/dev/null 2>&1; then
    $SUDO ip tuntap add name ogstun mode tun
    $SUDO ip addr add 10.45.0.1/16 dev ogstun
fi
$SUDO ip link set ogstun up
$SUDO sysctl -w net.ipv4.ip_forward=1
$SUDO iptables -t nat -C POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE 2>/dev/null \
    || $SUDO iptables -t nat -A POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE

$SUDO systemctl restart open5gs-mmed open5gs-sgwud

# Subscribers (Milenage; Open5GS does not support srsLTE's XOR test auth).
for i in `seq 1 30`; do
    mongo --quiet --eval 'db.version()' >/dev/null 2>&1 && break
    sleep 2
done
for sub in "$@"; do
    imsi=`echo "$sub" | cut -d, -f1`
    k=`echo "$sub" | cut -d, -f2`
    opc=`echo "$sub" | cut -d, -f3`
    mongo --quiet open5gs --eval '
      var ambr = {downlink: {value: NumberInt(1000000000), unit: NumberInt(0)},
                  uplink: {value: NumberInt(1000000000), unit: NumberInt(0)}};
      db.subscribers.updateOne({imsi: "'$imsi'"}, {$set: {
        schema_version: NumberInt(1), imsi: "'$imsi'", msisdn: [], imeisv: [],
        mme_host: [], mme_realm: [], purge_flag: [],
        security: {k: "'$k'", op: null, opc: "'$opc'", amf: "8000"},
        ambr: ambr,
        slice: [{sst: NumberInt(1), default_indicator: true, _id: new ObjectId(),
          session: [{name: "internet", type: NumberInt(3), _id: new ObjectId(),
            qos: {index: NumberInt(9), arp: {priority_level: NumberInt(8),
              pre_emption_capability: NumberInt(1), pre_emption_vulnerability: NumberInt(1)}},
            ambr: ambr, pcc_rule: []}]}],
        access_restriction_data: 32, subscriber_status: 0, network_access_mode: 0,
        operator_determined_barring: 0, subscribed_rau_tau_timer: 12, __v: 0
      }}, {upsert: true})'
done

echo open5gs > $OURDIR/core-type
echo 10.45.0.1 > $OURDIR/core-ue-gw
