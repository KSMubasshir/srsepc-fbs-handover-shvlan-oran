#!/usr/bin/env python
import geni.portal as portal
import geni.rspec.pg as rspec
import geni.rspec.igext as IG

# ======== GLOBAL CONSTANTS ========
class GLOBALS(object):
    BIN_PATH = "/local/repository/bin"
    DEPLOY_SRS = f"{BIN_PATH}/deploy-srs.sh"
    TUNE_CPU = f"{BIN_PATH}/tune-cpu.sh"
    NUC_HWTYPE = "nuc5300"
    SRSLTE_IMG = "urn:publicid:IDN+emulab.net+image+PowderProfiles:U18LL-SRSLTE"

# ======== EXPERIMENT DESCRIPTION ========
tourDescription = """
### srsRAN S1 Handover w/ Open5GS

This profile allocates resources in a controlled RF environment for
experimenting with LTE handover. It deploys srsRAN on three nodes: UE, eNB1, and a fake eNB2.
"""

tourInstructions = """
### Instructions

1. Start EPC services on `enb1`.
2. Start the `srsenb` service with the RIC agent configuration.
3. Start the UE and observe handover events between `enb1` and `fake_enb`.
"""

# ======== PARAMETER DEFINITIONS ========
pc = portal.Context()
pc.defineParameter("enb1_node", "Node for eNB1", portal.ParameterType.STRING, "nuc2", advanced=True)
pc.defineParameter("enbfake_node", "Node for fake eNB", portal.ParameterType.STRING, "nuc4", advanced=True)
pc.defineParameter("ue_node", "Node for UE", portal.ParameterType.STRING, "nuc1", advanced=True)
pc.defineParameter("shared_vlan", "Shared VLAN name (optional)", portal.ParameterType.STRING, "", advanced=True)

params = pc.bindParameters()
pc.verifyParameters()

# ======== MAIN EXPERIMENT SETUP ========
request = pc.makeRequestRSpec()

# ======== HELPER FUNCTIONS ========
def add_services(node, role):
    """
    Adds common services to the node, such as CPU tuning and srsLTE setup.
    """
    node.addService(rspec.Execute(shell="bash", command=GLOBALS.DEPLOY_SRS))
    node.addService(rspec.Execute(shell="bash", command=GLOBALS.TUNE_CPU))

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

def connect_shared_vlan(node, vlan_name, ip_address):
    """
    Connects the node to the shared VLAN.
    """
    iface = node.addInterface("shared_vlan_iface")
    iface.addAddress(rspec.IPv4Address(ip_address, "255.255.255.0"))
    link = request.Link(node.name + "_shared_vlan")
    link.addInterface(iface)
    link.connectSharedVlan(vlan_name)

# ======== SETUP NODES ========
# Setup UE node
ue = create_node("ue", params.ue_node, "UE")
ue_enb1_rf = create_interface(ue, "ue_enb1_rf")
ue_enb_fake_rf = create_interface(ue, "ue_enb_fake_rf")

# Setup first eNodeB
enb1 = create_node("enb1", params.enb1_node, "eNodeB")
enb1_s1_if = create_interface(enb1, "enb1_s1_if", "192.168.1.3", params.shared_vlan)
enb1_ue_rf = create_interface(enb1, "enb1_ue_rf")

# Setup fake eNodeB
enb_fake = create_node("fake_enb", params.enbfake_node, "Fake eNodeB")
enb_fake_s1_if = create_interface(enb_fake, "enb_fake_s1_if", "192.168.1.5", params.shared_vlan)
enb_fake_ue_rf = create_interface(enb_fake, "enb_fake_ue_rf")

# ======== SETUP NETWORK LINKS ========
# Create RF links
rflink1 = request.RFLink("rflink1")
rflink1.addInterface(enb1_ue_rf)
rflink1.addInterface(ue_enb1_rf)

rflink_fake = request.RFLink("rflink_fake")
rflink_fake.addInterface(enb_fake_ue_rf)
rflink_fake.addInterface(ue_enb_fake_rf)

# Create S1 links if shared VLAN is not specified
if params.shared_vlan:
    connect_shared_vlan(enb1, params.shared_vlan, "192.168.1.3")
    # connect_shared_vlan(enb_fake, params.shared_vlan, "192.168.1.5")
else:
    s1_link = request.LAN("s1_lan")
    s1_link.addInterface(enb1_s1_if)
    s1_link.link_multiplexing = True
    s1_link.vlan_tagging = True

    fake_s1_link = request.LAN("fake_s1_lan")
    fake_s1_link.addInterface(enb_fake_s1_if)
    fake_s1_link.link_multiplexing = True
    fake_s1_link.vlan_tagging = True

# ======== TOUR INFORMATION ========
tour = IG.Tour()
tour.Description(IG.Tour.MARKDOWN, tourDescription)
tour.Instructions(IG.Tour.MARKDOWN, tourInstructions)
request.addTour(tour)

# Print the RSpec request
pc.printRequestRSpec(request)
