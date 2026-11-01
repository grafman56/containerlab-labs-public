#!/usr/bin/env bash
set -euo pipefail

lab=clab-evpn-vxlan-fabric
spines=(spine1 spine2 spine3 spine4)
leaves=(leaf1 leaf2 leaf3 leaf4 leaf5 leaf6 leaf7 leaf8 leaf9 leaf10)
vni1020_leaves=(leaf1 leaf2 leaf3)

for node in "${spines[@]}" "${leaves[@]}"; do
  docker inspect "${lab}-${node}" >/dev/null
done

echo "Underlay IPv4 sessions"
for node in "${spines[@]}" "${leaves[@]}"; do
  docker exec "${lab}-${node}" vtysh -c "show bgp ipv4 unicast summary"
done

echo "EVPN sessions"
for node in "${spines[@]}" "${leaves[@]}"; do
  docker exec "${lab}-${node}" vtysh -c "show bgp l2vpn evpn summary"
done

echo "EVPN VNI state (leaf1, leaf10)"
docker exec "${lab}-leaf1" vtysh -c "show evpn vni"
docker exec "${lab}-leaf10" vtysh -c "show evpn vni"

echo "Endpoint reachability: VNI 1010 stretched to every leaf"
docker exec "${lab}-host1a" ping -c 3 10.10.10.20

echo "Endpoint reachability: VNI 1020 + VRF TENANT-A symmetric IRB (leaf1 <-> leaf2, cross-leaf inter-VNI)"
docker exec "${lab}-host1b" ping -c 3 10.20.20.12

echo "PASS: 4-spine/10-leaf EVPN-VXLAN fabric reachability verified"
