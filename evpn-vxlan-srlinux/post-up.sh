#!/usr/bin/env bash
# Run once after `netlab up`: load the fw zone policy, and point each host's
# default route at its leaf (netlab leaves the default on the mgmt network).
P=clab-evpn-srlinux
docker exec $P-fw nft -f /etc/zones.nft && echo "fw zones loaded"
# Both VRFs peer with the same fabric AS (65000). Routes the fw re-advertises
# carry 65000 in the path and the leaf drops them as a loop. as-override fixes it.
docker exec $P-fw vtysh -c "conf t" -c "router bgp 65100" \
  -c "neighbor 10.0.0.11 as-override" -c "neighbor 10.0.0.13 as-override" \
  -c "address-family ipv4 unicast" -c "neighbor 10.0.0.11 as-override" -c "neighbor 10.0.0.13 as-override" 2>&1 | grep -v "^$"
for h in h1 h2 h3 h4; do
  gw=$(docker exec $P-$h ip route | awk '/^10.0.0.0\/24 via/{print $3}')
  docker exec $P-$h ip route replace default via "$gw" && echo "$h default via $gw"
done
