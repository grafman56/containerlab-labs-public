#!/usr/bin/env bash
# Checks the MPLS L3VPN over SR-MPLS lab end to end. Waits up to 120 s for convergence.
set -euo pipefail

lab=clab-mpls-sr-l3vpn
v() { local n=$1; shift; docker exec "${lab}-$n" vtysh -c "$*" 2>/dev/null; }
x() { local n=$1; shift; docker exec "${lab}-$n" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# Poll a command until it succeeds, so a fresh deploy has time to converge.
wait_for() {
  local what=$1; shift
  for _ in $(seq 40); do "$@" >/dev/null 2>&1 && { echo "ok: $what"; return; }; sleep 3; done
  fail "$what"
}

for node in pe1 pe2 p1 p2 ce1a ce2a ce1b ce2b; do
  docker inspect "${lab}-${node}" >/dev/null || fail "container ${node} missing"
done

[[ $(x pe1 cat /proc/sys/net/mpls/platform_labels) != 0 ]] ||
  fail "host is missing mpls_router (sudo modprobe mpls_router mpls_iptunnel)"

# Capture first, then grep. "cmd | grep -q" can kill cmd with SIGPIPE, which
# pipefail reports as a failure (or, under "!", as a pass that hides a leak).
has_route(){ local o; o=$(v "$1" show ip bgp) && grep -q "$2" <<<"$o"; }

isis_up()  { [[ $(v "$1" show isis neighbor | grep -c ' Up ') -ge 2 ]]; }
# Every router must see all four SR nodes, each advertising the 16000-23999 block.
sr_up()    { [[ $(v "$1" show isis segment-routing node | grep -c '16000 - 23999') -ge 4 ]]; }
vpn_up()   { v "$1" show bgp ipv4 vpn summary | awk '$1 ~ /^10\.0\.0\./ && $10 ~ /^[0-9]+$/ {f=1} END {exit !f}'; }
for n in pe1 pe2 p1 p2; do wait_for "IS-IS adjacencies on $n" isis_up "$n"; done
for n in pe1 pe2 p1 p2; do wait_for "SR nodes on $n" sr_up "$n"; done
for n in pe1 pe2; do wait_for "VPNv4 session on $n" vpn_up "$n"; done

echo "No LDP: transport labels come from segment routing"
for n in pe1 pe2 p1 p2; do
  ldp=$(v "$n" show mpls ldp neighbor || true)
  ! grep -q OPERATIONAL <<<"$ldp" || fail "$n has an LDP session"
done
echo "ok: no LDP sessions"

echo "Transport: two equal-cost SR paths between the PEs, label = SRGB 16000 + node index 2"
ecmp=$(v pe1 show ip route 10.0.0.2/32)
printf '%s\n' "$ecmp"
[[ $(grep -c 'label 16002' <<<"$ecmp") -ge 2 ]] || fail "pe1 has no two-path SR route to pe2 with label 16002"

echo "TI-LFA: every core router has a precomputed backup for every IS-IS prefix"
for n in pe1 pe2 p1 p2; do
  frr=$(v "$n" show isis fast-reroute summary)
  grep -q 'Topology Independent LFA' <<<"$frr" || fail "$n has no TI-LFA"
  unprot=$(awk '/^ Unprotected/ {print $NF}' <<<"$frr")
  [[ $unprot == 0 ]] || fail "$n has $unprot unprotected prefixes"
done
echo "ok: 0 unprotected prefixes on pe1, pe2, p1, p2"
echo "Repair stack: p1's backup to pe2 goes back through pe1, steered by p2's node SID"
bk=$(v p1 show ip route 10.0.0.2/32)
grep -q 'b 10.1.1.1, via eth1, label 16012/16002' <<<"$bk" ||
  fail "p1 has no 16012/16002 backup to pe2 via pe1"
echo "ok: p1 backup to pe2 = push 16012/16002 via pe1"

echo "Customer routes cross the core"
wait_for "ce1a learns 10.10.2.0/24" has_route ce1a '10.10.2.0/24'
wait_for "ce1b learns 10.10.2.0/24" has_route ce1b '10.10.2.0/24'

echo "Isolation: the A-only and B-only prefixes stay in their own VPN"
has_route ce1a '172.16.100.0/24' || fail "ce1a lacks its own VPN prefix"
has_route ce1b '172.16.200.0/24' || fail "ce1b lacks its own VPN prefix"
! has_route ce1a '172.16.200.0/24' || fail "customer B prefix leaked into A"
! has_route ce1b '172.16.100.0/24' || fail "customer A prefix leaked into B"
echo "ok: no leak either way"

echo "Overlap: both customers use 10.10.1.0/24 and 10.10.2.0/24"
a=$(v ce1a show ip bgp 10.10.2.0/24); b=$(v ce1b show ip bgp 10.10.2.0/24)
grep -q '65000 65102' <<<"$a" || fail "A's 10.10.2.0/24 did not come from A's site 2"
grep -q '65000 65202' <<<"$b" || fail "B's 10.10.2.0/24 did not come from B's site 2"
echo "ok: same prefix, different origin AS per VPN"

echo "Label stack: SR transport label / VPN label on the PE VRF route"
stack=$(x pe1 ip route show vrf CUST-A 10.10.2.0/24)
printf '%s\n' "$stack"
grep -Eq 'encap mpls +16002/[0-9]+' <<<"$stack" || fail "no 16002/<vpn label> stack in CUST-A"

echo "BGP-free core: P routers hold no customer routes"
p1_routes=$(x p1 ip route show)
! grep -q '10\.10\.2\.0' <<<"$p1_routes" || fail "p1 knows a customer route"
[[ -n $(x p1 ip -f mpls route) ]] || fail "p1 has no MPLS forwarding entries"
echo "ok: p1 forwards on labels only"

echo "Data plane"
x ce1a ping -c 2 -W 2 -I 10.10.1.1 10.10.2.1 >/dev/null || fail "A site1 -> site2 ping"
x ce1b ping -c 2 -W 2 -I 10.10.1.1 10.10.2.1 >/dev/null || fail "B site1 -> site2 ping"
echo "ok: both VPNs forward end to end"

echo "PASS: IS-IS, SR-MPLS, TI-LFA, VPNv4, label stack, isolation, overlap and data plane verified"
