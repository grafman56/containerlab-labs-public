#!/usr/bin/env bash
set -euo pipefail

lab=${LAB:-clab-ibgp-rr}
route_output=$(docker exec "${lab}-p3" vtysh -c "show ip bgp 203.0.113.0/24")
neighbor_output=$(docker exec "${lab}-p3" vtysh -c "show ip bgp neighbors 10.0.0.11")

grep -q "Network not in table" <<<"$route_output"
grep -q "BGP state = Established" <<<"$neighbor_output"

echo "PASS: P3 lacks the service prefix while its RR1 session remains established"
