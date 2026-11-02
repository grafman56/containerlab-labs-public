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

## as-override on the firewall
`l2` is in AS 65000 and peers with `fw` in two VRFs. A prefix from one zone returns
with 65000 in the path and the leaf drops it as a loop. `as-override` on `fw` is the
PE-side fix from RFC 4364. `allowas-in` on the leaf also works. A default route
only would avoid it and show less routing.
*Rule: loop prevention is a feature. Turn it off in one place, for a known reason.*

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
