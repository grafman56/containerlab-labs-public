#!/usr/bin/env bash
# usage: keepalive.sh <gateway>
#
# Keeps this endpoint's EVPN type-2 MAC/IP route alive.
#
# With ARP suppression on, a leaf answers ARP from the EVPN routes instead of
# flooding. A type-2 route exists only while the leaf holds an ARP entry for
# the endpoint, and the kernel ages that entry out when the endpoint goes
# quiet. Real servers are chatty and never hit this. Idle lab containers do,
# and the symptom is nasty to read: everything works, then minutes later the
# same command times out with no configuration having changed.
#
# This is a lab remedy for a lab artefact, not a design pattern. The real
# lesson is the failure mode itself -- stop this loop, wait, and watch a
# healthy fabric stop forwarding to a host that is still up.
set -u
gw=$1
while :; do
  ping -c 1 -W 1 "$gw" >/dev/null 2>&1
  sleep 20
done
