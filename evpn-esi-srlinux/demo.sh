#!/usr/bin/env bash
# Narrated tour of the lab, about 2 minutes. Run after post-up.sh.
# PAUSE=1 ./demo.sh waits for Enter between steps. The script restores
# everything it changes.
P=clab-evpn-esi
step() { echo; echo "=== $*"; [ "${PAUSE:-0}" = 1 ] && read -r -p "[Enter] " _; }
port() { docker exec -i $P-$1 sr_cli <<EOF >/dev/null
enter candidate
set / interface ethernet-1/4 admin-state $2
commit now
EOF
}
trap 'port l1 enable; port l2 enable' EXIT

step "1. The VLAN to VNI mapping, read from each leaf"
./show-vni.sh

step "2. The Ethernet Segment. Both leaves share one ESI. One is DF."
docker exec $P-l1 sr_cli "show system network-instance ethernet-segments" | grep -E "is (up|down)|ESI|Peers|Candidates"

step "3. What h3 sees: one LACP partner, two links"
docker exec $P-h3 grep -E "Partner Mac|Slave Interface|MII Status" /proc/net/bonding/bond0

step "4. The EVPN routes that make it work (seen from l1)"
echo "Type 4 (Ethernet Segment): how the leaves find each other and elect the DF"
docker exec $P-l1 sr_cli "show network-instance default protocols bgp routes evpn route-type 4 summary" | grep -E "00:01:01|Type 4"
echo "Type 1 (Auto-Discovery): per-ES (tag 4294967295) is the mass-withdraw route; per-EVI (tag 0) is aliasing"
docker exec $P-l1 sr_cli "show network-instance default protocols bgp routes evpn route-type 1 summary" | grep -E "10.255.0.12:10"

step "5. Traffic from both leaves reaches the dual-homed host"
docker exec $P-h1 ping -c2 10.10.10.23 | tail -2
docker exec $P-h2 ping -c2 10.10.10.23 | tail -2

step "6. Cut h3's link to l1. h3 keeps its address and both hosts keep reaching it."
port l1 disable
sleep 6
docker exec $P-h3 grep -E "Slave Interface|MII Status" /proc/net/bonding/bond0 | paste -sd' '
docker exec $P-h1 ping -c3 10.10.10.23 | tail -2
docker exec $P-h2 ping -c3 10.10.10.23 | tail -2
echo "l2 is now the only DF candidate:"
docker exec $P-l2 sr_cli "show system network-instance ethernet-segments" | grep Candidates

step "7. Restore the link"
port l1 enable
sleep 20
docker exec $P-l1 sr_cli "show system network-instance ethernet-segments" | grep Candidates
docker exec $P-h1 ping -c2 10.10.10.23 | tail -2

echo; echo "Done. Next: README.md, section 'Things to try'."
