#!/usr/bin/env bash
# edge-a1: the access switch.
#
#   eth1          802.1Q trunk up to leaf1a, carrying VLAN 10 and VLAN 30
#   eth2, eth3    client ports, 802.1X controlled, NOT bridged
#
# The client ports are deliberately left out of any bridge. Two reasons, and
# both matter:
#
#  1. An unauthenticated port must not forward. If eth2 were already in the
#     staff bridge, the client would have access before it authenticated and
#     802.1X would be decoration.
#  2. hostapd's wired driver reads EAPOL off a raw socket on the interface. A
#     bridge consumes those frames first, so hostapd sees the supplicant's
#     first packet and none of its replies, and retransmits forever. If you
#     ever see CTRL-EVENT-EAP-RETRANSMIT2 in a loop, check this.
#
# Putting a port into a zone is therefore an explicit step -- authorize-port.sh
# -- which is exactly what a real switch does when it reads
# Tunnel-Private-Group-ID out of the Access-Accept. Here you do it by hand so
# you can see the attribute and the action as two separate things.
set -uo pipefail
exec >>/tmp/setup-edge.log 2>&1
echo "=== setup-edge $(date -Is) ==="
set -x

/cfg/wait-for-link.sh eth1 eth2 eth3 eth4

ip link set eth1 up

# One VLAN subinterface and one bridge per zone. The bridge is what a client
# port gets added to once it has authenticated into that zone.
#   VLAN 10 -> VNI 1010, VRF TENANT-A   campus staff
#   VLAN 30 -> VNI 1030, VRF EDUROAM    visitors, internet-only
mk_zone() {  # vlan bridge
  ip link show "eth1.$1"  >/dev/null 2>&1 || ip link add link eth1 name "eth1.$1" type vlan id "$1"
  ip link show "$2"       >/dev/null 2>&1 || ip link add "$2" type bridge
  ip link set "eth1.$1" master "$2"
  ip link set "eth1.$1" up
  ip link set "$2" up
}
mk_zone 10 br-staff
mk_zone 30 br-eduroam

# eth4 is the access point's trunk. Same VLANs, same zone bridges, so a
# wireless station and a wired station in the same VLAN share one segment and
# one VNI -- which is the point. The AP tags; this just carries it.
ip link set eth4 up
# Untagged frames from the AP are its management traffic, on the native VLAN.
# Tagged frames are its stations. Both end up in the right zone bridge: the
# kernel delivers tagged frames to the subinterface and untagged to eth4
# itself, so nothing is duplicated.
ip link set eth4 master br-staff
for v in 10:br-staff 30:br-eduroam; do
  vid=${v%%:*}; br=${v##*:}
  ip link show "eth4.$vid" >/dev/null 2>&1 || ip link add link eth4 name "eth4.$vid" type vlan id "$vid"
  ip link set "eth4.$vid" master "$br"
  ip link set "eth4.$vid" up
done

# The switch's own address, in the staff VLAN. RADIUS is sourced from here,
# which is why 10.10.10.0/24 is the client subnet on the NAC.
ip address replace 10.10.10.20/24 dev br-staff
ip route replace default via 10.10.10.1

# The relay needs an address in EVERY zone it relays for, because giaddr is
# taken from the interface the request arrived on. Without this, visitor DHCP
# is relayed with giaddr 0.0.0.0 and the server has no idea which subnet to
# allocate from.
ip address replace 10.30.30.20/24 dev br-eduroam

# See identity/keepalive.sh for why an idle endpoint goes unreachable.
pkill -f keepalive.sh 2>/dev/null || true
nohup /cfg/keepalive.sh 10.10.10.1 >/dev/null 2>&1 &
sleep 2

# Client ports: up, unbridged, 802.1X. One hostapd instance per port, because
# the wired driver has no concept of a BSS to share.
pkill -f 'hostapd -B' 2>/dev/null || true
sleep 1
for port in eth2 eth3; do
  ip link set "$port" nomaster 2>/dev/null || true
  ip link set "$port" up
  hostapd -B -f "/tmp/hostapd-${port}.log" "/cfg/edge/hostapd-${port}.conf"
done

# DHCP relay for both zones. It lives on the switch rather than on a leaf
# because the leaves run FRR, which has no relay. See the README for why that
# placement also hides the anycast-gateway giaddr problem from you.
pkill dhcrelay 2>/dev/null || true
sleep 1
# No DHCP relay here. The switch's uplink eth1.10 is a member of br-staff, so
# "upstream" and "downstream" are one segment and a relay has nothing to do.
# The DDI node therefore has a leg directly on the staff segment instead. See
# README "Things to build" for putting the relay where it belongs.
echo "=== setup-edge done ==="
