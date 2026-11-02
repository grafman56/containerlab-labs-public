#!/usr/bin/env bash
# Run once after `netlab up`: load the fw zone policy, and point each host's
# default route at its leaf (netlab leaves the default on the mgmt network).
P=clab-evpn-srlinux
# docker cp, not a bind mount: editing fw-zones.nft and re-running this just works.
docker cp "$(dirname "$0")/fw-zones.nft" $P-fw:/etc/zones.nft
docker exec $P-fw nft -f /etc/zones.nft && echo "fw zones loaded"
# fw learns every prefix from both VRFs but sends each VRF only a default route.
# Re-advertising each zone's prefixes back into the fabric made l2 prefer a path
# through l1 and the packets looped between the leaves.
docker exec $P-fw vtysh -c "conf t" \
  -c "ip prefix-list NONE seq 5 deny 0.0.0.0/0 le 32" \
  -c "router bgp 65100" -c "address-family ipv4 unicast" \
  -c "neighbor 10.0.0.11 default-originate" -c "neighbor 10.0.0.13 default-originate" \
  -c "neighbor 10.0.0.11 prefix-list NONE out" -c "neighbor 10.0.0.13 prefix-list NONE out" 2>&1 | grep -v "^$"
docker exec $P-fw vtysh -c "clear bgp * soft out" >/dev/null
for h in h1 h2 h3 h4; do
  gw=$(docker exec $P-$h ip route | awk '/^10.0.0.0\/24 via/{print $3}')
  docker exec $P-$h ip route replace default via "$gw" && echo "$h default via $gw"
done
