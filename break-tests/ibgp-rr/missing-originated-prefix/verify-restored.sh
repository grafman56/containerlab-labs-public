#!/usr/bin/env bash
set -euo pipefail

lab=${LAB:-clab-ibgp-rr}
route_output=$(docker exec "${lab}-p3" vtysh -c "show ip bgp 203.0.113.0/24")

grep -q "203.0.113.0/24" <<<"$route_output"
grep -q "Community: 65001:100" <<<"$route_output"

echo "PASS: P3 learns the service prefix and its intended community"
