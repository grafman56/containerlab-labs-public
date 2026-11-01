#!/usr/bin/env python3
"""Read-only reconciliation of the fabric, the NAC, DDI and the firewall.

Usage: ./reconcile.py [--json | --prometheus] [--now EPOCH] [--panos URL]

Reports the deltas between four registers that nothing else compares. See
registers.py for what each one knows and why DDI is the load-bearing join.

--prometheus prints the counts in Prometheus text format, for a Telegraf
prometheus input or a node_exporter textfile. A finding code with none open
is still printed as 0, so an alert can see it clear. If the PAN-OS API cannot
be reached, the output says campus_reconcile_up 0 instead of failing.

--panos URL reads the firewall register from a PAN-OS XML API (the
panos-emulator lab, or a firewall) instead of nftables. PANOS_KEY, if set, is
the API key. Without it, nothing changes.

Nothing here writes to a lab node. Publication is reconcile/publish.py.
"""

import json
import os
import statistics
import sys
import time

import registers as R

# Ordered worst first. The ordering is the point: a stale publication grants
# rights to whoever now holds the address, which is worse than an endpoint
# that merely cannot get through.
SEVERITY = ("CRITICAL", "WARN", "INFO")


# Every code add() can raise. Kept here so --prometheus can print a 0 for a
# code with nothing open; test_reconcile.py checks this list against the source.
CODES = {
    "CRITICAL": ("DUPLICATE_MAC", "LEASE_REASSIGNED", "STALE_PUBLICATION",
                 "VRF_MISMATCH", "WRONG_SEGMENT", "WRONG_TAG", "WRONG_USER",
                 "UNAUTHENTICATED"),
    "WARN": ("LEASE_EXPIRED", "MISSING_USER", "NO_ADDRESS", "OFF_IPAM",
             "PUBLISHED_WITHOUT_LEASE", "UNPUBLISHED", "UNAUTHENTICATED"),
    "INFO": ("MOBILITY", "NO_USERNAME_TO_PUBLISH"),
}


def prometheus(findings, registers, lat, now, up=1):
    """Prometheus text exposition of one reconcile run. Pure, so it is tested
    without a lab."""
    out = [
        "# HELP campus_reconcile_up 1 if every register could be read.",
        "# TYPE campus_reconcile_up gauge",
        "campus_reconcile_up %d" % up,
        "# HELP campus_reconcile_timestamp_seconds When this run happened.",
        "# TYPE campus_reconcile_timestamp_seconds gauge",
        "campus_reconcile_timestamp_seconds %d" % now,
        "# HELP campus_reconcile_findings Open findings by severity and code.",
        "# TYPE campus_reconcile_findings gauge",
    ]
    open_ = {}
    for f in findings:
        open_[(f["severity"], f["code"])] = open_.get((f["severity"], f["code"]), 0) + 1
    for sev, codes in CODES.items():
        for code in codes:
            out.append('campus_reconcile_findings{severity="%s",code="%s"} %d' % (
                sev, code, open_.pop((sev, code), 0)))
    for (sev, code), n in sorted(open_.items()):  # a code missing from CODES
        out.append('campus_reconcile_findings{severity="%s",code="%s"} %d' % (sev, code, n))
    out += ["# HELP campus_register_entries Entries in each register.",
            "# TYPE campus_register_entries gauge"]
    for name, n in registers.items():
        out.append('campus_register_entries{register="%s"} %d' % (name, n))
    if lat:
        out += ["# HELP campus_publication_latency_max_seconds Slowest NAC-to-firewall publication.",
                "# TYPE campus_publication_latency_max_seconds gauge",
                "campus_publication_latency_max_seconds %d" % max(lat)]
    return "\n".join(out) + "\n"


def reconcile(fab, nacs, leases, fw, now, infra=frozenset()):
    f = []

    def add(sev, code, subject, detail):
        f.append({"severity": sev, "code": code, "subject": subject,
                  "detail": detail})

    lease_by_ip = {l["ip"]: l for l in leases.values()}

    # ---- firewall-side: what have we told the firewall that is not true? ----
    for ip, pub in sorted(fw.items()):
        sess = nacs.get(pub["mac"]) if pub["mac"] else None
        if sess is None:
            sess = next((s for s in nacs.values()
                         if s["user"] and s["user"] == pub["user"]), None)
        if sess is None or not sess["live"]:
            # The dangerous one. The address is still tagged, the session is
            # gone, and the next device to take that address inherits the
            # rights. Produced by a missed Accounting-Stop, which is normal:
            # a laptop lid closes and nothing tells anyone.
            add("CRITICAL", "STALE_PUBLICATION", ip,
                "tagged role=%s user=%s, no live NAC session%s" % (
                    pub["role"], pub["user"] or "-",
                    "" if sess is None else " (last seen %ds ago)" % sess["age"]))
            continue

        if pub["role"] != sess["expected_role"]:
            add("CRITICAL", "WRONG_TAG", ip,
                "firewall says role=%s, NAC authorized %s (realm %s)" % (
                    pub["role"], sess["expected_role"], sess["realm"]))

        if pub["user"] and not sess["anonymous"] and pub["user"] != sess["user"]:
            # The address is tagged for the right role but mapped to someone
            # else. User-based rules and logs now name the wrong person.
            add("CRITICAL", "WRONG_USER", ip,
                "firewall maps this address to %s, the NAC session on it is %s" % (
                    pub["user"], sess["user"]))

        elif not pub["user"] and not sess["anonymous"]:
            # The tag is there and the user mapping is not: a login timeout
            # ran out, or a restore brought back tags only. Role-based rules
            # still work. Anything that names the user does not.
            add("WARN", "MISSING_USER", ip,
                "tagged role=%s, but the firewall has no user for this address; "
                "the NAC session on it is %s" % (pub["role"], sess["user"]))

        fabent = fab.get((pub["vrf"], pub["mac"])) if pub["mac"] else None
        if pub["vrf"] and fabent is None:
            others = [k[0] for k in fab if k[1] == pub["mac"]]
            if others:
                # Keying a mapping on IP alone is how two tenants with the
                # same address space silently acquire each other's rights.
                add("CRITICAL", "VRF_MISMATCH", ip,
                    "published in VRF %s, fabric holds this MAC in %s" % (
                        pub["vrf"], ",".join(others)))

        lease = lease_by_ip.get(ip)
        if lease is None:
            add("WARN", "PUBLISHED_WITHOUT_LEASE", ip,
                "no DDI lease backs this address; the mapping rests on "
                "nothing re-checkable")
        elif lease["expired"]:
            add("WARN", "LEASE_EXPIRED", ip,
                "lease expired %ds ago but the mapping is still live" % (
                    now - lease["expire"]))
        elif lease["mac"] != pub["mac"] and pub["mac"]:
            add("CRITICAL", "LEASE_REASSIGNED", ip,
                "lease now belongs to %s, mapping still claims %s" % (
                    lease["mac"], pub["mac"]))

    # ---- NAC-side: who did we authorize and fail to publish? ----
    for m, s in sorted(nacs.items()):
        if not s["live"]:
            continue
        lease = leases.get(m)
        published = [p for p in fw.values()
                     if p["mac"] == m or (p["user"] and p["user"] == s["user"])]

        if s["anonymous"]:
            # Correct PEAP behaviour at a Service Provider, and a hard limit
            # on user-based policy: there is no username to map. Policy for
            # visitors has to be segment-based, which is exactly why the
            # EDUROAM VRF exists instead of a rule naming people.
            add("INFO", "NO_USERNAME_TO_PUBLISH", m,
                "outer identity %s; only %s ever saw the real username" % (
                    s["user"], s["realm"]))

        if lease is None:
            # The BlueCat dependency, made visible. RADIUS accounting from
            # hostapd carries no Framed-IP-Address, so without a lease there
            # is no MAC-to-IP edge and the session CANNOT be published at all.
            add("WARN", "NO_ADDRESS", m,
                "live session for %s, no DHCP lease: nothing to map an IP to"
                % (s["user"] or "-"))
        elif not published and not s["anonymous"]:
            add("WARN", "UNPUBLISHED", m,
                "%s holds %s with a live session, firewall has no mapping "
                "(expect fall-through denies)" % (s["user"], lease["ip"]))

        fabent = next((v for k, v in fab.items() if k[1] == m), None)
        if fabent and fabent.get("vni"):
            actual = R.ROLE_FOR_VNI.get(fabent["vni"])
            if actual and actual != s["expected_role"]:
                # Gotcha 4's signature: authentication succeeded, the client
                # associated, and the Tunnel-* attributes were dropped, so the
                # station sits in the authenticator's default segment. Nothing
                # logs an error, because nothing went wrong.
                add("CRITICAL", "WRONG_SEGMENT", m,
                    "NAC authorized %s, fabric placed it in VNI %d (%s)" % (
                        s["expected_role"], fabent["vni"], actual))

    # ---- fabric-side: what is forwarding that nobody authorized? ----
    for (vrf, m), e in sorted(fab.items()):
        if "leaf" not in e:
            continue
        if m in nacs:
            continue
        if e.get("fabric_ip") in infra or m in infra:
            continue
        if "%s/%s" % (e["leaf"], e.get("port", "")) in infra:
            continue
        add("CRITICAL" if e.get("fabric_ip") else "WARN", "UNAUTHENTICATED", m,
            "forwarding on %s %s in %s%s, no NAC session (MAB bypass, "
            "unbridged-port shortcut, or rogue)" % (
                e["leaf"], e.get("port", "?"), vrf,
                " as " + e["fabric_ip"] if e.get("fabric_ip") else ""))

    for (vrf, m), e in sorted(fab.items()):
        ip = e.get("fabric_ip")
        if ip and m not in leases and m in nacs:
            # An address the fabric is forwarding that IPAM has never issued.
            # On a real campus this is the static-address-nobody-recorded
            # problem, and it is the single most common reason an IPAM
            # database and the network disagree.
            add("WARN", "OFF_IPAM", m,
                "fabric holds %s in %s with no DDI lease: static address "
                "outside IPAM" % (ip, vrf))
        if e.get("duplicate"):
            add("CRITICAL", "DUPLICATE_MAC", m,
                "FRR flagged this MAC as duplicate in %s: a loop, or the "
                "same address configured twice" % vrf)
        elif e.get("mobility", 0) > 1:
            add("INFO", "MOBILITY", m,
                "MAC mobility sequence %d in %s (roam, or a flap)" % (
                    e["mobility"], vrf))

    f.sort(key=lambda x: (SEVERITY.index(x["severity"]), x["code"], x["subject"]))
    return f


def latencies(nacs, fw):
    """How long between authorizing an endpoint and the firewall knowing.

    Nobody measures this, and it is the number that explains the help-desk
    ticket where the first connection after login fails and the retry works.
    """
    out = []
    for p in fw.values():
        s = nacs.get(p["mac"])
        # a negative gap means the session was renewed after the last publish,
        # so that publish says nothing about how fast the first one was
        if s and p["published_at"] and s["ts"] and p["published_at"] >= s["ts"]:
            out.append(p["published_at"] - s["ts"])
    return out


def panos_url(argv):
    for i, arg in enumerate(argv):
        if arg == "--panos" and i + 1 < len(argv):
            return argv[i + 1]
        if arg.startswith("--panos="):
            return arg.split("=", 1)[1]
    return os.environ.get("PANOS_URL") or None


def main(argv):
    want_json = "--json" in argv
    now = int(time.time())
    if "--now" in argv:
        now = int(argv[argv.index("--now") + 1])

    fab = R.fabric()
    nacs = R.nac(now)
    leases = R.ddi(now)
    url = panos_url(argv)
    if url:
        try:
            fw = R.panos_firewall(url, os.environ.get("PANOS_KEY", ""),
                                  vrfs={k[0] for k in fab}, leases=leases)
        except Exception as error:
            # A firewall that cannot be read is a different problem from a
            # firewall that disagrees. Say so rather than printing a traceback
            # or, worse, reporting every session as unpublished.
            if "--prometheus" in argv:
                print(prometheus([], {}, [], now, up=0), end="")
                return 0
            print("cannot read the PAN-OS API at %s: %s" % (url, error), file=sys.stderr)
            return 3
    else:
        fw = R.firewall()
    findings = reconcile(fab, nacs, leases, fw, now, R.infra() | R.infra_macs())
    lat = latencies(nacs, fw)

    if "--prometheus" in argv:
        print(prometheus(findings, {"fabric": len(fab), "nac_sessions": len(nacs),
                                    "ddi_leases": len(leases),
                                    "firewall_mappings": len(fw)}, lat, now), end="")
        return 0

    if want_json:
        print(json.dumps({
            "registers": {"fabric": len(fab), "nac_sessions": len(nacs),
                          "ddi_leases": len(leases), "firewall_mappings": len(fw)},
            "findings": findings,
            "publication_latency_secs": lat,
        }, indent=2))
        return 0

    print("registers: fabric=%d entries  nac=%d sessions (%d live)  "
          "ddi=%d leases  firewall=%d mappings" % (
              len(fab), len(nacs), sum(1 for s in nacs.values() if s["live"]),
              len(leases), len(fw)))
    if not any(( fab, nacs, leases, fw )):
        print("\nevery register is empty -- is the lab up? (./labctl status)")
        return 2
    if lat:
        print("publication latency: min %ds  median %ds  max %ds  (n=%d)" % (
            min(lat), int(statistics.median(lat)), max(lat), len(lat)))
    print()

    if not findings:
        print("no deltas. all four registers agree.")
        return 0

    width = max(len(f["subject"]) for f in findings)
    for f in findings:
        print("%-8s %-24s %-*s  %s" % (
            f["severity"], f["code"], width, f["subject"], f["detail"]))

    counts = {}
    for f in findings:
        counts[f["severity"]] = counts.get(f["severity"], 0) + 1
    print("\n" + "  ".join("%s=%d" % (s, counts[s])
                           for s in SEVERITY if s in counts))
    # Deltas are the normal state of a campus, not a failure. Exit 0 so this
    # can run on a timer without a monitoring system crying wolf; the counts
    # are the signal.
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
