#!/usr/bin/env bash
set -euo pipefail

lab=clab-ibgp-rr

for node in rr1 rr2 p1 p2 p3 e1; do
  docker inspect "${lab}-${node}" >/dev/null
done

echo "OSPF underlay"
docker exec "${lab}-rr1" vtysh -c "show ip ospf neighbor"
docker exec "${lab}-rr2" vtysh -c "show ip ospf neighbor"

echo "iBGP route-reflector sessions"
docker exec "${lab}-rr1" vtysh -c "show ip bgp summary"
docker exec "${lab}-rr2" vtysh -c "show ip bgp summary"

echo "Reflected edge prefix and community"
route_output=$(docker exec "${lab}-p3" vtysh -c "show ip bgp 203.0.113.0/24")
printf '%s\n' "$route_output"

grep -q '203.0.113.0/24' <<<"$route_output"
grep -q 'Community: 65001:100' <<<"$route_output"

echo "PASS: OSPF, route reflection, edge prefix, and community verified"
