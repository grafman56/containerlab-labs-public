#!/usr/bin/env bash
# Load the zone policy. Separate from setup-fw-identity.sh so the ruleset can
# be reloaded by hand while you are experimenting:
#
#   docker exec clab-evpn-vxlan-campus-fw-a nft -f /policy/zones.nft
#   docker exec clab-evpn-vxlan-campus-fw-a nft list ruleset
#   docker exec clab-evpn-vxlan-campus-fw-a nft list chain inet zones forward
#
# Counters on the drop rule tell you whether anything is actually being
# stopped, which is the first thing to check when someone says "the firewall
# is blocking it" and the second thing to check when they say it is not.
set -uo pipefail
for _ in $(seq 1 30); do
  ip link show eth3 >/dev/null 2>&1 && break
  sleep 1
done
nft -f /policy/zones.nft
