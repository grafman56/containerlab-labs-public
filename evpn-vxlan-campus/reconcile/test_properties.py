#!/usr/bin/env python3
"""Invariants of the join, checked on random campuses. Run: ./test_properties.py

A consistent world must produce no CRITICAL or WARN finding. Breaking one
register in one known way must produce the matching code. Nothing may raise.
"""

import random
from reconcile import reconcile, CODES

NOW = 1791459600
SEGMENTS = [("TENANT-A", 1010, "staff", "10.10.10"), ("EDUROAM", 1030, "visitor", "10.30.30")]


def world(rng, n):
    fab, nacs, leases, fw = {}, {}, {}, {}
    for i in range(n):
        vrf, vni, role, net = SEGMENTS[rng.randrange(2)]
        mac = "aa:c1:ab:00:%02x:%02x" % (i // 256, i % 256)
        ip = "%s.%d" % (net, 100 + i % 150)
        if ip in fw:
            continue
        user = "user%d@campus.edu" % i
        fab[(vrf, mac)] = {"vrf": vrf, "mac": mac, "vni": vni, "leaf": "leaf1a",
                           "port": "eth4", "mobility": 1, "duplicate": False,
                           "fabric_ip": ip}
        nacs[mac] = {"ts": NOW - 20, "status": "Interim-Update", "user": user, "mac": mac,
                     "realm": "campus.edu", "nas": "ap", "session": str(i), "age": 20,
                     "live": True, "anonymous": False, "expected_role": role}
        leases[mac] = {"ip": ip, "mac": mac, "expire": NOW + 500, "expired": False,
                       "subnet": vni, "hostname": "", "state": 0, "vrf": vrf}
        fw[ip] = {"ip": ip, "role": role, "user": user, "mac": mac,
                  "published_at": NOW - 10, "vrf": vrf}
    return fab, nacs, leases, fw


def codes(f):
    return {x["code"] for x in f}


def main():
    for seed in range(300):
        rng = random.Random(seed)
        fab, nacs, leases, fw = world(rng, rng.randrange(1, 40))

        bad = [x for x in reconcile(fab, nacs, leases, fw, NOW) if x["severity"] != "INFO"]
        assert not bad, (seed, bad)

        # Kill one session: its published address must go stale.
        ip = rng.choice(sorted(fw))
        dead = {m: dict(s, live=False) if m == fw[ip]["mac"] else s for m, s in nacs.items()}
        assert "STALE_PUBLICATION" in codes(
            [x for x in reconcile(fab, dead, leases, fw, NOW) if x["subject"] == ip]), seed

        # Publish the wrong role: must be flagged, and only that address.
        other = {"staff": "visitor", "visitor": "staff"}
        wrong = dict(fw, **{ip: dict(fw[ip], role=other[fw[ip]["role"]])})
        hit = {x["subject"] for x in reconcile(fab, nacs, leases, wrong, NOW)
               if x["severity"] != "INFO"}
        assert hit == {ip}, (seed, hit)

        # Garbage in any register must not raise, and every code must be known.
        junk = dict(fw, **{"203.0.113.9": {"ip": "203.0.113.9", "role": "", "user": "",
                                           "mac": "", "published_at": 0, "vrf": ""}})
        for regs in ((fab, {}, {}, junk), ({}, nacs, leases, {}), ({}, {}, {}, {})):
            for x in reconcile(*regs, NOW):
                assert x["code"] in CODES[x["severity"]], x
    print("ok")


main()
