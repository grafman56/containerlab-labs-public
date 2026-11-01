#!/usr/bin/env bash
# Guided demo: fabric -> NAC -> DDI -> firewall, with changes and break/fix.
#
# Needs the lab up (./labctl up, verify, verify-identity) and a PAN-OS XML API
# to publish to. The panos-emulator project is one (python3 panos_emulator.py).
#
#   ./demo.sh [PANOS_URL]          default http://127.0.0.1:8080
#
# It changes the lab and puts it back. Takes about 5 minutes. Safe to rerun.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
url=${1:-http://127.0.0.1:8080}
lab=clab-evpn-vxlan-campus
nac=$lab-nac staff=$lab-sta-staff
authz=/etc/freeradius/3.0/mods-config/files/authorize
fails=0

step()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
say()   { printf '   %s\n' "$*"; }
show()  { "$here/labctl" reconcile --panos "$url" 2>&1 | grep -E '^(CRITICAL|WARN|INFO|[A-Z]+=)' | cut -c1-160; }
expect() { # expect <code> present|absent
  local got ok=0
  got=$("$here/labctl" reconcile --panos "$url" 2>&1 | grep -c "^CRITICAL .*$1")
  if [ "$2" = present ]; then [ "$got" -gt 0 ] && ok=1; else [ "$got" -eq 0 ] && ok=1; fi
  if [ $ok -eq 1 ]; then say "ok: ${1:-no CRITICAL} $2"; else say "FAIL: expected ${1:-no CRITICAL} $2"; fails=$((fails + 1)); fi
}
# Wait until a CRITICAL code is gone (or is there), up to $3 seconds.
wait_for() {
  local end=$((SECONDS + ${3:-240}))
  while [ $SECONDS -lt $end ]; do
    n=$("$here/labctl" reconcile --panos "$url" 2>&1 | grep -c "^CRITICAL .*$1")
    { [ "$2" = present ] && [ "$n" -gt 0 ]; } || { [ "$2" = absent ] && [ "$n" -eq 0 ]; } && return 0
    sleep 5
  done
  return 1
}
radius_restart() {  # a docker restart would drop the node's links
  docker exec "$nac" pkill freeradius; sleep 2
  docker exec -d "$nac" sh -c 'freeradius -X > /tmp/radius.log 2>&1'; sleep 6
}
reauth_wifi() {
  docker exec "$staff" wpa_cli -i wlan0 disconnect >/dev/null
  docker exec "$staff" wpa_cli -i wlan0 pmksa_flush >/dev/null
  docker exec "$staff" wpa_cli -i wlan0 reconnect >/dev/null
}
set_vlan() {  # set_vlan <from> <to>
  docker exec "$nac" sed -i "0,/Group-ID = \"$1\"/s//Group-ID = \"$2\"/" "$authz"
  radius_restart; reauth_wifi
}
cleanup() { # always leave the lab as found
  docker exec "$nac" grep -q 'Group-ID = "30"' "$authz" 2>/dev/null && set_vlan 30 10
  docker exec "$staff" wpa_cli -i eth1 logon >/dev/null 2>&1
}
trap cleanup EXIT

step "1. Start state: stations get addresses from DDI"
docker exec "$staff" timeout 20 dhclient -1 eth1 >/dev/null 2>&1
docker exec "$staff" ip -br addr | grep -E 'eth1|wlan0' | cut -c1-70
say "The visitor has no DHCP lease. That is a known gap, see reconcile/README.md."

step "2. Before publishing: NAC knows the users, the firewall does not"
show
say "Expect UNPUBLISHED for jsmith: authenticated, but the firewall has no mapping."

step "3. Publish NAC identity to the firewall (user + role/segment tags)"
"$here/labctl" publish --panos "$url" 2>&1 | tail -6 | cut -c1-160
show
expect STALE_PUBLICATION absent
expect WRONG_ absent

step "4. What the firewall now holds"
curl -s "$url/api/?type=op&cmd=<show><user><ip-user-mapping><all/></ip-user-mapping></user></show>" | head -c 600; echo
curl -s "$url/api/?type=op&cmd=<show><object><registered-ip><all/></registered-ip></object></show>" | head -c 700; echo

step "5. CHANGE: move jsmith from the staff VLAN to the visitor VLAN"
say "NAC returns VLAN 30 on the next login. The fabric follows. The firewall does not."
set_vlan 10 30
wait_for WRONG_SEGMENT present 90 && show | grep -E 'WRONG_SEGMENT|CRITICAL='
expect WRONG_SEGMENT present

step "6. CHANGE BACK: revert; the finding clears once the AP ages out the old VLAN"
set_vlan 30 10
wait_for WRONG_SEGMENT absent 300
expect WRONG_SEGMENT absent

step "7. BREAK: the wired laptop logs off; the firewall still trusts its address"
docker exec "$staff" wpa_cli -i eth1 logoff >/dev/null
wait_for STALE_PUBLICATION present 120
show | grep -E 'STALE_PUBLICATION|CRITICAL='
expect STALE_PUBLICATION present

step "8. FIX: expire what no session backs"
"$here/labctl" publish --panos "$url" --expire 2>&1 | tail -4 | cut -c1-160
expect STALE_PUBLICATION absent

step "9. BREAK: someone hand-edits the firewall (wrong role tag)"
ip=$(docker exec "$staff" ip -4 -o addr show wlan0 | awk '{print $4}' | cut -d/ -f1)
curl -s --data-urlencode "type=user-id" --data-urlencode \
  "cmd=<uid-message><version>2.0</version><type>update</type><payload><register><entry ip=\"$ip\"><tag><member>role:visitor</member></tag></entry></register></payload></uid-message>" \
  "$url/api/" >/dev/null
expect WRONG_TAG present

step "10. FIX: publish replaces the managed tags"
"$here/labctl" publish --panos "$url" 2>&1 | tail -3 | cut -c1-160
expect WRONG_TAG absent

step "11. Restore the wired laptop and publish; end state"
docker exec "$staff" wpa_cli -i eth1 logon >/dev/null
sleep 25; docker exec "$staff" timeout 20 dhclient -1 eth1 >/dev/null 2>&1
"$here/labctl" publish --panos "$url" --expire >/dev/null 2>&1
show
expect "" absent

step "Result"
[ "$fails" -eq 0 ] && say "PASS: every expected finding appeared and cleared" || say "FAIL: $fails check(s) failed"
exit "$fails"
