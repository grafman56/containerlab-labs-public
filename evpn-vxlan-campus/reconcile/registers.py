#!/usr/bin/env python3
"""The four registers, and the join over them.

No register knows an endpoint. Each knows a projection of one, and the
projections overlap just enough to be joined and just little enough that
nothing checks anything else:

  FABRIC    (EVPN type-2)       MAC -> VNI, which leaf, which port, mobility
  NAC       (RADIUS accounting) MAC -> user, realm, session, last seen
  DDI       (DHCP lease)        MAC -> IP, expiry          <- the join key
  FIREWALL  (ip-user-mapping)   IP  -> user, tag

The fabric knows WHERE, the NAC knows WHO, the firewall knows WHAT IT MAY DO,
and only DDI knows the MAC-to-IP edge at a point in time. The fabric and the
NAC are keyed on MAC; the firewall is keyed on IP. Without the DHCP lease
there is no path from one to the other, which is the whole reason an IPAM/DDI
system is load-bearing here rather than an address-management convenience.

Join on IP + MAC + VRF. VRF is not optional: PAN-OS User-ID is per-vsys, so
two tenants with overlapping address space cross-attribute silently if you
key on IP alone. This lab has one overlapping-capable pair of VRFs on purpose.

Everything here is read-only. Parsing is defensive because every one of these
output formats is a vendor's, not an interface.
"""

import csv
import io
import json
import os
import re
import subprocess
import time

LAB = "evpn-vxlan-campus"
LEAVES = ("leaf1a", "leaf2a", "leaf1b", "leaf2b")

# Kea's subnet ids are deliberately the VNI numbers, so a lease can be placed
# in a VRF without asking the fabric. A real BlueCat holds this mapping as
# IPAM metadata on the network object -- which is the useful version, because
# then the source of truth for "what is this subnet for" lives beside the
# addresses instead of being inferred.
VNI_VRF = {1010: "TENANT-A", 1020: "TENANT-A", 1030: "EDUROAM"}

# The NAC's own enforcement rule, restated. identity/start-radius.sh puts
# anything proxied -- i.e. any realm that is not ours -- into VLAN 30. Local
# accounts carry Tunnel-Private-Group-ID = 10 from nac/authorize.
#
# This is the only place the expected segment can come from, because RADIUS
# ACCOUNTING does not carry the Tunnel-* attributes: the authorization is in
# the Access-Accept, and the accounting register never sees it. A real NAC
# keeps its own session table with the role it assigned. Rebuilding the rule
# here is the lab's stand-in for querying that table.
HOME_REALM = "campus.edu"
ROLE_FOR_VNI = {1010: "staff", 1030: "visitor"}

# hostapd sends interim accounting every 30s (radius_acct_interim_interval).
# Two missed intervals plus slack: past this, the NAC's session is not
# evidence that anything is still connected.
SESSION_FRESH_SECS = 90


def infra(path=None):
    """Addresses and ports that are not expected to hold a NAC session.

    See infra.txt. A real job reads this from IPAM, where the reservations
    already exist, rather than keeping a second list that drifts.
    """
    path = path or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "infra.txt")
    out = set()
    try:
        raw = open(path).read()
    except OSError:
        return out
    for line in raw.split("\n"):
        line = line.split("#")[0].strip()
        if line:
            out.add(line)
    return out


def infra_macs(nodes=("ap-a1", "edge-a1")):
    """MACs of the authenticators themselves, read from the running nodes.

    The AP and the access switch cannot sit behind their own 802.1X, and their
    MACs change on every deploy, so they cannot live in infra.txt. A real job
    reads these from IPAM reservations; this reads the interfaces instead.
    """
    out = set()
    for name in nodes:
        for line in dexec(name, "ip", "-o", "link").split("\n"):
            parts = line.split("link/ether ")
            if len(parts) > 1:
                out.add(mac(parts[1].split()[0]))
    out.discard("")
    return out


def node(name):
    return "clab-%s-%s" % (LAB, name)


def dexec(name, *argv):
    """Run a command in a lab node. Returns stdout, or '' if the node is
    unreachable -- a missing register is a finding, not a crash."""
    try:
        out = subprocess.run(
            ("docker", "exec", node(name)) + argv,
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return out.stdout if out.returncode == 0 else ""


def vtysh(name, cmd):
    raw = dexec(name, "vtysh", "-c", cmd)
    # vtysh prints config-file warnings to stdout before the JSON.
    brace = raw.find("{")
    if brace < 0:
        return {}
    try:
        return json.loads(raw[brace:])
    except ValueError:
        return {}


def mac(s):
    """One MAC spelling. RADIUS uses AA-BB-CC, FRR uses aa:bb:cc, and a
    reconciliation that misses this reports every endpoint twice."""
    h = re.sub(r"[^0-9a-fA-F]", "", s or "")
    if len(h) != 12:
        return ""
    return ":".join(h[i:i + 2] for i in range(0, 12, 2)).lower()


# --------------------------------------------------------------------------
# FABRIC: EVPN type-2, read per leaf.
#
# Each leaf holds only the VNIs it has locally plus what its peers advertise,
# so this has to ask every leaf. On a real fabric that is the same problem --
# query every leaf, or query a route reflector and lose the local/remote
# distinction. This lab has no reflector (full mesh), so: every leaf.
# --------------------------------------------------------------------------

def fabric():
    out = {}
    for leaf in LEAVES:
        vnis = vtysh(leaf, "show evpn vni json")
        for vni_s, v in vnis.items():
            if not isinstance(v, dict) or v.get("type") != "L2":
                continue
            vni = int(vni_s)
            vrf = v.get("tenantVrf") or VNI_VRF.get(vni, "")

            macs = vtysh(leaf, "show evpn mac vni %d json" % vni).get("macs", {})
            for m_raw, m in macs.items():
                m_key = mac(m_raw)
                if not m_key or not isinstance(m, dict):
                    continue
                # Only the leaf that holds it locally is authoritative for
                # where it is. Remote entries are the same endpoint seen from
                # elsewhere; recording them would multiply-count it.
                if m.get("type") != "local":
                    # Not ours. The ONLY location clue a remote type-2 carries
                    # is the VTEP it points at -- which is the whole argument
                    # for numbering VTEP loopbacks with geography in them. The
                    # next-hop is where location lives now.
                    e = out.setdefault((vrf, m_key), {})
                    e.setdefault("vrf", vrf)
                    e.setdefault("mac", m_key)
                    e.setdefault("vni", vni)
                    e.setdefault("remote_vtep", m.get("remoteVtep", ""))
                    continue
                e = out.setdefault((vrf, m_key), {})
                e.update(
                    vrf=vrf, mac=m_key, vni=vni, leaf=leaf,
                    port=m.get("intf", ""),
                    # Rising sequence = the fabric has moved this MAC. A step
                    # change on a wired port is a loop or a duplicate; on
                    # wireless it is a normal roam. isDuplicate is FRR giving
                    # up on it entirely.
                    mobility=int(m.get("localSequence") or 0),
                    duplicate=bool(m.get("isDuplicate")),
                )

            arps = vtysh(leaf, "show evpn arp-cache vni %d json" % vni)
            for ip, a in arps.items():
                if not isinstance(a, dict):
                    continue
                m_key = mac(a.get("mac", ""))
                if m_key and a.get("type") != "local":
                    e = out.setdefault((vrf, m_key), {})
                    e.setdefault("fabric_ip", ip)
                    if a.get("remoteVtep"):
                        e.setdefault("remote_vtep", a["remoteVtep"])
                    continue
                if m_key:
                    # The fabric's own idea of the address, independent of the
                    # lease. Disagreement with DDI is a real signal: a static
                    # address nobody put in IPAM.
                    out.setdefault((vrf, m_key), {})["fabric_ip"] = ip
    return out


# --------------------------------------------------------------------------
# NAC: FreeRADIUS detail accounting.
#
# The debug log (/tmp/radius.log) is the teaching surface and shows every
# attribute of every packet, but it is 27MB after a day and it is a log, not
# a register. The detail files are the machine-readable accounting record and
# are what a real NAC's session table is built from.
# --------------------------------------------------------------------------

def nac(now=None):
    now = now or time.time()
    raw = dexec("nac", "sh", "-c",
                "cat /var/log/freeradius/radacct/*/detail-* 2>/dev/null")
    return parse_nac(raw, now)


def parse_nac(raw, now):
    """Last record per session wins; a session is live if its last record was
    not a Stop and arrived recently enough to mean anything."""
    sessions = {}
    for block in raw.split("\n\n"):
        rec = {}
        for line in block.split("\n"):
            if "=" not in line or not line.startswith(("\t", " ")):
                continue
            k, _, v = line.partition("=")
            rec[k.strip()] = v.strip().strip('"')
        sid = rec.get("Acct-Unique-Session-Id")
        if not sid:
            continue
        ts = int(rec.get("Timestamp") or 0)
        if ts >= int(sessions.get(sid, {}).get("ts", -1)):
            sessions[sid] = {
                "ts": ts,
                "status": rec.get("Acct-Status-Type", ""),
                "user": rec.get("User-Name", ""),
                "mac": mac(rec.get("Calling-Station-Id", "")),
                "realm": rec.get("Realm", ""),
                "nas": rec.get("NAS-Identifier") or rec.get("NAS-IP-Address", ""),
                "session": rec.get("Acct-Session-Id", ""),
            }

    out = {}
    for s in sessions.values():
        if not s["mac"] or s["status"] == "Stop":
            continue
        s["age"] = int(now - s["ts"])
        s["live"] = s["age"] <= SESSION_FRESH_SECS
        # A visited site authenticating a roaming user only ever sees the
        # OUTER identity. That is PEAP working correctly -- and it means the
        # visited campus has no username to publish to its firewall for any
        # eduroam visitor. Not a defect to fix: a property to design around.
        s["anonymous"] = s["user"].split("@")[0].lower() in ("anonymous", "")
        s["expected_role"] = (
            "staff" if s["realm"] == HOME_REALM else "visitor"
        )
        # One MAC can hold a wired and a wireless session at once in this lab.
        # Keep the freshest; note the other.
        prev = out.get(s["mac"])
        if prev is None or s["ts"] > prev["ts"]:
            if prev:
                s["also_sessions"] = prev.get("also_sessions", 0) + 1
            out[s["mac"]] = s
        else:
            prev["also_sessions"] = prev.get("also_sessions", 0) + 1
    return out


# --------------------------------------------------------------------------
# DDI: the Kea lease file. BlueCat's equivalent is an API query against
# Address Manager; the data is the same four fields, and the operational
# property that matters -- a lease expires and the client keeps using the
# address anyway -- is identical.
# --------------------------------------------------------------------------

def ddi(now=None):
    now = now or time.time()
    raw = dexec("ddi", "sh", "-c", "cat /tmp/kea-leases4.csv 2>/dev/null")
    return parse_ddi(raw, now)


def parse_ddi(raw, now):
    out = {}
    if not raw.strip():
        return out
    for row in csv.DictReader(io.StringIO(raw)):
        m = mac(row.get("hwaddr", ""))
        if not m:
            continue
        expire = int(row.get("expire") or 0)
        # memfile keeps a row per write, newest last; and state 1/2 are
        # declined/expired-reclaimed, not a current binding.
        lease = {
            "ip": row.get("address", ""),
            "mac": m,
            "expire": expire,
            "expired": expire < now,
            "subnet": int(row.get("subnet_id") or 0),
            "hostname": row.get("hostname", ""),
            "state": int(row.get("state") or 0),
        }
        lease["vrf"] = VNI_VRF.get(lease["subnet"], "")
        prev = out.get(m)
        if prev is None or expire >= prev["expire"]:
            out[m] = lease
    return {m: l for m, l in out.items() if l["state"] == 0}


# --------------------------------------------------------------------------
# FIREWALL: nftables named sets as the PAN-OS stand-in.
#
# A dynamic address group IS a set of addresses with a tag -- it carries no
# username, which is why publication is a LOSSY projection of the NAC's
# decision and why reconciliation has to reconstruct it from the other side.
# The per-element comment stands in for the separate ip-user-mapping table,
# so that "who did we claim this address is" is answerable.
# --------------------------------------------------------------------------

def firewall(fw="fw-a"):
    raw = dexec(fw, "nft", "-j", "list", "table", "inet", "userid")
    return parse_firewall(raw)



def panos_firewall(url, key="", vrfs=(), leases=None):
    """The same register, read from a PAN-OS XML API instead of nftables.

    PAN-OS keeps an IP-to-user table and per-IP tags. It has no MAC, no VRF
    name and no publication time, so:
      - role comes from the role: tag; an address with no role tag is skipped
      - user comes from the IP-to-user table ("" for an anonymous visitor)
      - vrf comes from the vrf: tag, which is a slug, so it is mapped back to a
        real VRF name from `vrfs`
      - mac is joined from DDI by address, the same edge publish.py used. That
        means LEASE_REASSIGNED cannot fire against this register: the MAC is
        always the current lease holder's.
      - published_at is 0, so publication latency is not reported
    """
    import panos
    users = panos.mappings(url, key)
    by_slug = {re.sub(r"[^a-z0-9]+", "-", v.lower()).strip("-")[:40]: v for v in vrfs}
    mac_by_ip = {l["ip"]: m for m, l in (leases or {}).items()}
    out = {}
    for ip, tags in panos.tags(url, key).items():
        roles = [t[len("role:"):] for t in sorted(tags) if t.startswith("role:")]
        if not roles:
            continue
        # Two role tags on one address is a conflict, not a tie to break. Join
        # them so it can never equal the single role the NAC authorized.
        role = "+".join(roles)
        slug = next((t[len("vrf:"):] for t in sorted(tags) if t.startswith("vrf:")), "")
        out[ip] = {"ip": ip, "role": role, "user": users.get(ip) or "",
                   "mac": mac_by_ip.get(ip, ""), "published_at": 0,
                   "vrf": by_slug.get(slug, slug)}
    return out


def parse_firewall(raw):
    out = {}
    try:
        doc = json.loads(raw)
    except ValueError:
        return out
    for obj in doc.get("nftables", []):
        s = obj.get("set")
        if not s or not s.get("name", "").startswith("role_"):
            continue
        role = s["name"][len("role_"):]
        for elem in s.get("elem", []):
            e = elem.get("elem", elem) if isinstance(elem, dict) else {}
            ip = e.get("val") if isinstance(e, dict) else elem
            if not isinstance(ip, str):
                continue
            meta = dict(
                kv.split("=", 1)
                for kv in (e.get("comment", "") if isinstance(e, dict) else "").split(",")
                if "=" in kv
            )
            out[ip] = {
                "ip": ip, "role": role,
                "user": meta.get("user", ""),
                "mac": mac(meta.get("mac", "")),
                "published_at": int(meta.get("ts") or 0),
                "vrf": meta.get("vrf", ""),
            }
    return out
