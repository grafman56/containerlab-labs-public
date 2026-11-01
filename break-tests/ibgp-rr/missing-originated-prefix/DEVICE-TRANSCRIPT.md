# Annotated iBGP-RR Device Transcript

This file contains actual device output collected during one controlled
fault-and-restore cycle on a Containerlab host. It suppresses only the repeated local FRR
startup-warning pair. Each section states what the command checks, what the
output proves, and why the next command follows.

## Fault injection

```bash
docker exec clab-ibgp-rr-e1 vtysh \
  -c "configure terminal" \
  -c "router bgp 65001" \
  -c "address-family ipv4 unicast" \
  -c "no network 203.0.113.0/24 route-map SET-COMM" \
  -c "end" \
  -c "clear ip bgp 172.16.1.1 soft out"
```

```text
Fault injected. Run ./verify-fault.sh before issuing ticket.md.
```

**What this changes:** It removes only E1's BGP origin statement for the
documentation prefix, then sends the withdrawal to P1 without resetting BGP.

**Why this fault is useful:** The sessions remain established, but the prefix
disappears. This separates session health from route advertisement health.

## P3 BGP session summary

```bash
docker exec clab-ibgp-rr-p3 vtysh -c 'show ip bgp summary'
```

```text

IPv4 Unicast Summary:
BGP router identifier 10.0.0.3, local AS number 65000 VRF default vrf-id 0
BGP table version 23
RIB entries 0, using 0 bytes of memory
Peers 2, using 46 KiB of memory

Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
10.0.0.11       4      65000      7498      7469       22    0    0 5d04h21m            0        0 N/A
10.0.0.12       4      65000      7500      7469       22    0    0 5d04h21m            0        0 N/A

Total number of neighbors 2
```

**What this checks:** It checks whether P3's route-reflector sessions are up.

**What it found:** Both peers show a numeric `State/PfxRcd` value of `0`.
FRR uses a number in this column to show an established session. The zero is
the received-prefix count, not a failed session.

**Why the next command follows:** The sessions are healthy, so inspect the
specific affected prefix instead of restarting BGP.

## P3 BGP route lookup

```bash
docker exec clab-ibgp-rr-p3 vtysh -c 'show ip bgp 203.0.113.0/24'
```

```text
% Network not in table
```

**What this checks:** It asks whether BGP knows the advertised service prefix.

**What it found:** P3 has no BGP path for the prefix.

**Why the next command follows:** BGP can know a path that the IP RIB rejects.
The RIB lookup distinguishes a missing advertisement from an installation
problem such as an unresolved next hop.

## P3 IP route lookup

```bash
docker exec clab-ibgp-rr-p3 vtysh -c 'show ip route 203.0.113.0/24'
```

```text
% Network not in table
```

**What this checks:** It asks whether P3 can forward traffic toward the prefix.

**What it found:** P3 has no installed route.

**Why the next command follows:** The failure exists before P3's forwarding
decision. Walk toward the route originator instead of changing P3.

## E1 local route

```bash
docker exec clab-ibgp-rr-e1 vtysh -c 'show ip route 203.0.113.0/24'
```

```text
Routing entry for 203.0.113.0/24
  Known via "static", distance 1, metric 0, best
  Last update 5d04h22m ago
  Flags: Recursion Selected RR Distance 
  Status: Installed 
  * unreachable (blackhole), weight 1
```

**What this checks:** It verifies that E1 has the exact local prefix required
by the BGP `network` statement.

**What it found:** The blackhole route exists and is installed. It is expected
in this lab. It supports BGP origination but does not represent a real service
endpoint.

**Why the next command follows:** The local RIB prerequisite is satisfied. The
next question is whether E1 placed that route into its BGP table.

## E1 BGP route lookup

```bash
docker exec clab-ibgp-rr-e1 vtysh -c 'show ip bgp 203.0.113.0/24'
```

```text
% Network not in table
```

**What this checks:** It verifies whether E1 originated the local prefix into
BGP.

**What it found:** E1 does not have the prefix in BGP even though the static
route exists.

**Why the next command follows:** Nothing can be advertised to P1 until the
route exists in E1's BGP table. Check the outbound view, then the origin
configuration.

## E1 advertised routes

```bash
docker exec clab-ibgp-rr-e1 vtysh -c 'show ip bgp neighbor 172.16.1.1 advertised-routes'
```

```text
```

**What this checks:** It shows the routes E1 sends to P1.

**What it found:** The output is empty. This agrees with the missing E1 BGP
route and rules out a downstream route-reflector problem.

**Why the next command follows:** The fault boundary is now E1's BGP origin
configuration. Inspect the address family that controls this prefix.

## E1 running configuration

```bash
docker exec clab-ibgp-rr-e1 vtysh -c 'show running-config'
```

```text
Building configuration...

Current configuration:
!
frr version 10.7.0_git
frr defaults traditional
hostname e1
!
route-map SET-COMM permit 10
 set community 65001:100
exit
!
ip route 203.0.113.0/24 blackhole
!
interface eth1
 description to-p1
 ip address 172.16.1.2/30
exit
!
interface lo
 ip address 10.0.0.21/32
exit
!
router bgp 65001
 bgp router-id 10.0.0.21
 no bgp ebgp-requires-policy
 no bgp default ipv4-unicast
 neighbor 172.16.1.1 remote-as 65000
 !
 address-family ipv4 unicast
  neighbor 172.16.1.1 activate
 exit-address-family
exit
!
end
```

**What this checks:** It compares E1's effective BGP configuration with the
local RIB and BGP-table evidence.

**What it found:** The prefix route and `SET-COMM` route map exist, but the
IPv4 address family has no `network 203.0.113.0/24 route-map SET-COMM`
statement.

**Why the next command follows:** Add the missing origin statement and refresh
the outbound advertisement. A soft refresh avoids an unnecessary session reset.

## Fault restoration

```bash
docker exec clab-ibgp-rr-e1 vtysh \
  -c "configure terminal" \
  -c "router bgp 65001" \
  -c "address-family ipv4 unicast" \
  -c "network 203.0.113.0/24 route-map SET-COMM" \
  -c "end" \
  -c "clear ip bgp 172.16.1.1 soft out"
```

```text
Fault removed. Run ./verify-restored.sh.
```

**What this changes:** The `network` statement tells E1 to originate the exact
local blackhole route into BGP. The route map adds community `65001:100`.

**Why `clear ... soft out` is used:** It sends the new advertisement to P1
without dropping the eBGP session. This limits disruption and makes the repair
easy to verify.

## E1 restored BGP route

```bash
docker exec clab-ibgp-rr-e1 vtysh -c 'show ip bgp 203.0.113.0/24'
```

```text
BGP routing table entry for 203.0.113.0/24, version 13
Paths: (1 available, best #1, table default)
  Advertised to peers:
  172.16.1.1
  Local
    0.0.0.0 from 0.0.0.0 (10.0.0.21)
      Origin IGP, metric 0, weight 32768, valid, sourced, local, best (First path received)
      Community: 65001:100
      Last update: Tue Jul 28 19:43:14 2026
    Characteristics:
      BGPID: 10.0.0.21
```

**What this proves:** E1 now originates the prefix, marks it `sourced` and
`local`, attaches community `65001:100`, and selects P1 as an advertisement
target.

## E1 restored advertised routes

```bash
docker exec clab-ibgp-rr-e1 vtysh -c 'show ip bgp neighbor 172.16.1.1 advertised-routes'
```

```text
BGP table version is 13, local router ID is 10.0.0.21, vrf id 0
Default local pref 100, local AS 65001
Status codes:  s suppressed, d damped, h history, u unsorted, * valid, > best, = multipath,
               i internal, r RIB-failure, S Stale, R Removed
Nexthop codes: @NNN nexthop's vrf id, < announce-nh-self
Origin codes:  i - IGP, e - EGP, ? - incomplete
RPKI validation codes: V valid, I invalid, N Not found

     Network          Next Hop            Metric LocPrf Weight Path
 *>  203.0.113.0/24   0.0.0.0                  0             0 i

Total number of prefixes 1, total number of paths 1
```

**What this proves:** E1 actually advertises the prefix to P1. A local BGP
entry alone would not prove that export policy permits the route.

## P1 restored BGP route

```bash
docker exec clab-ibgp-rr-p1 vtysh -c 'show ip bgp 203.0.113.0/24'
```

```text
BGP routing table entry for 203.0.113.0/24, version 13
Paths: (1 available, best #1, table default)
  Advertised to peers:
  10.0.0.11 10.0.0.12 172.16.1.2
  65001
    172.16.1.2 from 172.16.1.2 (10.0.0.21)
      Origin IGP, metric 0, valid, external, best (First path received)
      Community: 65001:100
      Last update: Tue Jul 28 19:43:13 2026
```

**What this proves:** P1 receives the prefix from E1 as an external path. P1
also lists both route reflectors as advertisement targets, so the route can
enter the iBGP core.

## P3 restored BGP route

```bash
docker exec clab-ibgp-rr-p3 vtysh -c 'show ip bgp 203.0.113.0/24'
```

```text
BGP routing table entry for 203.0.113.0/24, version 24
Paths: (2 available, best #1, table default)
  Not advertised to any peer
  65001
    10.0.0.1 (metric 20) from 10.0.0.11 (10.0.0.1)
      Origin IGP, metric 0, localpref 100, valid, internal, multipath, best (Neighbor IP)
      Community: 65001:100
      Originator: 10.0.0.1, Cluster list: 10.0.0.11 
      Last update: Tue Jul 28 19:43:13 2026
  65001
    10.0.0.1 (metric 20) from 10.0.0.12 (10.0.0.1)
      Origin IGP, metric 0, localpref 100, valid, internal, multipath
      Community: 65001:100
      Originator: 10.0.0.1, Cluster list: 10.0.0.12 
      Last update: Tue Jul 28 19:43:13 2026
```

**What this proves:** P3 learns two valid reflected paths, one from each route
reflector. The intended community survives the full E1 to P1 to route-reflector
to P3 path.
