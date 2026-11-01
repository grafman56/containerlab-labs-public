# Campus Control-Plane Policy Exercises

This is a fast-deploy learning guide for the existing campus topology. It adds
policy only to the nodes already present. Do not add nodes, services, or a
real firewall for these exercises.

Run the baseline first:

```sh
./labctl check
./labctl up
./labctl verify
```

`verify` is the rollback check. Make one exercise change, run its observation
commands, prove its positive and negative result, then restore the file and
run `./labctl verify` again.

## The policy boundary map

| Question | Configure it on | Why it belongs there |
| --- | --- | --- |
| Which tenant prefixes may reach the firewall? | `bdr-*.conf`, outbound eBGP route-map | The border owns the fabric-to-firewall route handoff. |
| Which default is preferred at a leaf? | `leaf*.conf`, inbound EVPN route-map | Preference is local to each site. A border's local preference is propagated through the shared EVPN domain, so it cannot express both sites' local preference. |
| Which external prefix may enter the building IGP? | `acc-b1.conf`, BGP-to-OSPF route-map | `acc-b1` is the ASBR. Filter at redistribution, before the prefix enters OSPF. |
| Which default may leave the firewall model? | `fw-*.conf`, outbound eBGP prefix-list | This represents the firewall's virtual-router export boundary. |
| Who may use a route after it exists? | Firewall policy, not BGP | Routing decides reachability; the firewall decides permitted flows. Keep this high-level in this lab. |

The model uses EVPN route type 5 for routed tenant prefixes. RFC 9136 defines
type 5 as an IP Prefix route; do not confuse this control-plane route with a
type 2 endpoint MAC/IP route. See [RFC 9136](https://www.rfc-editor.org/rfc/rfc9136.html).

## 1. Read the current policy before changing it

The current baseline is intentionally small, but explicit:

- `bdr-*.conf` exports only the two `TENANT-A` /24 prefixes to its firewall
  peer. Campus A separately exports the `EDUROAM` /24. Its explicit final
  deny prevents all other IPv4 prefixes, and its inbound policy accepts only
  a default from the firewall.
- `fw-*.conf` exports only `0.0.0.0/0` back toward each border, also with an
  explicit final deny.
- `leaf*.conf` assigns local preference 200 to the local primary border and
  190 to the local secondary border. A remote border remains the fallback.
- `acc-b1.conf` redistributes only the research-provider `/32` from BGP into
  NSSA area 2. Its final deny blocks all other BGP routes.

Use these commands after `./labctl up`:

```sh
lab=clab-evpn-vxlan-campus
docker exec "$lab-bdr-a" vtysh -c 'show ip bgp vrf TENANT-A neighbors 198.51.100.1 advertised-routes'
docker exec "$lab-fw-a"  vtysh -c 'show ip bgp neighbors 198.51.100.0 advertised-routes'
docker exec "$lab-leaf1a" vtysh -c 'show bgp l2vpn evpn route type prefix'
docker exec "$lab-acc-b1" vtysh -c 'show ip route 203.0.113.3/32'
```

Expected result: the border shows tenant prefixes only, the firewall shows a
default only, and `leaf1a` selects its local primary border for the tenant
default. The exact EVPN display differs slightly by FRR version; if necessary,
use `show bgp l2vpn evpn` and filter for `0.0.0.0/0`.

## 2. Exercise: safe tenant export at the border

### Goal

Make the existing allow-list explicitly deny everything else, then prove a
host route cannot escape to the firewall.

### Configure

The baseline already applies this on all four `configs/bdr-*.conf` files:

```frr
ip prefix-list PL-TO-FW-TENANT-A seq 100 deny 0.0.0.0/0 le 32
```

`bdr-a.conf` and `bdr-a2.conf` apply the same pattern to
`PL-TO-FW-EDUROAM`. The route-map is an outbound policy under the tenant
VRF's eBGP neighbor:

```frr
route-map RM-TO-FW-TENANT-A permit 10
 match ip address prefix-list PL-TO-FW-TENANT-A
!
router bgp 65000 vrf TENANT-A
 address-family ipv4 unicast
  neighbor <firewall-peer> route-map RM-TO-FW-TENANT-A out
```

### Why here

The border is the first and narrowest fabric-to-firewall boundary. Filtering
there prevents accidental export of a default, a service `/32`, or another
tenant prefix. A Palo Alto virtual router has equivalent BGP import/export
rules, so this is the correct mental model even while the firewall remains an
FRR stand-in. Palo Alto documents matching import/export rules by prefix,
AS-path, and community in its [BGP import and export documentation](https://docs.paloaltonetworks.com/ngfw/help/11-1/network/network-virtual-routers/bgp/bgp-import-and-export-tabs).

### Prove it

1. Redeploy the lab and inspect advertised routes on `bdr-a`.
2. Temporarily add a connected `/32` inside `TENANT-A` on `bdr-a` or advertise
   one from a test process. Confirm it is absent from `advertised-routes`.
3. Confirm the two approved `/24` prefixes remain present.
4. Run `./labctl verify`.

Do not make this a broad permit. The explicit final deny is documentation of
intent and protects the policy if a later route-map sequence changes.

## 3. Exercise: explain and alter exit preference

### Goal

See why default-exit preference belongs at the receiving leaf in this
single-domain EVPN design.

### Configure

The current leaf policy is:

```frr
route-map RM-PREFER-LOCAL-EXIT permit 10
 set local-preference 200
!
route-map RM-PREFER-SECONDARY-EXIT permit 10
 set local-preference 190
!
router bgp 65000
 address-family l2vpn evpn
  neighbor <local-primary-border> route-map RM-PREFER-LOCAL-EXIT in
  neighbor <local-secondary-border> route-map RM-PREFER-SECONDARY-EXIT in
```

Keep this on every access leaf. For a short experiment, change the secondary
value from 190 to 210 on one leaf only, redeploy, and inspect which default it
chooses. Restore 190 afterward.

### Why here

Local preference is an iBGP path-selection attribute. If a border sets it in
this one full-mesh EVPN domain, that value is carried to both sites. It cannot
mean “prefer my local exit” everywhere. Applying the preference on the leaf
that consumes the route makes the policy site-local.

### Prove it

```sh
docker exec "$lab-leaf1a" vtysh -c 'show ip route vrf TENANT-A 0.0.0.0/0'
docker exec "$lab-leaf1a" vtysh -c 'show bgp l2vpn evpn 0.0.0.0/0'
```

Then run `./labctl verify`, which withdraws the local primary and both local
exits in turn. It proves primary, secondary, and remote-site fallback in that
order.

Use communities later to *classify* routes, for example `65000:100` for a
primary exit and `65000:190` for a secondary exit. Do not use a community by
itself to change path selection; match it in a local inbound route-map and set
local preference there. BGP communities are optional transitive attributes
that local policy can add or modify; see [RFC 4360](https://www.rfc-editor.org/rfc/rfc4360.html).

## 4. Exercise: controlled BGP-to-OSPF redistribution

### Goal

Restrict the research circuit so only its intended prefix enters OSPF area 2.

### Configure

`configs/acc-b1.conf` already contains:

```frr
ip prefix-list PL-RESEARCH-IN seq 10 permit 203.0.113.3/32
ip prefix-list PL-RESEARCH-IN seq 100 deny 0.0.0.0/0 le 32
!
route-map RM-BGP-TO-OSPF permit 10
 match ip address prefix-list PL-RESEARCH-IN
!
route-map RM-BGP-TO-OSPF deny 100
!
router ospf
 redistribute bgp route-map RM-BGP-TO-OSPF
```

Do not replace this policy with an unqualified `redistribute bgp`, and do not
add `default-information originate` in area 2: this provider is for the
research prefix, not general Internet exit.

### Why here

`acc-b1` is the ASBR. An unfiltered redistribution command gives every route
learned from that eBGP peer permission to enter the campus IGP. An NSSA
contains the external as a type 7 route, and `dist-b1` translates it to a type
5 for area 0. Filter before that first redistribution point.

### Prove it

```sh
docker exec "$lab-acc-b1"  vtysh -c 'show ip ospf database nssa-external'
docker exec "$lab-spine1b" vtysh -c 'show ip ospf database external'
docker exec "$lab-acc-a1"  vtysh -c 'show ip route 203.0.113.3/32'
```

The research `/32` must appear. A test default or unrelated BGP prefix must
not appear in the OSPF databases. `./labctl verify` already checks the type-7
to type-5 translation and end-to-end reachability.

## 5. Exercise: use communities as a campus policy vocabulary

### Goal

Add a small, documented vocabulary without changing forwarding behavior yet.

### Configure

The baseline applies a community only to prefixes that a border exports:

```frr
route-map RM-TO-FW-TENANT-A permit 10
 match ip address prefix-list PL-TO-FW-TENANT-A
 set community 65000:110 additive
```

`65000:110` means `campus-tenant-export`; `65000:130` means
`eduroam-tenant-export`. Inspect them at the firewall
side before writing any policy that depends on it. A later exercise can match
this community inbound and set local preference or deny export.

### Why here

A prefix-list answers “which networks?” A community answers “what is this
route for?” Keeping both makes policy reviewable. Community naming also maps
cleanly to Palo Alto BGP import/export rules, which can match community and
extended-community regular expressions.

### Prove it

```sh
docker exec "$lab-fw-a" vtysh -c 'show ip bgp community 65000:110'
```

If the community is absent, first confirm the route-map is applied in the
correct address family and direction. Do not add a second policy mechanism
until the first one is visible.

## Recommended learning order

1. Read current advertisements and selected defaults.
2. Add explicit terminal denies to border prefix-lists.
3. Run the exit-preference exercise and use `verify` to fail over.
4. Filter BGP-to-OSPF redistribution at `acc-b1`.
5. Add communities as labels, then consume one in a route-map.

Each step is a small configuration change to existing FRR files. `./labctl up`
remains the deployment path. Keep changes in a separate branch or commit per
exercise so restore is one command, not reconstruction from memory.

## Source material

- [FRR BGP documentation](https://docs.frrouting.org/en/stable-8.4/bgp.html)
  for BGP route-maps, local preference, and policy mechanisms. The lab pins
  FRR 10.7; check the installed CLI help if a command differs.
- [RFC 7432](https://www.rfc-editor.org/rfc/rfc7432.html) for the EVPN
  control-plane base.
- [RFC 9136](https://www.rfc-editor.org/rfc/rfc9136.html) for EVPN type-5 IP
  prefix advertisements.
- [RFC 4360](https://www.rfc-editor.org/rfc/rfc4360.html) for BGP extended
  communities and local-policy use.
- [Palo Alto BGP import/export rules](https://docs.paloaltonetworks.com/ngfw/help/11-1/network/network-virtual-routers/bgp/bgp-import-and-export-tabs)
  for the equivalent firewall virtual-router policy boundary.
