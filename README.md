# srsRAN S1 Handover with O-RAN Integration

## Overview

This POWDER profile deploys an LTE testbed with two eNodeBs for S1 handover experiments, connected over E2 to an O-RAN SC Near-RT RIC. It runs the POWDER E2-enabled `srslte-ric` fork of srsLTE on Intel NUC nodes with B210 SDRs in a controlled (attenuator-matrix) RF environment, and includes scripts to run experiments and collect E2, S1AP and MAC traces.

## Architecture

```
            RF (attenuated)                 RF (attenuated)
  enb1 (PCI 1) <-------------->   UE   <--------------> enb2 (PCI 2)
  srsENB + core*                srsUE                  srsENB
       |                                                  |
       +------------- S1 LAN 10.20.20.0/24 ---------------+
       |          (core at 10.20.20.10: on enb1,          |
       |           or on an optional `epc` node)          |
       |                                                  |
       +-------- E2 (SCTP): control network or ----------+
                 shared VLAN to the O-RAN SC RIC
                 (separate PowderProfiles/O-RAN experiment)
```

\* The core is Open5GS (default) or srsEPC. **srsEPC's MME does not implement S1 handover**; with it, handover attempts time out in the source eNodeB (`TS1Relocprep`). Open5GS completes S1 handover preparation.

## Parameters

### Hardware
- `deploy_epc_node`, `epc_node`: optional separate core node (otherwise the core runs on enb1)
- `enb1_node`, `enb2_node`, `ue_node`: NUC selection

### Core network
- `core_type`: `open5gs` (default, supports S1 handover) or `srsepc`

### O-RAN integration
- `oran_mode`:
  - `control_net` (default): eNodeBs connect straight to the RIC node's E2Term NodePort (32222) over the POWDER control network. No shared VLAN needed.
  - `shared_vlan`: eNodeBs join `shared_vlan` and route `oran_virtual_subnets` via `oran_address`.
  - `local`: O-RAN SC RIC in `kind` on enb1 (experimental; see [LOCAL-ORAN-DEPLOYMENT.md](LOCAL-ORAN-DEPLOYMENT.md)).
  - `none`
- `oran_e2term_host`: RIC E2Term address: the O-RAN node's control hostname (e.g. `pc797.emulab.net`) for `control_net`, the e2term cluster IP for `shared_vlan`. May be left empty and given at run time (`E2TERM_SCTP=...`).
- `oran_e2term_port`: defaults to 32222 for `control_net`, 36422 otherwise.

### Advanced
- `multiplex_lans`, `install_vnc`

## Running an experiment

1. Start a `PowderProfiles/O-RAN` experiment, then instantiate this profile with `oran_e2term_host` set to its node.
2. On the RIC node, deploy NexRAN:
   ```bash
   /local/setup/oran/dms_cli onboard /local/profile-public/nexran-config-file.json /local/setup/oran/xapp-embedded-schema.json
   /local/setup/oran/dms_cli install nexran 0.1.0 ricxapp
   ```
3. Copy [bin/ric-trace.sh](bin/ric-trace.sh) to the RIC node and run `ric-trace.sh start`; note the run id.
4. Start the RAN with that run id, in order:
   ```bash
   /local/repository/bin/ran-run.sh start enb <run-id>   # enb1 (starts the core too), then enb2
   /local/repository/bin/ran-run.sh start ue <run-id>    # ue: srsue + ping to the core gateway
   ```
5. Drive handover with the attenuators (`/local/repository/bin/atten -l` lists the path ids), register nodes with NexRAN, etc.
6. Stop: `ran-run.sh stop <role> <run-id>` on each node, `ric-trace.sh stop` on the RIC. Bundles land in `/local/logs/e2run/`.

### What gets captured

| Where | Files |
|-------|-------|
| RIC node | `e2-ric.pcap` (E2AP, both pre- and post-NodePort), e2term/e2mgr/submgr/rtmgr/appmgr and xApp logs, e2mgr NodeB state |
| eNodeBs | `e2-enb.pcap`, `s1ap-enb.pcap`, `mac-enb.pcap`, `enb.log`, `enb.out` |
| Core | Open5GS: `core-s1ap.pcap`, `open5gs/*.log` (this run only); srsEPC: `epc-s1ap.pcap`, `epc.log` |
| UE | `ue_mac.pcap`, `ue.log`, `ue.out`, `ping.out` |

Wireshark: *Decode As → SCTP port 32222 → E2AP* for the E2 captures.

## Scripts

| Script | Node | Purpose |
|--------|------|---------|
| [bin/setup-srslte.sh](bin/setup-srslte.sh) | enbs, ue | Build srslte-ric with E2 bindings |
| [bin/update-enb-config-files.sh](bin/update-enb-config-files.sh) | enbs | PLMN, frequency, gains, srsEPC subscriber db |
| [bin/configure-enb.sh](bin/configure-enb.sh) | enbs | S1 addresses, RIC address, cell identity, handover neighbor |
| [bin/setup-open5gs.sh](bin/setup-open5gs.sh) | core | Install/configure Open5GS 4G core, provision subscribers |
| [bin/configure-srsepc.sh](bin/configure-srsepc.sh) | core | Bind srsEPC to the core address, provision subscribers |
| [bin/setup-core-addr.sh](bin/setup-core-addr.sh) | enb1 | Core address alias when the core is co-located |
| [bin/update-ue-config-files.sh](bin/update-ue-config-files.sh) | ue | UE identity (Milenage), frequency, gains |
| [bin/ran-run.sh](bin/ran-run.sh) | all RAN nodes | Start/stop a run and collect traces |
| [bin/ric-trace.sh](bin/ric-trace.sh) | RIC node | E2 capture + RIC log collection |
| [bin/start-enb.sh](bin/start-enb.sh), [bin/start-ue.sh](bin/start-ue.sh) | enbs, ue | Shortcuts for `ran-run.sh start` + tmux attach |
| [bin/setup-ip-config.sh](bin/setup-ip-config.sh) | enbs | Routes for `shared_vlan` mode |
| [bin/setup-oran-local.sh](bin/setup-oran-local.sh) | enb1 | Local RIC (`local` mode) |

## Known limitations

- **Over-the-air handover completion.** With Open5GS, S1 handover preparation succeeds (HandoverRequired → HandoverRequest → HandoverRequestAcknowledge → HandoverCommand) and the UE receives the handover command, but in testing on nuc5300/B210 nodes the UE's random access on the target cell timed out (T304), as did re-establishment (T301), although direct attach to either cell works. Both cells share one carrier and the B210s are not time-synchronized; this needs radio-level tuning.
- `control_net` mode carries E2 over the public control network (the RIC's E2Term NodePort is reachable there); S1 stays on the experiment LAN.
- The local RIC deployment (`local`) failed to clone the O-RAN SC deployment repository in testing; the eNodeB setup now runs before it so the RAN is still usable if it fails.

## Related Profiles

- **O-RAN RIC**: `https://www.powderwireless.net/p/PowderProfiles/O-RAN`
- **srsLTE Base**: `https://www.powderwireless.net/p/PowderTeam/srslte-shvlan-oran`
