#!/usr/bin/env bash
# Static repository checks. Nothing here starts a lab or changes a container.
#
# The lab list comes from labs.toml, so adding a lab does not mean editing
# this file. Run it from anywhere; it changes to its own directory.
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$repo_dir"

echo "== manifest checks =="
# Standard library only, so this part runs on a host with no Python packages.
./labctl check

echo
echo "== topology checks =="
python3 - <<'PY'
from pathlib import Path
import json
import tomllib

try:
    import yaml
except ModuleNotFoundError:
    raise SystemExit(
        "PyYAML is required for the topology checks.\n"
        "Install it with: python3 -m pip install -r requirements.txt\n"
        "The manifest checks run without it: ./labctl check"
    )

labs = tomllib.load(open("labs.toml", "rb"))["labs"]

# Every containerlab lab in the manifest, in name order, so the output is
# stable. netlab labs are checked by netlab, not here.
topologies = [
    Path(lab["dir"]) / lab["topology"]
    for _name, lab in sorted(labs.items())
    if lab.get("driver", "containerlab") == "containerlab"
]

ansible_templates = [
    Path("ansible/containerlab-operations.yml"),
    Path("ansible/inventory.example.yml"),
    Path("ibgp-rr/ansible/inventory.example.yml"),
    Path("ibgp-rr/ansible/playbooks/edge_policy.yml"),
    Path("ibgp-rr/ansible/playbooks/access_fabric.yml"),
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
            # Directories are legitimate bind sources -- the identity lab
            # mounts a whole config tree at /cfg -- so check existence, not
            # file-ness.
            if not source_path.exists():
                raise SystemExit(
                    f"{topology_path}: {node_name} bind source missing: {source_path}"
                )

    print(f"PASS: {topology_path}")

for template_path in ansible_templates:
    with template_path.open() as stream:
        if yaml.safe_load(stream) is None:
            raise SystemExit(f"{template_path}: template is empty")
    print(f"PASS: {template_path}")

PY

echo
echo "== unit tests =="
python3 -m unittest discover -s tests -v
python3 -m unittest cin-rphy-transport/ansible/tests/test_rpa_probe_rows.py -v
python3 -m unittest cin-rphy-transport/tests/test_topology_role_intent.py -v
# The campus reconciliation self-check asserts the parsers and the join over
# fixtures trimmed from live lab output. It needs no running lab.
( cd evpn-vxlan-campus/reconcile && python3 test_reconcile.py )
( cd evpn-vxlan-campus/reconcile && python3 test_properties.py )

echo
echo "== shell syntax =="
# Every shell script in the repository, so a new lab cannot skip this check.
# The repository-level ./labctl is Python, not shell.
while IFS= read -r script; do
  bash -n "$script"
  echo "PASS: bash syntax $script"
done < <(
  find . -path ./.git -prune -o -name '*.sh' -print
  find . -path ./.git -prune -o -name labctl ! -path ./labctl -print
)

echo
echo "PASS: repository static validation"
