#!/usr/bin/env bash
set -euo pipefail

lab=${LAB:-clab-ibgp-rr}
p2="${lab}-p2"
route_output=$(docker exec "$p2" vtysh -c "show ip bgp 203.0.113.0/24")
summary_output=$(docker exec "$p2" vtysh -c "show ip bgp summary")

[[ "$route_output" == *"Network not in table"* ]]
grep -E '10\.0\.0\.11.*[[:space:]]0[[:space:]]+0' <<<"$summary_output" >/dev/null
grep -E '10\.0\.0\.12.*[[:space:]]0[[:space:]]+0' <<<"$summary_output" >/dev/null

echo "PASS: P2 lacks the edge prefix while both RR sessions remain established"
