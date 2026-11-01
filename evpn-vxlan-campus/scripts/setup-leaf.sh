#!/usr/bin/env bash
# usage: setup-leaf.sh <vtep-loopback> <access-bridge: br10|br20> [port ...]
#
# Ports default to eth3, the single host every leaf started with. Leaves that
# carry the identity edge or the identity services pass several.
set -euo pipefail
vtep=$1
access=$2
shift 2
ports=("$@")
[ ${#ports[@]} -eq 0 ] && ports=(eth3)

# VRF + L3 VNI 4100 for symmetric IRB and the routed path to the internet border.
ip link add TENANT-A type vrf table 4100
ip link set TENANT-A up
# The L3 VNI needs its own bridge acting as the SVI. Putting the VXLAN device
# straight into the VRF leaves the VNI in state Down with no router MAC, and
# symmetric IRB never comes up.
ip link add vxlan4100 type vxlan id 4100 local "$vtep" dstport 4789 nolearning
ip link add br4100 type bridge
ip link set vxlan4100 master br4100
ip link set br4100 master TENANT-A
ip link set vxlan4100 up
ip link set br4100 up

# Both L2 VNIs exist on every leaf. The bridge MAC is identical fabric-wide,
# which is what makes 10.10.10.1 / 10.20.20.1 anycast gateways.
add_vni() {  # bridge mac vni
  ip link add "$1" type bridge
  ip link set "$1" address "$2"
  ip link set "$1" master TENANT-A
  ip link set "$1" up
  ip link add "vx$1" type vxlan id "$3" local "$vtep" dstport 4789 nolearning
  ip link set "vx$1" master "$1"
  ip link set "vx$1" up
  # ARP suppression is mandatory with anycast gateways. Without it a leaf
  # floods the ARP for a remote host, and the reply is answered by whichever
  # leaf is local to that host, because every leaf shares the gateway MAC.
  # The requesting leaf never sees it. With it, the leaf answers from the
  # EVPN type-2 MAC/IP routes and never floods.
  bridge link set dev "vx$1" neigh_suppress on
  bridge link set dev "vx$1" learning off
}
add_vni br10 02:00:00:00:10:01 1010
add_vni br20 02:00:00:00:20:01 1020

for p in "${ports[@]}"; do
  ip link set "$p" up
  ip link set "$p" master "$access"
done
