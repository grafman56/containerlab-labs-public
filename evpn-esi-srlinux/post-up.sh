#!/usr/bin/env bash
# Run once after `netlab up`. netlab builds the fabric but has no ESI support
# for SR Linux, so this script adds:
#   - on l1 and l2: a LACP LAG on ethernet-1/4 and one all-active Ethernet Segment
#   - on h3: an 802.3ad bond over eth1 and eth2, with the host address
# Safe to run again: it replaces the LAG config and the bond.
set -euo pipefail
P=clab-evpn-esi
PORT=ethernet-1/4                 # the port netlab gives the h3 cable on each leaf
ESI=00:01:01:01:01:01:01:01:01:01 # same value on both leaves: that is what makes it one segment
LACP_MAC=00:00:00:00:10:10        # same LACP system ID on both leaves: h3 sees one switch
H3_ADDR=10.10.10.23/24

for l in l1 l2; do
  out=$(docker exec -i $P-$l sr_cli <<EOF 2>&1
enter candidate
delete / network-instance default interface $PORT.0
delete / interface $PORT subinterface 0
set / interface lag1 admin-state enable
set / interface lag1 vlan-tagging true
set / interface lag1 subinterface 10 type bridged
set / interface lag1 subinterface 10 vlan encap untagged
set / interface lag1 lag lag-type lacp
set / interface lag1 lag member-speed 25G
set / interface lag1 lag lacp interval FAST
set / interface lag1 lag lacp lacp-mode ACTIVE
set / interface lag1 lag lacp admin-key 1
set / interface lag1 lag lacp system-id-mac $LACP_MAC
set / interface lag1 lag lacp system-priority 1
set / interface $PORT admin-state enable
set / interface $PORT ethernet aggregate-id lag1
set / network-instance vlan10 interface lag1.10
set / system network-instance protocols bgp-vpn bgp-instance 1
set / system network-instance protocols evpn ethernet-segments bgp-instance 1 ethernet-segment es1 admin-state enable
set / system network-instance protocols evpn ethernet-segments bgp-instance 1 ethernet-segment es1 esi $ESI
set / system network-instance protocols evpn ethernet-segments bgp-instance 1 ethernet-segment es1 multi-homing-mode all-active
set / system network-instance protocols evpn ethernet-segments bgp-instance 1 ethernet-segment es1 interface lag1
commit now
EOF
  )
  if grep -qi "error" <<<"$out"; then echo "$l: FAILED"; echo "$out"; exit 1; fi
  echo "$l: lag1 and es1 configured"
done

# The host image has BusyBox `ip`, which ignores bond options. Set them in sysfs.
docker exec $P-h3 sh -c "
  ip addr flush dev bond0 2>/dev/null; ip link set bond0 down 2>/dev/null; ip link del bond0 2>/dev/null
  ip link set eth1 down; ip link set eth2 down
  echo +bond0 > /sys/class/net/bonding_masters
  echo 802.3ad > /sys/class/net/bond0/bonding/mode
  echo 100 > /sys/class/net/bond0/bonding/miimon
  echo fast > /sys/class/net/bond0/bonding/lacp_rate
  echo layer3+4 > /sys/class/net/bond0/bonding/xmit_hash_policy
  ip link set eth1 master bond0; ip link set eth2 master bond0
  ip link set bond0 up; ip link set eth1 up; ip link set eth2 up
  ip addr add $H3_ADDR dev bond0"
echo "h3: bond0 (802.3ad) up with $H3_ADDR"

# LACP takes a few seconds to bundle.
for _ in $(seq 1 30); do
  n=$(docker exec $P-h3 grep -c "Partner Mac Address: 00:00:00:00:10:10" /proc/net/bonding/bond0 || true)
  [ "$n" -ge 1 ] && { echo "LACP bundled: h3 sees the leaves as one switch"; exit 0; }
  sleep 2
done
echo "LACP did not bundle in 60 s. Run ./show-es.sh" >&2
exit 1
