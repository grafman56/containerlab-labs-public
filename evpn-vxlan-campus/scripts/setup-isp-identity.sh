#!/usr/bin/env bash
# usage: setup-isp-identity.sh
# The ISP's second logical hand-off, for the visitor zone. Same wire, separate
# subinterface, so the visitor zone never shares a routing table with campus.
set -uo pipefail
ip link add link eth1 name eth1.30 type vlan id 30
ip link set eth1.30 up
