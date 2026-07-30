# FRR EVPN-VXLAN: Two Spines, Two Leaves

This deployable lab demonstrates a routed eBGP underlay, redundant loopback-based eBGP EVPN sessions, VXLAN VNI 1010, and two endpoints in the same stretched subnet.

## Topology

```text
             spine1 AS65000     spine2 AS65000
              /        \         /        \
     AS65101 leaf1 ---------------------- leaf2 AS65102
                |                          |
             host1                      host2
          10.10.10.11                10.10.10.12

leaf1 VTEP 10.255.0.1       leaf2 VTEP 10.255.0.2
L2 VNI 1010                 L2 VNI 1010
```

Spines are control-plane and underlay transit nodes; they never terminate VXLAN. Leaves advertise their VTEP loopbacks in the IPv4 underlay and exchange EVPN routes over separate loopback sessions.

## Address plan

| Link or role | Addresses |
|---|---|
| spine1–leaf1 | `10.0.0.0/31`, `10.0.0.1/31` |
| spine1–leaf2 | `10.0.0.2/31`, `10.0.0.3/31` |
| spine2–leaf1 | `10.0.0.4/31`, `10.0.0.5/31` |
| spine2–leaf2 | `10.0.0.6/31`, `10.0.0.7/31` |
| spine loopbacks | `10.255.255.1/32`, `10.255.255.2/32` |
| leaf VTEPs | `10.255.0.1/32`, `10.255.0.2/32` |
| tenant segment | `10.10.10.0/24`, VNI `1010` |

## Deploy

```bash
docker pull quay.io/frrouting/frr:10.7.0
docker pull alpine:3.20
sudo -E containerlab deploy -t evpn-vxlan.clab.yml
./verify.sh
```

Allow approximately 20 seconds for underlay and overlay sessions before the first verification run.

### Scoped lab control

From this directory, use `./labctl check`, `./labctl up`, `./labctl verify`, `./labctl status`, and `./labctl down`. Every target is scoped to `evpn-vxlan.clab.yml`; it does not target the separate `ibgp-rr` lab. See `../PARALLEL_LABS.md` for the concurrent-lab runbook and safety rules.

## Learning checkpoints

```bash
docker exec clab-evpn-vxlan-leaf1 vtysh -c "show bgp ipv4 unicast summary"
docker exec clab-evpn-vxlan-leaf1 ip route get 10.255.0.2
docker exec clab-evpn-vxlan-leaf1 vtysh -c "show bgp l2vpn evpn summary"
docker exec clab-evpn-vxlan-leaf1 vtysh -c "show bgp l2vpn evpn route"
docker exec clab-evpn-vxlan-leaf1 vtysh -c "show evpn vni"
docker exec clab-evpn-vxlan-leaf1 bridge fdb show br br10
docker exec clab-evpn-vxlan-host1 ping -c 3 10.10.10.12
```

## Failure drills

1. Shut one leaf uplink and verify the second path retains VTEP reachability.
2. Stop one spine and verify underlay plus overlay survival.
3. Remove `advertise-all-vni` from one leaf and observe Type 3 and flood-list changes.
4. Change one VNI to create a deliberate mismatch.
5. Reduce one uplink MTU and test larger encapsulated packets.

Capture state before and after each failure. Restore the original configuration before starting the next drill.

## Scope

This first stage proves L2 VNI operation and Type 3 discovery. The next stage adds distributed anycast gateways, tenant VRF/L3 VNI, symmetric IRB, and a border-leaf Type 5 route.

## Destroy

```bash
sudo -E containerlab destroy -t evpn-vxlan.clab.yml --cleanup
```
