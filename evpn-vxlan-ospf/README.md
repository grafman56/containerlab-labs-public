# Small OSPF EVPN-VXLAN Lab

> **Caveat: VLAN-to-VNI mapping.** A VLAN ID is local to one switch. A VNI is the fabric-wide segment ID. A real EVPN-VXLAN fabric needs an explicit VLAN-to-VNI mapping on every leaf (for example VLAN 10 on leaf1 and VLAN 110 on leaf2 can both map to VNI 1010). These labs do not model VLAN IDs on access ports. Each host port joins a Linux bridge that is bound to exactly one VNI, so the mapping is implied by the bridge. Build or extend the lab with an explicit VLAN-to-VNI table before you use it to explain VLAN design. Where the anycast gateway and border sit (leaf or spine) is a separate design choice.

Two spines and two leaves form a Clos underlay. OSPF area 0 advertises all
loopbacks and point-to-point links. The leaf VTEPs use iBGP EVPN over their
OSPF-reachable loopbacks to carry L2 VNI 1010 between `host1` and `host2`.

Run on a Containerlab host:

```bash
cd ~/labs/containerlab-managed/evpn-vxlan-ospf
sudo -n containerlab deploy -t evpn-vxlan-ospf.clab.yml --reconfigure
./verify.sh
```

The verifier checks all four OSPF adjacencies, the leaf EVPN session and type-3
routes, the VXLAN FDB, and `host1` to `host2` reachability. The original
`evpn-vxlan` eBGP-underlay lab remains separate and unchanged.
