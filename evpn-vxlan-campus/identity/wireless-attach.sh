#!/usr/bin/env bash
# Attach simulated radios to the AP and the two stations. Run on the
# containerlab HOST after deploy, from labctl.
#
# mac80211_hwsim creates its phys in the host namespace, so they have to be
# moved in afterwards -- containerlab has no concept of a radio. Two details
# matter:
#
#  1. phy numbering is NOT stable. Reload the module and phy0 becomes phy2.
#     Never hardcode a phy name; enumerate /sys/class/ieee80211 instead. This
#     cost real time to find, because the failure is a bare
#     "command failed: No such file or directory (-2)".
#  2. `iw phy X set netns PID` resolves /proc/PID/ns/net, so whatever runs it
#     needs the HOST pid namespace. Rather than installing iw on the lab host,
#     run it from a throwaway container with --net=host --pid=host.
set -euo pipefail

lab=clab-evpn-vxlan-campus
img=campus-identity:1.1.0
nodes=(ap-a1 sta-staff sta-visitor)

need_radios=${#nodes[@]}

if [ "$(ls /sys/class/ieee80211 2>/dev/null | wc -l)" -lt "$need_radios" ]; then
  sudo -n modprobe -r mac80211_hwsim 2>/dev/null || true
  sleep 1
  sudo -n modprobe mac80211_hwsim "radios=${need_radios}"
  sleep 2
fi

mapfile -t phys < <(ls /sys/class/ieee80211)
[ "${#phys[@]}" -ge "$need_radios" ] || {
  echo "only ${#phys[@]} radios available, need ${need_radios}" >&2; exit 1; }

args=""
for i in "${!nodes[@]}"; do
  pid=$(docker inspect -f '{{.State.Pid}}' "${lab}-${nodes[$i]}")
  args+="iw phy ${phys[$i]} set netns ${pid} && "
  echo "${phys[$i]} -> ${nodes[$i]} (pid ${pid})"
done

sudo -n docker run --rm --net=host --pid=host --privileged "$img" \
  sh -c "${args} true"

# Rename every radio to wlan0 inside its own namespace.
#
# The interface keeps whatever name it had on the host -- wlan1, wlan2, and so
# on -- and those names depend on phy numbering, which changes every time the
# module is reloaded. Configs that hardcode an interface name would silently
# target a non-existent one, and the only symptom is a supplicant that never
# associates while everything else looks healthy. Each namespace holds exactly
# one radio, so wlan0 everywhere is unambiguous.
for n in "${nodes[@]}"; do
  docker exec "${lab}-${n}" sh -c '
    cur=$(ip -br link | grep -o "^wlan[0-9]*" | head -1)
    [ -n "$cur" ] || exit 0
    [ "$cur" = "wlan0" ] && exit 0
    ip link set "$cur" down
    ip link set "$cur" name wlan0
    ip link set wlan0 up
  ' || true
  printf '%-12s radio -> wlan0\n' "$n"
done

# Bring the radios up and start the AP.
docker exec "${lab}-ap-a1" bash /cfg/ap/setup-ap.sh || true
echo "radios attached"
