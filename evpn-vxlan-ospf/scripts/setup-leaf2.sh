#!/usr/bin/env bash
set -euo pipefail
ip link set eth3 up
ip link add br10 type bridge
ip link set br10 address 02:00:00:00:10:02
ip link set br10 up
ip link set eth3 master br10
ip link add vxlan10 type vxlan id 1010 local 10.255.0.2 dstport 4789 nolearning
ip link set vxlan10 master br10
ip link set vxlan10 up
