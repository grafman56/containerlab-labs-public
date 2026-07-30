#!/usr/bin/env bash
set -euo pipefail

readonly lab='wireless-radius-8021x'
readonly radius="clab-${lab}-radius"
readonly ap="clab-${lab}-ap"
readonly client="clab-${lab}-client"

for _ in $(seq 1 30); do
  if docker exec "$client" grep -q 'CTRL-EVENT-EAP-SUCCESS' /run/wpa_supplicant.log &&
    docker exec "$radius" grep -q 'Access-Accept' /run/freeradius.log; then
    echo 'PASS: WPA2-Enterprise PEAP authentication succeeded'
    exit 0
  fi
  sleep 1
done

echo 'FAIL: no EAP success after 30 seconds' >&2
docker exec "$client" sh -c "grep -Ei 'CTRL-EVENT|certificate|EAP.*(SUCCESS|FAILURE)' /run/wpa_supplicant.log | tail -80" >&2 || true
docker exec "$ap" sh -c "grep -Ei 'EAP|RADIUS|authentication' /run/hostapd.log | tail -80" >&2 || true
docker exec "$radius" sh -c "grep -Ei 'Access-(Accept|Reject)|RADIUS.*(Received|Sending)' /run/freeradius.log | tail -80" >&2 || true
exit 1
