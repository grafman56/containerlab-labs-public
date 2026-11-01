#!/usr/bin/env bash
set -euo pipefail

lab=${LAB:-clab-ibgp-rr}
p2="${lab}-p2"
route_output=$(docker exec "$p2" vtysh -c "show ip bgp 203.0.113.0/24")
config_output=$(docker exec "$p2" vtysh -c "show running-config")

grep -q "Paths: (2 available" <<<"$route_output"
grep -q "Community: 65001:100" <<<"$route_output"
! grep -q "LAB-BLOCK-EDGE-IN" <<<"$config_output"
! grep -q "route-map .* in" <<<"$config_output"

echo "PASS: P2 learns both reflected paths and has no residual drill policy"
