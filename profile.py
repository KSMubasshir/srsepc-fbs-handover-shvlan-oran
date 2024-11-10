#!/usr/bin/env python
import os
import geni.portal as portal
import geni.rspec.pg as rspec
import geni.rspec.igext as IG

# ======== GLOBAL CONSTANTS ========
class GLOBALS(object):
    BIN_PATH = "/local/repository/bin"
    DEPLOY_SRS = os.path.join(GLOBALS.BIN_PATH, "deploy-srs.sh")
    TUNE_CPU = os.path.join(GLOBALS.BIN_PATH, "tune-cpu.sh")
    NUC_HWTYPE = "nuc5300"
    UBUNTU_1804_IMG = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU18-64-STD"
    SRSLTE_IMG = "urn:publicid:IDN+emulab.net+image+PowderProfiles:U18LL-SRSLTE"

# ======== EXPERIMENT DESCRIPTION ========
tourDescription = """
### srsRAN S1 Handover w/ Open5GS

This profile allocates resources in a controlled RF environment for
experimenting with LTE handover. It deploys srsRAN on three nodes, each
consisting of a NUC5300 compute node and a B210 SDR, in our RF attenuator
matrix. One node serves as the UE, while the other two serve as "neighboring"
eNBs. A command line tool is provided that allows you to change the amount 
of attenuation on the paths between the UE and both eNBs in order to simulate 
mobility and trigger S1 handover events.
## srsLTE Controlled/Indoor RF with O-RAN support

---

IMPORTANT: DO NOT start this expirment until you have first instantiated a
companion O-RAN experiment via the following profile:

  https://www.powderwireless.net/p/PowderProfiles/O-RAN

Furthermore, DO NOT start the srsLTE services in that experiment as
directed.  See the instructions in this profile for more information.

---

Use this profile to instantiate an end-to-end srsLTE network in a controlled RF
environment (wired connections between UE and eNB).

The following resources will be allocated:

  * Intel NUC5300/B210 w/ srsLTE UE(s) 
    * 1 or 2, depending on "Number of UEs" parameter: `rue1`, `rue2`
  * Intel NUC5300/B210 w/ srsLTE eNB/EPC (`enb1`)
"""
tourInstructions = """

### Prerequisites: O-RAN Setup

You should have already started up an O-RAN experiment connected to
the same shared VLAN you specified during the "parameterize" step.
Make sure it is up and fully deployed first - see the instructions
included in that profile.  However, DO NOT start the srsLTE components
or `kpimon` xApp as directed in those instructions.

Make note of the `e2term-sctp` service's IP address in the O-RAN
experiment.  To do that, open an SSH session to `node-0` in that
experiment and run:

```
# Extract `e2term-sctp` IP address
kubectl get svc -n ricplt --field-selector metadata.name=service-ricplt-e2term-sctp-alpha -o jsonpath='{.items[0].spec.clusterIP}'
```

You will need this address when starting the srsLTE eNodeB service.

### Start EPC and eNB

Login to `enb1` via `ssh` and start the srsLTE EPC services:

```
# start srsepc
sudo srsepc
```

Then in another SSH session on `enb1`, start the eNB service.
Substitute the IP address (or set it as an environment variable) in
this command for the one captured for the `e2term-sctp` O-RAN service
in the previous step.

```
# start srsenb (with agent connectivity to O-RAN RIC)
sudo srsenb --ric.agent.remote_ipv4_addr=${E2TERM_IP} --log.all_level=warn --ric.agent.log_level=debug --log.filename=stdout
```

There will be output in srsenb and the O-RAN e2term mgmt and other
service logs showing that the enb has connected to the O-RAN RIC.

### Start the `kpimon` xApp

Go back to the instructions in the O-RAN profile and follow the steps
for starting the `kpimon` xApp (start with step 3 under "Running the
O-RAN/srsLTE scp-kpimon demo").

You should start seeing `srsenb` send periodic reports once the
`kpimon` xApp starts.  These will appear in the `kpimon` xApp log
output as well in the srsenb output.

### Start the srsLTE UE

SSH to `rue1` and run:

```
sudo srsue
```

You should see changes in the `kpimon` output when `srsue` is
connected.  Try pinging `172.16.0.1` (the srs SPGW gateway address)
from the UE and watch the `kpimon` counters tick.

Note: this profile includes startup scripts that download, install, and
configure the required software stacks. After the experiment becomes ready, wait
until the "Startup" column on the "List View" tab indicates that the startup
scripts have finished on all of the nodes before proceeding.

#### Overview

In the following example, the `ue` will start out camped on `enb1`, with the
matrix path corresponding to the downlink between `enb1` and `ue` being
unattenuated. `enb2` will also be running, but we'll attenuate the downlink to
simulate the `ue` being out of range for the cell it provides. Then we'll
introduce some attentuation for the `enb1` downlink, simulating the UE being
closer to the edge of that cell. Finally, we'll incrementally reduce the
attenuation for the `enb2` downlink, simulating the `ue` moving closer to
`enb2`. At some point, the `ue` will start reporting better downlink signal
quality for `enb2` than for `enb1`, as indicated by RSRP measurements in srsRAN,
and eventually a handover from `enb1` to `enb2` will be triggered.

#### Instructions

```
# on enb_real
sudo srsenb /etc/srsran/enb.conf
```

```
# on enb_fake
sudo srsenb /etc/srsran/enb.conf
```

You should see indications of S1 connection establishment for each eNB in the
MME log.

Next, use the provided command line tool identify the attenuator IDs for the eNB
downlinks, and attenuate the downlink path between `enb2` and `ue`. This tool
can be used on any node in your experiment. Here's the help output for the tool
for reference:


Use the `-l` flag to produce a list of node pairs and corresponding attenuator
IDs. Here's the output for an example experiment:

```
$ /local/repository/bin/atten -l
2,33:nuc1/nuc2
4,35:nuc1/nuc4
```


In our example, this path corresponds to the LTE downlink
between `enb2` and `ue`. Attenuate this path by 40 dB initially:

```
/local/repository/bin/atten 35 40
```

Ensure that the dowlink path for `enb1` is set to 0:

```
/local/repository/bin/atten 33 0
```

Now open an SSH session on `ue` and start the srsRAN UE:

```
sudo srsue
```

The UE should immediately sync with `enb1`. Pressing `t` and `<return>` will
cause `srsue` to begin printing various metrics to `stdout`:

```
---------Signal----------|-----------------DL-----------------|-----------UL-----------
 cc  pci  rsrp  pl   cfo | mcs  snr  iter  brate  bler  ta_us | mcs   buff  brate  bler
  0    1   -72  72   401 |  14   37   0.5   1.6k    0%    0.5 |  24    0.0   8.5k    0%
  0    1   -72  72   402 |  14   36   0.5   1.6k    0%    0.5 |  24    0.0   8.5k    0%
  0    1   -72  72   403 |  14   37   0.5   1.6k    0%    0.5 |  24    0.0   8.5k    0%
  0    1   -72  72   402 |  14   37   0.5   1.6k    0%    0.5 |  24    0.0   8.5k    0%
```

The physical cell identifier (PCI) and reference signal received power (RSRP)
columns in the "Signal" section will be of interest. The PCI indicates which
cell the UE is currently attached to. This profile configures `enb1` and `enb2`
to have PCIs 1 and 2, respectively. RSRP represents the average power of
resource elements containing reference signals on the downlink. The UE reports
RSRP values for the current and neighboring cells back to the the current cell,
which decides if/when handover should occur.

In another SSH session on `ue`, start a ping process pointed at the EPC:

```
ping 172.16.0.1
```

This will keep the UE from going idle while you are adjusting gains, and allow
you to verify that the packet data connection remains intact across handover
events.

Next, add some attenuation to the downlink for `enb1`:

```
/local/repository/bin/atten 33 10
```

Observe the changes in the metrics reported by the UE. The RSRP measurements
for the current cell will drop by around 10 dB, and the UE may start reporting
measurements for the "neighbor" cell `enb2`.

Add some more attenuation to the `enb1` downlink:

```
/local/repository/bin/atten 33 20
```

Again, the RSRP will degrade by around 10 dB, and the UE is almost certain to
start reporting measurements for `enb2`:

```

Next, start incrementally decreasing the attenuation for the `enb2` downlink.
Steps of 5 or 10 dB work well. Larger steps may result in a failed handover.
When you get to 20 dB attenuation for the `enb2` downlink. The RSRP measurements
will be similar for both cells:

```
/local/repository/bin/atten 35 20
```

At this point, another 10 dB reduction in attenuation for the `enb2` downlink
should trigger a handover. `enb1` will indicate that it is starting an S1
handover and the UE will indicate that it has received a handover command and
attach to `enb2`:


Notice that the UE now indicates that it is attached to `enb2` (PCI 2) and is
reporting measurements for `enb1` (PCI 1) as a neigbor cell. You can continue to
adjust downlink attenuation levels to trigger more handover events.
"""

# ======== PARAMETER DEFINITIONS ========
pc = portal.Context()
pc.defineParameter("enb1_node", "PhantomNet NUC+B210 for first eNodeB",
                   portal.ParameterType.STRING, "nuc2", advanced=True,
                   longDescription="Specific eNodeB node to bind to.")
pc.defineParameter("enbfake_node", "PhantomNet NUC+B210 for fake eNodeB",
                   portal.ParameterType.STRING, "nuc4", advanced=True,
                   longDescription="Specific fake eNodeB node to bind to.")
pc.defineParameter("ue_node", "PhantomNet NUC+B210 for UE",
                   portal.ParameterType.STRING, "nuc1", advanced=True,
                   longDescription="Specific UE node to bind to.")
pc.defineParameter("shared_vlan", "Shared VLAN name (optional)",
                   portal.ParameterType.STRING, "", advanced=True,
                   longDescription="Specify a shared VLAN if you want to connect to an existing shared network.")

params = pc.bindParameters()
pc.verifyParameters()

# ======== HELPER FUNCTIONS ========
def add_services(node, role):
    """
    Adds common services to the node, such as CPU tuning and srsLTE setup.
    """
    node.addService(rspec.Execute(shell="bash", command=GLOBALS.DEPLOY_SRS))
    node.addService(rspec.Execute(shell="bash", command=GLOBALS.TUNE_CPU))
    # print(f"Added services to {role}")

def create_node(name, component_id, role):
    """
    Creates a node with the specified name, hardware type, and role.
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
    Creates an interface for the node. If a VLAN name is provided, binds the interface to the shared VLAN.
    """
    iface = node.addInterface(iface_name)
    if ip_address:
        iface.addAddress(rspec.IPv4Address(ip_address, "255.255.255.0"))
    if vlan_name:
        iface.vlan_name = vlan_name
        # print(f"Interface {iface_name} connected to shared VLAN: {vlan_name}")
    return iface

# ======== MAIN EXPERIMENT SETUP ========
request = pc.makeRequestRSpec()

# Setup UE
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

# Create S1 links if shared VLAN is not specified
if not params.shared_vlan:
    s1_link = request.LAN("s1_lan")
    s1_link.addInterface(enb1_s1_if)
    s1_link.link_multiplexing = True
    s1_link.vlan_tagging = True
    s1_link.best_effort = True

    fake_s1_link = request.LAN("fake_s1_lan")
    fake_s1_link.addInterface(enb_fake_s1_if)
    fake_s1_link.link_multiplexing = True
    fake_s1_link.vlan_tagging = True
    fake_s1_link.best_effort = True
else:
    print("Using shared VLAN for S1 links.")

# Create RF links
rflink1 = request.RFLink("rflink1")
rflink1.addInterface(enb1_ue_rf)
rflink1.addInterface(ue_enb1_rf)

rflink_fake = request.RFLink("rflink_fake")
rflink_fake.addInterface(enb_fake_ue_rf)
rflink_fake.addInterface(ue_enb_fake_rf)

# ======== TOUR INFORMATION ========
tour = IG.Tour()
tour.Description(IG.Tour.MARKDOWN, tourDescription)
tour.Instructions(IG.Tour.MARKDOWN, tourInstructions)
request.addTour(tour)

# Print the RSpec request
pc.printRequestRSpec(request)
