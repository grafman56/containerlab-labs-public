#!/bin/sh
set -eu
address=${NODE_IP:?NODE_IP must be set}
attempt=0
while ! ip link show dev eth1 >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 30 ]; then
    echo "Containerlab did not create eth1 within 30 seconds" >&2
    exit 1
  fi
  sleep 1
done
ip address add "$address/30" dev eth1
exec "$@"
