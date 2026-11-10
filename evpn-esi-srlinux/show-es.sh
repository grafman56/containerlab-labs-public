#!/usr/bin/env bash
# Print the multihoming state. Read-only, no redeploy.
# Per leaf: the Ethernet Segment, which leaf is DF, and the type 1 / type 4 routes.
# Then the bond as the host h3 sees it.
P=clab-evpn-esi
for l in l1 l2; do
  echo "== $l: Ethernet Segment"
  docker exec $P-$l sr_cli "show system network-instance ethernet-segments" |
    grep -E "is (up|down)|ESI|Peers|Interface:|Candidates"
  echo "== $l: EVPN routes for the segment"
  r4=$(docker exec $P-$l sr_cli "show network-instance default protocols bgp routes evpn route-type 4 summary" | grep -c "00:01:01:01:01")
  r1=$(docker exec $P-$l sr_cli "show network-instance default protocols bgp routes evpn route-type 1 summary" | grep -c "00:01:01:01:01")
  echo "  type 4 (Ethernet Segment) paths: $r4   type 1 (Auto-Discovery) paths: $r1"
done
echo "== h3: bond0"
docker exec $P-h3 grep -E "Bonding Mode|Partner Mac|Slave Interface|MII Status|Aggregator ID" /proc/net/bonding/bond0 |
  awk '{printf "  %s\n", $0}'
