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
    NUC_HWTYPE = "nuc5300"
    SRSLTE_IMG = "urn:publicid:IDN+emulab.net+image+PowderProfiles:U18LL-SRSLTE"

# ======== EXPERIMENT DESCRIPTION ========
tourDescription = """
### srsRAN S1 Handover w/ O-RAN Integration

This profile allocates resources in a controlled RF environment for
experimenting with LTE handover and O-RAN integration. It deploys srsRAN on three nodes: UE, eNB1, and a fake eNB2.

**Key Features:**
- **Configurable O-RAN Integration**: Set custom gateway addresses and Kubernetes subnets during parameterization
- **Shared VLAN Support**: Connect to existing O-RAN experiments with customizable network settings
- **Handover Testing**: Experiment with S1 handover between multiple eNodeBs
- **RIC Connectivity**: Ready for O-RAN RIC agent integration

**Parameterization Options:**
- Customize O-RAN gateway address (default: 10.254.254.1)
- Configure Kubernetes subnets for routing (default: 10.96.0.0/12)
- Set shared VLAN parameters to match your O-RAN experiment
"""

tourInstructions = """
### Instructions

**Prerequisites:** If using O-RAN integration, ensure you have an O-RAN experiment running 
on the same shared VLAN with services accessible at the configured O-RAN gateway address.

1. **Start EPC services on `enb1`:**
   ```
   sudo srsepc
   ```

2. **Start the `srsenb` service with RIC agent configuration:**
   ```
   sudo srsenb --ric.agent.remote_ipv4_addr=${E2TERM_IP} --log.all_level=warn --ric.agent.log_level=debug --log.filename=stdout
   ```
   (Replace `${E2TERM_IP}` with the actual O-RAN E2Term service IP if using O-RAN integration)

3. **Start the UE and observe handover events:**
   ```
   sudo srsue
   ```
   
4. **Monitor handover between `enb1` and `fake_enb`** and observe O-RAN RIC interactions if configured.
"""

# ======== PARAMETER DEFINITIONS ========
pc = portal.Context()

# Define parameter groups for better organization
pc.defineParameterGroup("hardware", "Hardware Configuration")
pc.defineParameterGroup("networking", "Network Configuration") 
pc.defineParameterGroup("oran", "O-RAN Integration")
pc.defineParameterGroup("advanced", "Advanced Options")

pc.defineParameter("enb1_node", "Node for eNB1", portal.ParameterType.STRING, "nuc2", groupId="hardware")
pc.defineParameter("enbfake_node", "Node for fake eNB", portal.ParameterType.STRING, "nuc4", groupId="hardware")
pc.defineParameter("ue_node", "Node for UE", portal.ParameterType.STRING, "nuc1", groupId="hardware")
# Network Configuration
pc.defineParameter("shared_vlan", "Shared VLAN name (optional)", portal.ParameterType.STRING, "", 
    longDescription="Name of an existing shared VLAN to connect to O-RAN experiment. Leave empty if not using O-RAN integration.",
    groupId="networking")
pc.defineParameter(
    "shared_vlan_netmask", "Shared VLAN IP Netmask",
    portal.ParameterType.STRING, "255.255.255.0",
    longDescription="Set the subnet mask for the shared VLAN interface.", 
    groupId="networking")
pc.defineParameter(
    "shared_vlan_gateway", "Shared VLAN Gateway Address",
    portal.ParameterType.STRING, "192.168.1.1",
    longDescription="The gateway IP address for the shared VLAN subnet. This should match the subnet used by your O-RAN experiment.", 
    groupId="networking")
pc.defineParameter(
    "multiplex_lans", "Multiplex Networks",
    portal.ParameterType.BOOLEAN, True,
    longDescription="Multiplex any networks over physical interfaces using VLANs.", 
    groupId="advanced")

# O-RAN Integration Parameters
pc.defineParameter(
    "oran_address", "O-RAN Services Gateway Address",
    portal.ParameterType.STRING, "10.254.254.1",
    longDescription="The IP address of the O-RAN services gateway running on an adjacent experiment connected to the same shared VLAN. Change this to match your O-RAN experiment's gateway address.",
    groupId="oran")
pc.defineParameter(
    "oran_virtual_subnets", "O-RAN Kubernetes Subnets to route via Gateway",
    portal.ParameterType.STRING, "10.96.0.0/12",
    longDescription="A space-separated list of subnets in CIDR format to route via the O-RAN Services Gateway Address. Common values: '10.96.0.0/12' for default Kubernetes, '10.244.0.0/16' for some CNI configurations.",
    groupId="oran")

# Advanced Options
pc.defineParameter(
    "install_vnc", "Install VNC on Compute Nodes",
    portal.ParameterType.BOOLEAN, False,
    longDescription="Install VNC on the compute nodes for remote desktop access.", 
    groupId="advanced")

params = pc.bindParameters()
pc.verifyParameters()

# ======== MAIN EXPERIMENT SETUP ========
request = pc.makeRequestRSpec()

if params.install_vnc:
    request.initVNC()

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

def add_services(node, role):
    """
    Adds common services to the node, such as CPU tuning and srsLTE setup.
    """
    # Add O-RAN IP configuration for eNodeB nodes
    if role in ["eNodeB", "Fake eNodeB"] and params.shared_vlan:
        node.addService(rspec.Execute(shell="bash", command="/local/repository/bin/setup-ip-config.sh %s '%s'" % (params.oran_address, params.oran_virtual_subnets)))
    
    node.addService(rspec.Execute(shell="bash", command=GLOBALS.DEPLOY_SRS))
    node.addService(rspec.Execute(shell="bash", command=GLOBALS.TUNE_CPU))
    if params.install_vnc:
        node.startVNC()

def create_node(name, component_id, role):
    """
    Creates a node with the specified name and hardware type.
    """
    node = request.RawPC(name)
    node.hardware_type = GLOBALS.NUC_HWTYPE
    node.component_id = component_id
    node.disk_image = GLOBALS.SRSLTE_IMG
    node.Desire("rf-controlled", 1)
    add_services(node, role)
    return node

def create_interface(node, iface_name, ip_address=None, vlan_name=None):
    """
    Creates an interface for the node.
    """
    iface = node.addInterface(iface_name)
    if ip_address:
        iface.addAddress(rspec.IPv4Address(ip_address, "255.255.255.0"))
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
# Setup UE node
ue = create_node("ue", params.ue_node, "UE")
ue_enb1_rf = create_interface(ue, "ue_enb1_rf")
ue_enb_fake_rf = create_interface(ue, "ue_enb_fake_rf")

# Setup first eNodeB
enb1 = create_node("enb1", params.enb1_node, "eNodeB")
enb1_ue_rf = create_interface(enb1, "enb1_ue_rf")

# Setup fake eNodeB
enb_fake = create_node("fake_enb", params.enbfake_node, "Fake eNodeB")
enb_fake_ue_rf = create_interface(enb_fake, "enb_fake_ue_rf")

# ======== SETUP NETWORK LINKS ========
# Create RF links
rflink1 = request.RFLink("rflink1")
rflink1.addInterface(enb1_ue_rf)
rflink1.addInterface(ue_enb1_rf)

rflink_fake = request.RFLink("rflink_fake")
rflink_fake.addInterface(enb_fake_ue_rf)
rflink_fake.addInterface(ue_enb_fake_rf)

# Create shared VLAN if specified
if params.shared_vlan:
    # Calculate IP addresses for each node using O-RAN address as base
    enb1_ip = next_ipv4_addr(params.oran_address, params.shared_vlan_netmask, 1)
    fake_enb_ip = next_ipv4_addr(params.oran_address, params.shared_vlan_netmask, 2)
    
    # Connect nodes to shared VLAN
    connect_shared_vlan(enb1, params.shared_vlan, enb1_ip, params.shared_vlan_netmask)
    connect_shared_vlan(enb_fake, params.shared_vlan, fake_enb_ip, params.shared_vlan_netmask)

# ======== TOUR INFORMATION ========
tour = IG.Tour()
tour.Description(IG.Tour.MARKDOWN, tourDescription)
tour.Instructions(IG.Tour.MARKDOWN, tourInstructions)
request.addTour(tour)

# Print the RSpec request
pc.printRequestRSpec(request)
