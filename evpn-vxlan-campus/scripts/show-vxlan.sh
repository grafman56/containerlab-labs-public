#!/usr/bin/env bash
# Print the VXLAN dataplane of the node this runs in.
#
# FRR has no VLAN-to-VNI command, so there is no vtysh command to copy. The
# mapping lives in the Linux kernel, and zebra reads it from there. This script
# prints the same four views a VTEP switch shows, from those two sources:
#
#   kernel: VXLAN devices, the VLAN to VNI binding, the VNI list
#   zebra:  the EVPN VNIs and the VRF to L3VNI mapping
#
# Run it through the lab wrapper:
#
#   ./labctl show vlan-vni            # leaf1a
#   ./labctl show vlan-vni all        # every VTEP in the fabric
#   ./labctl show vlan-vni bdr-a
#
# Or against any node by hand:
#
#   docker exec -i clab-evpn-vxlan-campus-leaf1a bash -s < scripts/show-vxlan.sh
#
# Read-only. It changes nothing.
set -uo pipefail

BR=/usr/sbin/bridge
[ -x "$BR" ] || BR=$(command -v bridge)

node=$(vtysh -c 'show hostname' 2>/dev/null | head -1)
[ -n "${node:-}" ] || node=$(hostname)

echo "== ${node}: VXLAN devices =="
printf '%-12s %-8s %-15s %s\n' ifname vni local model
svd=0
while IFS='|' read -r ifname vni local model; do
  [ -n "$ifname" ] || continue
  printf '%-12s %-8s %-15s %s\n' "$ifname" "$vni" "$local" "$model"
  case "$model" in *SVD*) svd=1 ;; esac
done < <(
  ip -o -d link show type vxlan 2>/dev/null | awk '
    {
      name = $2; sub(/:$/, "", name)
      id = "-"
      if (match($0, /vxlan id [0-9]+/))
        id = substr($0, RSTART + 9, RLENGTH - 9)
      lcl = "-"
      if (match($0, /local [0-9.]+/))
        lcl = substr($0, RSTART + 6, RLENGTH - 6)
      if ($0 ~ /external/) {
        model = "SVD"
        if ($0 ~ /vnifilter/) model = model ", vnifilter"
        if ($0 ~ /vlan_tunnel on/) model = model ", vlan_tunnel on"
      } else {
        model = "traditional"
      }
      print name "|" id "|" lcl "|" model
    }'
)

if [ "$svd" -eq 0 ]; then
  echo
  echo "No VLAN to VNI binding exists in this node's kernel."
  echo "This lab builds one bridge and one VXLAN device per VNI, with untagged"
  echo "host ports, so no VLAN number ever reaches the dataplane and 'show evpn"
  echo "vni' reports VLAN 1 for every VNI. See DATAPLANE.md."
fi

echo
echo "== ${node}: VLAN to VNI, kernel binding =="
# 'bridge vlan tunnelshow' is the only command in iproute2 that prints this
# table. It reads the tunnel_info set by 'bridge vlan add ... tunnel_info id'.
if "$BR" vlan tunnelshow 2>/dev/null | sed -n '2,$p' | grep -q '[0-9]'; then
  "$BR" vlan tunnelshow
else
  echo "  (empty: no 'tunnel_info' binding on any port)"
fi

if [ "$svd" -eq 1 ]; then
  echo
  echo "== ${node}: VNIs admitted on the single VXLAN device =="
  # 'bridge vni show' prints the vnifilter list, one line per VNI. A
  # traditional device has no such list; its VNI is in the table above.
  if "$BR" vni show 2>/dev/null | sed -n '2,$p' | grep -q '[0-9]'; then
    "$BR" vni show
  else
    echo "  (empty: no VNI added to the vnifilter)"
  fi
fi

if command -v vtysh >/dev/null 2>&1; then
  echo
  echo "== ${node}: VNIs, zebra view =="
  vtysh -c 'show evpn vni' 2>/dev/null || echo "  (zebra does not answer)"

  echo
  echo "== ${node}: VRF to L3VNI, zebra view =="
  vtysh -c 'show vrf vni' 2>/dev/null || echo "  (zebra does not answer)"
fi
