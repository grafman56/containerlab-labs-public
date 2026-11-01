#!/usr/bin/env bash
set -euo pipefail

lab=clab-evpn-vxlan-ospf

for node in spine1 spine2 leaf1 leaf2 host1 host2; do
  docker inspect "${lab}-${node}" >/dev/null
done

echo "OSPF underlay"
for node in spine1 spine2 leaf1 leaf2; do
  docker exec "${lab}-${node}" vtysh -c "show ip ospf neighbor"
done

echo "EVPN sessions and routes"
for node in leaf1 leaf2; do
  docker exec "${lab}-${node}" vtysh -c "show bgp l2vpn evpn summary"
done
docker exec "${lab}-leaf1" vtysh -c "show bgp l2vpn evpn route type 3"
docker exec "${lab}-leaf2" vtysh -c "show bgp l2vpn evpn route type 3"

echo "VXLAN and bridge state"
docker exec "${lab}-leaf1" ip -d link show vxlan10
docker exec "${lab}-leaf2" ip -d link show vxlan10
docker exec "${lab}-leaf1" bridge fdb show br br10
docker exec "${lab}-leaf2" bridge fdb show br br10

echo "Endpoint reachability"
docker exec "${lab}-host1" ping -c 3 10.10.10.12

echo "PASS: EVPN-VXLAN host reachability verified"
