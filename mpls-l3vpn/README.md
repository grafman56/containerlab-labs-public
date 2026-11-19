# MPLS L3VPN

A small service provider core with two customers. Two PE routers carry two
customer VRFs across two P routers. The core runs IS-IS and LDP. The PEs
exchange customer routes with MP-BGP (VPNv4). The P routers never see a customer
route.

An Ansible playbook builds the four core configs from one data file, and shows
any difference from the running lab.

## Quick start

On a Linux host with Docker and Containerlab:

```sh
sudo modprobe mpls_router mpls_iptunnel     # once per boot
./labctl up mpls-l3vpn                      # from the repository root
./labctl verify mpls-l3vpn                  # ends with: PASS
```

Access to a node is `docker exec`:

```sh
docker exec -it clab-mpls-l3vpn-pe1 vtysh
```

## Topology

```text
  ce1a --+                                      +-- ce2a      customer A, AS 65101 and 65102
         |        p1                            |
        pe1 ---<        >--- pe2                |
         |        p2                            |
  ce1b --+                                      +-- ce2b      customer B, AS 65201 and 65202

  pe1 and pe2: IS-IS, LDP, VRF CUST-A and CUST-B, VPNv4 between them, AS 65000
  p1 and p2:   IS-IS and LDP only
```

Each PE links to both P routers, and each P router links to both PEs. The PEs
have two equal-cost paths to each other.

| Item | Value |
|---|---|
| Image | FRR 10.7.0 |
| Core IGP | IS-IS, level 2 only, wide metrics |
| Labels | LDP |
| VPN control plane | MP-BGP, address family `ipv4 vpn`, AS 65000, PE to PE |
| Customer A | VRF `CUST-A`, RD and RT `65000:100` |
| Customer B | VRF `CUST-B`, RD and RT `65000:200` |
| Overlap | Both customers use `10.10.1.0/24` and `10.10.2.0/24` |
| Management network | `172.100.122.0/24` |

## What `verify.sh` checks

1. IS-IS adjacencies and LDP sessions on all four core routers.
2. The VPNv4 session between the PEs.
3. Two equal-cost labelled paths from `pe1` to `pe2`.
4. Customer routes cross the core.
5. The customer A and B prefixes stay in their own VPN, in both directions.
6. The overlapping prefixes keep a different origin AS in each VPN.
7. The PE VRF route has a two-label stack (transport label and VPN label).
8. The P routers hold no customer routes and forward on labels only.
9. Both VPNs pass traffic from site 1 to site 2.

## Automation

The four core configs (`pe1`, `pe2`, `p1`, `p2`) are generated. The data is in
`ansible/core.yml`. The template is `ansible/core.conf.j2`. The customer
router configs stay hand-written.

```sh
cd mpls-l3vpn/ansible
ansible-playbook site.yml --check --diff   # drift: what would change in configs/
ansible-playbook site.yml                  # write configs/, then run verify.sh
ansible-playbook site.yml --tags render    # write configs/ only
ansible-playbook site.yml --tags verify    # verify only
```

Tested with `ansible-core` 2.20. The playbook runs on the Containerlab
host and talks to no router. It writes files and runs `verify.sh`.

To change the network, edit `core.yml`, run the playbook, and redeploy the lab.

## Gotchas

| Symptom | Cause and fix |
|---|---|
| Deploy works but `verify.sh` says the host is missing `mpls_router` | Load the modules: `sudo modprobe mpls_router mpls_iptunnel`. This does not survive a reboot |
| A router starts without its VRF interface | The start script waits up to 120 seconds for each interface. Check `docker logs` on the node |
| `ansible-playbook` shows a diff you did not expect | Someone edited a file in `configs/` by hand. Change `core.yml` instead, and run the playbook |

## Limits

- **FRR in containers is software.** There is no ASIC, so timers and
  convergence times are not hardware numbers.
- **LDP, not segment routing.** The core does not run SR-MPLS or SRv6.
- **The playbook does not change a running lab.** It writes config files. A
  redeploy loads them, because the kernel VRFs are created at container start.
- **Customer routers are stand-ins.** Their configs are hand-written.
- **Two PEs, two P routers.** There is no route reflector and no inter-AS link.
