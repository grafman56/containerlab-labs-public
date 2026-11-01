#!/usr/bin/env bash
# The BlueCat stand-in: DHCP and DNS on one node, because that is how DDI is
# actually deployed. Kea is the DHCP half, BIND9 the DNS half. What BlueCat
# adds on top is the IPAM database and the management plane -- the protocol
# behaviour below is the same, and it is the part that breaks.
set -uo pipefail

/cfg/wait-for-link.sh eth1 eth2

# Two legs, one per segment it serves.
#
# A real campus would not do this: the leaf would hold the anycast gateway and
# relay DHCP up to a single BlueCat address. FRR has no DHCP relay, and a
# relay on the access switch is pointless because the switch's "upstream" and
# "downstream" are the same L2 segment -- which is itself worth seeing once.
# The relay, and the anycast-gateway giaddr problem it brings with it, are in
# README "Things to build".
ip address replace 10.20.20.50/24 dev eth1
ip link set eth1 up
ip address replace 10.10.10.50/24 dev eth2
ip link set eth2 up
ip route replace 10.0.0.0/8 via 10.20.20.1

# See identity/keepalive.sh for why an idle endpoint goes unreachable.
nohup /cfg/keepalive.sh 10.20.20.1 >/dev/null 2>&1 &
sleep 2

mkdir -p /run/kea /var/run/kea

# Kea opens raw sockets per interface at startup and does not retry. If an
# interface is not yet UP with an address, Kea comes up bound to nothing and
# looks perfectly healthy -- its log shows only lease reclamation and never a
# received packet, while DHCPDISCOVER arrives at the host and is ignored.
# wait-for-link only proves the interface exists, which is not enough here.
for i in $(seq 1 60); do
  up=0
  for dev in eth1 eth2; do
    ip -4 addr show "$dev" 2>/dev/null | grep -q 'inet ' && up=$((up+1))
  done
  [ "$up" -eq 2 ] && break
  sleep 1
done

named -c /cfg/ddi/named.conf -u bind || true
exec kea-dhcp4 -c /cfg/ddi/kea-dhcp4.conf
