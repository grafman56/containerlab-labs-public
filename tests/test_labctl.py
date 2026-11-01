"""Tests for the repository lifecycle driver.

Run with: python3 -m unittest discover -s tests -v
"""

import contextlib
import importlib.machinery
import importlib.util
import io
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

loader = importlib.machinery.SourceFileLoader("labctl", str(ROOT / "labctl"))
spec = importlib.util.spec_from_loader("labctl", loader)
assert spec is not None
labctl = importlib.util.module_from_spec(spec)
loader.exec_module(labctl)


class TopologyFactsTests(unittest.TestCase):
    """The indentation reader must agree with the nine real topologies."""

    def test_reads_name_and_management_subnet(self):
        facts = labctl.topology_facts(ROOT / "evpn-vxlan" / "evpn-vxlan.clab.yml")
        self.assertEqual(facts["name"], "evpn-vxlan")
        self.assertEqual(facts["mgmt_subnet"], "172.100.110.0/24")
        self.assertEqual(len(facts["nodes"]), 8)
        self.assertIn("host4", facts["nodes"])

    def test_node_image_falls_back_to_topology_defaults(self):
        facts = labctl.topology_facts(ROOT / "ibgp-rr" / "ibgp-rr.clab.yml")
        self.assertEqual(len(facts["nodes"]), 15)
        self.assertEqual(facts["nodes"]["rr1"]["image"], "quay.io/frrouting/frr:10.7.0")

    def test_reads_bind_sources(self):
        facts = labctl.topology_facts(ROOT / "ibgp-rr" / "ibgp-rr.clab.yml")
        self.assertIn("configs/rr1.conf:/etc/frr/frr.conf", facts["nodes"]["rr1"]["binds"])

    def test_runtime_dirs_come_from_binds(self):
        facts = labctl.topology_facts(
            ROOT / "evpn-vxlan-campus" / "evpn-vxlan-campus.clab.yml"
        )
        # The campus topology binds runtime/<node> for its 21 FRR nodes.
        self.assertEqual(len(labctl.runtime_dirs(facts)), 21)
        self.assertIn("spine1a", labctl.runtime_dirs(facts))
        self.assertNotIn("host1", labctl.runtime_dirs(facts))

    def test_reads_kind_images(self):
        facts = labctl.topology_facts(ROOT / "wireless-radius-8021x" / "wireless-radius-8021x.clab.yml")
        self.assertEqual(facts["name"], "wireless-radius-8021x")
        images = {node["image"] for node in facts["nodes"].values()}
        self.assertTrue(all(images), "every node must resolve an image")


class PinTests(unittest.TestCase):
    def test_rejects_floating_and_bare_images(self):
        self.assertFalse(labctl.is_pinned("alpine"))
        self.assertFalse(labctl.is_pinned("alpine:latest"))
        self.assertFalse(labctl.is_pinned("quay.io/frrouting/frr:latest"))

    def test_accepts_tag_and_digest(self):
        self.assertTrue(labctl.is_pinned("alpine:3.20"))
        self.assertTrue(labctl.is_pinned("quay.io/frrouting/frr:10.7.0"))
        self.assertTrue(labctl.is_pinned("registry/app@sha256:" + "a" * 64))
        self.assertTrue(labctl.is_pinned("localhost:5000/team/app:1.0.0"))


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.labs = labctl.load_manifest()

    def test_every_lab_directory_exists(self):
        for name, lab in self.labs.items():
            self.assertTrue((ROOT / lab["dir"]).is_dir(), name)

    def test_management_subnets_are_unique(self):
        subnets = [lab["mgmt_subnet"] for lab in self.labs.values() if lab["mgmt_subnet"]]
        self.assertEqual(len(subnets), len(set(subnets)))



class SafetyTests(unittest.TestCase):
    def setUp(self):
        self.labs = labctl.load_manifest()

    def test_refuses_netlab_lab(self):
        with self.assertRaises(labctl.LabError):
            labctl.require_containerlab(self.labs, "enterprise-fabric")

    def test_refuses_unknown_lab(self):
        with self.assertRaises(labctl.LabError):
            labctl.require_containerlab(self.labs, "not-a-lab")

    def test_destroy_is_scoped_to_one_topology(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = labctl.main(["down", "ibgp-rr", "--dry-run"])
        printed = out.getvalue()
        self.assertEqual(code, 0)
        self.assertIn("destroy -t ibgp-rr.clab.yml", printed)
        self.assertNotIn("--all", printed)
        self.assertNotIn("evpn-vxlan.clab.yml", printed)

    def test_deploy_is_scoped_to_one_topology(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = labctl.main(["up", "evpn-vxlan", "--dry-run", "--no-preflight"])
        printed = out.getvalue()
        self.assertEqual(code, 0)
        self.assertIn("deploy -t evpn-vxlan.clab.yml", printed)
        self.assertNotIn("--all", printed)

    def test_down_requires_a_lab_argument(self):
        with self.assertRaises(SystemExit):
            with contextlib.redirect_stderr(io.StringIO()):
                labctl.main(["down", "--all"])


class SubnetTests(unittest.TestCase):
    def test_overlap_is_reported(self):
        labs = {
            "a": {"mgmt_subnet": "172.100.100.0/24"},
            "b": {"mgmt_subnet": "172.100.100.0/24"},
            "c": {"mgmt_subnet": "172.100.100.128/25"},
        }
        problems = labctl.subnet_problems(labs)
        # All three pairs overlap.
        self.assertEqual(len(problems), 3, problems)

    def test_invalid_cidr_is_reported(self):
        problems = labctl.subnet_problems({"a": {"mgmt_subnet": "not-an-address"}})
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("not valid CIDR", problems[0])

    def test_disjoint_subnets_pass(self):
        labs = {
            "a": {"mgmt_subnet": "172.100.100.0/24"},
            "b": {"mgmt_subnet": "172.100.101.0/24"},
            "c": {"mgmt_subnet": ""},
        }
        self.assertEqual(labctl.subnet_problems(labs), [])


class CheckTests(unittest.TestCase):
    def test_repository_check_passes(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = labctl.main(["check"])
        self.assertEqual(code, 0, out.getvalue())
        self.assertIn("no problems", out.getvalue())


if __name__ == "__main__":
    unittest.main()
