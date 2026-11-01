#!/usr/bin/env bash
# usage: authorize-port.sh <port> <vlan>
#
# What a real switch does for you when the Access-Accept arrives:
#
#     Tunnel-Type             = VLAN
#     Tunnel-Medium-Type      = IEEE-802
#     Tunnel-Private-Group-ID = "10"      <-- this is the VLAN below
#
# All three attributes are required. Return two of the three and the switch
# silently leaves the port in its configured VLAN, which looks like a working
# authentication and a broken network.
#
# Doing it by hand here keeps the attribute and the consequence visible as two
# separate events. Read the VLAN out of the RADIUS log, then apply it:
#
#   docker exec clab-evpn-vxlan-campus-nac \
#     grep -A4 'Sent Access-Accept' /tmp/radius.log | grep Tunnel-Private
set -euo pipefail
port=$1
vlan=$2

case "$vlan" in
  10) bridge=br-staff   ;;
  30) bridge=br-eduroam ;;
  *)  echo "unknown VLAN $vlan (lab knows 10=staff, 30=eduroam)" >&2; exit 1 ;;
esac

ip link set "$port" master "$bridge"
echo "$port authorized into VLAN $vlan ($bridge)"
