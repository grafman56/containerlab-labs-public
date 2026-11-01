#!/usr/bin/env bash
# usage: setup-fw-identity.sh
#
# The firewall side of the per-zone hand-off. The visitor zone gets its own
# VRF here, not just its own subinterface.
#
# Why the VRF: with both zones in one table this box held routes into campus
# AND the visitor default, so it forwarded between them -- a visitor reached
# campus services even though no leaf held a route for it. A real Palo Alto
# keeps them apart with zones and the absence of an inter-zone rule. FRR has
# no policy engine, so a routing instance per zone is the honest equivalent.
set -uo pipefail

ip link add ZONE-EDUROAM type vrf table 4300
ip link set ZONE-EDUROAM up

for pair in eth1:30 eth2:30 eth4:30; do
  dev=${pair%%:*}; vid=${pair##*:}
  ip link add link "$dev" name "${dev}.${vid}" type vlan id "$vid"
  ip link set "${dev}.${vid}" master ZONE-EDUROAM
  ip link set "${dev}.${vid}" up
done
