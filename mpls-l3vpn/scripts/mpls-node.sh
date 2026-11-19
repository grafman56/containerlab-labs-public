#!/bin/sh
# Container start wrapper for PE and P nodes.
#   mpls-node.sh <core-ifaces,comma-separated> [VRF:iface:table ...]
# Enables the Linux MPLS data plane, builds kernel VRFs, then starts FRR.
# It runs before FRR so frr.conf finds every interface already in place.
set -eu

core=$1
shift

wait_if() {
  n=0
  until ip link show "$1" >/dev/null 2>&1; do
    n=$((n + 1))
    [ "$n" -gt 120 ] && { echo "interface $1 never appeared" >&2; exit 1; }
    sleep 1
  done
}

echo 1 > /proc/sys/net/ipv4/ip_forward
echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
echo 0 > /proc/sys/net/ipv4/conf/default/rp_filter
# Needs the mpls_router module on the host; see README.
echo 100000 > /proc/sys/net/mpls/platform_labels
echo 1 > /proc/sys/net/mpls/conf/lo/input

for i in $(echo "$core" | tr ',' ' '); do
  wait_if "$i"
  echo 1 > "/proc/sys/net/mpls/conf/$i/input"
done

for spec in "$@"; do
  vrf=${spec%%:*}
  rest=${spec#*:}
  ifc=${rest%%:*}
  table=${rest#*:}
  wait_if "$ifc"
  ip link add "$vrf" type vrf table "$table"
  ip link set "$vrf" up
  ip link set "$ifc" master "$vrf"
  ip link set "$ifc" up
  # Lets the kernel accept VPN-labelled packets and look them up in this VRF.
  echo 1 > "/proc/sys/net/mpls/conf/$vrf/input"
done

exec /usr/lib/frr/docker-start
