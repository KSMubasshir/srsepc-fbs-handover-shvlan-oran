#!/bin/bash
#
# Add the core network address as a secondary address on the interface in
# the same /24, so a core co-located with an eNodeB has its own address
# (avoids the eNodeB and SGW-U both binding GTP-U on one address).
# Idempotent; addresses do not survive reboot, so run on every boot.
#
# usage: setup-core-addr.sh <core_ip>
#

set -x

CORE_IP=$1
PREFIX=`echo $CORE_IP | cut -d. -f1-3`

if ip -4 -br addr | grep -qw "$CORE_IP"; then
    exit 0
fi

IFACE=`ip -4 -br addr | grep " ${PREFIX}\." | awk '{print $1}' | cut -d@ -f1 | head -1`
if [ -z "$IFACE" ]; then
    echo "ERROR: no interface in ${PREFIX}.0/24 to add $CORE_IP to"
    exit 1
fi
sudo ip addr add $CORE_IP/24 dev $IFACE
