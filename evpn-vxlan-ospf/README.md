# Small OSPF EVPN-VXLAN Lab

> **Limitation: VLAN-to-VNI mapping is not in the FRR config.** FRR (`vtysh`) has no command that maps a VLAN to a VNI, unlike NX-OS or Junos. FRR only discovers the VNIs that already exist in the Linux kernel (`advertise-all-vni`). The mapping is part of how the Containerlab nodes are built: the bridge and VXLAN devices created by each node's setup script (`scripts/`) or `exec` lines in the topology file. To add or change a VLAN-to-VNI mapping, change those scripts, not `configs/*.conf`. These labs use one bridge per VNI and untagged host ports. FRR learns this state from the kernel over Netlink and does not create or manage these interfaces. FRR recommends single VXLAN devices (SVD), but these labs use the older traditional model. See [The Linux VXLAN dataplane](https://docs.frrouting.org/en/latest/evpn.html#the-linux-vxlan-dataplane).

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
