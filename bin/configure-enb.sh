#!/bin/bash
#
# Point srsenb at the core network and the RIC, give the cell a unique
# identity, and configure the neighbor cell for S1 handover.  Idempotent;
# safe to run on every boot.
#
# usage: configure-enb.sh <enb_ip> <core_ip> <cell_id> <pci> <nbr_eci> <nbr_pci> [e2term_host] [e2term_port]
#
#   enb_ip       local address used for S1-C/S1-U
#   core_ip      MME / SGW-U address
#   cell_id      this cell's id (e.g. 0x01)
#   pci          this cell's PCI
#   nbr_eci      neighbor E-UTRAN cell id: (enb_id << 8) | cell_id, e.g. 0x00202
#   nbr_pci      neighbor PCI
#   e2term_host  optional RIC E2Term address/hostname
#   e2term_port  optional RIC E2Term SCTP port
#
# A3 handover trigger (environment): A3_OFFSET dB (1), A3_HYSTERESIS dB
# (0.5), A3_TTT ms (160, a TS 36.331 timeToTrigger value).  rr.conf holds
# offset and hysteresis in the 36.331 0.5 dB units.  Both cells share one
# carrier, so the neighbor is interference: with srsenb's defaults (3 dB,
# 480 ms) the serving SINR can drop low enough for radio link failure before
# the UE's report gets through.
#

set -x

ENB_IP=$1
CORE_IP=$2
CELL_ID=$3
PCI=$4
NBR_ECI=$5
NBR_PCI=$6
E2_HOST=$7
E2_PORT=$8
A3_OFFSET=${A3_OFFSET:-1}
A3_HYSTERESIS=${A3_HYSTERESIS:-0.5}
A3_TTT=${A3_TTT:-160}

if [ -z "$NBR_PCI" ]; then
    echo "usage: $0 <enb_ip> <core_ip> <cell_id> <pci> <nbr_eci> <nbr_pci> [e2term_host] [e2term_port]"
    exit 1
fi

ENB_CONF=/etc/srslte/enb.conf
RR_CONF=/etc/srslte/rr.conf

sudo cp -n $ENB_CONF $ENB_CONF.orig
sudo cp -n $RR_CONF $RR_CONF.orig

# When the core runs on this same address (no dedicated core address),
# srsenb and the SGW-U would both bind GTP-U port 2152; move srsenb's
# GTP-U to loopback, which the co-located SGW-U can still reach.
GTP_BIND=$ENB_IP
if [ "$ENB_IP" = "$CORE_IP" ]; then
    GTP_BIND=127.0.1.1
fi

sudo crudini --set $ENB_CONF enb mme_addr "$CORE_IP"
sudo crudini --set $ENB_CONF enb gtp_bind_addr "$GTP_BIND"
sudo crudini --set $ENB_CONF enb s1c_bind_addr "$ENB_IP"

if [ -n "$E2_HOST" ]; then
    E2_IP=`getent ahostsv4 "$E2_HOST" | awk 'NR==1 {print $1}'`
    if [ -z "$E2_IP" ]; then
        echo "WARNING: cannot resolve E2Term host $E2_HOST; leaving RIC address unset"
    else
        sudo crudini --set $ENB_CONF ric agent.remote_ipv4_addr "$E2_IP"
        # Bind the E2 agent to whichever local address routes to the RIC
        # (control network, or the shared VLAN when routes point there).
        E2_SRC=`ip -4 route get "$E2_IP" | sed -nre 's/.* src ([0-9.]+).*/\1/p'`
        if [ -n "$E2_SRC" ]; then
            sudo crudini --set $ENB_CONF ric agent.local_ipv4_addr "$E2_SRC"
        fi
    fi
fi
if [ -n "$E2_PORT" ]; then
    sudo crudini --set $ENB_CONF ric agent.remote_port "$E2_PORT"
fi

# Rewrite the serving cell identity and the neighbor list in rr.conf.  The
# neighbor uses the serving cell's EARFCN: both cells share one frequency.
sudo python3 - "$RR_CONF" "$CELL_ID" "$PCI" "$NBR_ECI" "$NBR_PCI" "$A3_OFFSET" "$A3_HYSTERESIS" "$A3_TTT" <<'PY'
import re, sys

path, cell_id, pci, nbr_eci, nbr_pci, a3_offset, a3_hyst, a3_ttt = sys.argv[1:]
text = open(path).read()

start = re.search(r'^\s*cell_list\s*=', text, re.M).start()
meas = re.search(r'meas_cell_list\s*=\s*\(.*?\)\s*;', text[start:], re.S)
serving = text[start:start + meas.start()]

serving = re.sub(r'cell_id\s*=\s*0x[0-9A-Fa-f]+;', 'cell_id = %s;' % cell_id, serving, count=1)
serving = re.sub(r'(\n\s*)pci\s*=\s*\d+;', r'\1pci = %s;' % pci, serving, count=1)
serving = re.sub(r'ho_active\s*=\s*\w+;', 'ho_active = true;', serving, count=1)
earfcn = re.search(r'dl_earfcn\s*=\s*(\d+);', serving).group(1)

neighbors = ('meas_cell_list =\n'
             '    (\n'
             '      {\n'
             '        eci = %s;\n'
             '        dl_earfcn = %s;\n'
             '        pci = %s;\n'
             '      }\n'
             '    );') % (nbr_eci, earfcn, nbr_pci)

text = (text[:start] + serving + neighbors
        + text[start + meas.end():])
half_db = lambda db: str(int(round(float(db) * 2)))
for key, value in (('a3_offset', half_db(a3_offset)), ('a3_hysteresis', half_db(a3_hyst)),
                   ('a3_time_to_trigger', a3_ttt)):
    text = re.sub(r'(\b%s\s*=\s*)-?\d+;' % key, r'\g<1>%s;' % value, text)
open(path, 'w').write(text)
PY

grep -E '^(enb_id|mme_addr|gtp_bind_addr|s1c_bind_addr|agent\.)' $ENB_CONF
grep -E 'a3_(offset|hysteresis|time_to_trigger)' $RR_CONF
