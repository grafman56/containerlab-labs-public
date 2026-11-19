# MPLS L3VPN over SR-MPLS

The same service provider core as [`mpls-l3vpn`](../mpls-l3vpn/README.md), with
segment routing in place of LDP. IS-IS distributes a node SID for each loopback, and
the PEs push that SR label for transport. There is no LDP in the core.

Two PE routers carry two customer VRFs across two P routers. The PEs exchange
customer routes with MP-BGP (VPNv4). The P routers hold no customer route.

## Quick start

On a Linux host with Docker and Containerlab:

```sh
sudo modprobe mpls_router mpls_iptunnel     # once per boot
./labctl up mpls-sr-l3vpn                   # from the repository root
./labctl verify mpls-sr-l3vpn               # ends with: PASS
```

Access to a node is `docker exec`:

```sh
docker exec -it clab-mpls-sr-l3vpn-pe1 vtysh
```

This lab and `mpls-l3vpn` use different names and management networks, so both can run
at the same time. They were run together during testing.

## Topology

The layout is the same as `mpls-l3vpn`: `pe1` and `pe2` each link to `p1` and `p2`.
Customer A is AS 65101 and 65102. Customer B is AS 65201 and 65202.

| Item | Value |
|---|---|
| Image | FRR 10.7.0 |
| Core IGP | IS-IS, level 2 only, wide metrics |
| Transport | SR-MPLS. SRGB 16000-23999, no LDP (`ldpd=no`) |
| Node SIDs | `pe1` 1, `pe2` 2, `p1` 11, `p2` 12 (label = 16000 + index) |
| VPN control plane | MP-BGP, address family `ipv4 vpn`, AS 65000, PE to PE |
| Customer A | VRF `CUST-A`, RD and RT `65000:100` |
| Customer B | VRF `CUST-B`, RD and RT `65000:200` |
| Management network | `172.100.123.0/24` |

## What `verify.sh` checks

The checks match `mpls-l3vpn`, with the LDP checks replaced:

1. IS-IS adjacencies on all four core routers.
2. Every router sees all four SR nodes, each advertising SRGB 16000-23999.
3. The VPNv4 session between the PEs.
4. No router has an LDP session.
5. Two equal-cost paths from `pe1` to `pe2`, both with label 16002 (16000 + index 2).
6. Customer routes cross the core, stay in their own VPN, and keep a different origin
   AS for the overlapping prefixes.
7. The PE VRF route has the stack `16002/<VPN label>`.
8. The P routers hold no customer routes and forward on labels only.
9. Both VPNs pass traffic from site 1 to site 2.

## Automation

The core configs are generated from `ansible/core.yml` with the template in
`../mpls-l3vpn/ansible/core.conf.j2`. A router with a `sid` gets SR-MPLS over IS-IS and
no LDP. A router without one gets LDP. Both labs use the same template.

```sh
cd mpls-sr-l3vpn/ansible
ansible-playbook site.yml --check --diff   # drift: what would change in configs/
ansible-playbook site.yml                  # write configs/, then run verify.sh
```

Tested with `ansible-core` 2.20. The playbook writes files only. Redeploy to load them.

## Gotchas

| Symptom | Cause and fix |
|---|---|
| `verify.sh` says the host is missing `mpls_router` | `sudo modprobe mpls_router mpls_iptunnel` |
| IS-IS adjacencies are up but no SR nodes appear, and there is no route to the far PE | Seen once, on the first deploy of this lab (the cause is unknown). The LSPs stayed at sequence 1 without SR data. Entering `segment-routing global-block 16000 23999` under `router isis CORE` on each router fixed it. Four later clean deploys converged in about 31 seconds with no manual step. If it happens, redeploy first |
| `ansible-playbook` shows a diff you did not expect | Someone edited `configs/` by hand. Change `core.yml` instead |

## Limits

- **FRR in containers is software.** Convergence times are not hardware numbers.
- **SR-MPLS only.** There is no SRv6, no SR-TE policy, no TI-LFA, and no flexible
  algorithm. Paths follow the IS-IS shortest path.
- **No inter-AS or multi-domain SR.**
- **The playbook does not change a running lab.** It writes config files.
- **The first-deploy convergence failure above is not explained.**
