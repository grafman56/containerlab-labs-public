# Small OSPF EVPN-VXLAN Lab

> **Limitation: no VLAN-to-VNI mapping.** Containerlab runs FRR on the host's Linux kernel, so these labs use the traditional VXLAN model: one VXLAN device per VNI, each in its own non-VLAN-aware bridge. There is no VLAN-to-VNI mapping table as on a hardware leaf, and host ports are untagged. Treat a bridge and its VNI as the "VLAN". See [FRR EVPN: VLAN-aware bridges and single VXLAN devices](https://docs.frrouting.org/en/stable-10.7/evpn.html).

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
