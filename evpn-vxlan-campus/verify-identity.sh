#!/usr/bin/env bash
# Identity-edge checks. verify.sh covers the fabric; this covers who is on it.
#
# Run verify.sh first. If the fabric is broken, everything below fails in
# confusing ways.
set -euo pipefail

lab=clab-evpn-vxlan-campus
x() { docker exec "${lab}-$1" "${@:2}"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== identity services reachable from the access switch =="
for ip in 10.20.20.20 10.20.20.30 10.20.20.40 10.20.20.50; do
  x edge-a1 ping -c1 -W2 "$ip" >/dev/null 2>&1 || fail "edge-a1 cannot reach $ip"
done
echo "ok: nac, fed, idp-remote, ddi"

echo "== local realm authenticates on campus =="
x edge-a1 radtest jsmith@campus.edu labpass 10.20.20.20 0 edge-secret 2>&1 \
  | grep -q Access-Accept || fail "campus.edu did not authenticate locally"
echo "ok"

echo "== the VLAN assignment is complete: all three attributes or none =="
out=$(x edge-a1 radtest jsmith@campus.edu labpass 10.20.20.20 0 edge-secret 2>&1)
for a in Tunnel-Type Tunnel-Medium-Type Tunnel-Private-Group-Id; do
  grep -q "$a" <<<"$out" || fail "Access-Accept is missing $a; two of three silently does nothing"
done
echo "ok: VLAN $(grep -oE 'Tunnel-Private-Group-Id:0 = \"[0-9]+' <<<"$out" | grep -oE '[0-9]+$')"

echo "== a foreign realm is proxied through the federation, not answered locally =="
count_accepts() { x idp-remote sh -c "grep -c 'Sent Access-Accept' /tmp/radius.log 2>/dev/null || true" | tr -dc '0-9'; }
before=$(count_accepts); before=${before:-0}
x edge-a1 radtest visitor@remote.edu roampass 10.20.20.20 0 edge-secret 2>&1 \
  | grep -q Access-Accept || fail "remote.edu visitor was not authenticated"
after=$(count_accepts); after=${after:-0}
[ "$after" -gt "$before" ] || fail "the visitor was answered locally; the home institution never saw it"
echo "ok: authenticated at remote.edu, not at nac"

echo "== an unknown realm is refused, not forwarded somewhere hopeful =="
x edge-a1 radtest nobody@elsewhere.edu x 10.20.20.20 0 edge-secret 2>&1 \
  | grep -q Access-Accept && fail "an unknown realm was accepted"
echo "ok"

echo "== 802.1X over EAPOL, both stations =="
# Mark where the NAC's log is now. The radtest probes above deliberately use
# PAP with a real username, so only the lines produced by the EAPOL run below
# are admissible evidence for the outer-identity check.
mark=$(x nac sh -c "wc -l < /tmp/radius.log" | tr -dc '0-9')
for s in sta-staff sta-visitor; do x "$s" pkill wpa_supplicant 2>/dev/null || true; done
sleep 1
docker exec -d "${lab}-sta-staff"   sh -c 'wpa_supplicant -D wired -i eth1 -c /cfg/sta/wpa-staff.conf   -d > /tmp/wpa.log 2>&1'
docker exec -d "${lab}-sta-visitor" sh -c 'wpa_supplicant -D wired -i eth1 -c /cfg/sta/wpa-visitor.conf -d > /tmp/wpa.log 2>&1'
sleep 30
for s in sta-staff sta-visitor; do
  x "$s" grep -q 'EAPOL authentication completed - result=SUCCESS' /tmp/wpa.log \
    || fail "$s did not complete 802.1X"
  echo "ok: $s authenticated"
done

echo "== the visitor's username never left the tunnel =="
# The visited site must see only the realm. Seeing the inner identity in the
# NAC's log means the supplicant leaked it in the outer identity, which is a
# reportable defect, not a lab detail.
x nac sh -c "tail -n +${mark} /tmp/radius.log | grep -q 'User-Name = \"anonymous@remote.edu\"'" \
  || fail "the visited NAC never saw an anonymous outer identity"
if x nac sh -c "tail -n +${mark} /tmp/radius.log | grep -q 'User-Name = \"visitor@remote.edu\"'"; then
  fail "the visitor's real username is visible at the visited site: outer identity leak"
fi
echo "ok: nac saw anonymous@remote.edu and never visitor@remote.edu"

echo "== the home institution did see it, because it terminates the tunnel =="
x idp-remote grep -q 'visitor@remote.edu' /tmp/radius.log \
  || fail "remote.edu never saw its own user"
echo "ok"

# Do this BEFORE any reachability check below. An unauthorized port is in no
# bridge at all, so a station behind one cannot reach anything -- which makes
# "the visitor cannot reach campus" pass for entirely the wrong reason. It did
# exactly that until the internet check further down failed and gave it away.
echo "== authorized ports land in their zone bridge =="
# hostapd cycles a wired port when a supplicant reconnects, and that can land
# between the enslave and the check. Retry rather than pretend it is instant.
for attempt in 1 2 3 4 5; do
  x edge-a1 /cfg/edge/authorize-port.sh eth2 10 >/dev/null 2>&1 || true
  x edge-a1 /cfg/edge/authorize-port.sh eth3 30 >/dev/null 2>&1 || true
  sleep 2
  if x edge-a1 bridge link | grep -q 'eth2.*master br-staff' \
     && x edge-a1 bridge link | grep -q 'eth3.*master br-eduroam'; then
    break
  fi
  [ "$attempt" = 5 ] && fail "ports did not stay in their zone bridges after 5 attempts"
done
echo "ok"

echo "== zones are separate VRFs on the fabric =="
x leaf1a vtysh -c 'show vrf' 2>/dev/null | grep -q 'vrf EDUROAM'  || fail "leaf1a has no EDUROAM VRF"
x leaf1a vtysh -c 'show vrf' 2>/dev/null | grep -q 'vrf TENANT-A' || fail "leaf1a has no TENANT-A VRF"
echo "ok"

echo "== the visitor zone has a default, learned from the firewall hand-off =="
x leaf1a vtysh -c 'show ip route vrf EDUROAM 0.0.0.0/0' 2>/dev/null | grep -q '10.255.1.1' \
  || fail "EDUROAM has no default via the border"
echo "ok: via bdr-a, the preferred border leaf for campus A"

echo "== and no path at all to the campus zone =="
# Two assertions, because the first one alone is not worth much.
#
# The leaf genuinely holds no route -- the prefix was never imported, so there
# is nothing to filter. But that passed while a visitor could still reach
# campus services: the visitor default pointed at the firewall, and the
# firewall held routes into both zones in one table with no policy, so it
# forwarded between them.
#
# VRF separation on the fabric is not isolation if something downstream has
# both routes. Assert the end-to-end result, not just the table.
if x leaf1a vtysh -c 'show ip route vrf EDUROAM 10.20.20.0/24' 2>/dev/null | grep -q 'via'; then
  fail "EDUROAM holds a route to the campus services subnet"
fi
echo "ok: 10.20.20.0/24 does not exist in the visitor table"

echo "== and a visitor cannot actually reach campus, end to end =="
x sta-visitor ip address replace 10.30.30.50/24 dev eth1 >/dev/null 2>&1 || true
x sta-visitor ip route replace default via 10.30.30.1 >/dev/null 2>&1 || true
if x sta-visitor ping -c2 -W2 10.20.20.20 >/dev/null 2>&1; then
  fail "a visitor reached the campus services subnet; the zones are not isolated"
fi
echo "ok: blocked on the wire, not just absent from a table"

echo "== while the visitor still has internet, through the firewall =="
x sta-visitor ping -c3 -W3 203.0.113.1 >/dev/null 2>&1 \
  || fail "visitor has no internet; the zone is isolated but useless"
echo "ok"

echo "== WPA2-Enterprise over the air, and the AP acting on the VLAN =="
# Note the EAPOL step above killed every wpa_supplicant on these nodes,
# wireless included, and only restarted the wired one. Bring the radios back
# before anything that needs them.
for s in sta-staff sta-visitor; do x "$s" pkill -f 'wpa_supplicant -D nl80211' 2>/dev/null || true; done
sleep 1
docker exec -d "${lab}-sta-staff" \
  sh -c 'wpa_supplicant -D nl80211 -i wlan0 -c /cfg/sta/wpa-staff-wifi.conf   -d > /tmp/wifi.log 2>&1'
docker exec -d "${lab}-sta-visitor" \
  sh -c 'wpa_supplicant -D nl80211 -i wlan0 -c /cfg/sta/wpa-visitor-wifi.conf -d > /tmp/wifi.log 2>&1'
sleep 35
for s in sta-staff sta-visitor; do
  x "$s" wpa_cli -i wlan0 status 2>/dev/null | grep -q 'wpa_state=COMPLETED' \
    || fail "$s did not associate over WPA2-Enterprise"
  echo "ok: $s associated"
done

# The certificates are pinned by CA and by server name, so an association
# here also proves the supplicant verified the right institution.
echo "ok: both verified their institution's certificate"

# And the AP acted on the RADIUS reply itself -- no manual step.
x ap-a1 grep -q 'RADIUS: VLAN ID 10' /tmp/hostapd.log \
  || fail "the AP did not put the staff station in VLAN 10"
x ap-a1 grep -q 'RADIUS: VLAN ID 30' /tmp/hostapd.log \
  || fail "the AP did not put the visitor in VLAN 30"
echo "ok: one radio, two stations, two VLANs -> two VRFs on the fabric"

echo "== DHCP and DNS from the DDI node =="
# Over the air, because that is the path a campus endpoint actually takes and
# because it is the one hostapd assigned a VLAN to. The wired port is kept for
# watching EAPOL; running dhclient on both at once just races them.
x sta-staff pkill dhclient 2>/dev/null || true
x sta-staff sh -c 'timeout 25 dhclient -1 wlan0' >/dev/null 2>&1 || true
addr=$(x sta-staff ip -4 -br addr show wlan0 | awk '{print $3}')
[ -n "$addr" ] || fail "sta-staff got no DHCP lease"
echo "ok: sta-staff leased ${addr}"
x sta-staff sh -c 'dig +short +time=3 +tries=3 @10.10.10.50 nac.campus.edu' 2>/dev/null \
  | grep -q '10.20.20.20' || fail "DNS did not resolve nac.campus.edu"
echo "ok: DNS resolves from the same node that issued the lease"

echo "PASS: identity edge verified"
