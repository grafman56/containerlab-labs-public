"""Static intent checks for the vendor-neutral CIN site topology."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


LAB_DIR = Path(__file__).resolve().parents[1]
TOPOLOGY = LAB_DIR / "cin-rphy-transport.clab.yml"


def topology_neighbors() -> dict[str, set[str]]:
    links = re.findall(
        r'endpoints:\s*\["([^"\s]+)",\s*"([^"\s]+)"\]',
        TOPOLOGY.read_text(),
    )
    neighbors: dict[str, set[str]] = {}
    for left, right in links:
        left_node = left.split(":", 1)[0]
        right_node = right.split(":", 1)[0]
        neighbors.setdefault(left_node, set()).add(right_node)
        neighbors.setdefault(right_node, set()).add(left_node)
    return neighbors


class HubAttachedRoleIntentTests(unittest.TestCase):
    def test_every_modeled_hub_attached_role_is_dual_homed(self) -> None:
        neighbors = topology_neighbors()

        for node in ("vcmts", "rpa1", "rpa2", "aar1", "dsr1", "dsr2"):
            with self.subTest(node=node):
                self.assertTrue(
                    {"hub1", "hub2"}.issubset(neighbors.get(node, set())),
                    f"{node} must have one transport attachment to each hub",
                )

    def test_aar_is_a_parallel_hub_attached_role(self) -> None:
        neighbors = topology_neighbors()

        self.assertEqual({"hub1", "hub2"}, neighbors.get("aar1"))


if __name__ == "__main__":
    unittest.main()
