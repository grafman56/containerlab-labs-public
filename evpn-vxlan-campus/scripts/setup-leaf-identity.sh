#!/usr/bin/env bash
# usage: setup-leaf-identity.sh <vtep-loopback> <trunk-port>
#
# Additive to setup-leaf.sh. Adds the second zone and turns one access port
# into an 802.1Q trunk, which is what the campus looks like once an access
# switch with more than one VLAN hangs off the leaf.
#
#   VRF EDUROAM   L3VNI 4200   L2VNI 1030   10.30.30.0/24
#
# Why a separate VRF and not just a second VLAN in TENANT-A: an eduroam
# visitor must not reach campus resources, and the cheapest way to guarantee
# that is for the route simply not to exist in their table. A deny rule you
# can misconfigure is weaker than a route that was never imported.
set -uo pipefail
vtep=$1
trunk=$2

ip link add EDUROAM type vrf table 4200
ip link set EDUROAM up

# L3 VNI needs its own bridge as the SVI -- same reason as TENANT-A/br4100.
ip link add vxlan4200 type vxlan id 4200 local "$vtep" dstport 4789 nolearning
ip link add br4200 type bridge
ip link set vxlan4200 master br4200
ip link set br4200 master EDUROAM
ip link set vxlan4200 up
ip link set br4200 up

# L2 VNI 1030, anycast gateway, same identical-bridge-MAC trick as br10/br20.
ip link add br30 type bridge
ip link set br30 address 02:00:00:00:30:01
ip link set br30 master EDUROAM
ip link set br30 up
ip link add vxbr30 type vxlan id 1030 local "$vtep" dstport 4789 nolearning
ip link set vxbr30 master br30
ip link set vxbr30 up
bridge link set dev vxbr30 neigh_suppress on
bridge link set dev vxbr30 learning off

# The trunk. The port already belongs to br10 from setup-leaf.sh; take it back
# and hand each VLAN to its own zone bridge instead.
ip link set "$trunk" nomaster
ip link set "$trunk" up
for v in 10:br10 30:br30; do
  vlan=${v%%:*}; br=${v##*:}
  ip link add link "$trunk" name "${trunk}.${vlan}" type vlan id "$vlan"
  ip link set "${trunk}.${vlan}" master "$br"
  ip link set "${trunk}.${vlan}" up
done
