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

## Fabric and building design

### One AS, full mesh, no route reflectors

Eight VTEPs peer with each other: four access leaves and four border leaves,
28 sessions. The session count stays visible, and border redundancy is easy to
add. The cost grows with the square of the VTEP count, because each new VTEP
peers with all the others. A larger fabric needs route reflectors.

The spines carry no BGP for the same reason. EVPN sessions run between
loopbacks that OSPF already advertises, so the spines only forward. This keeps
the underlay and overlay separate when you break one of them.

This is not the usual vendor design. Cisco's guide calls the spine the most
logical place for an EVPN route reflector, and most real fabrics do it that
way. If you describe a fabric you did not build, check whether its spines are
reflectors. The `ibgp-rr` lab shows the reflector pattern.

### OSPF areas

The fabric underlay is one area (area 0). Cisco's guidance says so directly:
"The general recommendation is to use a single area, 0, in the underlay."
Their scale argument is that a 1000-leaf fabric makes about 2000 underlay LSAs,
which a modern switch handles easily. This is vendor guidance, not a standard.
RFC 7432 and RFC 8365 do not care which underlay you use, and RFC 7938 argues
for dropping the IGP and using eBGP only.

Buildings are where areas help. The core stays in area 0, each building gets its
own area, and the building's distribution switch becomes the area border router.
That is `dist-a1` and `dist-b1`.

The two buildings use different area types because their facts differ:

| | Building A1 | Building B1 |
|---|---|---|
| Own provider | none | research link, `inet-res` AS 65400 |
| Area type | area 1, totally stubby (`area 1 stub no-summary`) | area 2, NSSA (`area 2 nssa`, RFC 3101) |
| LSAs | 3 | 40 |
| OSPF routes | 1, a default | 37, a default plus every type 3 summary |

A1 redistributes nothing, so it has no ASBR and any stub type is allowed. Totally
stubby is the smallest, so it uses that.

B1 has its own provider. `acc-b1` runs eBGP with `inet-res` and redistributes it
into OSPF, so it is an ASBR. Stub and totally stubby areas do not allow an
ASBR, so NSSA is the only choice. `acc-b1` originates the research network as a
type 7 LSA in area 2, and `dist-b1` translates it to type 5 as it enters
area 0. Area 1 never sees it as an external route, but `user-a1` still reaches
it through the default route from its own border router. `verify.sh` checks
each step.

### Buildings stay out of the tenant VRFs

The buildings are in the global routing table. They reach the underlay and each
other. They do not reach the EVPN tenants or the internet, because the internet
exit is inside VRF `TENANT-A` on the border leaves. Joining the two needs a
firewall or a fusion router. This lab leaves that out until the route scope and
firewall policy are written down.

### Layer 3 VNIs belong to a VRF

`TENANT-A` has L3 VNI 4100 and `EDUROAM` has L3 VNI 4200. The Layer 2 VNIs in
one VRF share that VRF's L3 VNI. They do not share it across tenants.

### Borders and the firewall

Each border leaf has a routed eBGP link to the site firewall. The firewall peers
with the ISP, so the border leaves never peer with the ISP directly. Campus A
also carries `EDUROAM` on a separate tagged link and VRF.

The firewall sends only a default route to each border leaf. Each border
advertises it as an EVPN type 5 route. Every leaf prefers its own site's
primary border (local preference 200), then the secondary (190). The other
site's borders are the backup after both local paths fail.

### Anycast gateways and ARP suppression

Every leaf holds both L2 VNIs with the same bridge MAC and the same gateway
address, so `10.10.10.1` and `10.20.20.1` are live on all four leaves at once.

Because of that, `neigh_suppress` is on for every VXLAN bridge port. Without
it, a leaf floods the ARP request for a remote host, and the leaf closest to that
host answers. All leaves share the gateway MAC, so the requesting leaf never
sees the reply. With it, the leaf answers from EVPN type 2 routes and does not
flood. Each host pings its gateway once at startup, so its leaf has a MAC and IP
to advertise before anyone asks.

### The L3 VNI needs its own bridge

`vxlan4100` sits in bridge `br4100`, and `br4100` is the interface enslaved to
the VRF. If the VXLAN device goes straight into the VRF, the VNI stays down with
no router MAC, and symmetric IRB never comes up.

Border leaves also need `advertise-all-vni`, even though they have no L2 VNI.
Without it, zebra never registers the L3 VNI there, and no type 5 route is
imported or originated.
