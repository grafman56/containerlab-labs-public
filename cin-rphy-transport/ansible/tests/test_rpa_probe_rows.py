import json
import pathlib
import sys
import unittest

ANSIBLE_DIR = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ANSIBLE_DIR / "playbooks" / "filter_plugins"))

from rpa_probe_rows import rpa_probe_rows  # noqa: E402


class RpaProbeRowsTests(unittest.TestCase):
    def setUp(self):
        fixture_path = pathlib.Path(__file__).with_name("fixtures") / "rpa1-ip-addr.json"
        self.interfaces = json.loads(fixture_path.read_text())

    def test_reports_only_rpd_facing_interfaces_with_intent_and_live_ip(self):
        rows = rpa_probe_rows(
            self.interfaces,
            {"eth3": "rpd1", "eth4": "rpd2"},
        )

        self.assertEqual(
            rows,
            [
                {
                    "interface": "eth3",
                    "rpd": "rpd1",
                    "ipv4": ["10.10.4.1/31"],
                    "admin_up": True,
                    "carrier_up": True,
                    "operstate": "UP",
                },
                {
                    "interface": "eth4",
                    "rpd": "rpd2",
                    "ipv4": ["10.10.5.1/31"],
                    "admin_up": True,
                    "carrier_up": True,
                    "operstate": "UP",
                },
            ],
        )

    def test_keeps_rpd_intent_when_a_link_has_no_ipv4_address(self):
        interfaces = [
            {
                "ifname": "eth3",
                "flags": ["BROADCAST", "MULTICAST", "UP"],
                "operstate": "DOWN",
                "addr_info": [],
            }
        ]

        self.assertEqual(
            rpa_probe_rows(interfaces, {"eth3": "rpd1"}),
            [
                {
                    "interface": "eth3",
                    "rpd": "rpd1",
                    "ipv4": [],
                    "admin_up": True,
                    "carrier_up": False,
                    "operstate": "DOWN",
                }
            ],
        )


if __name__ == "__main__":
    unittest.main()
