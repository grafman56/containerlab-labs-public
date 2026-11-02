"""Minimal PAN-OS User-ID client, standard library only.

Talks to a firewall's XML API, or to the panos-emu-public lab. Only the four
User-ID verbs and the two read commands that a NAC-to-firewall integration
needs. The builders and parsers are pure so the self-check runs without a
firewall.
"""

import urllib.parse
import urllib.request
from xml.etree.ElementTree import Element, SubElement, fromstring, tostring

SHOW_MAPPINGS = "<show><user><ip-user-mapping><all/></ip-user-mapping></user></show>"
SHOW_TAGS = "<show><object><registered-ip><all/></registered-ip></object></show>"


def uid_message(login=(), logout=(), register=(), unregister=()):
    """Build one <uid-message>.

    login:      (user, ip[, minutes]) the user on that address; minutes is the
                                      mapping timeout (the firewall default if omitted)
    logout:     (user, ip)
    register:   (ip, [tags])          tag an address (dynamic address groups)
    unregister: (ip, [tags])          no tags = drop every tag on the address
    """
    root = Element("uid-message")
    SubElement(root, "version").text = "2.0"
    SubElement(root, "type").text = "update"
    payload = SubElement(root, "payload")
    for verb, rows in (("login", login), ("logout", logout)):
        if rows:
            parent = SubElement(payload, verb)
            for user, ip, *minutes in rows:
                entry = SubElement(parent, "entry", name=user, ip=ip)
                if verb == "login" and minutes and minutes[0] is not None:
                    entry.set("timeout", str(minutes[0]))
    for verb, rows in (("register", register), ("unregister", unregister)):
        if rows:
            parent = SubElement(payload, verb)
            for ip, tags in rows:
                entry = SubElement(parent, "entry", ip=ip)
                if tags:
                    tag = SubElement(entry, "tag")
                    for name in tags:
                        SubElement(tag, "member").text = name
    return tostring(root, encoding="unicode")


def parse_mappings(xml):
    """show user ip-user-mapping -> {ip: user}"""
    return {e.findtext("ip"): e.findtext("user")
            for e in fromstring(xml).findall("result/entry")}


def parse_tags(xml):
    """show object registered-ip -> {ip: {tag, ...}}"""
    return {e.findtext("ip"): {m.text for m in e.findall("tag/member")}
            for e in fromstring(xml).findall("result/entry")}


def _call(base, key, **fields):
    if key:
        fields["key"] = key
    data = urllib.parse.urlencode(fields).encode()
    with urllib.request.urlopen(base.rstrip("/") + "/api", data=data, timeout=10) as r:
        return r.read().decode()


def send(base, key, **kwargs):
    """POST a uid-message. Raises RuntimeError if the firewall says error."""
    body = _call(base, key, type="user-id", cmd=uid_message(**kwargs))
    root = fromstring(body)
    if root.get("status") != "success":
        raise RuntimeError(root.findtext("result/msg") or "User-ID update failed")


def mappings(base, key):
    return parse_mappings(_call(base, key, type="op", cmd=SHOW_MAPPINGS))


def tags(base, key):
    return parse_tags(_call(base, key, type="op", cmd=SHOW_TAGS))
