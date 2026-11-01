# Architecture

This is an FRR/containerlab learning model, not a Cisco Cloud Fabric or a Palo
Alto implementation. Its purpose is to make the control-plane, forwarding, and
security-boundary decisions visible and testable.

## Design source and scope

The design uses the Cisco Cloud Fabric validated case study as a reference for
principles: routed underlay first, EVPN/VXLAN overlay, VRF macro-segmentation,
redundant border handoffs, and validation before adding identity policy. It
does not copy Cisco Cloud Fabric workflow, Meraki Dashboard behavior, SGT
propagation, or PAN-OS.

| Concern | This lab | Why |
|---|---|---|
| Underlay | OSPF over routed point-to-point links | Transport is independent of tenant routing. |
| Overlay | iBGP EVPN full mesh between VTEPs | Keeps EVPN routes visible for a small lab. |
| Tenant macro-segmentation | `TENANT-A` and `EDUROAM` VRFs | A missing route is the first isolation control. |
| Tenant forwarding | L2 VNIs attach to a VRF; one L3 VNI exists per VRF | Multiple VLANs in one tenant can route without making them separate tenants. |
| External handoff | Per-VRF eBGP over routed or tagged firewall links | A firewall is not a VTEP; the border terminates VXLAN and owns route policy. |
| Firewall | FRR plus nftables stand-in for PAN-OS | It is one data-plane stand-in: minimal per-zone BGP routing plus stateful policy. |

## Deliberate divergences

Cisco Cloud Fabric supports dedicated borders or border-on-spine. This lab uses
redundant border-leaf pairs because it exposes EVPN, VRF, and firewall handoff
state in a small topology. Do not present that placement as Cisco Cloud Fabric
product behavior.

The case study prefers unique routed subnets per leaf. This lab retains
stretched L2 and anycast-gateway examples (`VNI 1010` and `VNI 1020`) to teach
mobility and symmetric IRB. They are examples, not the recommended default for
every campus subnet.

## Current security model

`VNI 1010` and `VNI 1020` are both in `TENANT-A`, using L3 VNI `4100`. They
are allowed to route because they are one tenant. `VNI 1030` is in `EDUROAM`,
using L3 VNI `4200`; it has no campus-route import.

At campus A, the border pair hands both VRFs to `fw-a` on separate tagged
interfaces. `fw-a` keeps the visitor routing table separate and nftables uses a
default-drop forward policy. Guest-to-internet is allowed; guest-to-campus and
campus-to-guest are denied. The two controls intentionally overlap: routing
prevents normal reachability, while policy catches a route that appears through
another path.

The firewall advertises only defaults toward the fabric. The border leaves
filter their own tenant-prefix advertisements toward the firewall. In this
single EVPN domain, local-versus-remote exit preference remains an import policy
on each access leaf: no one global local-preference value on a border can make
both sites prefer their own secondary border over the other site's primary.
The firewall still receives routed zone handoffs and enforces stateful policy;
it does not own fabric route policy.

## Shared services: intentionally not implemented

There is no generic cross-VRF shared-service leak. Adding one without a stated
service, consumers, return path, and firewall policy would teach the wrong
lesson.

The next learning exercise should add a `SERVICES` VRF and a single service
prefix. It must include all of these together:

1. A narrow, bidirectional route exchange for that service and its consumers.
2. A firewall rule permitting only the required application from the approved
   source zone to that destination.
3. Default denial for every other `EDUROAM` to `SERVICES` flow.
4. Tests for allowed service traffic, denied alternate ports, denied unrelated
   service addresses, and stateful return traffic.

That is an implementation decision to make explicitly, not a default property
of EVPN or BGP.

## Validation order

Run the checks in this order:

```sh
./labctl check
./labctl up
./labctl verify
./labctl verify-identity
```

`verify` establishes underlay, EVPN, symmetric-IRB, and border-failover
behavior. `verify-identity` then proves authentication, dynamic VLAN placement,
VRF separation, end-to-end guest denial, and guest Internet access. This order
prevents a policy result from hiding an underlay or overlay fault.

`POLICY-EXERCISES.md` extends that order with route-policy exercises. It keeps
policy at its ownership boundary: border eBGP filtering at the border, leaf
exit selection at the leaf, and BGP-to-OSPF filtering at the ASBR. It does not
turn the firewall stand-in into a second fabric route-policy owner.

## Why Batfish is not a gate here

Batfish reads device configs offline and answers questions about them. It is
tempting as a pre-deployment check, so it was tried on this lab's 21 FRR
configs (2026-11-01) before anything was wired in.

Every file came back `PARTIALLY_UNRECOGNIZED`. Batfish reads FRR through its
Cisco-family grammar, and that grammar does not know FRR's native OSPF lines
(`router ospf`, `network ... area`, `area stub`), the EVPN lines (`vni`,
`address-family l2vpn evpn`, `advertise-all-vni`) or `frr version`. It then
reported no OSPF sessions and 56 of 67 BGP sessions `NOT_ESTABLISHED`, while the
running lab has them all up. Without the OSPF underlay, its model cannot bring
up iBGP over loopbacks.

So a Batfish step here would fail a healthy lab. It is left out of `labctl` and
`demo.sh`. The checks that do work are the running ones: `verify` and
`verify-identity` test the real control plane, and `reconcile` compares the
registers.

**Principle:** a static analyzer is only as good as its model of the dialect.
Measure how much of your config it understands (parse status first) before you
trust its verdicts, and never gate on a tool that cannot read your files.

Batfish is still useful on BGP-only FRR labs (`ibgp-rr`), and it lists Palo
Alto among its supported vendors, so a check on real PAN-OS config exports is
worth trying later. Not tested: whether it models User-ID rules.
