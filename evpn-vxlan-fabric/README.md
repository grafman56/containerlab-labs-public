# FRR EVPN-VXLAN: 4 Spines, 10 Leaves

> **Limitation: no VLAN-to-VNI mapping.** Containerlab runs FRR on the host's Linux kernel, so these labs use the traditional VXLAN model: one VXLAN device per VNI, each in its own non-VLAN-aware bridge. There is no VLAN-to-VNI mapping table as on a hardware leaf, and host ports are untagged. Treat a bridge and its VNI as the "VLAN". See [FRR EVPN: VLAN-aware bridges and single VXLAN devices](https://docs.frrouting.org/en/stable-10.7/evpn.html).

A larger Clos fabric than `evpn-vxlan/` (2 spines, 2 leaves): a routed eBGP
underlay, full-mesh loopback-based eBGP EVPN sessions between every leaf
and every spine, two L2 VNIs, and a VRF/L3VNI for inter-VNI routing
(symmetric IRB). Generated from a small script rather than hand-written,
so a 14-device fleet doesn't invite a copy-paste typo in some neighbor
statement.

## Topology

- 4 spines (AS 65000), 10 leaves (AS 65101-65110). Spines never peer with
  each other — every spine-to-spine path goes through a leaf, which is
  the point of a 2-tier Clos.
- Every leaf has an eBGP underlay session (directly connected) and a
  loopback-to-loopback multihop EVPN session to all 4 spines.
- VNI 1010 (`10.10.10.0/24`) is stretched to every leaf, one host each
  (`hostNa`).
- VNI 1020 (`10.20.20.0/24`) lives on leaf1-leaf3 only, one host each
  (`hostNb`), to exercise inter-VNI routing without doubling every host.
- VRF `TENANT-A` + L3VNI 4100 gives every leaf symmetric IRB: a host on
  VNI 1010 can reach a host on VNI 1020, same leaf or a different one,
  routed through the VRF rather than bridged.
- `ip access-list extended ACL-TENANT-A`, `route-map RM-TENANT-A-IN`, and
  `ip prefix-list PL-LOOPBACKS` / `route-map RM-UNDERLAY-IN` gate what
  gets redistributed into the tenant VRF and set local-preference on the
  underlay — real policy, not decoration.

## Editing the generated files

`configs/`, `scripts/`, and `evpn-vxlan-fabric.clab.yml` came from a
generator that is not part of this repository. If you change the fabric
shape (spine/leaf counts, VNI assignment, address plan), apply the same
change on every leaf and spine, then run `./verify.sh`. A change on one
node only will leave the fabric inconsistent.

## Deploy

```bash
docker pull quay.io/frrouting/frr:10.7.0
docker pull alpine:3.20
sudo -E containerlab deploy -t evpn-vxlan-fabric.clab.yml
./verify.sh
```

Allow ~30 seconds for the full underlay + EVPN mesh (14 BGP speakers) to
converge before the first verification run.

### Scoped lab control

From this directory: `./labctl check`, `./labctl up`, `./labctl verify`,
`./labctl status`, `./labctl down`. Every target is scoped to
`evpn-vxlan-fabric.clab.yml`; it does not touch `evpn-vxlan` or any other
lab. See `../PARALLEL_LABS.md` for the concurrent-lab runbook.

**After a host reboot**: containerlab-managed veth links do not survive a
clean reboot even though the containers restart on their own (Docker's
restart policy brings the containers back, but not the interfaces
containerlab wired between them). Redeploy with `--reconfigure` to
recreate the data-plane links, and `chown -R 100:101 runtime/` first if
FRR fails to start with "Permission denied" on its `/var/run/frr` bind
mount (that uid:gid is the `frr` user/group inside the container image).

## Learning checkpoints

```bash
docker exec clab-evpn-vxlan-fabric-leaf1 vtysh -c "show bgp summary"
docker exec clab-evpn-vxlan-fabric-leaf1 vtysh -c "show bgp l2vpn evpn summary"
docker exec clab-evpn-vxlan-fabric-leaf1 vtysh -c "show evpn vni"
docker exec clab-evpn-vxlan-fabric-leaf1 vtysh -c "show bgp vrf TENANT-A ipv4 unicast"
docker exec clab-evpn-vxlan-fabric-host1a ping -c 3 10.10.10.20   # far-leaf, same VNI
docker exec clab-evpn-vxlan-fabric-host1b ping -c 3 10.20.20.12   # cross-leaf, inter-VNI (routed)
```

## Scope

Proves a full-mesh underlay/overlay at fleet scale, symmetric IRB across
VNIs, and BGP policy (route-maps, prefix-lists, an ACL) on top of it. It
does not add ESI multihoming, redundant management, or anything past
what a single containerlab host can run — see the parent repo's
`enterprise-fabric/` for a production-style netlab-generated lab with
route reflectors and Ansible-driven config instead.

## Destroy

```bash
sudo -E containerlab destroy -t evpn-vxlan-fabric.clab.yml --cleanup
```
