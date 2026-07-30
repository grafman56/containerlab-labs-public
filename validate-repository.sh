#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$repo_dir"

python3 - <<'PY'
from pathlib import Path
import sys
import yaml

topologies = [
    Path("ibgp-rr/ibgp-rr.clab.yml"),
    Path("evpn-vxlan/evpn-vxlan.clab.yml"),
    Path("sdwan-dual-transport/sdwan-dual-transport.clab.yml"),
    Path("cin-rphy-transport/cin-rphy-transport.clab.yml"),
    Path("wireless-radius-8021x/wireless-radius-8021x.clab.yml"),
]

for topology_path in topologies:
    with topology_path.open() as stream:
        topology = yaml.safe_load(stream)

    nodes = topology["topology"]["nodes"]
    endpoints = set()
    for link in topology["topology"]["links"]:
        for endpoint in link["endpoints"]:
            node, _, _interface = endpoint.partition(":")
            if node not in nodes:
                raise SystemExit(f"{topology_path}: link references unknown node {node}")
            if endpoint in endpoints:
                raise SystemExit(f"{topology_path}: endpoint reused by multiple links: {endpoint}")
            endpoints.add(endpoint)

    for node_name, node in nodes.items():
        for binding in node.get("binds", []):
            source = binding.split(":", 1)[0]
            if source == f"runtime/{node_name}":
                continue
            source_path = topology_path.parent / source
            if not source_path.is_file():
                raise SystemExit(
                    f"{topology_path}: {node_name} bind source missing: {source_path}"
                )

    print(f"PASS: {topology_path}")
PY

python3 -m unittest cin-rphy-transport/ansible/tests/test_rpa_probe_rows.py -v
python3 -m unittest cin-rphy-transport/tests/test_topology_role_intent.py -v

echo "PASS: CIN probe filter and topology-role intent tests"

for script in \
  ibgp-rr/verify.sh \
  evpn-vxlan/verify.sh \
  sdwan-dual-transport/verify.sh \
  cin-rphy-transport/verify.sh \
  wireless-radius-8021x/lifecycle.sh \
  wireless-radius-8021x/verify.sh \
  evpn-vxlan/labctl \
  evpn-vxlan/scripts/setup-leaf1.sh \
  evpn-vxlan/scripts/setup-leaf2.sh; do
  bash -n "$script"
  echo "PASS: bash syntax $script"
done

echo "PASS: repository static validation"
