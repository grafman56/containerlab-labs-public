# iBGP with Route Reflectors

Core (AS 65000): two route reflectors (`rr1`, `rr2`) meshed with each other,
three P routers (`p1`, `p2`, `p3`) that peer **only** to both RRs (no P-to-P
iBGP — that's the whole point of the RR shape). OSPF is the underlay on every
point-to-point interface.

Edge (AS 65001): `e1` speaks eBGP with `p1` and originates `203.0.113.0/24`
tagged with community `65001:100`.

## Topology

```text
                         iBGP AS 65000

                     rr1 ═════ rr2
                    / | \     / | \
                   /  |  \   /  |  \
                 p1   p2  p3   p2   p3
                 |
                 e1 AS65001

Physical underlay: each client connects to both RRs; p2 also connects to p3.
BGP overlay: every client peers only with rr1 and rr2 over loopbacks.
```

    rr1, rr2   : route reflectors, iBGP mesh between them
    p1, p2, p3 : RR clients (peer both RRs, no P-to-P iBGP)
    e1         : AS 65001, eBGP peer of p1, originates 203.0.113.0/24

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
```

## Poke around live

```bash
docker exec -it clab-ibgp-rr-rr1 vtysh
```

FRR's standard container does not run SSH. Use `docker exec` for these lightweight labs; use `enterprise-fabric/` for production-style SSH, Ansible, and telemetry practice.

## Destroy

```bash
sudo -E containerlab destroy -t ibgp-rr.clab.yml --cleanup
```
