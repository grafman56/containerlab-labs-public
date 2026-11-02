#!/usr/bin/env python3
"""Make fw forward what the PAN-OS emulator's committed rulebase says.

Run on the Containerlab host:  ./sync-fw.py [--url URL] [--dry-run]

Reads the running security rules, the registered-ip tags and the ip-user
mappings from the emulator, and rewrites nftables chain `zone_policy` on fw. A tag or
user match becomes the set of addresses User-ID knows for it, so a rule written
against "vni:1010" or "alice@lab.local" holds no prefix. Rules are first match
wins, like PAN-OS. The chain ends in the base ruleset's default drop.

Supported: source/destination zones, application (see APPS), source-tag,
source-user, action allow/deny. Anything else in a rule is ignored here.
"""
import subprocess, sys, urllib.parse, urllib.request
from xml.etree.ElementTree import fromstring

APPS = {"icmp": "ip protocol icmp", "ssh": "tcp dport 22", "web-browsing": "tcp dport 80",
        "ssl": "tcp dport 443", "dns": "meta l4proto { tcp, udp } th dport 53"}
VSYS = "/config/devices/entry[@name='localhost.localdomain']/vsys/entry[@name='vsys1']/rulebase/security/rules"


def get(url, **q):
    d = urllib.parse.urlencode(q)
    return fromstring(urllib.request.urlopen(url + "/api?" + d, timeout=10).read())


def members(e, tag):
    return [m.text for m in e.findall(tag + "/member")]


def build(rules, tag_ips, user_ips):
    """rules: [{name, source, destination, application, source-tag, source-user, action}]"""
    out = []
    for r in rules:
        ips = None  # None = no identity condition
        for key, table in (("source-tag", tag_ips), ("source-user", user_ips)):
            want = r.get(key) or []
            if want:
                found = {ip for w in want for ip in table.get(w, ())}
                ips = found if ips is None else ips & found
        if ips is not None and not ips:
            continue  # identity named but nobody holds it right now
        verdict = "accept" if r["action"] == "allow" else "drop"
        srcs = [z for z in r["source"] if z != "any"] or [None]
        dsts = [z for z in r["destination"] if z != "any"] or [None]
        apps = [a for a in r["application"] if a != "any"] or [None]
        for s in srcs:
            for d in dsts:
                for a in apps:
                    if a is not None and a not in APPS:
                        continue  # unknown application: do not guess a port
                    parts = ['iifname @%s_ifaces' % s if s else "", 'oifname @%s_ifaces' % d if d else "",
                             "ip saddr { %s }" % ", ".join(sorted(ips)) if ips else "", APPS[a] if a else "",
                             'counter', verdict, 'comment "%s"' % r["name"]]
                    out.append("add rule inet zones zone_policy " + " ".join(p for p in parts if p))
    return out


def selfcheck():
    r = [{"name": "t", "source": ["tenant"], "destination": ["guest"], "application": ["icmp"],
          "source-tag": ["vni:1010"], "source-user": [], "action": "allow"}]
    got = build(r, {"vni:1010": {"10.10.10.21", "10.10.10.22"}}, {})
    assert got == ['add rule inet zones zone_policy iifname @tenant_ifaces oifname @guest_ifaces '
                   'ip saddr { 10.10.10.21, 10.10.10.22 } ip protocol icmp counter accept comment "t"'], got
    assert build(r, {}, {}) == []  # nobody tagged: no rule, so default deny


if __name__ == "__main__":
    selfcheck()
    url = sys.argv[sys.argv.index("--url") + 1] if "--url" in sys.argv else "http://127.0.0.1:8080"
    rules = [{"name": e.get("name"), "action": e.findtext("action"),
              **{k: members(e, k) for k in ("source", "destination", "application", "source-tag", "source-user")}}
             for e in get(url, type="config", action="show", xpath=VSYS).findall("result/rules/entry")]
    tag_ips, user_ips = {}, {}
    for e in get(url, type="op", cmd="<show><object><registered-ip><all/></registered-ip></object></show>").findall("result/entry"):
        for t in members(e, "tag"):
            tag_ips.setdefault(t, set()).add(e.findtext("ip"))
    for e in get(url, type="op", cmd="<show><user><ip-user-mapping><all/></ip-user-mapping></user></show>").findall("result/entry"):
        if e.findtext("user"):
            user_ips.setdefault(e.findtext("user"), set()).add(e.findtext("ip"))
    cmds = ["flush chain inet zones zone_policy"] + build(rules, tag_ips, user_ips)
    print("\n".join(cmds))
    if "--dry-run" not in sys.argv:
        subprocess.run(["docker", "exec", "-i", "clab-evpn-srlinux-fw", "nft", "-f", "-"],
                       input="\n".join(cmds), text=True, check=True)
        # Existing sessions would keep matching `ct state established`. Clear them
        # so a changed rule takes effect now. (A real firewall ages sessions out.)
        subprocess.run(["docker", "exec", "clab-evpn-srlinux-fw", "conntrack", "-F"], capture_output=True)
        print("fw policy updated: %d rule(s)" % (len(cmds) - 1))
