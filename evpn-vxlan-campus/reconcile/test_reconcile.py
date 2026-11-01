#!/usr/bin/env python3
"""Self-check for the parsers and the join. Run: ./test_reconcile.py

Fixtures are trimmed from real output taken off the running lab, because the
only parsing bugs that matter are the ones a vendor's actual format causes.
"""

import registers as R
from reconcile import reconcile, latencies

NOW = 1791459600

NAC_DETAIL = """Thu Oct  8 11:39:44 2026
\tAcct-Status-Type = Interim-Update
\tUser-Name = "jsmith@campus.edu"
\tNAS-Identifier = "edge-a1.campus.edu"
\tCalling-Station-Id = "AA-C1-AB-FE-FC-8A"
\tAcct-Session-Id = "A3A0DAD1E3D4E0B0"
\tAcct-Unique-Session-Id = "2a157ebcaa20329e97640969b99a08fe"
\tRealm = "campus.edu"
\tTimestamp = 1791459584

Thu Oct  8 11:39:44 2026
\tAcct-Status-Type = Interim-Update
\tUser-Name = "anonymous@remote.edu"
\tCalling-Station-Id = "AA-C1-AB-A9-36-E2"
\tAcct-Unique-Session-Id = "96baf7be594d555ced570ef6d9d44cb2"
\tRealm = "remote.edu"
\tTimestamp = 1791459584

Thu Oct  8 10:00:00 2026
\tAcct-Status-Type = Interim-Update
\tUser-Name = "gone@campus.edu"
\tCalling-Station-Id = "AA-C1-AB-DE-AD-01"
\tAcct-Unique-Session-Id = "deadbeef"
\tRealm = "campus.edu"
\tTimestamp = 1791450000

Thu Oct  8 11:00:00 2026
\tAcct-Status-Type = Stop
\tUser-Name = "stopped@campus.edu"
\tCalling-Station-Id = "AA-C1-AB-DE-AD-02"
\tAcct-Unique-Session-Id = "cafe"
\tRealm = "campus.edu"
\tTimestamp = 1791456000
"""

LEASES = """address,hwaddr,client_id,valid_lifetime,expire,subnet_id,fqdn_fwd,fqdn_rev,hostname,state,user_context,pool_id
10.10.10.100,aa:c1:ab:fe:fc:8a,,600,1791460000,1010,0,0,,0,,0
10.30.30.100,aa:c1:ab:a9:36:e2,,600,1791460000,1030,0,0,,0,,0
10.10.10.101,aa:c1:ab:de:ad:01,,600,1791459000,1010,0,0,,0,,0
10.10.10.199,aa:c1:ab:de:ad:09,,600,1791460000,1010,0,0,,1,,0
"""

FW_JSON = """{"nftables":[{"table":{"family":"inet","name":"userid"}},
 {"set":{"family":"inet","name":"role_staff","table":"userid","type":"ipv4_addr",
  "elem":[
   {"elem":{"val":"10.10.10.100","comment":"user=jsmith@campus.edu,mac=aa:c1:ab:fe:fc:8a,ts=1791459590,vrf=TENANT-A"}},
   {"elem":{"val":"10.10.10.101","comment":"user=gone@campus.edu,mac=aa:c1:ab:de:ad:01,ts=1791450010,vrf=TENANT-A"}}
  ]}},
 {"set":{"family":"inet","name":"role_visitor","table":"userid","type":"ipv4_addr",
  "elem":[
   {"elem":{"val":"10.30.30.100","comment":"user=anonymous@remote.edu,mac=aa:c1:ab:a9:36:e2,ts=1791459592,vrf=EDUROAM"}}
  ]}}]}"""

FABRIC = {
    ("TENANT-A", "aa:c1:ab:fe:fc:8a"): dict(
        vrf="TENANT-A", mac="aa:c1:ab:fe:fc:8a", vni=1010, leaf="leaf1a",
        port="eth4.10", mobility=2, duplicate=False, fabric_ip="10.10.10.100"),
    # Authorized as a visitor, but the fabric put it in the staff VNI: the
    # Tunnel-* attributes were dropped somewhere.
    ("TENANT-A", "aa:c1:ab:a9:36:e2"): dict(
        vrf="TENANT-A", mac="aa:c1:ab:a9:36:e2", vni=1010, leaf="leaf1a",
        port="eth4.10", mobility=0, duplicate=False, fabric_ip="10.30.30.100"),
    # Forwarding with no session at all.
    ("TENANT-A", "02:00:00:00:01:00"): dict(
        vrf="TENANT-A", mac="02:00:00:00:01:00", vni=1010, leaf="leaf1a",
        port="eth4.10", mobility=0, duplicate=False),
}


def codes(findings, subject=None):
    return {f["code"] for f in findings
            if subject is None or f["subject"] == subject}


def main():
    assert R.mac("AA-C1-AB-FE-FC-8A") == "aa:c1:ab:fe:fc:8a"
    assert R.mac("aa:c1:ab:fe:fc:8a") == "aa:c1:ab:fe:fc:8a"
    assert R.mac("garbage") == ""

    nacs = R.parse_nac(NAC_DETAIL, NOW)
    # A Stop record removes the session from the register entirely.
    assert "aa:c1:ab:de:ad:02" not in nacs, nacs.keys()
    assert nacs["aa:c1:ab:fe:fc:8a"]["live"] is True
    assert nacs["aa:c1:ab:fe:fc:8a"]["expected_role"] == "staff"
    assert nacs["aa:c1:ab:a9:36:e2"]["anonymous"] is True
    assert nacs["aa:c1:ab:a9:36:e2"]["expected_role"] == "visitor"
    # Old interim, no Stop: still in the register, but not live.
    assert nacs["aa:c1:ab:de:ad:01"]["live"] is False

    leases = R.parse_ddi(LEASES, NOW)
    assert leases["aa:c1:ab:fe:fc:8a"]["ip"] == "10.10.10.100"
    assert leases["aa:c1:ab:fe:fc:8a"]["vrf"] == "TENANT-A"
    assert leases["aa:c1:ab:a9:36:e2"]["vrf"] == "EDUROAM"
    assert leases["aa:c1:ab:de:ad:01"]["expired"] is True
    # state != 0 is not a current binding.
    assert "aa:c1:ab:de:ad:09" not in leases

    fw = R.parse_firewall(FW_JSON)
    assert fw["10.10.10.100"]["role"] == "staff"
    assert fw["10.10.10.100"]["user"] == "jsmith@campus.edu"
    assert fw["10.10.10.100"]["mac"] == "aa:c1:ab:fe:fc:8a"
    assert fw["10.30.30.100"]["vrf"] == "EDUROAM"

    f = reconcile(FABRIC, nacs, leases, fw, NOW)

    # The dead session's mapping is still published: the dangerous delta.
    assert "STALE_PUBLICATION" in codes(f, "10.10.10.101")
    # Published in EDUROAM, but the fabric holds that MAC in TENANT-A.
    assert "VRF_MISMATCH" in codes(f, "10.30.30.100")
    # Authorized visitor, placed in the staff segment.
    assert "WRONG_SEGMENT" in codes(f, "aa:c1:ab:a9:36:e2")
    # Forwarding, never authenticated.
    assert "UNAUTHENTICATED" in codes(f, "02:00:00:00:01:00")
    # A roaming user's real name never reaches the visited site.
    assert "NO_USERNAME_TO_PUBLISH" in codes(f, "aa:c1:ab:a9:36:e2")
    # Mobility sequence 2 is a roam, reported but not an alarm.
    assert "MOBILITY" in codes(f, "aa:c1:ab:fe:fc:8a")
    # The correctly published staff endpoint raises nothing against itself.
    assert codes(f, "10.10.10.100") == set(), codes(f, "10.10.10.100")

    assert sorted(latencies(nacs, fw)) == [6, 8, 10], latencies(nacs, fw)

    # A clean campus produces no findings at all.
    clean_fab = {("TENANT-A", "aa:c1:ab:fe:fc:8a"): dict(
        FABRIC[("TENANT-A", "aa:c1:ab:fe:fc:8a")], mobility=1)}
    clean_nac = {"aa:c1:ab:fe:fc:8a": nacs["aa:c1:ab:fe:fc:8a"]}
    clean_lease = {"aa:c1:ab:fe:fc:8a": leases["aa:c1:ab:fe:fc:8a"]}
    clean_fw = {"10.10.10.100": fw["10.10.10.100"]}
    assert reconcile(clean_fab, clean_nac, clean_lease, clean_fw, NOW) == []

    check_panos()
    check_prometheus()
    print("ok")


def check_panos():
    """The PAN-OS leg: message building, parsing, and the opt-in switch."""
    import os
    import panos
    import publish
    from xml.etree.ElementTree import fromstring

    msg = fromstring(panos.uid_message(
        login=[("jsmith@campus.edu", "10.10.10.100")],
        register=[("10.10.10.100", ["role:staff", "bldg:howard-tilton"])],
        unregister=[("10.10.10.101", [])]))
    assert msg.find("payload/login/entry").attrib == {
        "name": "jsmith@campus.edu", "ip": "10.10.10.100"}
    assert [m.text for m in msg.findall("payload/register/entry/tag/member")] == [
        "role:staff", "bldg:howard-tilton"]
    # No tags means "drop every tag on this address": no <tag> element at all.
    assert msg.find("payload/unregister/entry/tag") is None
    # Empty verbs are left out rather than sent empty.
    assert fromstring(panos.uid_message(login=[("u", "1.1.1.1")])).find("payload/register") is None

    maps = ('<response status="success"><result><entry><ip>10.10.10.100</ip>'
            '<user>jsmith@campus.edu</user></entry><count>1</count></result></response>')
    assert panos.parse_mappings(maps) == {"10.10.10.100": "jsmith@campus.edu"}
    tags = ('<response status="success"><result><entry><ip>10.10.10.100</ip>'
            '<tag><member>role:staff</member></tag></entry><count>1</count></result></response>')
    assert panos.parse_tags(tags) == {"10.10.10.100": {"role:staff"}}

    # The PAN-OS register: role and vrf from tags, user from the mapping table,
    # MAC joined from DDI by address, anonymous visitors kept (not "stale").
    import registers
    orig = (panos.mappings, panos.tags)
    panos.mappings = lambda u, k: {"10.10.10.100": "jsmith@campus.edu"}
    panos.tags = lambda u, k: {"10.10.10.100": {"role:staff", "vrf:tenant-a"},
                               "10.30.30.100": {"role:visitor", "vrf:eduroam"},
                               "10.99.99.9": {"site:x"}}
    try:
        got = registers.panos_firewall(
            "http://x", "", vrfs={"TENANT-A", "EDUROAM"},
            leases={"aa:c1:ab:fe:fc:8a": {"ip": "10.10.10.100"},
                    "aa:c1:ab:a9:36:e2": {"ip": "10.30.30.100"}})
    finally:
        panos.mappings, panos.tags = orig
    assert sorted(got) == ["10.10.10.100", "10.30.30.100"], got  # no role tag: skipped
    assert got["10.10.10.100"]["user"] == "jsmith@campus.edu"
    assert got["10.10.10.100"]["vrf"] == "TENANT-A"
    assert got["10.10.10.100"]["mac"] == "aa:c1:ab:fe:fc:8a"
    assert got["10.30.30.100"]["user"] == "" and got["10.30.30.100"]["mac"] == "aa:c1:ab:a9:36:e2"

    # Replace, don't accumulate: managed tags that are no longer wanted go,
    # tags somebody else added stay.
    assert publish.stale_tags({"role:staff", "closet:idf-1", "quarantine"},
                              ["role:staff", "closet:idf-2"]) == ["closet:idf-1"]
    assert publish.stale_tags([], ["role:staff"]) == []
    # Two role tags are a conflict that can never equal one authorized role.
    panos.mappings = lambda u, k: {}
    panos.tags = lambda u, k: {"10.0.0.9": {"role:staff", "role:visitor"}}
    try:
        both = registers.panos_firewall("http://x")
    finally:
        panos.mappings, panos.tags = orig
    assert both["10.0.0.9"]["role"] == "staff+visitor"

    # WRONG_USER: right role, wrong person on the address.
    from reconcile import reconcile as rec
    mac = "aa:c1:ab:fe:fc:8a"
    sess = {"live": True, "anonymous": False, "user": "jsmith@campus.edu", "age": 5,
            "expected_role": "staff", "realm": "campus.edu", "ts": NOW - 5}
    lease = {"ip": "10.10.10.100", "mac": mac, "vrf": "TENANT-A", "expired": False,
             "expire": NOW + 99}
    fwrow = {"ip": "10.10.10.100", "role": "staff", "user": "bob@campus.edu", "mac": mac,
             "published_at": 0, "vrf": "TENANT-A"}
    got = rec({("TENANT-A", mac): {"mobility": 1}}, {mac: sess}, {mac: lease},
              {"10.10.10.100": fwrow}, NOW)
    assert "WRONG_USER" in {f["code"] for f in got}, got
    fwrow["user"] = "jsmith@campus.edu"
    got = rec({("TENANT-A", mac): {"mobility": 1}}, {mac: sess}, {mac: lease},
              {"10.10.10.100": fwrow}, NOW)
    assert "WRONG_USER" not in {f["code"] for f in got}, got

    # Without the flag or the variable, publish.py does nothing extra.
    os.environ.pop("PANOS_URL", None)
    assert publish.panos_target(["--expire"]) is None
    assert publish.panos_target(["--panos", "http://x:8080"]) == "http://x:8080"
    assert publish.panos_target(["--panos=http://y:8080"]) == "http://y:8080"
    os.environ["PANOS_URL"] = "http://z:8080"
    try:
        assert publish.panos_target([]) == "http://z:8080"
    finally:
        del os.environ["PANOS_URL"]


def check_prometheus():
    import re
    import reconcile as rc
    from pathlib import Path

    # CODES must list every code the source can raise, or a cleared finding
    # would vanish from the metrics instead of reading 0.
    src = Path(rc.__file__).read_text()
    raised = set(re.findall(r'add\("(?:CRITICAL|WARN|INFO)", "([A-Z_]+)"', src))
    listed = {c for codes in rc.CODES.values() for c in codes}
    assert raised <= listed, sorted(raised - listed)

    text = rc.prometheus(
        [{"severity": "CRITICAL", "code": "STALE_PUBLICATION", "subject": "x", "detail": ""}],
        {"firewall_mappings": 3}, [4, 9], 100)
    lines = text.splitlines()
    assert 'campus_reconcile_findings{severity="CRITICAL",code="STALE_PUBLICATION"} 1' in lines
    assert 'campus_reconcile_findings{severity="CRITICAL",code="WRONG_TAG"} 0' in lines
    assert 'campus_register_entries{register="firewall_mappings"} 3' in lines
    assert "campus_publication_latency_max_seconds 9" in lines
    assert "campus_reconcile_up 1" in lines
    assert "campus_reconcile_up 0" in rc.prometheus([], {}, [], 100, up=0)


if __name__ == "__main__":
    main()
