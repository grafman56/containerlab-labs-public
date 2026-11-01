# iBGP with Route Reflectors

Core (AS 65000): two route reflectors (`rr1`, `rr2`) meshed with each other,
three P routers (`p1`, `p2`, `p3`) that peer **only** to both RRs (no P-to-P
iBGP — that's the whole point of the RR shape). OSPF is the underlay on every
point-to-point interface.

Customer edge (AS 65001): `e1` speaks eBGP with `p1`, originates
`203.0.113.0/24` tagged with community `65001:100`, and peers with `isp1`.

ISP (AS 64500): `isp1` advertises a default route to `e1` and accepts only the
customer `/24`.

## Topology

```text
                         iBGP AS 65000

                     rr1 ═════ rr2
                    / | \     / | \
                   /  |  \   /  |  \
                 p1   p2  p3   p2   p3
                 |
                 e1 AS65001 ─── isp1 AS64500

    client1 ─ sw1 ═════ sw2 ─ client2    VLAN 120
    client3 ─ sw1 ═════ sw2 ─ client4    VLAN 121
    client5 ─ sw1 ═════ sw2 ─ client6    VLAN 122

Physical underlay: each client connects to both RRs; p2 also connects to p3.
BGP overlay: every client peers only with rr1 and rr2 over loopbacks.
```

    rr1, rr2   : route reflectors, iBGP mesh between them
    p1, p2, p3 : RR clients (peer both RRs, no P-to-P iBGP)
    e1         : AS 65001 customer edge, eBGP peer of p1 and isp1
    isp1       : AS 64500 ISP edge, sends default and filters customer routes
    sw1, sw2   : Linux-bridge access switches, VLANs 120-122 on the inter-switch trunk
    client1, client2 : VLAN 120 endpoints at 10.120.0.11 and 10.120.0.12
    client3, client4 : VLAN 121 endpoints at 10.121.0.11 and 10.121.0.12
    client5, client6 : VLAN 122 endpoints at 10.122.0.11 and 10.122.0.12

## Deploy

```bash
cd ibgp-rr
sudo -E containerlab deploy -t ibgp-rr.clab.yml
```

Give OSPF ~15 seconds, BGP another 30 or so. Then verify.

## Verify

```bash
./verify.sh

# BGP sessions on rr1: one RR peer plus three clients
docker exec clab-ibgp-rr-rr1 vtysh -c "show ip bgp summary"

# OSPF neighbors on rr1
docker exec clab-ibgp-rr-rr1 vtysh -c "show ip ospf neighbor"

# The eBGP prefix and community reached p3 through the RRs
docker exec clab-ibgp-rr-p3 vtysh -c "show ip bgp 203.0.113.0/24"
docker exec clab-ibgp-rr-p3 vtysh -c "show ip bgp community 65001:100"

# ISP/customer eBGP
docker exec clab-ibgp-rr-e1 vtysh -c "show ip bgp summary"
docker exec clab-ibgp-rr-e1 vtysh -c "show ip route 0.0.0.0/0"
docker exec clab-ibgp-rr-isp1 vtysh -c "show ip bgp 203.0.113.0/24"

# Access VLANs and MAC learning
docker exec clab-ibgp-rr-client1 ping -c 2 10.120.0.12
docker exec clab-ibgp-rr-client3 ping -c 2 10.121.0.12
docker exec clab-ibgp-rr-client5 ping -c 2 10.122.0.12
docker exec clab-ibgp-rr-sw1 bridge vlan show
docker exec clab-ibgp-rr-sw1 bridge fdb show br br-access
docker exec clab-ibgp-rr-sw2 bridge vlan show
docker exec clab-ibgp-rr-sw2 bridge fdb show br br-access
```

## Edge policy template

`p1` models an enterprise edge policy boundary. It accepts only the documented
customer prefix from `e1`, sets local preference to 150, and exports to the
route reflectors only routes tagged with community `65001:100`. The explicit
deny sequences prevent an unclassified edge route from entering the core.

The tracked FRR configuration is the normal baseline. The Ansible template
under `ansible/` lets an operator audit the live policy or reapply the same
named objects after a scoped lab deployment. It does not modify a lab unless
the operator sets `policy_state=present`.

```bash
cd ibgp-rr/ansible

# Read-only: confirm the expected objects and BGP attachments exist.
ansible-playbook -i inventory.yml playbooks/edge_policy.yml

# Apply the reviewed baseline to the named running lab only.
ansible-playbook -i inventory.yml playbooks/edge_policy.yml \
  -e policy_state=present
```

After a policy apply, run `../verify.sh`. Verify `p1` accepts the edge prefix,
the reflectors receive it, and `p3` retains two reflected paths.

## Declared device inventory

`declared-inventory.json` is the declared device set for Miser's static
resolver: one record per FRR node with ASN, router-id, interfaces, and peer
ASN/role/address, plus `e1`'s owned `203.0.113.0/24`. It mirrors the NetBox
`config_context` record shape so both resolvers return the same evidence.

- Source of truth is the tracked `configs/*.conf` baseline, not invented
  state. Keep the file in sync when a tracked config changes.
- The repo validator checks that every declared target names a real topology
  node: `./validate-repository.sh` at the repository root.

### Render-and-compare verification (read-only)

The acceptance check for intent -> config integrity renders every device's
truthful intent against the static resolver and compares it with live state:

1. Compile the device intent with Miser (`compile_intent` against
   `build_static_resolver(file=declared-inventory.json)`) and render it with
   the FRR adapter (`render_frr_config`).
2. Collect live state read-only:
   `docker exec clab-ibgp-rr-<dev> vtysh -c "show running-config bgpd"`.
3. Compare sessions (neighbor address -> remote-as, activate) and router-id.
   Peer-group members resolve through their group on the live side.

The full-lab pass (all 7 FRR devices, zero session or router-id mismatches) is
the baseline evidence. Expected diffs are adapter-vocabulary gaps, not
failures: peer-groups, `update-source`, `next-hop-self`,
`route-reflector-client`, `default-originate`, and route-map names on the
devices that use them. Config apply stays behind the Miser policy gate.

## Poke around live

```bash
docker exec -it clab-ibgp-rr-rr1 vtysh
```

FRR's standard container does not run SSH. Use `docker exec` for these lightweight labs. NetBox records the host SSH plus Docker exec command for every node. Router commands open `vtysh`; access switches and clients open `bash`.

## Destroy

```bash
sudo -E containerlab destroy -t ibgp-rr.clab.yml --cleanup
```
