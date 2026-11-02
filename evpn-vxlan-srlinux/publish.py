#!/usr/bin/env python3
"""Publish host identity to the PAN-OS emulator: User-ID login plus VNI/VRF/VLAN tags.

Run on the Containerlab host after post-up.sh:  ./publish.py [--url URL] [--clear]

Per host: IP from the host, then IRB subnet -> VLAN id and VRF from the leaf, and
VLAN -> VNI from the leaf's vxlan0 interface. The firewall never sees a VNI, so it
goes in as a tag: a rule can match source-tag vni:1010 with no prefix in it.
"""
import ipaddress, re, subprocess, sys, urllib.parse, urllib.request
from xml.etree.ElementTree import Element, SubElement, tostring

P = "clab-evpn-srlinux-"
# host -> (leaf it hangs off, user). The user is lab data: a NAC would supply it.
HOSTS = {"h1": ("l1", "alice@lab.local"), "h2": ("l2", "bob@lab.local"),
         "h3": ("l2", "visitor1@lab.local"), "h4": ("l1", "carol@lab.local")}


def run(node, *cmd):
    return subprocess.run(["docker", "exec", P + node, *cmd], capture_output=True, text=True, check=True).stdout


def leaf_maps(leaf):
    """{vlan: (network, vni, vrf)} read from the leaf."""
    def cli(c): return run(leaf, "sr_cli", c)
    return parse_leaf(cli("info flat from running interface irb0 subinterface * ipv4 address *"),
                      cli("info flat from running tunnel-interface vxlan0 vxlan-interface * ingress vni"),
                      cli("info flat from running network-instance * interface irb0.*"))


def parse_leaf(addrs, vnis, vrfs):
    net = {v: ipaddress.ip_interface(a).network for v, a in re.findall(r"subinterface (\d+) ipv4 address (\S+)", addrs)}
    vni = dict(re.findall(r"vxlan-interface (\d+) ingress vni (\d+)", vnis))
    vrf = {v: n for n, v in re.findall(r"network-instance (\S+) interface irb0\.(\d+)", vrfs) if not n.startswith("vlan")}
    return {v: (net[v], vni.get(v), vrf.get(v)) for v in net}


def tags_for(ip, maps):
    for vlan, (net, vni, vrf) in maps.items():
        if ipaddress.ip_address(ip) in net:
            return ["vlan:" + vlan, "vni:%s" % vni, "vrf:%s" % vrf]
    return []


def uid(login=(), register=(), unregister=(), logout=()):
    r = Element("uid-message"); SubElement(r, "version").text = "2.0"; SubElement(r, "type").text = "update"
    p = SubElement(r, "payload")
    for verb, rows in (("login", login), ("logout", logout)):
        if rows:
            e = SubElement(p, verb)
            for u, ip in rows: SubElement(e, "entry", name=u, ip=ip)
    for verb, rows in (("register", register), ("unregister", unregister)):
        if rows:
            e = SubElement(p, verb)
            for ip, tags in rows:
                t = SubElement(SubElement(e, "entry", ip=ip), "tag")
                for x in tags: SubElement(t, "member").text = x
    return tostring(r, encoding="unicode")


def post(url, msg):
    d = urllib.parse.urlencode({"type": "user-id", "cmd": msg}).encode()
    return urllib.request.urlopen(url.rstrip("/") + "/api", d, timeout=10).read().decode()


def selfcheck():
    m = parse_leaf("set / interface irb0 subinterface 10 ipv4 address 10.10.10.11/24\n",
                   "set / tunnel-interface vxlan0 vxlan-interface 10 ingress vni 1010\n",
                   "set / network-instance tenant interface irb0.10\nset / network-instance vlan10 interface irb0.10\n")
    assert tags_for("10.10.10.21", m) == ["vlan:10", "vni:1010", "vrf:tenant"], m


if __name__ == "__main__":
    selfcheck()
    url = sys.argv[sys.argv.index("--url") + 1] if "--url" in sys.argv else "http://127.0.0.1:8080"
    maps, logins, regs = {}, [], []
    for h, (leaf, user) in HOSTS.items():
        ip = re.search(r"inet (\S+?)/", run(h, "ip", "-o", "-4", "addr", "show", "eth1")).group(1)
        t = tags_for(ip, maps.setdefault(leaf, leaf_maps(leaf)))
        print("%-3s %-15s %-20s %s" % (h, ip, user, " ".join(t)))
        logins.append((user, ip)); regs.append((ip, t))
    if "--clear" in sys.argv:
        print(post(url, uid(logout=logins, unregister=regs)))
    else:
        print(post(url, uid(login=logins, register=regs)))
