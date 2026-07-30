#!/usr/bin/env bash
set -euo pipefail

lab=clab-sdwan-dual-transport

for node in branch1 hub1 isp-a isp-b corp-client dc-app; do
  docker inspect "${lab}-${node}" >/dev/null
done

echo "Overlay BGP sessions"
branch_summary=$(docker exec "${lab}-branch1" vtysh -c "show bgp ipv4 unicast summary")
hub_summary=$(docker exec "${lab}-hub1" vtysh -c "show bgp ipv4 unicast summary")
printf '%s\n%s\n' "$branch_summary" "$hub_summary"
grep -q '172.31.1.2' <<<"$branch_summary"
grep -q '172.31.2.2' <<<"$branch_summary"

echo "Primary-path route selection"
branch_route=$(docker exec "${lab}-branch1" vtysh -c "show ip route 10.20.20.0/24")
hub_route=$(docker exec "${lab}-hub1" vtysh -c "show ip route 10.10.10.0/24")
printf '%s\n%s\n' "$branch_route" "$hub_route"
grep -q '172.31.1.2' <<<"$branch_route"
grep -q '172.31.1.1' <<<"$hub_route"

echo "End-to-end branch-to-DC traffic"
docker exec "${lab}-corp-client" ping -c 3 -W 1 10.20.20.10

echo "PASS: dual overlays, preferred ISP-A path, and branch-to-DC traffic verified"
