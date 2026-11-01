#!/usr/bin/env bash
set -euo pipefail

trunk_port=${1:?trunk port is required}
shift

if [[ $# -ne 3 ]]; then
  printf '%s\n' 'three access ports are required' >&2
  exit 2
fi
access_ports=("$@")

ip link add name br-access type bridge vlan_filtering 1
ip link set br-access up

for port in "$trunk_port" "${access_ports[@]}"; do
  ip link set "$port" up
  ip link set "$port" master br-access
done

for vlan in 120 121 122; do
  bridge vlan add dev br-access vid "$vlan" self
  bridge vlan add dev "$trunk_port" vid "$vlan"
done

for index in 0 1 2; do
  vlan=$((120 + index))
  bridge vlan add dev "${access_ports[$index]}" vid "$vlan" pvid untagged
done
