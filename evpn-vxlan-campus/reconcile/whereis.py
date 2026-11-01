#!/usr/bin/env python3
"""Where is this endpoint? The lookup the subnet used to give you for free.

Usage: ./whereis.py <mac | ip | username | partial>   [...]
       ./whereis.py --all

In a hierarchical design you read the location off the address. In a fabric
the address tells you nothing -- the same VNI is on every leaf and the gateway
is the same address everywhere. The location is in the CONTROL PLANE instead:
which VTEP advertises the MAC, out of which port, in which VNI, since when.

That is strictly MORE precise than a /24 ever was. A /24 told you a building;
a type-2 route tells you the closet, the patch port and the VLAN, right now.
What was lost is only the zero-effort lookup, and this is the lookup.

Everything here is read-only.
"""

import sys
import time

import registers as R


def places(path=None):
    """leaf / VTEP / port -> a human place. See locations.txt."""
    import os
    path = path or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "locations.txt")
    out = {}
    try:
        raw = open(path).read()
    except OSError:
        return out
    for line in raw.split("\n"):
        line = line.split("#")[0].strip()
        if "=" in line:
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip()
    return out


def collect(now):
    """One pass over every register, indexed every way you might ask."""
    fab = R.fabric()
    nacs = R.nac(now)
    leases = R.ddi(now)
    fw = R.firewall()
    loc = places()

    eps = {}
    for (vrf, m), e in fab.items():
        ep = eps.setdefault(m, {"mac": m})
        ep.update({k: v for k, v in e.items() if v not in (None, "")})
        ep["vrf"] = vrf
    for m, s in nacs.items():
        eps.setdefault(m, {"mac": m})["nac"] = s
    for m, l in leases.items():
        eps.setdefault(m, {"mac": m})["lease"] = l
    for ip, p in fw.items():
        if p["mac"]:
            eps.setdefault(p["mac"], {"mac": p["mac"]})["published"] = p

    for ep in eps.values():
        # Location, best available. Local beats remote: the leaf that holds
        # the MAC knows the port; a remote VTEP only knows the building.
        # Two levels, deliberately kept apart. "area" is the structured
        # site/building/closet of the LEAF, which is what policy should be
        # tagged with. "place" is the most specific string available, usually
        # the patch port, which is what a human wants to read. Slugging the
        # port description into a tag produces nonsense like
        # bldg:howard-tilton-idf-1-patch-4-ap-a1-ceilin.
        if ep.get("leaf"):
            port_key = "%s/%s" % (ep["leaf"], ep.get("port", ""))
            ep["area"] = loc.get(ep["leaf"], "")
            ep["place"] = loc.get(port_key) or ep["area"] or ""
            ep["how"] = "local type-2 on %s %s" % (ep["leaf"],
                                                   ep.get("port", "?"))
        elif ep.get("remote_vtep"):
            ep["area"] = loc.get(ep["remote_vtep"], "")
            ep["place"] = ep["area"]
            ep["how"] = "remote type-2 via VTEP %s" % ep["remote_vtep"]
        else:
            ep["how"] = "not in the fabric right now"
        # The address, from whichever register has it.
        ep["ip"] = (ep.get("lease", {}).get("ip")
                    or ep.get("fabric_ip")
                    or ep.get("published", {}).get("ip") or "")
        ep["user"] = (ep.get("nac", {}).get("user")
                      or ep.get("published", {}).get("user") or "")
    return eps


def matches(ep, q):
    q = q.lower()
    hay = [ep["mac"], ep.get("ip", ""), ep.get("user", ""),
           ep.get("leaf", ""), ep.get("place", ""),
           ep.get("lease", {}).get("hostname", "")]
    return any(q in (h or "").lower() for h in hay)


def show(ep, now):
    print("%s  %s" % (ep.get("ip") or "(no address)", ep["mac"]))
    print("  where     %s" % (ep.get("place") or "(no location on record)"))
    print("  evidence  %s" % ep["how"])
    if ep.get("vni"):
        print("  segment   VNI %s, VRF %s" % (ep["vni"], ep.get("vrf", "?")))

    s = ep.get("nac")
    if s:
        print("  who       %s (realm %s, authorized %s)%s" % (
            s["user"], s["realm"], s["expected_role"],
            "" if s["live"] else "  -- SESSION NOT LIVE, last seen %ds ago"
            % s["age"]))
        if s["anonymous"]:
            print("            outer identity only; the real name never "
                  "left %s" % s["realm"])
    else:
        print("  who       unknown -- no NAC session for this MAC")

    l = ep.get("lease")
    if l:
        print("  address   leased from DDI, %s %ds" % (
            "expired" if l["expired"] else "expires in",
            abs(l["expire"] - now)))
    elif ep.get("fabric_ip"):
        print("  address   %s seen by the fabric, no DDI lease (static, or "
              "outside IPAM)" % ep["fabric_ip"])

    p = ep.get("published")
    if p:
        print("  policy    firewall tags it role=%s as %s" % (
            p["role"], p["user"] or "(address only)"))
    else:
        print("  policy    no firewall mapping")

    if ep.get("mobility", 0) > 1 or ep.get("duplicate"):
        print("  movement  mobility sequence %s%s -- it has moved" % (
            ep.get("mobility"), ", FLAGGED DUPLICATE" if ep.get("duplicate")
            else ""))
    print()


def main(argv):
    now = int(time.time())
    eps = collect(now)
    if not eps:
        print("nothing in any register -- is the lab up?")
        return 2

    if not argv or argv == ["--all"]:
        for ep in sorted(eps.values(), key=lambda e: (e.get("place", "~"),
                                                      e.get("ip", ""))):
            show(ep, now)
        return 0

    hits = [ep for ep in eps.values() if any(matches(ep, q) for q in argv)]
    if not hits:
        print("no endpoint matches %s in any register.\n"
              "Note what that does NOT tell you: an endpoint absent from the\n"
              "fabric may simply have gone quiet. With ARP suppression the\n"
              "leaf answers from type-2 routes, and a type-2 exists only\n"
              "while the leaf holds an ARP entry." % " ".join(argv))
        return 1
    for ep in sorted(hits, key=lambda e: e.get("ip", "")):
        show(ep, now)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
