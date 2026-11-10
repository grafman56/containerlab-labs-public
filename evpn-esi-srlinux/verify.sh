#!/usr/bin/env bash
# Checks the lab end to end. Run on the Containerlab host after post-up.sh.
# It breaks each leaf's h3 port in turn and always restores it.
# Exits non-zero on any failure.
set -uo pipefail
cd "$(dirname "$0")"
P=clab-evpn-esi
ESI=00:01:01:01:01:01:01:01:01:01
fail=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1"; fail=1; }
has()  { grep -q "$3" <<<"$2" && ok "$1" || bad "$1"; }          # name, text, pattern
ping_() { docker exec $P-$2 ping -c2 -W2 "$3" >/dev/null 2>&1 && got=ok || got=fail
          [ "$got" = "$1" ] && ok "$4" || bad "$4 (wanted $1, got $got)"; }  # want, host, ip, name
es()   { docker exec $P-$1 sr_cli "show system network-instance ethernet-segments"; }
bond() { docker exec $P-h3 cat /proc/net/bonding/bond0; }

port() { # leaf, enable|disable
  docker exec -i $P-$1 sr_cli <<EOF >/dev/null
enter candidate
set / interface ethernet-1/4 admin-state $2
commit now
EOF
}
wait_for() { # seconds, command...: wait until the command succeeds
  local t=$1; shift
  for _ in $(seq 1 "$t"); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done; return 1
}
two_candidates() { [ "$(es "$1" | grep -c "Candidates : .*,")" -ge 1 ]; }
bundled() { [ "$(bond | grep -c "MII Status: up")" -eq 3 ] &&
            [ "$(bond | grep "Aggregator ID" | sed "s/^[[:space:]]*//" | sort -u | wc -l)" -eq 1 ] &&
            bond | grep -q "Partner Mac Address: 00:00:00:00:10:10"; }
restore() { port l1 enable; port l2 enable; }
trap restore EXIT

echo "VLAN to VNI on the leaves"
vni=$(./show-vni.sh)
has "VLAN 10 is VNI 1010" "$vni" "vxlan0.10 .*VNI 1010"

echo "LACP between h3 and the leaves"
wait_for 30 bundled && ok "bond0 has both links in one aggregator" || bad "bond0 has both links in one aggregator"
has "h3 sees one LACP partner (shared system ID)" "$(bond)" "Partner Mac Address: 00:00:00:00:10:10"
has "bond mode is 802.3ad" "$(bond)" "IEEE 802.3ad"

echo "Ethernet Segment"
for l in l1 l2; do
  e=$(es $l)
  has "$l: es1 is up, all-active" "$e" "es1 is up, all-active"
  has "$l: ESI $ESI" "$e" "$ESI"
  two_candidates $l && ok "$l: both leaves are DF candidates" || bad "$l: both leaves are DF candidates"
done
dfs=$( (es l1; es l2) | grep -o "10.255.0.1[12] (DF)" | sort -u | wc -l)
[ "$dfs" = 1 ] && ok "both leaves agree on one DF" || bad "both leaves agree on one DF ($dfs seen)"

echo "EVPN routes for the segment"
for l in l1 l2; do
  [ $l = l1 ] && peer=10.255.0.12 || peer=10.255.0.11
  r4=$(docker exec $P-$l sr_cli "show network-instance default protocols bgp routes evpn route-type 4 summary")
  r1=$(docker exec $P-$l sr_cli "show network-instance default protocols bgp routes evpn route-type 1 summary")
  has "$l: type 4 route from $peer" "$r4" "$ESI .* $peer"
  has "$l: type 1 per-ES route from $peer" "$r1" "$peer:10 .*$ESI .*4294967295"
done

echo "Dataplane"
ping_ ok h1 10.10.10.23 "h1 (l1) -> h3 (dual-homed)"
ping_ ok h2 10.10.10.23 "h2 (l2) -> h3 (dual-homed)"
ping_ ok h1 10.10.10.22 "h1 -> h2, same VLAN over VXLAN"
ping_ ok h3 10.10.10.21 "h3 -> h1"

for down in l1 l2; do
  [ $down = l1 ] && up=l2 || up=l1
  echo "Failure: h3 link to $down goes down"
  port $down disable
  wait_for 15 bash -c "docker exec $P-h3 grep -c 'MII Status: down' /proc/net/bonding/bond0 | grep -q 1"
  has "bond0 sees one link down" "$(bond)" "MII Status: down"
  ping_ ok h1 10.10.10.23 "h1 -> h3 still works"
  ping_ ok h2 10.10.10.23 "h2 -> h3 still works"
  e=$(es $up)
  has "$up: only itself is left as a candidate" "$e" "Candidates : 10.255.0.1[12] (DF)$"
  port $down enable
  wait_for 60 bundled && ok "$down link back, bond bundled" || bad "$down link back, bond bundled"
  wait_for 30 two_candidates $up && ok "$up sees both candidates again" || bad "$up sees both candidates again"
  ping_ ok h1 10.10.10.23 "h1 -> h3 after recovery"
done

[ $fail = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
