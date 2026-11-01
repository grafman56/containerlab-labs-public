#!/usr/bin/env bash
# usage: setup-border-identity.sh <vtep-loopback>
#
# Additive to setup-border.sh. Gives the border the visitor VRF and its own
# dot1q subinterface to the firewall -- the VRF-lite hand-off a Palo Alto
# actually takes, since the firewall is not a VTEP and speaks no EVPN.
set -uo pipefail
vtep=$1

ip link add EDUROAM type vrf table 4200
ip link set EDUROAM up

ip link add vxlan4200 type vxlan id 4200 local "$vtep" dstport 4789 nolearning
ip link add br4200 type bridge
ip link set vxlan4200 master br4200
ip link set br4200 master EDUROAM
ip link set vxlan4200 up
ip link set br4200 up

# One subinterface per zone on the existing firewall link. FRR configures the
# address and the peering; the kernel has to create the interface first.
ip link add link eth3 name eth3.30 type vlan id 30
ip link set eth3.30 master EDUROAM
ip link set eth3.30 up
