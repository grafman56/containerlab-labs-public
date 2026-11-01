#!/usr/bin/env bash
# usage: wait-for-link.sh <iface> [...]
#
# Containerlab runs a node's exec list as soon as the container is up, which
# is not the same moment its veth pairs are attached. A daemon that binds
# sockets at startup -- Kea does, FreeRADIUS does -- will come up bound to
# nothing and then sit there looking healthy. Wait for the interfaces first.
set -u
for iface in "$@"; do
  for _ in $(seq 1 60); do
    ip link show "$iface" >/dev/null 2>&1 && break
    sleep 0.5
  done
done
