#!/usr/bin/env python
import geni.portal as portal
import geni.rspec.pg as rspec
import geni.rspec.igext as IG
import geni.rspec.emulab.pnext as PN
import geni.rspec.emulab.emuext
import geni.urn as URN
import hashlib
import os
import socket
import struct

# ======== GLOBAL CONSTANTS ========
class GLOBALS(object):
    BIN_PATH = "/local/repository/bin"
    DEPLOY_SRS = BIN_PATH + "/deploy-srs.sh"
    TUNE_CPU = BIN_PATH + "/tune-cpu.sh"
    TUNE_B210 = BIN_PATH + "/tune-b210.sh"
    SETUP_SRSLTE = BIN_PATH + "/setup-srslte.sh"
    SETUP_IP_CONFIG = BIN_PATH + "/setup-ip-config.sh"
    UPDATE_ENB_CONFIG = BIN_PATH + "/update-enb-config-files.sh"
    UPDATE_UE_CONFIG = BIN_PATH + "/update-ue-config-files.sh"
    NUC_HWTYPE = "nuc5300"
    SRSLTE_IMG = "urn:publicid:IDN+emulab.net+image+PowderProfiles:U18LL-SRSLTE"

    # S1 LAN joining the eNodeBs and the core.  The core always has its own
    # address; when it is co-located on enb1 it is added there as a
    # secondary address, so the SGW-U and srsenb never share a GTP-U socket.
    S1_NETMASK = "255.255.255.0"
    CORE_IP = "10.20.20.10"
    ENB_S1_IP = {1: "10.20.20.2", 2: "10.20.20.3"}

    # Single test subscriber (Milenage), shared by all cores.
    UE_IMSI = "001010012345001"
    UE_IMEI = "353490012345001"
    UE_KEY = "00112233445566778899aabbccddeeff"
    UE_OPC = "63bfa50ee6523365ff14c1f45f88737d"
    UE_STATIC_IP = "192.168.0.10"  # srsEPC only

    # Default E2Term SCTP port per O-RAN mode: the O-RAN profile exposes
    # e2term as NodePort 32222 on the RIC node; the service port is 36422.
    E2TERM_PORT = {"control_net": "32222", "shared_vlan": "36422", "local": "36422"}

# ======== EXPERIMENT DESCRIPTION ========
tourDescription = """
### srsRAN S1 Handover w/ O-RAN Integration

This profile creates an LTE testbed with two eNodeBs for S1 handover experiments, connected to an O-RAN SC Near-RT RIC over E2.
It deploys srsRAN (the POWDER E2-enabled `srslte-ric` fork) on three Intel NUC nodes with B210 SDRs in a controlled RF environment.

#### **Architecture**
- **`ue` node**: srsUE with B210 SDR, RF-linked to both eNodeBs
- **`enb1` node**: srsENB (cell PCI 1), plus the core network unless a separate `epc` node is requested
- **`enb2` node**: srsENB (cell PCI 2), handover neighbor of `enb1`
- **`epc` node** (optional): core network
- **S1 LAN** (`10.20.20.0/24`): joins the eNodeBs and the core (core address `10.20.20.10`)

#### **Core network**
- **Open5GS** (default): its MME implements S1 handover
- **srsEPC**: lightweight, but its MME does **not** implement S1 handover

#### **O-RAN RIC connectivity**
- **Remote RIC over the control network** (default): eNodeBs reach the E2Term NodePort (32222) of a separate `PowderProfiles/O-RAN` experiment directly. No shared VLAN needed.
- **Remote RIC over a shared VLAN**: eNodeBs join a shared VLAN with the O-RAN experiment and route Kubernetes service subnets via its gateway.
- **Local RIC on enb1** (experimental): O-RAN SC RIC in `kind` on `enb1`.
"""

tourInstructions = """
### Instructions

#### **1. Start the RIC**

Start a `PowderProfiles/O-RAN` experiment (`https://www.powderwireless.net/p/PowderProfiles/O-RAN`) and wait for its setup to finish.
For the default control-network mode, set the `E2Term host` parameter of this profile to that experiment's node, e.g. `pc797.emulab.net`.
(If you did not know it at instantiation, pass it at run time: `E2TERM_SCTP=<ip> E2TERM_PORT=32222 /local/repository/bin/start-enb.sh`.)

On the RIC node, onboard and deploy the NexRAN xApp:
```bash
/local/setup/oran/dms_cli onboard /local/profile-public/nexran-config-file.json /local/setup/oran/xapp-embedded-schema.json
/local/setup/oran/dms_cli install nexran 0.1.0 ricxapp
```

#### **2. Wait for node setup**

`enb1` and `enb2` build srsRAN with E2 support (~15 min); the core is installed on `enb1` (or `epc`).
Setup output: `/var/tmp/startup-*.txt`; completion markers: `/local/setup/*-done`.

#### **3. Run an experiment with traces**

Copy `bin/ric-trace.sh` to the RIC node and start RIC-side collection; it prints a run id:
```bash
/local/logs/e2run/ric-trace.sh start
```
Then, with that run id, start (in order) `enb1`, `enb2`, and the `ue`:
```bash
/local/repository/bin/ran-run.sh start enb <run-id>     # on enb1 (starts the core too) and enb2
/local/repository/bin/ran-run.sh start ue <run-id>      # on ue; pings the core gateway (IPERF=1 adds iperf3)
```
Everything runs in tmux session `ran` (`tmux attach -t ran`). Stop each node with `ran-run.sh stop <role> <run-id>` and the RIC with `ric-trace.sh stop`;
each writes a bundle under `/local/logs/e2run/`.

Captures: E2AP (RIC node and each eNodeB), S1AP and MAC (eNodeBs), S1AP and Open5GS logs (core), MAC (UE), plus RIC component and xApp logs.
Decode E2 in Wireshark with *Decode As: SCTP port 32222 -> E2AP*.

#### **4. Drive handover**

The RF paths are attenuator-controlled. On any node, `/local/repository/bin/atten -l` lists the attenuator ids per path; raise the serving cell's path in steps:
```bash
for v in 25 30 35 40 45 50; do for id in <ids of serving path>; do /local/repository/bin/atten $id $v; done; sleep 4; done
```
Both cells are configured as each other's A3 neighbors (same EARFCN, PCI 1 and 2).

#### **5. Use NexRAN**

On the RIC node (`. /local/repository/demo/get-env.sh` first), register the eNodeBs (`id` 1 and 2, `mcc` 001, `mnc` 01) and the UE (`001010012345001`) with NexRAN; see `/local/repository/demo/run-nexran-slicing-4G.sh` for the API calls.
"""

# ======== PARAMETER DEFINITIONS ========
pc = portal.Context()

# Define parameter groups for better organization
pc.defineParameterGroup("hardware", "Hardware Configuration")
pc.defineParameterGroup("core", "Core Network")
pc.defineParameterGroup("oran", "O-RAN Integration")
pc.defineParameterGroup("networking", "Network Configuration")
pc.defineParameterGroup("advanced", "Advanced Options")

# Hardware Configuration - EPC is optional (if disabled, the core runs on enb1)
pc.defineParameter("deploy_epc_node", "Deploy separate EPC node", portal.ParameterType.BOOLEAN, False,
    longDescription="Deploy a separate core network node. If disabled, the core will run on the enb1 node.",
    groupId="hardware")
pc.defineParameter("epc_node", "Node for EPC", portal.ParameterType.STRING, "nuc1", groupId="hardware")
pc.defineParameter("enb1_node", "Node for eNB1", portal.ParameterType.STRING, "nuc2", groupId="hardware")
pc.defineParameter("enb2_node", "Node for eNB2", portal.ParameterType.STRING, "nuc4", groupId="hardware")
pc.defineParameter("ue_node", "Node for UE", portal.ParameterType.STRING, "nuc3", groupId="hardware")

# Core Network
pc.defineParameter("core_type", "Core network", portal.ParameterType.STRING, "open5gs",
    [("open5gs", "Open5GS (supports S1 handover)"), ("srsepc", "srsEPC (no S1 handover)")],
    longDescription="Core network software. srsEPC's MME does not implement S1 handover, so handover attempts time out in the source eNodeB; use Open5GS for handover experiments.",
    groupId="core")

# O-RAN Integration
pc.defineParameter("oran_mode", "O-RAN RIC connectivity", portal.ParameterType.STRING, "control_net",
    [("control_net", "Remote RIC over the control network"),
     ("shared_vlan", "Remote RIC over a shared VLAN"),
     ("local", "Local RIC on enb1 (experimental)"),
     ("none", "No RIC")],
    longDescription="How the eNodeB E2 agents reach a Near-RT RIC. 'control_net' connects directly to the E2Term NodePort of a separate PowderProfiles/O-RAN experiment over the POWDER control network. 'shared_vlan' connects over a shared VLAN and routes the RIC's Kubernetes subnets via its gateway. 'local' deploys the O-RAN SC RIC in kind on enb1.",
    groupId="oran")
pc.defineParameter("oran_e2term_host", "E2Term host", portal.ParameterType.STRING, "",
    longDescription="Address of the RIC's E2Term. For 'control_net', the control-network hostname or IP of the O-RAN experiment's node (e.g. pc797.emulab.net). For 'shared_vlan', the e2term SCTP service's cluster IP. Leave empty to supply it at run time via E2TERM_SCTP.",
    groupId="oran")
pc.defineParameter("oran_e2term_port", "E2Term SCTP port", portal.ParameterType.STRING, "",
    longDescription="E2Term SCTP port. Empty selects 32222 (the O-RAN profile's NodePort) for 'control_net' and 36422 otherwise.",
    groupId="oran")
pc.defineParameter(
    "oran_address", "O-RAN Services Gateway Address (shared VLAN)",
    portal.ParameterType.STRING, "10.254.254.1",
    longDescription="The IP address of the O-RAN services gateway running on an adjacent experiment connected to the same shared VLAN. Only used with 'shared_vlan'.",
    groupId="oran")
pc.defineParameter(
    "oran_virtual_subnets", "O-RAN Kubernetes Subnets to route via Gateway (shared VLAN)",
    portal.ParameterType.STRING, "10.96.0.0/12",
    longDescription="A space-separated list of subnets in CIDR format to route via the O-RAN Services Gateway Address. Only used with 'shared_vlan'.",
    groupId="oran")

# Network Configuration
pc.defineParameter("shared_vlan", "Shared VLAN name (shared VLAN mode only)", portal.ParameterType.STRING, "",
    longDescription="Name of an existing shared VLAN to connect to a remote O-RAN experiment. Required when O-RAN connectivity is 'shared_vlan'; ignored otherwise.",
    groupId="networking")
pc.defineParameter(
    "shared_vlan_netmask", "Shared VLAN IP Netmask",
    portal.ParameterType.STRING, "255.255.255.0",
    longDescription="Set the subnet mask for the shared VLAN interface. Only used with 'shared_vlan'.",
    groupId="networking")
pc.defineParameter(
    "shared_vlan_gateway", "Shared VLAN Gateway Address",
    portal.ParameterType.STRING, "192.168.1.1",
    longDescription="The gateway IP address for the shared VLAN subnet. Only used with 'shared_vlan'.",
    groupId="networking")
pc.defineParameter(
    "multiplex_lans", "Multiplex Networks",
    portal.ParameterType.BOOLEAN, True,
    longDescription="Multiplex any networks over physical interfaces using VLANs.",
    groupId="advanced")

# Advanced Options
pc.defineParameter(
    "install_vnc", "Install VNC on Compute Nodes",
    portal.ParameterType.BOOLEAN, False,
    longDescription="Install VNC on the compute nodes for remote desktop access.",
    groupId="advanced")

params = pc.bindParameters()

if params.oran_mode == "shared_vlan" and not params.shared_vlan:
    pc.reportError(portal.ParameterError(
        "Shared VLAN mode requires a shared VLAN name.", ["shared_vlan", "oran_mode"]))

pc.verifyParameters()

# ======== MAIN EXPERIMENT SETUP ========
request = pc.makeRequestRSpec()

if params.install_vnc:
    request.initVNC()

E2TERM_HOST = ""
E2TERM_PORT = ""
if params.oran_mode != "none":
    E2TERM_HOST = params.oran_e2term_host.strip()
    E2TERM_PORT = params.oran_e2term_port.strip() or GLOBALS.E2TERM_PORT[params.oran_mode]

# ======== HELPER FUNCTIONS ========
def next_ipv4_addr(base_addr_str, mask_str, offset):
    """
    Calculate the next IP address given a base address, netmask, and offset.
    """
    bai = struct.unpack(">i", socket.inet_aton(base_addr_str))[0]
    mi = struct.unpack(">i", socket.inet_aton(mask_str))[0]
    ni = bai + offset
    if bai & mi != ni & mi:
        raise Exception("insufficient space in netmask %s to increment %s + %d" % (
            mask_str, base_addr_str, offset))
    return socket.inet_ntoa(struct.pack(">i", ni))

def bin_cmd(script, *args):
    """
    Builds a command line for a script in the repository's bin directory.
    """
    return " ".join([GLOBALS.BIN_PATH + "/" + script] + ["'%s'" % (a,) for a in args])

def add_core_services(node):
    """
    Adds core network services (Open5GS or srsEPC) bound to the core address.
    """
    if params.core_type == "open5gs":
        sub = ",".join([GLOBALS.UE_IMSI, GLOBALS.UE_KEY, GLOBALS.UE_OPC])
        node.addService(rspec.Execute(shell="bash", command=bin_cmd(
            "setup-open5gs.sh", GLOBALS.CORE_IP, sub)))
    else:
        sub = ",".join([GLOBALS.UE_IMSI, GLOBALS.UE_KEY, GLOBALS.UE_OPC, GLOBALS.UE_STATIC_IP])
        node.addService(rspec.Execute(shell="bash", command=bin_cmd(
            "configure-srsepc.sh", GLOBALS.CORE_IP, sub)))

def add_epc_services(epc):
    """
    Adds services for the separate EPC node.
    """
    epc.addService(rspec.Execute(shell="bash", command="/local/repository/bin/tune-cpu.sh"))
    if params.core_type == "srsepc":
        epc.addService(rspec.Execute(shell="bash", command="/local/repository/bin/setup-srslte.sh"))
    add_core_services(epc)
    if params.install_vnc:
        epc.startVNC()

def add_ue_services(ue, ue_index):
    """
    Adds services for UE nodes following srslte-shvlan-oran pattern.
    """
    ue.addService(rspec.Execute(shell="bash", command="/local/repository/bin/tune-cpu.sh"))
    ue.addService(rspec.Execute(shell="bash", command="/local/repository/bin/tune-b210.sh"))
    ue.addService(rspec.Execute(shell="bash", command="/local/repository/bin/setup-srslte.sh"))
    # Generate UE configuration with unique IMSI
    imsi = "001010{:06d}{:03d}".format(12345, ue_index)
    imei = "353490{:06d}{:03d}".format(12345, ue_index)
    ue.addService(rspec.Execute(shell="bash", command="/local/repository/bin/update-ue-config-files.sh '%s,%s'" % (imsi, imei)))
    if params.install_vnc:
        ue.startVNC()

def add_enb_services(enb, enb_index):
    """
    Adds services for eNodeB nodes.  Order matters: Execute services run in
    sequence, so the srsRAN build and configuration come before the
    (long-running, failure-prone) local RIC deployment.
    """
    enb.addService(rspec.Execute(shell="bash", command="/local/repository/bin/tune-cpu.sh"))
    enb.addService(rspec.Execute(shell="bash", command="/local/repository/bin/tune-b210.sh"))
    enb.addService(rspec.Execute(shell="bash", command="/local/repository/bin/setup-srslte.sh"))

    ue_db = ",".join(["1", GLOBALS.UE_IMSI, GLOBALS.UE_IMEI, GLOBALS.UE_STATIC_IP])
    enb.addService(rspec.Execute(shell="bash", command=bin_cmd(
        "update-enb-config-files.sh", "0x{:03x}".format(enb_index), ue_db)))

    # Core co-located on enb1: give it its own S1 LAN address.
    if enb_index == 1 and not params.deploy_epc_node:
        enb.addService(rspec.Execute(shell="bash", command=bin_cmd(
            "setup-core-addr.sh", GLOBALS.CORE_IP)))
        add_core_services(enb)

    # Remote O-RAN over the shared VLAN: route the RIC's Kubernetes subnets
    # via its gateway (before configure-enb.sh resolves the E2 source address).
    if params.oran_mode == "shared_vlan":
        enb.addService(rspec.Execute(shell="bash", command="/local/repository/bin/setup-ip-config.sh %s '%s'" % (params.oran_address, params.oran_virtual_subnets)))

    # Cell identity and handover neighbor: ECI = (enb_id << 8) | cell_id,
    # with cell_id = enb_index for both eNodeBs.
    nbr_index = 2 if enb_index == 1 else 1
    enb.addService(rspec.Execute(shell="bash", command=bin_cmd(
        "configure-enb.sh",
        GLOBALS.ENB_S1_IP[enb_index], GLOBALS.CORE_IP,
        "0x{:02x}".format(enb_index), str(enb_index),
        "0x{:05x}".format((nbr_index << 8) | nbr_index), str(nbr_index),
        E2TERM_HOST, E2TERM_PORT)))

    # Deploy O-RAN RIC locally on eNB1 if enabled (only on the primary eNodeB)
    if params.oran_mode == "local" and enb_index == 1:
        enb.addService(rspec.Execute(shell="bash", command="/local/repository/bin/setup-oran-local.sh"))

    if params.install_vnc:
        enb.startVNC()

def create_interface(node, iface_name, ip_address=None, vlan_name=None):
    """
    Creates an interface for the node.
    """
    iface = node.addInterface(iface_name)
    if ip_address:
        iface.addAddress(rspec.IPv4Address(ip_address, GLOBALS.S1_NETMASK))
    if vlan_name:
        iface.vlan_name = vlan_name
    return iface

def connect_shared_vlan(node, vlan_name, ip_address, netmask):
    """
    Connects the node to the shared VLAN with full configuration support.
    """
    iface = node.addInterface("ifSharedVlan")
    if ip_address:
        iface.addAddress(rspec.IPv4Address(ip_address, netmask))
    link = request.Link(node.name + "-shvlan")
    link.addInterface(iface)
    link.connectSharedVlan(vlan_name)
    if params.multiplex_lans:
        link.link_multiplexing = True
        link.best_effort = True

# ======== SETUP NODES ========
s1_ifaces = []

# Setup optional EPC node
if params.deploy_epc_node:
    epc = request.RawPC("epc")
    epc.hardware_type = GLOBALS.NUC_HWTYPE
    epc.component_id = params.epc_node
    epc.disk_image = GLOBALS.SRSLTE_IMG
    add_epc_services(epc)
    s1_ifaces.append(create_interface(epc, "epc_s1", GLOBALS.CORE_IP))

# Setup UE node
ue = request.RawPC("ue")
ue.hardware_type = GLOBALS.NUC_HWTYPE
ue.component_id = params.ue_node
ue.disk_image = GLOBALS.SRSLTE_IMG
ue.Desire("rf-controlled", 1)
add_ue_services(ue, 1)
ue_enb1_rf = create_interface(ue, "ue_enb1_rf")
ue_enb2_rf = create_interface(ue, "ue_enb2_rf")

# Setup first eNodeB
enb1 = request.RawPC("enb1")
enb1.hardware_type = GLOBALS.NUC_HWTYPE
enb1.component_id = params.enb1_node
enb1.disk_image = GLOBALS.SRSLTE_IMG
enb1.Desire("rf-controlled", 1)
add_enb_services(enb1, 1)
enb1_ue_rf = create_interface(enb1, "enb1_ue_rf")
s1_ifaces.append(create_interface(enb1, "enb1_s1", GLOBALS.ENB_S1_IP[1]))

# Setup second eNodeB
enb2 = request.RawPC("enb2")
enb2.hardware_type = GLOBALS.NUC_HWTYPE
enb2.component_id = params.enb2_node
enb2.disk_image = GLOBALS.SRSLTE_IMG
enb2.Desire("rf-controlled", 1)
add_enb_services(enb2, 2)
enb2_ue_rf = create_interface(enb2, "enb2_ue_rf")
s1_ifaces.append(create_interface(enb2, "enb2_s1", GLOBALS.ENB_S1_IP[2]))

# ======== SETUP NETWORK LINKS ========
# Create RF links between eNodeBs and UE
rflink1 = request.RFLink("rflink1")
rflink1.addInterface(enb1_ue_rf)
rflink1.addInterface(ue_enb1_rf)

rflink2 = request.RFLink("rflink2")
rflink2.addInterface(enb2_ue_rf)
rflink2.addInterface(ue_enb2_rf)

# S1 LAN between the eNodeBs and the core (also usable for X2)
s1lan = request.LAN("s1lan")
for iface in s1_ifaces:
    s1lan.addInterface(iface)
if params.multiplex_lans:
    s1lan.link_multiplexing = True
    s1lan.best_effort = True

# Create shared VLAN only for remote O-RAN integration over a shared VLAN
if params.oran_mode == "shared_vlan":
    # Calculate IP addresses for each node using O-RAN address as base
    enb1_ip = next_ipv4_addr(params.oran_address, params.shared_vlan_netmask, 1)
    enb2_ip = next_ipv4_addr(params.oran_address, params.shared_vlan_netmask, 2)

    # Connect nodes to shared VLAN
    connect_shared_vlan(enb1, params.shared_vlan, enb1_ip, params.shared_vlan_netmask)
    connect_shared_vlan(enb2, params.shared_vlan, enb2_ip, params.shared_vlan_netmask)

# ======== TOUR INFORMATION ========
tour = IG.Tour()
tour.Description(IG.Tour.MARKDOWN, tourDescription)
tour.Instructions(IG.Tour.MARKDOWN, tourInstructions)
request.addTour(tour)

# Print the RSpec request
pc.printRequestRSpec(request)
