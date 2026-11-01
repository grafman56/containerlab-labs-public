#!/usr/bin/env bash
set -euo pipefail

lab=${LAB:-clab-ibgp-rr}
e1="${lab}-e1"

docker inspect "$e1" >/dev/null

docker exec "$e1" vtysh \
  -c "configure terminal" \
  -c "router bgp 65001" \
  -c "address-family ipv4 unicast" \
  -c "no network 203.0.113.0/24 route-map SET-COMM" \
  -c "end" \
  -c "clear ip bgp 172.16.1.1 soft out"

sleep "${CONVERGENCE_WAIT_SECONDS:-2}"

echo "Fault injected. Run ./verify-fault.sh before issuing ticket.md."
