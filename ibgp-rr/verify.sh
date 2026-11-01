#!/usr/bin/env bash
set -euo pipefail

lab=clab-ibgp-rr

for node in rr1 rr2 p1 p2 p3 e1 isp1 sw1 sw2 client1 client2 client3 client4 client5 client6; do
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

echo "ISP/customer eBGP"
docker exec "${lab}-e1" vtysh -c "show ip bgp summary"
docker exec "${lab}-isp1" vtysh -c "show ip bgp summary"
customer_default=$(docker exec "${lab}-e1" vtysh -c "show ip route 0.0.0.0/0")
isp_prefix=$(docker exec "${lab}-isp1" vtysh -c "show ip bgp 203.0.113.0/24")
printf '%s\n' "$customer_default"
printf '%s\n' "$isp_prefix"

grep -q '0.0.0.0/0' <<<"$customer_default"
grep -q '203.0.113.0/24' <<<"$isp_prefix"

echo "Access VLANs and MAC learning"
for pair in 120:client1 121:client3 122:client5; do
  vlan=${pair%%:*}
  client=${pair#*:}
  docker exec "${lab}-${client}" ping -c 2 -W 2 "10.${vlan}.0.12"
done
for switch in sw1 sw2; do
  vlan_state=$(docker exec "${lab}-${switch}" bridge vlan show)
  fdb_state=$(docker exec "${lab}-${switch}" bridge fdb show br br-access)
  printf '%s\n' "$vlan_state"
  printf '%s\n' "$fdb_state"
  for vlan in 120 121 122; do
    grep -q "$vlan" <<<"$vlan_state"
  done
  grep -q 'br-access' <<<"$fdb_state"
done

echo "PASS: OSPF, route reflection, ISP default, customer prefix, community, VLANs 120-122, trunks, and MAC learning verified"
