# Small OSPF EVPN-VXLAN Lab

> **Note: the VLAN-to-VNI mapping is not an FRR setting.** FRR (`vtysh`) has no VLAN-to-VNI command. It only reads the VNIs that exist in the Linux kernel. The setup scripts in `scripts/` build that mapping into each node (bridge plus VXLAN device, one per VNI, untagged host ports). To change it, edit those scripts, not `configs/*.conf`. See [The Linux VXLAN dataplane](https://docs.frrouting.org/en/latest/evpn.html#the-linux-vxlan-dataplane).

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
