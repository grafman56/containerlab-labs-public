#!/usr/bin/env python3
"""Publish NAC sessions to the firewall. The ClearPass-to-PAN-OS leg.

Usage: ./publish.py [--expire] [--flush] [--dry-run]

This is the only writer in reconcile/. It joins the NAC's live sessions to
DDI's leases to get an IP, then puts that IP into a role set on fw-a -- the
same shape as a ClearPass Endpoint Context Server action calling the PAN-OS
XML API to register a dynamic address group tag.

It deliberately does NOT remove anything by default, because that is what the
real thing does: membership is added on Accounting-Start and ages out on a
timeout. A session that ends without an Accounting-Stop -- a closed lid, a
device out of range, an AP reboot -- leaves its mapping behind. Run
reconcile.py afterwards and the stale entry is sitting there.

  --expire  remove mappings with no live session. The fix, so the difference
            between the two runs is visible rather than described.
  --flush   drop the whole table, to start a walk-through clean.
  --enforce install one counter rule per tag, so you can watch policy match
            on "staff in Howard-Tilton" with no prefix in the rule.
"""

import re
import subprocess
import sys
import time

import registers as R
import whereis

FW = "fw-a"
TABLE = ("inet", "userid")


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:40]


def tags_for(ep, role):
    """The three-field tag: identity, location, intent.

    Publishing only a role gets you back to "who", which is what the NAC
    already knew. The reason to publish LOCATION too is that a fabric took
    location out of the address, so a firewall keyed on addresses lost it --
    and location is most of what the old subnet-shaped policy was expressing.
    Putting it back as a TAG rather than a prefix is the whole trick: a rule
    can say "staff in the nursing building" again, sourced from the control
    plane instead of from the address.

    identity comes from the NAC. location comes from the fabric's type-2
    next-hop, resolved through IPAM. segment intent comes from the IPAM
    network object -- which is the one of the four that holds something a
    human wrote down rather than something a protocol reported.
    """
    out = ["role:" + role]

    # The STRUCTURED location of the leaf, not the free-text patch label.
    # "Site A / Howard-Tilton / IDF-1 (basement)" -> site, building, closet.
    area = ep.get("area") or ""
    if area:
        parts = [p.strip() for p in area.split("/")]
        if len(parts) >= 1:
            out.append("site:" + slug(parts[0]))
        if len(parts) >= 2:
            out.append("bldg:" + slug(parts[1]))
        if len(parts) >= 3:
            out.append("closet:" + slug(parts[2].split("(")[0]))

    if ep.get("vrf"):
        out.append("vrf:" + slug(ep["vrf"]))
    if ep.get("vni"):
        out.append("vni:%s" % ep["vni"])

    # No location on record is itself worth tagging. An endpoint the fabric
    # cannot place, or a VTEP nobody mapped to a closet, should be visible in
    # policy rather than quietly indistinguishable from a located one.
    if not area:
        out.append("loc:unknown")
    return out


def nft(*args, dry=False):
    cmd = ("docker", "exec", R.node(FW), "nft") + args
    if dry:
        print("would run: nft " + " ".join(args))
        return True
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        print("nft failed: %s" % (r.stderr.strip() or r.stdout.strip()),
              file=sys.stderr)
    return r.returncode == 0


def ensure_tag(tag, dry=False):
    """One nftables set per tag. A PAN-OS dynamic address group is exactly
    this: a named set of addresses, matched by policy, with no username in
    it."""
    nft("add", "set", TABLE[0], TABLE[1], "tag_" + slug(tag),
        "{ type ipv4_addr; }", dry=dry)


def ensure_table(dry=False):
    nft("add", "table", *TABLE, dry=dry)
    for role in ("staff", "visitor"):
        # No 'flags interval': these are host addresses, and an interval set
        # silently merges adjacent ones, which would make two endpoints look
        # like one range.
        nft("add", "set", TABLE[0], TABLE[1], "role_" + role,
            "{ type ipv4_addr; }", dry=dry)


def enforce(dry=False):
    """Install one counter rule per tag, so the tags are demonstrably
    MATCHABLE rather than just present.

    This is the point of the whole exercise: a rule here says "traffic from
    the nursing building" or "traffic from staff" without naming a single
    prefix. That is the subnet-shaped policy you used to write, expressed as a
    tag, with the location sourced from the fabric's type-2 next-hop instead
    of from the address.

    It lives in its own table rather than in firewall/zones.nft because
    nftables lets several tables hook forward independently -- so this adds
    policy without disturbing the zone ruleset verify-identity.sh asserts on.
    Priority is after the zone filter, and these are COUNTERS, not drops:
    swapping `counter` for `counter drop` is the one-line change that gives a
    stale mapping teeth, and it should be a decision rather than a default.

    Re-pushed from scratch every run, which is what a controller does.
    """
    nft("add", "chain", TABLE[0], TABLE[1], "tags",
        "{ type filter hook forward priority filter + 10; policy accept; }",
        dry=dry)
    nft("flush", "chain", TABLE[0], TABLE[1], "tags", dry=dry)
    for tag in tag_sets(dry=dry):
        nft("add", "rule", TABLE[0], TABLE[1], "tags",
            "ip", "saddr", "@" + tag, "counter",
            "comment", '"from %s"' % tag[len("tag_"):], dry=dry)


def tag_sets(dry=False):
    """Every tag_* set currently on the firewall."""
    import json
    raw = R.dexec(FW, "nft", "-j", "list", "table", *TABLE)
    try:
        doc = json.loads(raw)
    except ValueError:
        return []
    return [o["set"]["name"] for o in doc.get("nftables", [])
            if o.get("set", {}).get("name", "").startswith("tag_")]


def main(argv):
    dry = "--dry-run" in argv
    now = int(time.time())

    if "--flush" in argv:
        nft("delete", "table", *TABLE, dry=dry)
        print("flushed inet userid on %s" % FW)
        if "--expire" not in argv:
            return 0

    ensure_table(dry=dry)

    nacs = R.nac(now)
    leases = R.ddi(now)
    fw = R.firewall(FW)
    # One pass over every register, so an endpoint's LOCATION is available
    # here and not just in the report. whereis already does this join.
    eps = whereis.collect(now)

    added = kept = 0
    for mac, s in sorted(nacs.items()):
        if not s["live"]:
            continue
        lease = leases.get(mac)
        if lease is None:
            # No lease, no IP, no mapping. The firewall is keyed on address;
            # a session without one is unpublishable. reconcile.py reports it
            # as NO_ADDRESS rather than this failing quietly.
            continue
        if s["anonymous"]:
            # A visited site has no real username for a roaming user. It can
            # still tag the ADDRESS -- which is all a dynamic address group
            # needs -- so publish the role and record the outer identity for
            # what it is worth. User-based rules for visitors are not
            # available, by design, not by omission.
            pass
        if fw.get(lease["ip"], {}).get("role") == s["expected_role"]:
            kept += 1
            continue
        ep = eps.get(mac, {})
        tags = tags_for(ep, s["expected_role"])
        comment = "user=%s,mac=%s,ts=%d,vrf=%s" % (
            s["user"], mac, now, lease["vrf"])
        if nft("add", "element", TABLE[0], TABLE[1],
               "role_" + s["expected_role"],
               '{ %s comment "%s" }' % (lease["ip"], comment), dry=dry):
            added += 1
            print("published %-15s %s" % (lease["ip"], " ".join(tags)))
            print("          %s" % (ep.get("place") or "no location on record"))
        # The tag sets. These are the dynamic address groups a Palo rule
        # would actually match on.
        for tag in tags:
            ensure_tag(tag, dry=dry)
            nft("add", "element", TABLE[0], TABLE[1], "tag_" + slug(tag),
                "{ %s }" % lease["ip"], dry=dry)

    removed = 0
    if "--expire" in argv:
        for ip, pub in sorted(fw.items()):
            s = nacs.get(pub["mac"])
            if s and s["live"]:
                continue
            if nft("delete", "element", TABLE[0], TABLE[1],
                   "role_" + pub["role"], "{ %s }" % ip, dry=dry):
                removed += 1
                # Every tag set too, or the location tags outlive the role and
                # the stale case comes back wearing a different name.
                for tag in tag_sets(dry=dry):
                    nft("delete", "element", TABLE[0], TABLE[1], tag,
                        "{ %s }" % ip, dry=dry)
                print("expired   %-15s role=%-7s %s" % (
                    ip, pub["role"], pub["user"] or "-"))

    if "--enforce" in argv:
        enforce(dry=dry)
        print("\ninstalled counter rules for: %s" % ", ".join(
            t[len("tag_"):] for t in tag_sets()))

    print("\nadded=%d unchanged=%d removed=%d%s" % (
        added, kept, removed,
        "" if "--expire" in argv
        else "  (no --expire: stale mappings left in place on purpose)"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
