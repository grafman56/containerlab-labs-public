#!/usr/bin/env bash
# Unload the simulated radios. Run on the containerlab host before destroy,
# so the phys are not left orphaned in dead namespaces.
set -uo pipefail
sudo -n modprobe -r mac80211_hwsim 2>/dev/null || true
echo "radios released"
