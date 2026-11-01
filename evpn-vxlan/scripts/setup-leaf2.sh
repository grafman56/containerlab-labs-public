#!/usr/bin/env bash
set -euo pipefail

# VRF + L3 VNI for symmetric IRB (inter-VNI routing)
ip link add TENANT-A type vrf table 4100
ip link set TENANT-A up
ip link add vxlan4100 type vxlan id 4100 local 10.255.0.2 dstport 4789 nolearning
ip link set vxlan4100 master TENANT-A
ip link set vxlan4100 up

# VNI 1010 - tenant A, subnet 10.10.10.0/24
ip link set eth3 up
ip link add br10 type bridge
ip link set br10 address 02:00:00:00:10:02
ip link set br10 master TENANT-A
ip link set br10 up
ip link set eth3 master br10
ip link add vxlan10 type vxlan id 1010 local 10.255.0.2 dstport 4789 nolearning
ip link set vxlan10 master br10
ip link set vxlan10 up

# VNI 1020 - tenant A, subnet 10.20.20.0/24
ip link set eth4 up
ip link add br20 type bridge
ip link set br20 address 02:00:00:00:20:02
ip link set br20 master TENANT-A
ip link set br20 up
ip link set eth4 master br20
ip link add vxlan20 type vxlan id 1020 local 10.255.0.2 dstport 4789 nolearning
ip link set vxlan20 master br20
ip link set vxlan20 up
