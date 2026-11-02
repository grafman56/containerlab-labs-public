#!/usr/bin/env bash
# Checks the lab end to end. Run on the Containerlab host after post-up.sh and
# with the PAN-OS emulator up (mirror mode). Exits non-zero on any failure.
set -uo pipefail
cd "$(dirname "$0")"
P=clab-evpn-srlinux
API=${PANOS_URL:-http://127.0.0.1:8080}/api
fail=0
check() { # name, expected (ok|fail), host, ip
  docker exec $P-$3 ping -c2 -W2 "$4" >/dev/null 2>&1 && got=ok || got=fail
  [ "$got" = "$2" ] && echo "PASS $1" || { echo "FAIL $1 (wanted $2, got $got)"; fail=1; }
}
has() { # name, text, pattern
  grep -q "$3" <<<"$2" && echo "PASS $1" || { echo "FAIL $1"; fail=1; }
}

echo "VLAN to VNI on the leaves"
vni=$(./show-vni.sh)
for v in "vxlan0.10 .*VNI 1010" "vxlan0.20 .*VNI 1020" "vxlan0.30 .*VNI 1030" "VNI 4100" "VNI 4200"; do has "$v" "$vni" "$v"; done

echo "Dataplane"
check "h1 -> h2 same VLAN, other leaf" ok h1 10.10.10.22
check "h1 -> h4 VLAN 10 to 20 (IRB)" ok h1 10.20.20.24
check "h1 -> h3 tenant to guest (fw allows icmp)" ok h1 10.30.30.23
check "h3 -> h1 guest to tenant (fw drops)" fail h3 10.10.10.21

echo "PAN-OS emulator"
zones=$(curl -s -G "$API" --data-urlencode type=op --data-urlencode "cmd=<show><interface>all</interface></show>")
has "emulator mirrors zone tenant" "$zones" "<zone>tenant</zone>"
has "emulator mirrors zone guest" "$zones" "<zone>guest</zone>"

./publish.py >/dev/null && echo "PASS publish.py" || { echo "FAIL publish.py"; fail=1; }
tags=$(curl -s -G "$API" --data-urlencode type=op --data-urlencode "cmd=<show><object><registered-ip><all/></registered-ip></object></show>")
has "10.10.10.21 tagged vni:1010" "$tags" "vni:1010"
has "10.30.30.23 tagged vni:1030" "$tags" "vni:1030"

curl -s -G "$API" --data-urlencode type=config --data-urlencode action=set \
  --data-urlencode "xpath=security/rules/entry[@name='vni1010-to-guest']" \
  --data-urlencode "element=<entry name='vni1010-to-guest'><source>tenant</source><destination>guest</destination><application>icmp</application><source-tag><member>vni:1010</member></source-tag><action>allow</action></entry>" >/dev/null
curl -s -X POST --data-urlencode type=commit "$API" >/dev/null; sleep 1
match() { curl -s -G "$API" --data-urlencode type=op --data-urlencode "cmd=<test><security-policy-match><from>tenant</from><to>guest</to><source>$1</source><destination>10.30.30.23</destination><application>icmp</application></security-policy-match></test>"; }
has "policy: VNI 1010 host allowed" "$(match 10.10.10.21)" "vni1010-to-guest"
has "policy: VNI 1020 host denied" "$(match 10.20.20.24)" "interzone-default"

[ $fail = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
