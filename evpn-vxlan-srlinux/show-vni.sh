#!/usr/bin/env bash
# Print the VLAN/VNI binding as the leaves hold it. Read-only, no redeploy.
# vxlan0.<n> is the VXLAN interface; n is the VLAN id (or the VRF transit index).
# Usage: ./show-vni.sh [leaf ...]   (default: l1 l2)
for leaf in "${@:-l1 l2}"; do
  for l in $leaf; do
    echo "== $l"
    docker exec "clab-evpn-srlinux-$l" sr_cli "info flat from running tunnel-interface vxlan0 vxlan-interface * ingress vni" |
      awk '{printf "  vxlan0.%-4s VNI %s\n", $6, $9}'
    docker exec "clab-evpn-srlinux-$l" sr_cli "info flat from running network-instance * type" |
      awk '$4 != "default" && $4 != "mgmt" {printf "  %-10s %s\n", $4, $6}'
  done
done
