#!/usr/bin/env bash
# Narrated walkthrough, about 2 minutes. Run on the Containerlab host after
# post-up.sh, with the PAN-OS emulator up. Safe to repeat: it removes its own rule first.
#   PAUSE=1 ./demo.sh    wait for Enter between steps
cd "$(dirname "$0")"
P=clab-evpn-srlinux
API=${PANOS_URL:-http://127.0.0.1:8080}/api
RULE=vni1010-to-guest
step() { echo; echo "=== $*"; [ -n "$PAUSE" ] && read -r _; }
png() { printf '  %-26s' "$1 -> $2:"; docker exec $P-$1 ping -c2 -W2 "$3" >/dev/null 2>&1 && echo reachable || echo BLOCKED; }
api() { curl -s -G "$API" "$@"; }

# reset: no demo rule, empty fw policy
api --data-urlencode type=config --data-urlencode action=delete \
    --data-urlencode "xpath=security/rules/entry[@name='$RULE']" >/dev/null
curl -s -X POST --data-urlencode type=commit "$API" >/dev/null; sleep 1; ./sync-fw.py >/dev/null

step "1. The VLAN to VNI binding, read from the SR Linux leaves"
./show-vni.sh

step "2. The fabric: stretched L2, then routing between VLANs"
png h1 h2 10.10.10.22
png h1 h4 10.20.20.24

step "3. The firewall starts closed: tenant to guest is blocked"
png h1 h3 10.30.30.23

step "4. Publish who is where. Tags carry the VNI, because the firewall never sees one"
./publish.py | head -4

step "5. The emulator, as the firewall API sees it: zones and tags"
api --data-urlencode type=op --data-urlencode "cmd=<show><interface>all</interface></show>" | grep -o 'name="[^"]*"><state>up</state><virtual-router>default</virtual-router><ip>[^<]*</ip><zone>[^<]*' | sed 's/"><state>up.*<ip>/  /; s/<\/ip><zone>/  zone /; s/name="//'

step "6. Write a rule in the PAN-OS API: tenant to guest, icmp, only source-tag vni:1010"
api --data-urlencode type=config --data-urlencode action=set \
    --data-urlencode "xpath=security/rules/entry[@name='$RULE']" \
    --data-urlencode "element=<entry name='$RULE'><source>tenant</source><destination>guest</destination><application>icmp</application><source-tag><member>vni:1010</member></source-tag><action>allow</action></entry>" | sed 's/^/  /'; echo
curl -s -X POST --data-urlencode type=commit "$API" | sed 's/^/  /'; echo; sleep 1
m() { printf '  policy match %-12s ' "$1:"; api --data-urlencode type=op --data-urlencode "cmd=<test><security-policy-match><from>tenant</from><to>guest</to><source>$1</source><destination>10.30.30.23</destination><application>icmp</application></security-policy-match></test>" | grep -o 'entry name="[^"]*"' ; }
m 10.10.10.21; m 10.20.20.24

step "7. Push the committed rules into the fw data path, then try the traffic"
./sync-fw.py | tail -1
png h1 h3 10.30.30.23
png h2 h3 10.30.30.23
png h4 h3 10.30.30.23
png h3 h1 10.10.10.21

step "8. The fw counted the packets on the rule"
docker exec $P-fw nft list chain inet zones zone_policy | grep counter | sed 's/^\s*/  /'
echo; echo "Done. Re-run any time: it resets its own rule."
