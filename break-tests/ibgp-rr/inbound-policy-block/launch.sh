#!/usr/bin/env bash
set -euo pipefail

lab=${LAB:-clab-ibgp-rr}
p2="${lab}-p2"

: "${CONVERGENCE_WAIT_SECONDS:=2}"
docker inspect "$p2" >/dev/null

docker exec "$p2" vtysh \
  -c "configure terminal" \
  -c "ip prefix-list LAB-BLOCK-EDGE-IN seq 10 permit 203.0.113.0/24" \
  -c "route-map LAB-BLOCK-EDGE-IN deny 10" \
  -c "match ip address prefix-list LAB-BLOCK-EDGE-IN" \
  -c "route-map LAB-BLOCK-EDGE-IN permit 20" \
  -c "router bgp 65000" \
  -c "address-family ipv4 unicast" \
  -c "neighbor 10.0.0.11 route-map LAB-BLOCK-EDGE-IN in" \
  -c "neighbor 10.0.0.12 route-map LAB-BLOCK-EDGE-IN in" \
  -c "end" \
  -c "clear ip bgp 10.0.0.11 soft in" \
  -c "clear ip bgp 10.0.0.12 soft in"

sleep "$CONVERGENCE_WAIT_SECONDS"
echo "Fault injected. Run ./verify-fault.sh before issuing ticket.md."
