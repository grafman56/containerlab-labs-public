# Architecture: why the lab looks like this

Each decision, then the general rule behind it.

## Two leaves, one Ethernet Segment
The lab answers one question: how does a host connect to two leaves without an MLAG
peer link? Two leaves are enough to show the segment, the DF election, link failure and
recovery. A third leaf would add a remote view of aliasing and mass withdraw. It also
adds an SR Linux node, which costs about 2 GB. The README lists this as a limit.
*Rule: build the smallest topology that can show the thing you study. Name what it cannot show.*

## SR Linux leaves, FRR spines
Spines relay EVPN routes and run the OSPF underlay. They never see a VLAN, a VNI or an
ESI, as on a real fabric. The leaves hold the mapping and the segment, so they run
SR Linux, where both are readable config. FRR spines save about 3 GB.
*Rule: put the expensive, realistic node only where the thing you want to study lives.*

## EVPN multihoming, not MLAG
The leaves share an ESI and coordinate with route types 1 and 4 over the existing
BGP sessions. There is no peer link, no keepalive link and no MLAG domain. A leaf
needs no cable to its partner.
*Rule: if the control plane already carries the state, do not add a second channel for it.*

## Same ESI and same LACP system ID on both leaves
The ESI makes the two leaves one Ethernet Segment for the rest of the fabric. The LACP
system ID makes them one switch for the host. These are two separate identities for two
separate audiences, and both must match. README tests 4 and 5 break each one on purpose.
*Rule: when one device is shown as two, check what each audience uses to tell devices apart.*

## post-up.sh holds the ESI config, not netlab
netlab 26.10 has an EVPN multihoming plugin, but its templates cover EOS only. The lab
uses netlab for what it does well (underlay, EVPN, VLAN to VNI) and adds the ESI with
`sr_cli` in one script. The cost: `netlab up` alone does not give a working ESI. The
script is safe to run again.
*Rule: use the generator for the common part. Keep the part it cannot do in one visible, re-runnable place.*

## Do not set `ifname` on SR Linux ports
`ifname: ethernet-1/10` made netlab write config for port 10 while Containerlab cabled
the next free port (`e1-4`). LACP never came up and `lag1` said `lower-layer-down`.
The topology now leaves the name to netlab, and `post-up.sh` names port 1/4 in one
variable, with a comment on why.
*Rule: when two tools name the same object, let one of them choose.*

## The host bond is set through sysfs
The host image has BusyBox `ip`. It accepted `ip link add type bond` and ignored the
options, so the first bond ran in round-robin mode with no LACP. Writing mode, miimon
and the hash policy to `/sys/class/net/bond0/bonding/` works with the same image.
*Rule: a command that succeeds is not proof that it did what you asked. Read the result back.*

## Layer 2 only
One VLAN in bridge mode, no VRF, no gateway. ESI is a Layer 2 feature. Symmetric IRB
and type 5 routes are covered by the other labs. Adding them here would hide the
routes this lab is about.
*Rule: remove every feature that does not serve the question.*

## verify.sh breaks things and always restores them
The check cuts each leaf's port to `h3` and proves the host stays reachable. A trap
sets both ports back to `enable` when the script exits, even after a failure. It waits
for LACP and the DF candidates to return before it moves on.
*Rule: a test that changes state must restore it on every exit path.*

## Single-active is a test, not the default
In single-active mode the non-DF leaf drops traffic that the host sends to it. A host
that uses both links of an LACP bond loses traffic. The lab runs all-active, and README
test 3 shows the loss on purpose.
*Rule: a fabric mode must match the host's behavior. Test the mismatch, then keep the matched pair.*
