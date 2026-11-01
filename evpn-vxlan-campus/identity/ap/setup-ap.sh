#!/usr/bin/env bash
# ap-a1: the access point. Trunk uplink on eth1, radio on wlan0.
#
# The radio is a mac80211_hwsim phy moved into this namespace from the host by
# identity/wireless-attach.sh after deploy. If wlan0 is absent, that step has
# not run.
set -uo pipefail
exec >>/tmp/setup-ap.log 2>&1
echo "=== setup-ap $(date -Is) ==="
set -x

/cfg/wait-for-link.sh eth1
ip link set eth1 up

# The AP's own address, untagged on the trunk -- a native VLAN, which is how
# access points are normally managed. It has to exist before hostapd starts,
# because hostapd sources RADIUS from it, and because the per-VLAN interfaces
# hostapd builds for stations do not exist until a station has authenticated.
# Chicken and egg otherwise: no RADIUS reachability, so no station, so no
# interface to reach RADIUS from.
ip address replace 10.10.10.21/24 dev eth1
ip route replace default via 10.10.10.1

# See identity/keepalive.sh.
pkill -f keepalive.sh 2>/dev/null || true
nohup /cfg/keepalive.sh 10.10.10.1 >/dev/null 2>&1 &
sleep 2

for _ in $(seq 1 60); do
  ip link show wlan0 >/dev/null 2>&1 && break
  sleep 1
done
ip link show wlan0 >/dev/null 2>&1 || { echo "no wlan0: run wireless-attach.sh"; exit 1; }

# hostapd builds the per-VLAN interfaces and bridges itself; nothing to
# pre-create. It does need the tagged uplink to exist and be up, which is why
# wait-for-link runs first.
pkill -f 'hostapd -B' 2>/dev/null || true
sleep 1
hostapd -B -f /tmp/hostapd.log /cfg/ap/hostapd.conf
echo "=== setup-ap done ==="
