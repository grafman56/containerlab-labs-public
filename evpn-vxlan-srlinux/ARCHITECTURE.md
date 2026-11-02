# Architecture: why the lab looks like this

Each decision, then the general rule behind it.

## SR Linux leaves, FRR spines
The VLAN to VNI binding lives where VXLAN starts and ends: the leaves. The spines
only run the OSPF underlay and relay EVPN routes. They never see a VNI.
So the leaves run SR Linux, where the binding is readable config, and the spines
run FRR, which saves about 3 GB.
*Rule: put the expensive, realistic node only where the thing you want to study lives.*

## The mapping chain, and where it stops
`VLAN -> VNI -> VRF -> border-leaf link -> firewall interface -> zone`.
The VNI ends at the border leaf. A firewall sees a routed link or a VLAN tag.
The lab keeps the chain consistent in data: `topology.yml` for the fabric,
`fw-zones.nft` for zones, `publish.py` for tags.
*Rule: an identifier that stops at a boundary must be carried across as data, not assumed.*

## One routed link and one eBGP session per VRF
The border leaf hands each VRF to the firewall on its own link. This is VRF-lite
to a firewall, the common campus pattern. BGP carries prefixes only. It does not
carry users, and PAN-OS does not map communities to zones.
*Rule: routing says where to send; identity says who is sending. Different systems.*

## The firewall is two things
The emulator is the PAN-OS management plane: API, User-ID, rules, policy match. It
does not forward packets. `fw` (FRR plus nftables) is the data path, so a ping
tests something real. The emulator mirrors `fw` for interfaces and zones.
The two rulebases are separate and kept in step by hand.
*Rule: when a tool cannot do the whole job, pair it with a stand-in and say where the seam is.*

## fw sends each VRF only a default route
`fw` learns every prefix from both VRFs but advertises only `0.0.0.0/0` back into
each one. My first version re-advertised each zone's prefixes. `l2` peers with `fw`
in two VRFs from one AS, so those routes came back with its own ASN in the path
and were dropped as a loop. `as-override` hid that, but a second loop remained
(see next section). Default-only avoids both, and it is what a campus edge sends.
*Rule: a firewall is a routing stub for the fabric. Give it everything, ask for a default.*

## OSPF is off inside the VRFs
netlab's `ospf` module also runs OSPF in each VRF, between the two leaves over the
IRB, and redistributes it into the BGP session to `fw`. The two protocols then
passed the same prefixes back and forth. A traceroute showed the packet bouncing
between `l1` and `l2`, and `fw` counted zero packets. `ospf: false` on both VRFs
fixes it. Underlay OSPF in the default VRF is unaffected.
*Rule: when a tool enables a protocol everywhere, check where you did not mean it.*

## Rules in the emulator drive the data path
`sync-fw.py` reads the emulator's committed rules, tags and user mappings and
rewrites one nftables chain on `fw`. A rule on `source-tag vni:1010` becomes the
set of addresses tagged that way, so a tag change plus a sync moves the policy
with no prefix in the rule. It also flushes conntrack, so a changed rule applies
at once. The two rulebases are still two systems: the sync is one way, from
emulator to `fw`, and runs when you run it.
*Rule: one source of truth for policy, one explicit step to push it.*

## Tags carry the VNI
`publish.py` sends `vlan:`, `vni:` and `vrf:` tags with each login. A rule can then
say "source-tag vni:1010" and hold no prefix. The fabric took location out of the
address; a tag puts it back from the control plane.
*Rule: when the network stops encoding a fact in the address, publish it as an attribute.*

## Container names and ssh access
Containers use the default `clab-<lab>-<node>` names, as every other lab does.
The access path is host SSH, then `docker exec`.
*Rule: follow the convention operators already type.*

## Pinned: ansible-core below 2.21
With 2.21.5, `netlab initial` failed: the `paramiko` connection plugin was not
found. 2.20.10 works. Only this one version pair was tested.
