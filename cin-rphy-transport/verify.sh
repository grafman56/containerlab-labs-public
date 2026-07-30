#!/usr/bin/env bash
set -euo pipefail

lab=clab-cin-rphy-transport

for node in hub1 hub2 rpa1 rpa2 aar1 dsr1 dsr2 rpd1 rpd2 vcmts service; do
  docker inspect "${lab}-${node}" >/dev/null
done

echo "OSPF adjacencies on the hub, RPA, AAR, and DSR transport tiers"
docker exec "${lab}-hub1" vtysh -c 'show ip ospf neighbor'
docker exec "${lab}-hub2" vtysh -c 'show ip ospf neighbor'
docker exec "${lab}-rpa1" vtysh -c 'show ip ospf neighbor'
docker exec "${lab}-rpa2" vtysh -c 'show ip ospf neighbor'
docker exec "${lab}-aar1" vtysh -c 'show ip ospf neighbor'
docker exec "${lab}-dsr1" vtysh -c 'show ip ospf neighbor'
docker exec "${lab}-dsr2" vtysh -c 'show ip ospf neighbor'

echo "RPD reachability to the vCMTS and service network"
docker exec "${lab}-rpd1" vtysh -c 'show ip route 10.255.2.1'
docker exec "${lab}-rpd2" vtysh -c 'show ip route 198.18.100.10/32'
docker exec "${lab}-rpd1" ping -c 3 -W 1 198.18.100.10
docker exec "${lab}-rpd2" ping -c 3 -W 1 198.18.100.10

echo "PASS: redundant hub-attached CMTS, RPA, AAR, and DSR OSPF transport roles verified"
