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

## Batfish

Batfish cannot read this lab's FRR configs, so there is no Batfish step in
`labctl` or `demo.sh`.

We ran it on the 21 FRR configs on 2026-11-01. Every file came back
`PARTIALLY_UNRECOGNIZED`. Batfish reads FRR as Cisco-style config and skips
FRR's own OSPF lines, the EVPN lines (`vni`, `address-family l2vpn evpn`,
`advertise-all-vni`) and `frr version`. With no OSPF underlay in its model, 56
of 67 BGP sessions showed `NOT_ESTABLISHED` and OSPF returned nothing. In the
running lab they are all up. A Batfish check would fail a healthy lab.

We use `verify` and `verify-identity` instead, which test the real control
plane, and `reconcile`, which compares the registers.

General rule: check how much of your config an analyzer can parse before you
trust what it reports.

Batfish still works on BGP-only labs like `ibgp-rr`. It lists Palo Alto as
supported, so checking real PAN-OS config exports may be worth a try. That is
untested, and so is whether it models User-ID rules.
