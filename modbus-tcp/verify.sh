#!/usr/bin/env bash
set -euo pipefail

docker exec clab-modbus-tcp-client python /lab/client.py 192.0.2.1
docker exec clab-modbus-tcp-client python /lab/tank_plant_check.py 172.100.120.10
