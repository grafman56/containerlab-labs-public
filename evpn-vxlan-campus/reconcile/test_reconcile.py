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

    print("ok")


if __name__ == "__main__":
    main()
