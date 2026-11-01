#!/usr/bin/env bash
# usage: setup-border.sh <vtep-loopback>
set -euo pipefail
vtep=$1

# Border holds only the L3 VNI. No L2 VNIs: it routes tenant traffic out, it
# does not bridge any host segment.
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

ip link set eth3 up
ip link set eth3 master TENANT-A
