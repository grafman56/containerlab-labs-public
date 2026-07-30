# Dual-Transport SD-WAN Mechanics Lab

This is a self-contained lab for the transferable operational pieces of an
SD-WAN: two transports, overlay tunnels, routing across both overlays, policy
preference, failover, and end-to-end validation. It is intentionally not a
vendor controller emulator.

The overlay uses GRE so the routing and failure domains are visible and easy to
capture. GRE is **not encrypted**. A later version can replace it with
WireGuard or IPsec after the control-plane workflow is familiar.

## Topology

```text
10.10.10.10                                             10.20.20.10
corp-client -- branch1 (AS65010) == GRE/ISP-A == hub1 (AS65020) -- dc-app
                    |                         |
                    +------ GRE/ISP-B --------+

ISP-A underlay: branch1 100.64.1.2 -- isp-a -- hub1 100.64.10.2
ISP-B underlay: branch1 100.64.2.2 -- isp-b -- hub1 100.64.20.2

Overlay A: 172.31.1.0/30 (preferred with local preference 200)
Overlay B: 172.31.2.0/30 (backup with local preference 100)
```

`branch1` advertises `10.10.10.0/24`; `hub1` advertises `10.20.20.0/24`.
Both sites use eBGP over both GRE tunnels. ISP routers only provide transport;
they do not participate in BGP.

## Deploy and validate

```bash
cd sdwan-dual-transport
sudo -E containerlab deploy -t sdwan-dual-transport.clab.yml
./verify.sh
```

The normal state has both BGP sessions established, while routes select Overlay
A. Capture `branch1:eth2`, `branch1:tun-isp-a`, and `branch1:tun-isp-b` in
EdgeShark to contrast transport packets with overlay traffic.

## First practice ticket: primary overlay unavailable

**Customer report:** Branch users can still reach the DC, but latency and
capacity are degraded after the preferred WAN path became unavailable.

Baseline checks:

```bash
docker exec -it clab-sdwan-dual-transport-branch1 vtysh
show bgp ipv4 unicast summary
show ip route 10.20.20.0/24
show ip bgp 10.20.20.0/24
```

To inject the fault only when you are ready:

```bash
docker exec clab-sdwan-dual-transport-branch1 ip link set tun-isp-a down
docker exec clab-sdwan-dual-transport-hub1 ip link set tun-isp-a down
```

Expected result: the ISP-A BGP session drops, the route changes to
`172.31.2.2`, and branch-to-DC ping continues through ISP-B. Restore the
healthy state with:

```bash
docker exec clab-sdwan-dual-transport-branch1 ip link set tun-isp-a up
docker exec clab-sdwan-dual-transport-hub1 ip link set tun-isp-a up
```

Then verify from both the routing table and an endpoint flow. Do not assume a
green interface alone proves the selected overlay is carrying application
traffic.

## Destroy

```bash
sudo -E containerlab destroy -t sdwan-dual-transport.clab.yml --cleanup
```
