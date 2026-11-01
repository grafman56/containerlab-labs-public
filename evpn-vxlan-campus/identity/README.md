# Identity edge: 802.1X, eduroam, zones, DDI

The fabric lab answers "can these two hosts talk". This answers "who are they,
and who said so".

## Why this exists

Adding EVPN to a campus removes location as a security signal.

In a hierarchical campus, the subnet *was* the third floor of the nursing
building. Policy written against an address range was roughly right, because
the address encoded where you were and where you were encoded who you probably
were. A stretched L2 VNI with an anycast gateway destroys that on purpose:
`10.10.10.1` is live on every leaf at once and the same subnet exists in both
campuses simultaneously.

That trade is deliberate -- it buys mobility -- but something has to replace
the signal it spends, and the only honest replacement is identity. Which is
why "we are deploying EVPN" and "we need the firewall tied to endpoints"
turn up in the same project. They are one decision.

So this lab exists to make the identity chain observable end to end, on a
fabric, at a level of detail you cannot get from a diagram:

- who authenticates whom, and what the authenticator can and cannot see
- what a federated visitor's identity actually looks like at the visited site
- which attributes carry the authorization, and what acts on them
- when the IP address comes into existence, relative to all of the above
- what the fabric independently knows about the same endpoint
- and where the seams are, because the seams are where the work is

It is a **control-plane and operations** lab. It is not a security product:
`fw-a` is FRR with no policy engine, and nothing here enforces at the data
plane the way a real PAN-OS box does. What it models faithfully is the
plumbing -- who tells whom, in what order, over which protocol, and what
breaks when one step is wrong.

The intended use is hands-on: deploy it, capture on the hops, read the logs,
break a piece, and watch which of the three registers notices. Every gotcha
in the section below was found exactly that way.

It adds eight identity nodes to the campus topology. The full lab now has
35 nodes after adding a second border leaf at each site. `./labctl verify`
covers the fabric, and `./labctl verify-identity` covers the identity path.

```
                     (((  ap-a1  )))                .-- nac        10.20.20.20  "ClearPass"
                           | trunk                  |
 sta-staff   --eth2--.     |                        |-- fed        10.20.20.30  eduroam NRO
              wired  |     |                        |
                  edge-a1 -+------ trunk ---- leaf1a|-- idp-remote 10.20.20.40  remote.edu
                     |            VLAN 10,30     :  |
 sta-visitor --eth3--'                           :  |-- ddi        10.20.20.50  "BlueCat"
              wired                        leaf2a '--'             10.10.10.50

 Each station has BOTH a wired port and a radio, so the same account can be
 walked through either path and compared.
```

| Node | Stands in for | Owns |
|---|---|---|
| `edge-a1` | Aruba CX access switch | wired 802.1X authenticator, trunk uplink |
| `ap-a1` | Aruba AP | WPA2-Enterprise over the air, dynamic VLAN assignment |
| `nac` | ClearPass | realm `campus.edu`, proxies the rest |
| `fed` | eduroam national roaming operator | realm routing only, no credentials |
| `idp-remote` | another institution | realm `remote.edu`, the visitor's credential |
| `ddi` | BlueCat | DHCP (Kea) + DNS (BIND9) |

One image, `campus-identity:1.1.0`, serves every role. The role is chosen by
which config a node is handed, so every node also has `tcpdump` and you can
capture on any hop without rebuilding anything.

## Zones

| Zone | VLAN | L2VNI | L3VNI | VRF | Subnet | Reaches |
|---|---|---|---|---|---|---|
| Campus | 10 | 1010 | 4100 | `TENANT-A` | 10.10.10.0/24 | everything |
| Visitors | 30 | 1030 | 4200 | `EDUROAM` | 10.30.30.0/24 | internet only |

Separate VRFs, not two VLANs in one VRF. A visitor must not reach campus
resources, and the cheapest way to guarantee that is for the route simply not
to exist in their table. A deny rule you can mistype is weaker than a route
that was never imported. `verify-identity.sh` asserts the absence.

## Build it

```sh
# ./labctl up builds campus-identity:1.1.0 from labs.toml before it deploys.
# The explicit build below is only useful when debugging the image itself.
cd identity && docker build -t campus-identity:1.1.0 .
cd .. && ./labctl up
./labctl verify            # the fabric, unchanged
./labctl verify-identity   # this
```

## Walk the identity chain

The point of the lab is that each step below is separately observable.

### 1a. WPA2-Enterprise, over the air

The radios are `mac80211_hwsim` phys moved into the namespaces by
`wireless-attach.sh`, which `labctl up` runs for you. One SSID, `eduroam`,
WPA2-Enterprise.

```sh
docker exec -d clab-evpn-vxlan-campus-sta-staff \
  sh -c 'wpa_supplicant -D nl80211 -i wlan0 -c /cfg/sta/wpa-staff-wifi.conf -d > /tmp/wifi.log 2>&1'
docker exec clab-evpn-vxlan-campus-sta-staff wpa_cli -i wlan0 status
```

Look for `wpa_state=COMPLETED`, then the AP's view:

```sh
docker exec clab-evpn-vxlan-campus-ap-a1 \
  grep -E 'RADIUS: VLAN ID|AP-STA-CONNECTED' /tmp/hostapd.log
```

```
STA 02:00:00:00:01:00 RADIUS: VLAN ID 10      <- staff
STA 02:00:00:00:02:00 RADIUS: VLAN ID 30      <- visitor
```

**Two stations, one radio, two VRFs on the fabric.** The AP read
`Tunnel-Private-Group-ID` out of each Access-Accept and put each station in
that VLAN itself -- creating `wlan0.<vid>`, creating `eth1.<vid>` on the
tagged uplink, and bridging them. No manual step. That is `dynamic_vlan=1` in
`ap/hostapd.conf`, and it is what makes the chain genuinely end to end:

```
NAC decides a VLAN -> AP acts on it -> switch trunks it -> leaf maps it to a
VNI -> the station is in a VRF
```

The wired path in step 1 below leaves you to apply the VLAN by hand, which is
useful for seeing the attribute. This is what actually happens.

Certificates are pinned here, which is the other half of a real deployment:

```sh
grep -E 'ca_cert|domain_suffix_match' /cfg/sta/wpa-staff-wifi.conf
```

Each institution generates its own CA and its server certificate is named
after it (`CN=radius.campus.edu`, `CN=radius.remote.edu`). A supplicant that
trusts any valid certificate is the one an evil twin harvests credentials
from, because anybody can stand up an SSID called `eduroam`. eduroam CAT and
MDM exist to deliver exactly those two lines to devices nobody administers.

To see it matter, point `ca_cert` at the wrong institution's CA and re-run:
the client refuses with `unknown CA` and never sends its credential.

### 1. EAPOL, between supplicant and authenticator

```sh
docker exec -d clab-evpn-vxlan-campus-edge-a1 \
  timeout 40 tcpdump -ni eth2 -w /tmp/eapol.pcap ether proto 0x888e
docker exec -d clab-evpn-vxlan-campus-sta-staff \
  sh -c 'wpa_supplicant -D wired -i eth1 -c /cfg/sta/wpa-staff.conf -d > /tmp/wpa.log 2>&1'
docker cp clab-evpn-vxlan-campus-edge-a1:/tmp/eapol.pcap .
```

In Wireshark: `eapol`. EAPOL-Start, Request Identity, the PEAP exchange,
EAPOL-Success. The authenticator never sees a credential — `eap_server=0` in
`edge/hostapd-eth2.conf` is what makes that true.

### 2. RADIUS, between authenticator and NAC

```sh
docker exec clab-evpn-vxlan-campus-edge-a1 \
  tcpdump -ni br-staff -w /tmp/radius.pcap udp port 1812 or udp port 1813
```

Everything here is in the clear except the inner tunnel. **That is the whole
argument for RadSec**, and it is more convincing seen than read.

### 3. The realm decides where it goes

```sh
docker exec clab-evpn-vxlan-campus-nac grep 'Looking up realm' /tmp/radius.log
```

`campus.edu` is answered locally. `remote.edu` is proxied to `fed`, which
proxies to `idp-remote`. Confirm the home institution really did the work:

```sh
docker exec clab-evpn-vxlan-campus-idp-remote grep 'Login OK' /tmp/radius.log
```

### 4. The visitor's username never leaves their home institution

The single most useful thing in this lab. Compare the two servers:

```sh
docker exec clab-evpn-vxlan-campus-nac \
  grep -o 'User-Name = "[^"]*"' /tmp/radius.log | sort -u
docker exec clab-evpn-vxlan-campus-idp-remote \
  grep -o 'User-Name = "[^"]*"' /tmp/radius.log | sort -u
```

The visited site sees `anonymous@remote.edu`. Only `idp-remote`, which
terminates the TLS tunnel, sees `visitor@remote.edu`.

This is why eduroam visitors get segment-based policy and not user-based
policy: **you cannot write a least-privilege rule about a person you are not
permitted to identify.** The internet-only visitor VRF is a consequence of
the identity you can actually obtain, not a vendor default.

To see it break, set `anonymous_identity` to the real username in
`sta/wpa-visitor.conf` and re-run. `verify-identity.sh` fails, as it should —
that is a reportable defect, not a lab detail.

### 5. The authorization, and acting on it

```sh
docker exec clab-evpn-vxlan-campus-nac \
  grep -A4 'Sent Access-Accept' /tmp/radius.log | grep Tunnel
```

```
Tunnel-Type             = VLAN
Tunnel-Medium-Type      = IEEE-802
Tunnel-Private-Group-ID = "10"
```

All three or nothing. Return two and the switch silently leaves the port
where it was, which looks like a working authentication and a broken network.

A real switch acts on this for you. Here you do it by hand, so the attribute
and the consequence stay visible as two separate events:

```sh
docker exec clab-evpn-vxlan-campus-edge-a1 /cfg/edge/authorize-port.sh eth2 10
docker exec clab-evpn-vxlan-campus-edge-a1 /cfg/edge/authorize-port.sh eth3 30
```

Note what `idp-remote` does **not** return: no VLAN. A home institution does
not get to choose where its user lands on someone else's campus. The visited
site decides, which is why the visitor goes to VLAN 30 by local policy.

### 6. Only then does an address exist

```sh
docker exec clab-evpn-vxlan-campus-sta-staff dhclient -v -1 eth1
```

Authentication finishes, *then* DHCP runs. Everything that wants to publish
"IP 10.10.10.100 is jsmith" has to wait for this. On a real campus that
window is where sessions run unidentified, and at 08:55 on a Monday it is
thousands of them at once. Time it.

### 7. The endpoint, as the fabric sees it

```sh
docker exec clab-evpn-vxlan-campus-leaf1a vtysh -c 'show evpn mac vni 1010'
docker exec clab-evpn-vxlan-campus-leaf1a vtysh -c 'show bgp l2vpn evpn route-type 2'
docker exec clab-evpn-vxlan-campus-leaf2a vtysh -c 'show evpn mac vni 1010'
```

Same endpoint, learned on leaf1a, visible on leaf2a as a type-2 route it never
saw directly. The fabric knows **where**. It has no idea **who** — that only
exists in the NAC, and the NAC has no idea of the **address**, which only
exists in DDI. `reconcile/` joins all three to the firewall's mapping table
and reports where they disagree.

## Gotchas already paid for

Each of these cost real time here. They are all live on a real campus.

**The DEFAULT proxy realm swallows the inner tunnel.** A Service Provider
wants `realm DEFAULT { auth_pool = ... }` so unknown realms reach the roaming
operator. With it, PEAP's *inner* request — the one inside TLS, carrying the
real username — is matched against the realm list a second time and proxied
too. The federation has never heard of your local users, so they fail with
`MS-CHAP-Error = "E=691 ... Authentication rejected"`, which reads exactly
like a wrong password. Local users fail, roaming users work, and nothing in
the message says "proxy". It is also a privacy bug: the inner identity is
what PEAP exists to protect. Diagnose it by looking for an Access-Reject
*arriving from the proxy* rather than generated locally:

```sh
docker exec clab-evpn-vxlan-campus-nac grep 'Received Access-Reject' /tmp/radius.log
```

`nac/proxy.conf` lists realms explicitly to avoid it. Reproduce it below.

**A silent endpoint is an unreachable endpoint.** ARP suppression means the
leaf answers from EVPN type-2 routes instead of flooding. A type-2 exists only
while the leaf holds an ARP entry, and the kernel ages that out when the host
goes quiet. Real servers are chatty; idle containers are not. The symptom is
vicious: everything works, then minutes later the same command times out with
nothing changed. `keepalive.sh` papers over it; stop it and watch a healthy
fabric stop forwarding to a host that is still up.

**802.1X ports must not be bridge members.** hostapd's wired driver reads
EAPOL off a raw socket. A bridge consumes those frames first, so hostapd sees
the supplicant's first packet and none of its replies, and retransmits
forever. `CTRL-EVENT-EAP-RETRANSMIT2` in a loop means this. An unauthenticated
port in a bridge is also forwarding, which makes the 802.1X decorative.

**Containerlab execs run before the links attach.** A daemon that binds
sockets at startup comes up bound to nothing and still looks healthy. Hence
`wait-for-link.sh`.

**Three attributes or none.** Covered above, and asserted.

**Debian's FreeRADIUS ships the snakeoil certificate.** `mods-enabled/eap`
points `certificate_file` at `/etc/ssl/certs/ssl-cert-snakeoil.pem`
(`CN=localhost`) and `ca_file` at the system trust store. EAP then works
perfectly -- right up until a client actually verifies the server, which is
what eduroam requires. A campus that never configures supplicant profiles
properly will never notice, and shipping snakeoil quietly trains every device
to accept any certificate. `start-radius.sh` repoints it.

**FreeRADIUS cannot read its own certificates.** The bootstrap writes them as
root; `freeradius` drops to the `freerad` user before reading them, so EAP
dies with `Failed reading certificate file ... Permission denied` and the
module fails to instantiate. Debian's Makefile only fixes up `server.key`.

**Re-running the certificate bootstrap gives you a mismatched set.** The
Makefile rebuilds some artifacts and not others, so you end up with a server
certificate signed by a CA key that no longer matches `ca.pem` -- while both
still carry the same subject DN. The client reports `unable to get local
issuer certificate`, which sends you looking at the client. Proving it is one
command on the server: `openssl verify -CAfile ca.pem server.pem`. Always
`make destroycerts` first. Keep `dh`, though: it is also destroyed, and
regenerating a 2048-bit safe prime makes the node look hung.

**PEAP throws away the inner reply unless you ask for it.** The authorization
comes back from the inner-tunnel virtual server, `Tunnel-Private-Group-ID`
included -- and Debian ships `use_tunneled_reply = no`, so it is discarded.
Authentication succeeds, the client associates, everything looks healthy, and
the station silently sits in the AP's default VLAN instead of the one the NAC
chose. Nothing logs an error, because nothing went wrong.

**Radio interface names are not stable.** A `mac80211_hwsim` phy keeps
whatever name it had on the host, and phy numbering shifts every time the
module reloads -- `phy0` becomes `phy2`, `wlan0` becomes `wlan1`. Hardcode a
name and the only symptom is a supplicant that never associates while
everything else looks fine. `wireless-attach.sh` enumerates
`/sys/class/ieee80211` rather than guessing, and renames each radio to `wlan0`
inside its own namespace. Relatedly, `iw phy X set netns PID` resolves
`/proc/PID/ns/net`, so whatever runs it needs the host PID namespace.

**An AP needs an address before hostapd starts.** hostapd sources RADIUS from
it, and the per-VLAN interfaces hostapd builds do not exist until a station
has authenticated -- so you cannot use one of those. No RADIUS reachability,
no station, no interface. `ap-a1` is addressed untagged on the trunk, which is
how APs are normally managed.

## What is deliberately not built, and why

Several things here are missing on purpose. Each one is missing because
building it would hide a decision worth making consciously, or because the
honest version needs a component this lab does not have. They are listed as
work rather than hidden as polish.

**Visitor-zone DHCP.** `ddi` sits in `TENANT-A`; the `EDUROAM` VRF has no
route to it. That is not an oversight, it is the zone separation working.
Wiring it silently would mean quietly leaking a route and losing the point.
Shared infrastructure crossing a zone boundary is a real design decision and
it belongs to whoever runs the campus, not to the lab.

**The DHCP relay, in the right place.** `ddi` currently has a leg directly on
the staff segment. A real leaf holds the anycast gateway and relays. FRR has
no DHCP relay at all, and a relay on the access switch is meaningless because
its upstream and downstream are the same L2 segment -- which is itself worth
seeing once. Faking it would skip the interesting problem underneath.

**RadSec.** The proxy legs are plain UDP RADIUS. That is on purpose for now:
it is exactly what makes the federation legible in Wireshark, and seeing the
exchange in clear is the most convincing argument for encrypting it. Turning
it on first would remove the lesson.

**Data-plane enforcement.** `fw-a` is FRR. The separation between zones here
is routing, not policy. Anything claiming to be a firewall rule would be
pretending, so there are none.

**Campus B's visitor zone.** `leaf1b`, `leaf2b`, `bdr-b` and `bdr-b2` have no `EDUROAM`
VRF. A visitor roaming between campuses is the interesting case and it is
left as the exercise that forces you to touch every layer at once.

**EVPN multihoming (type 4 / ESI).** Inherited from the parent lab: every
host is single-attached. Dual-homed APs and closet switches are normal on a
campus, and adding them is also what exposes why route-reflector best-path
hiding degrades aliasing without add-path.

**Reconciliation.** ~~Left unbuilt because it is the deliverable, not the
scenery.~~ Now built, in `reconcile/` — see `reconcile/README.md`. Its own
unbuilt list is at the bottom of that file, and the biggest item is that
`firewall/zones.nft` does not yet consume the published role sets, so a stale
mapping is a reported finding rather than live access.

## Things to build

Roughly in order of how much they teach.

1. **Give the visitor zone DHCP.** It has none, on purpose. `ddi` lives in
   `TENANT-A` and the EDUROAM VRF has no route to it — which is the entire
   point of the separate VRF. Decide how shared infrastructure crosses a zone
   boundary: a second DDI leg in the VRF, a shared-services VRF both zones
   import from, leaking just the DHCP and DNS /32s, or relaying out through
   the firewall so the hand-off is inspected. Every campus answers this and
   few write down why.

2. **Put the DHCP relay where it belongs.** Today `ddi` has a leg directly on
   the staff segment, which is a lab shortcut. A real leaf holds the anycast
   gateway and relays to one BlueCat address. FRR has no relay, and a relay on
   the access switch is meaningless because its upstream and downstream are
   the same L2 segment. Solve that and you immediately meet the real problem:
   **every leaf shares the same SVI address**, so whose `giaddr` goes in the
   relayed packet? Relay from the anycast address and the reply comes back to
   whichever leaf the underlay picked. Loopback-sourced relay plus the right
   subnet-selection option is the fix. This breaks real deployments.

> **Restarting RADIUS.** Never `docker restart` a lab node: it gets a new
> network namespace and loses its links, and only a full `./labctl down` and
> `up` brings it back. `freeradius -X` ignores SIGHUP and reads
> `/etc/freeradius/3.0/mods-config/files/authorize`, not `users`. Edit that,
> then `docker exec clab-evpn-vxlan-campus-nac pkill freeradius`, then
> `docker exec -d clab-evpn-vxlan-campus-nac sh -c 'freeradius -X > /tmp/radius.log 2>&1'`.
> Edits made in the container are lost on redeploy; the source is `nac/authorize`.

3. **Reproduce the DEFAULT-realm trap.** In `nac/proxy.conf` replace the
   explicit `realm remote.edu` pool with `realm DEFAULT { auth_pool =
   eduroam-pool, nostrip }`, restart the RADIUS process (see the box below, not `docker restart`), and watch `sta-staff` fail with
   E=691 while `sta-visitor` keeps working. Then find it from the logs alone.

4. **RadSec between the proxies.** Today `nac` → `fed` → `idp-remote` is
   plain UDP RADIUS, which is why step 2 above is so legible in Wireshark.
   Move the proxy legs to RADIUS over TLS on TCP/2083 with a per-institution
   CA. Capture before and after.

5. **Reconciliation.** DONE — `reconcile/`. `./labctl reconcile` joins the
   leaves' type-2 table, the NAC's sessions, DDI's leases and the firewall's
   mapping table on IP, MAC and VRF, read-only. The join only closes because
   DDI holds the MAC-to-IP edge: RADIUS accounting carries no
   `Framed-IP-Address`, which is the concrete reason a DDI system is
   load-bearing next to an EVPN build rather than adjacent to one.

6. **Publication to the firewall.** PARTLY DONE — `reconcile/publish.py`
   populates nftables role sets on `fw-a`, which are the dynamic address
   groups, and deliberately never removes an entry unless asked, so the stale
   case appears on its own. Still to do: fire it from FreeRADIUS `rlm_exec`
   on Accounting-Start instead of on demand, and have `zones.nft` actually
   filter on those sets.

7. **Second campus.** `leaf1b`, `leaf2b`, `bdr-b` and `bdr-b2` have no EDUROAM VRF. A
   visitor roaming between campuses is the interesting case, and it is
   deliberately not built.

8. **MAC randomisation.** Change a station's MAC between runs and watch what
   it does to the endpoint record. This is why MAB is finished for personal
   devices.

## Accounts

| Realm | Account | Password | Inner | Lands in |
|---|---|---|---|---|
| `campus.edu` | `jsmith@campus.edu` | `labpass` | PEAP/MSCHAPv2 | VLAN 10, by Tunnel-Private-Group-ID |
| `remote.edu` | `visitor@remote.edu` | `roampass` | PEAP/MSCHAPv2 | VLAN 30, by local policy |

Lab credentials, in a lab, on an isolated topology. Nothing here is a secret.
