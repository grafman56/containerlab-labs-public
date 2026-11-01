#!/usr/bin/env bash
set -euo pipefail

lab=clab-evpn-vxlan-campus
spines="spine1a spine2a spine1b spine2b"
leaves="leaf1a leaf2a leaf1b leaf2b"
vteps="leaf1a leaf2a leaf1b leaf2b bdr-a bdr-a2 bdr-b bdr-b2"
fws="fw-a fw-b"
hosts="host1 host2 host3 host4"

for node in $spines $vteps $fws inet-a inet-b inet-res $hosts; do
  docker inspect "${lab}-${node}" >/dev/null
done

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== OSPF underlay =="
for node in $spines $vteps; do
  n=$(docker exec "${lab}-${node}" vtysh -c "show ip ospf neighbor" | grep -c Full || true)
  echo "${node}: ${n} full adjacencies"
  [ "$n" -ge 2 ] || fail "${node} has ${n} OSPF adjacencies, expected >= 2"
done

echo "== Site link: exactly one point-to-point link joins the two sites =="
dci=$(docker exec "${lab}-spine2a" vtysh -c "show ip ospf neighbor json" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for v in d.get("neighbors",{}).values() for n in v if n.get("ifaceName","").startswith("eth4")))')
echo "spine2a site-link adjacencies: ${dci}"
[ "$dci" -eq 1 ] || fail "expected exactly 1 site-link adjacency on spine2a, found ${dci}"

echo "== EVPN full mesh: every VTEP peers with the other seven =="
for node in $vteps; do
  n=$(docker exec "${lab}-${node}" vtysh -c "show bgp l2vpn evpn summary json" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for p in d.get("peers",{}).values() if p.get("state")=="Established"))')
  echo "${node}: ${n} established EVPN peers"
  [ "$n" -eq 7 ] || fail "${node} has ${n} EVPN peers, expected 7"
done

echo "== VNI state =="
for node in $leaves; do
  docker exec "${lab}-${node}" vtysh -c "show evpn vni"
done

# Each leaf advertises a type-2 MAC/IP route only for endpoints whose ARP it
# has actually learned, and the kernel ages those entries out when a host goes
# quiet. Real endpoints are chatty, idle lab hosts are not, so have each host
# announce itself first. The control plane still has to do all the work of
# distributing those routes; this only replaces the background noise a real
# network would have.
for h in $hosts; do
  gw=$(docker exec "${lab}-${h}" ip route | awk '/^10\./ {print $3; exit}')
  docker exec "${lab}-${h}" ping -c 1 -W 1 "$gw" >/dev/null 2>&1 || true
done
sleep 5

echo "== Stretched L2: host1 (campus A) to host3 (campus B), same VNI 1010 =="
docker exec "${lab}-host1" ping -c 3 -W 2 10.10.10.13 >/dev/null || fail "host1 cannot reach host3"
echo "ok"

echo "== Symmetric IRB: host1 (VNI 1010) to host4 (VNI 1020, campus B) =="
docker exec "${lab}-host1" ping -c 3 -W 2 10.20.20.14 >/dev/null || fail "host1 cannot reach host4"
echo "ok"

echo "== Internet egress, both campuses =="
docker exec "${lab}-host1" ping -c 3 -W 2 203.0.113.1 >/dev/null || fail "host1 cannot reach the internet"
docker exec "${lab}-host3" ping -c 3 -W 2 203.0.113.2 >/dev/null || fail "host3 cannot reach the internet"
echo "ok"

echo "== Each campus prefers its primary border for the default route =="
default_via() {
  docker exec "${lab}-$1" vtysh -c "show ip route vrf TENANT-A 0.0.0.0/0 json" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["0.0.0.0/0"][0]["nexthops"][0].get("ip",""))'
}
check_exit() {  # leaf expected-vtep
  got=$(default_via "$1")
  echo "$1 default via ${got} (expected $2)"
  [ "$got" = "$2" ] || fail "$1 exits via ${got}, expected $2"
}
check_exit leaf1a 10.255.1.1
check_exit leaf1b 10.255.1.2

echo "== Border failover: campus A uses its secondary border =="
docker exec "${lab}-bdr-a" vtysh -c "conf t" -c "router bgp 65000 vrf TENANT-A" \
  -c "neighbor 198.51.100.1 shutdown" >/dev/null
sleep 10
got=$(default_via leaf1a || true)
echo "leaf1a default via ${got} (expected 10.255.1.3, campus A secondary border)"
[ "$got" = "10.255.1.3" ] || { docker exec "${lab}-bdr-a" vtysh -c "conf t" -c "router bgp 65000 vrf TENANT-A" -c "no neighbor 198.51.100.1 shutdown" >/dev/null; fail "campus A did not select its secondary border"; }
docker exec "${lab}-host1" ping -c 3 -W 2 203.0.113.1 >/dev/null \
  || { docker exec "${lab}-bdr-a" vtysh -c "conf t" -c "router bgp 65000 vrf TENANT-A" -c "no neighbor 198.51.100.1 shutdown" >/dev/null; fail "host1 lost internet after primary border failure"; }
docker exec "${lab}-bdr-a" vtysh -c "conf t" -c "router bgp 65000 vrf TENANT-A" \
  -c "no neighbor 198.51.100.1 shutdown" >/dev/null
sleep 10
check_exit leaf1a 10.255.1.1
echo "ok, campus A returned to its primary border"

echo "== Site failover: campus A loses both border paths and uses campus B =="
restore_a_borders() {
  docker exec "${lab}-bdr-a" vtysh -c "conf t" -c "router bgp 65000 vrf TENANT-A" \
    -c "no neighbor 198.51.100.1 shutdown" >/dev/null 2>&1 || true
  docker exec "${lab}-bdr-a2" vtysh -c "conf t" -c "router bgp 65000 vrf TENANT-A" \
    -c "no neighbor 198.51.100.17 shutdown" >/dev/null 2>&1 || true
}
trap restore_a_borders EXIT
docker exec "${lab}-bdr-a" vtysh -c "conf t" -c "router bgp 65000 vrf TENANT-A" \
  -c "neighbor 198.51.100.1 shutdown" >/dev/null
docker exec "${lab}-bdr-a2" vtysh -c "conf t" -c "router bgp 65000 vrf TENANT-A" \
  -c "neighbor 198.51.100.17 shutdown" >/dev/null
sleep 10
got=$(default_via leaf1a || true)
echo "leaf1a default via ${got} (expected 10.255.1.2, campus B border)"
[ "$got" = "10.255.1.2" ] || fail "campus A did not fail over to campus B"
docker exec "${lab}-host1" ping -c 3 -W 2 203.0.113.2 >/dev/null \
  || fail "host1 lost internet after both campus A border paths failed"
docker exec "${lab}-bdr-a" vtysh -c "conf t" -c "router bgp 65000 vrf TENANT-A" \
  -c "no neighbor 198.51.100.1 shutdown" >/dev/null
docker exec "${lab}-bdr-a2" vtysh -c "conf t" -c "router bgp 65000 vrf TENANT-A" \
  -c "no neighbor 198.51.100.17 shutdown" >/dev/null
trap - EXIT
sleep 10
check_exit leaf1a 10.255.1.1
echo "ok, campus A returns to its primary border"

echo "== Non-fabric buildings: area 1 totally stubby vs area 2 NSSA =="
ospf_routes() { docker exec "${lab}-$1" vtysh -c "show ip route ospf" 2>/dev/null | grep -c "^O" || true; }
lsas()        { docker exec "${lab}-$1" vtysh -c "show ip ospf database" 2>/dev/null | grep -cE "^[0-9]+\\.[0-9]"; }

a1r=$(ospf_routes acc-a1); b1r=$(ospf_routes acc-b1)
a1l=$(lsas acc-a1);        b1l=$(lsas acc-b1)
echo "area 1 (totally stubby): ${a1l} LSAs, ${a1r} OSPF route(s)"
echo "area 2 (NSSA):           ${b1l} LSAs, ${b1r} OSPF routes"
[ "$a1r" -eq 1 ] || fail "area 1 should carry exactly one OSPF route, the default; found ${a1r}"
[ "$b1r" -gt "$a1r" ] || fail "the NSSA should carry more routes than the totally stubby area"
[ "$b1l" -gt "$a1l" ] || fail "the NSSA LSDB should be larger than the totally stubby one"

echo "== Building B1 has its own provider, which is what forces NSSA =="
docker exec "${lab}-acc-b1" vtysh -c "show bgp ipv4 unicast summary" 2>/dev/null \
  | grep -q "65400" || fail "acc-b1 has no eBGP session with its research provider"
docker exec "${lab}-acc-b1" vtysh -c "show ip route 203.0.113.3/32" 2>/dev/null \
  | grep -q "bgp" || fail "acc-b1 did not learn the research network over eBGP"
echo "ok, acc-b1 is a genuine ASBR"

echo "== That route enters area 2 as a type 7 and leaves area 0 as a type 5 =="
docker exec "${lab}-acc-b1" vtysh -c "show ip ospf database nssa-external" 2>/dev/null \
  | grep -q "203.0.113.3" || fail "acc-b1 is not originating a type 7 for the research network"
docker exec "${lab}-spine1a" vtysh -c "show ip ospf database external" 2>/dev/null \
  | grep -q "203.0.113.3" || fail "dist-b1 did not translate the type 7 into a type 5 for area 0"
echo "ok, translated at the ABR"

echo "== The totally stubby area is shielded from it entirely =="
n=$(docker exec "${lab}-acc-a1" vtysh -c "show ip ospf database external" 2>/dev/null | grep -c "203.0.113.3" || true)
[ "$n" -eq 0 ] || fail "the totally stubby area must not see external LSAs, saw ${n}"
docker exec "${lab}-user-a1" ping -c 3 -W 2 203.0.113.3 >/dev/null \
  || fail "user-a1 cannot reach the research network over its default"
echo "ok, blocked as a type 5 yet still reachable over the default"

echo "== A building user reaches the fabric core over the injected default =="
docker exec "${lab}-user-a1" ping -c 3 -W 2 10.255.255.1 >/dev/null \
  || fail "user-a1 cannot reach the fabric core"
echo "ok"

echo "== Firewall is an OSPF ASBR originating a type 5 default =="
docker exec "${lab}-fw-a" vtysh -c "show ip ospf database self-originate" 2>/dev/null \
  | grep -q "0.0.0.0" || fail "fw-a is not originating a type 5 default"
docker exec "${lab}-spine1a" vtysh -c "show ip route 0.0.0.0/0" 2>/dev/null \
  | grep -q "10.0.5.1" || fail "area 0 did not learn the default from fw-a"
echo "ok, area 0 learns it from 10.0.5.1"

echo "== Neither non-zero area accepts that type 5 =="
for pair in "acc-a1:totally-stubby" "acc-b1:NSSA"; do
  n=$(docker exec "${lab}-${pair%%:*}" vtysh -c "show ip ospf database external" 2>/dev/null \
      | grep -c "0.0.0.0" || true)
  echo "${pair#*:} area external LSAs for the default: ${n}"
  [ "$n" -eq 0 ] || fail "${pair%%:*} should not hold a type 5 default, found ${n}"
done
echo "ok, both get a default from their own ABR instead"

echo "== Campus building users reach the internet through the firewall =="
docker exec "${lab}-user-a1" ping -c 3 -W 2 203.0.113.1 >/dev/null \
  || fail "user-a1 cannot reach the internet"
docker exec "${lab}-user-b1" ping -c 3 -W 2 203.0.113.2 >/dev/null \
  || fail "user-b1 cannot reach the internet"
echo "ok"

echo "PASS: two-campus EVPN-VXLAN fabric verified"
