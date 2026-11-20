#!/usr/bin/env bash
# TI-LFA failure drill. Fails the p1-pe2 link while customer A sends traffic, then
# shows that p1 moves to the backup path it computed before the failure.
# Restores the link at the end, also on Ctrl-C. Run on the lab host.
set -euo pipefail

lab=clab-mpls-sr-l3vpn
v() { local n=$1; shift; docker exec "${lab}-$n" vtysh -c "$*" 2>/dev/null; }
x() { local n=$1; shift; docker exec "${lab}-$n" "$@"; }
now() { date +%s.%N; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN {printf "%.1f s", b - a}'; }
nexthops() { v "$1" show ip route "$2" | grep -E '^ +[*b] ' || true; }

ping_log=$(mktemp)
restore() {
  x p1 ip link set eth2 up 2>/dev/null || true
  rm -f "$ping_log"
}
trap restore EXIT

echo "== 1. Before the failure. p1 to pe2 (10.0.0.2): primary, and backup (b)"
before=$(nexthops p1 10.0.0.2/32)
printf '%s\n' "$before"
backup=$(grep -oE 'b [0-9.]+, via eth[0-9]+, label [0-9/]+' <<<"$before" | sed 's/^b //') ||
  { echo "FAIL: p1 has no TI-LFA backup to pe2. Run ./verify.sh first." >&2; exit 1; }
echo "   The backup goes back to pe1 with two labels: 16012 (p2's node SID) on top"
echo "   of 16002 (pe2). Without 16012, pe1 could send the packet back to p1."
echo "   The kernel holds only the primary path:"
x p1 ip -f mpls route show 16002 | sed 's/^/   /'

echo
echo "== 2. Customer A sends 20 pings per second, ce1a 10.10.1.1 -> ce2a 10.10.2.1"
x ce1a ping -q -i 0.05 -c 300 -W 1 -I 10.10.1.1 10.10.2.1 >"$ping_log" 2>&1 &
ping_pid=$!
sleep 2

echo "== 3. Fail the p1-pe2 link (p1 eth2 down)"
t0=$(now)
x p1 ip link set eth2 down

until nexthops p1 10.0.0.2/32 | grep -q "\* ${backup}"; do
  [[ $(awk -v a="$t0" -v b="$(now)" 'BEGIN {print (b - a > 30)}') == 1 ]] &&
    { echo "FAIL: p1 did not move to the backup in 30 s" >&2; exit 1; }
  sleep 0.1
done
echo "   p1 uses the precomputed backup after $(since "$t0"):"
nexthops p1 10.0.0.2/32 | sed 's/^/   /'
echo "   pe1 at the same time (it can still send to p1, and p1 repairs the traffic):"
nexthops pe1 10.0.0.2/32 | sed 's/^/   /'

until [[ $(nexthops pe1 10.0.0.2/32 | grep -c '^ *\*') == 1 ]]; do sleep 0.2; done
echo "   pe1 removes the path through p1 after $(since "$t0"):"
nexthops pe1 10.0.0.2/32 | sed 's/^/   /'

echo
echo "== 4. Customer traffic during the failure"
wait "$ping_pid" || true
grep -E 'transmitted|round-trip' "$ping_log" | sed 's/^/   /'

echo
echo "== 5. Restore the link"
x p1 ip link set eth2 up
until [[ $(nexthops pe1 10.0.0.2/32 | grep -c 'label 16002') -ge 2 ]]; do sleep 0.5; done
echo "   pe1 has two equal-cost paths to pe2 again. Drill done."
