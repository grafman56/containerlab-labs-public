# Reconciliation: four registers, no single truth

Nothing on a campus knows what an endpoint is. Four systems each know a
projection of one, and nothing compares them.

| Register | Keyed on | Knows | Read here from |
|---|---|---|---|
| Fabric (EVPN type-2) | MAC | which VNI, which leaf, which port, mobility sequence | `vtysh show evpn mac/arp-cache` on every leaf |
| NAC (RADIUS accounting) | MAC | user, realm, session, last seen | FreeRADIUS detail files on `nac` |
| DDI (DHCP lease) | MAC | **IP**, expiry, hostname | Kea lease file on `ddi` |
| Firewall (ip-user-mapping) | **IP** | user, role tag | nftables named sets on `fw-a` |

Read that table again and the problem states itself: the fabric and the NAC
are keyed on MAC, the firewall is keyed on IP, and **only DDI holds the edge
between them.** RADIUS accounting from hostapd carries no
`Framed-IP-Address` — look at a detail record and see for yourself. So
without a lease database there is no path from "jsmith authenticated" to
"10.10.10.100 may do things", and every user-based firewall rule on the
campus rests on that one join.

That is what BlueCat is for, and it is why DDI is not a side quest next to an
EVPN build. It is load-bearing.

## Why EVPN makes this mandatory rather than nice

A stretched L2 VNI with an anycast gateway means `10.10.10.1` is live on every
leaf and the same subnet exists at both campuses. The subnet used to *be* the
third floor of the nursing building, so subnet-based policy was approximately
right. Stretching it destroys that signal deliberately, in exchange for
mobility. Identity is the only honest replacement — so "we are deploying EVPN"
and "the firewall has to know about endpoints" are one decision.

And once policy is keyed on identity, the chain is only as good as its joins.
Reconciliation is how you find out whether it holds.

## Join on IP + MAC + VRF

VRF is not optional. PAN-OS User-ID is **per-vsys**, so two tenants with
overlapping address space silently acquire each other's rights if a mapping
is keyed on IP alone. This lab has two VRFs on purpose (`TENANT-A`,
`EDUROAM`), and `reconcile.py` reports `VRF_MISMATCH` when the firewall and
the fabric disagree about which one an endpoint is in.

## "I used to know exactly where everything was"

In a hierarchical design the **prefix was the location**. `10.20.30.0/24`
meant the nursing building, third floor, because you decided that at design
time and cabled it that way. You could read a place off an address in your
head, with no tool.

EVPN takes that away deliberately. Location did not disappear, though — it
moved **out of the prefix and into the next-hop**. A type-2 route says "this
MAC is behind VTEP `10.255.0.1` in VNI 1010", and that VTEP is a leaf, and a
leaf is in a closet, in a building.

| | Hierarchical | EVPN |
|---|---|---|
| Location is encoded in | the prefix | the VTEP next-hop, and the port |
| Decided by | you, at design time | the network, at run time |
| Granularity | a /24 ≈ a building or a floor | a leaf + a port ≈ a closet + a jack |
| Looked up by | reading the address | querying the fabric |
| Changes when | you re-cable | someone walks |

**A type-2 route is strictly more precise than a /24 ever was.** It names the
leaf, the port, the VLAN, and how many times it has moved. Nothing was lost
except the zero-effort lookup — and rebuilding that lookup is the whole job.

Two things follow, and they are the practical answer:

**1. The VTEP loopback plan is the new subnet plan.** Give it the care you
used to give the subnet plan. Number it with geography in it —
`10.255.<site>.<building><closet>` — and every type-2 route in the fabric
carries a readable location for free. This lab deliberately gets it wrong:
leaves are `10.255.0.1`–`.4`, flat and geography-free, which is the common
mistake. `locations.txt` is the patch over that, and the reason you want the
numbering instead of the file.

**2. The lookup has to be a query, not a memory.** That is `whereis.py`:

```sh
./labctl whereis jsmith          # or a MAC, an IP, a building, a hostname
```

```text
10.10.10.100  02:00:00:00:01:00
  where     Howard-Tilton IDF-1, patch 4 -> ap-a1, ceiling of room 112
  evidence  local type-2 on leaf1a eth4.10
  segment   VNI 1010, VRF TENANT-A
  who       jsmith@campus.edu (realm campus.edu, authorized staff)
  address   leased from DDI, expires in 371s
  policy    firewall tags it role=staff as jsmith@campus.edu
```

That is your spreadsheet, regenerated from the live network on every run. Note
`evidence`: it says *how* the location is known, because "local type-2 on
leaf1a eth4.10" and "remote type-2 via VTEP 10.255.0.3" are very different
amounts of confidence. A remote entry only narrows it to a building; the leaf
holding the MAC is the one that knows the port.

Run `./labctl whereis 10.20.20` and the thing that broke the old mental model
is visible in one screen: the same `/24` has endpoints in Howard-Tilton **and**
in Uptown, because VNI 1020 is stretched. The address no longer tells you the
campus. The next-hop does.

It is also honest about what it cannot see: an endpoint absent from the fabric
may simply have gone quiet. With ARP suppression the leaf answers from type-2
routes, and a type-2 exists only while the leaf holds an ARP entry — so
"missing" and "idle" look identical. That is gotcha 2 in
`identity/README.md`, and it is why absence is never evidence here.

## Run it

```sh
./labctl reconcile              # read-only, the report
./labctl reconcile --json       # same, for a pipeline
./labctl publish                # the ClearPass -> PAN-OS leg
./labctl publish --expire       # ...and the cleanup it normally lacks
cd reconcile && ./test_reconcile.py && ./test_properties.py
```

`reconcile.py` never writes to a lab node. `publish.py` is the only writer.

## What it reports, and what each one means on a real campus

Worst first, which is the ordering that matters: a stale publication grants
rights to whoever now holds the address, which is worse than an endpoint that
merely cannot get through.

| Code | What happened | Why it bites |
|---|---|---|
| `STALE_PUBLICATION` | firewall still tags an address, no live session | **the dangerous one.** The next device to take that address inherits someone else's rights. Caused by a missed Accounting-Stop — a closed lid, a device out of range, an AP reboot. Completely normal. |
| `WRONG_TAG` | firewall role ≠ the role the NAC authorized | policy applied to the wrong person |
| `WRONG_USER` | firewall maps the address to a different user than the NAC session on it | right role, wrong person: user-based rules and logs name someone else. Usually a hand edit on the firewall |
| `MISSING_USER` | firewall tags the address with the right role but holds no user for it | a login timeout ran out, or a restore brought back tags only. Role rules still work; rules that name the user do not. `publish` repairs it |
| `WRONG_SEGMENT` | NAC authorized one role, fabric placed it in another VNI | the `use_tunneled_reply` signature: auth succeeded, the client associated, the `Tunnel-*` attributes were dropped, the station sits in the authenticator's default segment. **Nothing logs an error, because nothing went wrong.** |
| `VRF_MISMATCH` | published in one VRF, fabric holds the MAC in another | the overlapping-address trap above |
| `LEASE_REASSIGNED` | the lease moved to a different MAC, the mapping did not | the stale case, caught earlier |
| `UNAUTHENTICATED` | forwarding in the fabric, no NAC session at all | MAB bypass, a port someone shortcut, or a rogue |
| `DUPLICATE_MAC` | FRR gave up on the MAC | a loop, or the same address twice |
| `NO_ADDRESS` | live session, no lease | **unpublishable.** The DDI dependency, visible. |
| `UNPUBLISHED` | session + lease, no firewall mapping | mystery denies, or fall-through to a broader rule |
| `PUBLISHED_WITHOUT_LEASE` | mapping with no lease behind it | rests on nothing re-checkable |
| `LEASE_EXPIRED` | lease gone, mapping live | the client kept using the address, as clients do |
| `OFF_IPAM` | fabric forwards an address IPAM never issued | the static-address-nobody-recorded problem; the commonest reason IPAM and the network disagree |
| `NO_USERNAME_TO_PUBLISH` | live session, anonymous outer identity | correct PEAP at a Service Provider, and a hard limit — see below |
| `MOBILITY` | mobility sequence climbing | a roam on wireless, a loop on a wired port |

It also prints **publication latency** — NAC session start to firewall
mapping. Nobody measures this, and it is the number that explains the ticket
where the first connection after login fails and the retry works.

## Three findings this produced on the running lab

**1. Infrastructure has to be classified before the report means anything.**
First run: six `CRITICAL UNAUTHENTICATED` lines, all of them the lab's own
RADIUS, DDI and authenticator nodes, and one real finding underneath. A report
that is 85% noise gets read once. `infra.txt` is the exemption list — and it
is the IPAM half of DDI doing its actual job, because a real one reads those
reservations from BlueCat's API rather than from a text file. An address in
neither a lease nor a reservation is, by definition, something nobody
recorded. That is the finding.

**2. A visited campus has no username for an eduroam visitor, ever.** The
outer identity is `anonymous@remote.edu`; only `idp-remote` terminates the TLS
tunnel and sees the real name. So user-based firewall rules are unavailable
for visitors — not through an omission, but because PEAP is working. The only
policy you can write for them is segment-based, which is precisely why the
`EDUROAM` VRF exists instead of a rule naming people. If an interviewer asks
how you would apply User-ID to eduroam guests, this is the answer.

**3. The lab's DDI node had no database.** `persist: false` on Kea's memfile
meant the one register everything else needs to be joined through was
unreadable — a protocol demonstration with nothing queryable behind it, which
is exactly the half of BlueCat that matters. One config line.

## Make the stale case appear on demand

`reconcile.py --now <epoch>` evaluates freshness against a time you pick.
Push it past the accounting interval and every session goes stale without
touching the lab:

```sh
./labctl reconcile --now $(( $(date +%s) + 200 ))
# CRITICAL STALE_PUBLICATION  10.10.10.100  tagged role=staff
#          user=jsmith@campus.edu, no live NAC session (last seen 226s ago)
```

Then the honest version: `./labctl publish` (never removes anything, like the
real thing), stop a station, wait out the interim interval, and reconcile.

## Tying BlueCat, the VTEP and the firewall together

Of the four registers, BlueCat is the only one keyed on the ADDRESS that also
holds metadata a human wrote. The fabric reports facts keyed on MAC. The NAC
reports a decision keyed on MAC. Palo enforces, keyed on IP. BlueCat holds
**intent** keyed on IP and network — "this is the nursing clinical VLAN,
zone=clinical, bldg=nursing". That is why it is the hinge and not just an
address dispenser: the *lease* reaches into the MAC-keyed world, the *network
object* reaches into the IP-keyed one.

So publish three fields instead of one:

```
10.10.10.100 -> role:staff            NAC        who
                site:site-a           fabric     where, via the type-2 next-hop
                bldg:howard-tilton               resolved through IPAM
                closet:idf-1
                vrf:tenant-a          IPAM       what the segment is for
                vni:1010
```

A rule can then say *"staff in Howard-Tilton"* with **no prefix in it at
all**. That is the subnet-shaped policy you used to write, expressed as a tag,
with the location sourced from the control plane instead of from the address.

`./labctl publish --enforce` makes that matchable and demonstrates it:

```text
$ ./labctl publish --enforce
published 10.10.10.100    role:staff site:site-a bldg:howard-tilton closet:idf-1 vrf:tenant-a vni:1010
          Howard-Tilton IDF-1, patch 4 -> ap-a1, ceiling of room 112

$ docker exec clab-evpn-vxlan-campus-sta-staff ping -c3 203.0.113.1
$ docker exec clab-evpn-vxlan-campus-fw-a nft list chain inet userid tags
ip saddr @tag_role-staff        counter packets 3 bytes 252
ip saddr @tag_bldg-howard-tilton counter packets 3 bytes 252
ip saddr @tag_closet-idf-1      counter packets 3 bytes 252
```

Three pings from a station that authenticated over the air, counted by a rule
whose only selector is *the building it is in* — a building the firewall
learned from the fabric's type-2 next-hop, not from the address.

The rules live in their own nftables table, because several tables can hook
`forward` independently. That adds policy without disturbing the zone ruleset
`verify-identity.sh` asserts on. They are **counters, not drops**: swapping
`counter` for `counter drop` is the one-line change that gives a stale mapping
teeth, and that should be a decision rather than a default.

### Division of labour, honestly

**BlueCat will never learn a VNI or a VTEP.** Address Manager gives IPAM, DNS
and DHCP behind a REST API; DNS Edge gives per-client DNS query visibility.
Neither knows anything about identity or the fabric. So the custom piece is
unavoidable: BlueCat supplies the address-to-intent half and the lease join,
and something has to carry VTEP-to-location and NAC-to-identity across to
Palo. That something is this directory.

| Lab node | Real product |
|---|---|
| `nac` | **Aruba ClearPass** |
| `fed` | eduroam national roaming operator |
| `idp-remote` | another institution's RADIUS |
| `ddi` | **BlueCat** (Kea + BIND = the protocol half) |
| `ap-a1` | **Aruba AP** (hostapd over mac80211_hwsim) |
| `edge-a1` | access switch, wired 802.1X |
| `fw-a` / `fw-b` | **Palo Alto** (FRR + nftables) |
| `leaf*` / `bdr-*` | NX-OS leaves and borders (FRR EVPN-VXLAN) |

Name the boundary rather than overclaiming: FreeRADIUS is ClearPass's protocol
engine without posture checking, profiling or Endpoint Context Servers;
nftables is zones and default-deny without App-ID, User-ID or Panorama.

### One lab wrinkle found while proving this

`sta-staff`'s default route points at the containerlab management network, not
at the campus gateway, because `dhclient -1 wlan0` installs the on-link route
and `eth0` already owns the default. The first counter test read zero for that
reason and not because the tags were wrong. A per-destination route is enough
to drive traffic through the fabric:

```sh
docker exec clab-evpn-vxlan-campus-sta-staff \
  ip route replace 203.0.113.1/32 via 10.10.10.1 dev wlan0
```

Worth knowing generally: a counter reading zero means *nothing arrived*, which
is a different claim from *the rule does not match*. Confirm traffic took the
path before concluding anything about policy.

## Optional: send the same publication to a PAN-OS API

`publish.py` can also send each login and tag to a PAN-OS XML API: the
`panos-emu-public` lab (a separate project), or a real firewall. It is off by default. Without the flag, nothing changes and the nftables firewall is the only target.

```sh
# in the panos-emu-public project
python3 panos_emulator.py                      # listens on :8080

# here
./labctl publish --panos http://127.0.0.1:8080
PANOS_KEY=... ./labctl publish --panos http://fw:443   # when the API needs a key
```

What it sends, per live NAC session that has a DHCP lease:

- a `login` mapping of IP to user, except for anonymous roaming users, who have no real name to map;
- a `register` of the role, site, building, closet, VRF and VNI tags on the IP.

`--expire` sends `logout` and `unregister` for mappings with no live session. `--flush` clears the PAN-OS User-ID tables too. `--dry-run` prints the messages instead of sending them. If the API is down, the nftables publication still happens and the failure is printed.

The login mapping has a timeout (45 minutes on PAN-OS unless you set one) and tags do not expire. Run `publish` more often than the timeout, or pass `--panos-timeout MINUTES`. If the mapping expires while the session is live, `reconcile` reports `MISSING_USER`, and the next `publish` restores it.

A session that ends cleanly sends an Accounting-Stop, so `reconcile` reports it `STALE_PUBLICATION` within seconds. A crash or lost radio only shows up after the 90 second freshness window. Either way the firewall keeps the mapping until `publish --expire` removes it. Nothing here reacts to the Stop by itself.

Read the result back with `show user ip-user-mapping` and `show object registered-ip`, or let `reconcile.py` read it:

```sh
./labctl reconcile --panos http://127.0.0.1:8080
```

`publish --panos` replaces, it does not only add. On each run it removes the tags it manages (`role`, `site`, `bldg`, `closet`, `vrf`, `vni`, `loc`) that are no longer wanted, so a renumbered closet or a changed role does not leave the old tag behind. Tags in other namespaces, such as a hand-added `quarantine`, are never removed. With `--expire` it also removes any address the API tags that has no live, addressed session, even if the nftables firewall never knew about it. If any update fails, `publish` says so and exits 1; the nftables publication still stands.

With `--panos`, the firewall register comes from the API instead of nftables. PAN-OS holds no MAC, VRF name or publication time, so the reader rebuilds them: the role and VRF come from the `role:` and `vrf:` tags, the user from the IP-to-user table, and the MAC from the DDI lease on that address. Two things follow. `LEASE_REASSIGNED` cannot fire, because the MAC is always the current lease holder's. Publication latency is not reported. Addresses with no `role:` tag are ignored. An anonymous visitor is tagged but has no user mapping, and is not reported as stale while the session is live.

## Monitoring

`reconcile.py --prometheus` prints the counts in Prometheus text format. Run it on a timer and let a Telegraf `prometheus` input, or a node_exporter textfile collector, pick it up:

```toml
[[inputs.prometheus]]
  urls = ["http://127.0.0.1:19100/campus.prom"]   # a file server over the timer's output
```

| Metric | Meaning |
| --- | --- |
| `campus_reconcile_findings{severity,code}` | Open findings. Every code is printed, so a cleared one reads 0 and an alert can see it clear |
| `campus_register_entries{register}` | Entries in the fabric, NAC, DDI and firewall registers |
| `campus_publication_latency_max_seconds` | Slowest NAC-to-firewall publication, when the register has timestamps |
| `campus_reconcile_up` | 0 if a register could not be read, such as the PAN-OS API being down. Alert on this, or a dead firewall looks like a clean campus |
| `campus_reconcile_timestamp_seconds` | When the run happened. Alert if it stops moving |

Useful alerts: `STALE_PUBLICATION > 0` (a session ended without an Accounting-Stop and the mapping is still live), `WRONG_TAG` or `WRONG_USER > 0` (drift), and `campus_reconcile_up == 0`. A reconcile run exits 3 if the API cannot be read, and 0 otherwise, because deltas are the normal state of a campus.

### Known gaps in the PAN-OS leg

- A visitor holds a static address in this lab and gets no DHCP lease, so it has no IP to publish. The anonymous-visitor path (tags, no user) is covered by the self-check and a fake-register run, not by the live lab.
- The emulator matches a rule on `source-user` and `source-tag`, but a real PAN-OS matches on address objects and dynamic address groups. Re-check that on a real firewall, see the checklist in the `panos-emu-public` `TRAINING.md`.
- `LEASE_REASSIGNED` cannot fire against the PAN-OS register, and publication latency is not reported (see above).

## What the firewall register is, and is not

A PAN-OS **dynamic address group is a set of addresses with a tag.** It
carries no username. So publication is a *lossy* projection of the NAC's
decision, and reconciliation has to reconstruct the rest from the other side
— which is the whole reason this cannot be done by reading one system.

`publish.py` models that with one nftables named set per role
(`role_staff`, `role_visitor`) and uses the per-element comment as the
separate `ip-user-mapping` table, so "who did we claim this address is" stays
answerable. Real equivalents: `type=user-id` with a `uid-message` for the
mapping, `register` entries for the tags, and `type=op` /
`show user ip-user-mapping all` to read it back.

## Not built

**Policy does not consume the role sets yet.** `firewall/zones.nft` filters
on zone interfaces, so a stale mapping is currently a reporting finding
rather than live access. Referencing `role_*` from the `zones` table — the
sets have to move into it, since nftables sets are per-table — is what gives
the stale case teeth. It also changes the policy `verify-identity.sh`
asserts on, so it is a deliberate next step rather than a quiet rewiring.

**Reading the real APIs.** The collectors shell out to `vtysh`, `nft` and
`cat`. The shapes are right (per-leaf queries because no leaf holds the whole
fabric; address-keyed firewall; MAC-keyed NAC), but a real job would use
NX-API, the PAN-OS XML API, the ClearPass REST API and BlueCat Address
Manager. Each of those is a credential and a client, not a new idea.

**Accounting-Start as the trigger.** `publish.py` is run on demand. FreeRADIUS
`rlm_exec` on Accounting-Start is how this becomes event-driven — and
measuring the latency *before* doing that is the point of having the number.

## Try it: a role change

Move `jsmith` from the staff VLAN to the visitor VLAN and watch the registers disagree.

1. In `nac`, change `Tunnel-Private-Group-ID` for `jsmith@campus.edu` from `"10"` to `"30"` in
   `/etc/freeradius/3.0/mods-config/files/authorize`, then restart the RADIUS process
   (see `identity/README.md`).
2. Force a full re-authentication. `reassociate` is not enough, the supplicant reuses its cached key:
   `wpa_cli -i wlan0 disconnect; wpa_cli -i wlan0 pmksa_flush; wpa_cli -i wlan0 reconnect`
   in `sta-staff`.
3. `./labctl reconcile` reports `CRITICAL WRONG_SEGMENT`: NAC authorized staff, the fabric holds
   the MAC in VNI 1030. The station keeps its old IP until it renews its lease, as a real client does.
4. Revert the file, restart RADIUS, and re-authenticate the same way. The finding stays for about
   three minutes, until the AP's bridge ages out the MAC it learned on the old VLAN.

The wired port is not dynamic here: `edge/authorize-port.sh` moves it by hand, so only the Wi-Fi path follows RADIUS.
