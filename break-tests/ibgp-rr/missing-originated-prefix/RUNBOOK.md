# Missing Originated Prefix

This controller runbook documents the iBGP-RR incident exercised on 2026-07-28.
It presents the investigative commands, observed output, and reasoning before
the repair. Give the learner only [ticket.md](ticket.md). The full device
output, with two repeated FRR startup-warning lines suppressed, is in
[DEVICE-TRANSCRIPT.md](DEVICE-TRANSCRIPT.md).

## Scope and safety

- Target topology: `ibgp-rr` only.
- Target containers: `clab-ibgp-rr-e1`, `clab-ibgp-rr-p1`, and
  `clab-ibgp-rr-p3`.
- Baseline source: `ibgp-rr/configs/e1.conf` on the reviewed repository
  revision.
- The scenario changes live FRR state only. Do not use `write memory`.
- The test prefix is a documentation range. The lab has no endpoint behind it.
  Prove BGP and RIB state, not an ICMP response to an invented service host.
- Restore with `restore.sh` before another exercise or a topology restart.

Run the scripts on the Containerlab host. Set `LAB` only when the topology uses
a different Containerlab prefix.

```bash
cd break-tests/ibgp-rr/missing-originated-prefix
./launch.sh
./verify-fault.sh
# Give the learner ticket.md.
./restore.sh
./verify-restored.sh
```

## Troubleshooting method

Start at the affected client. Confirm whether the route is in the BGP table and
RIB. Then work one hop toward the originator. At each hop, distinguish these
questions:

1. Does the router have the route in its BGP table?
2. Does it advertise the route to the next peer?
3. Does the next router receive the route?
4. If the route is present, is its next hop resolvable and valid?

A green BGP summary proves that the TCP session and BGP session are up. It does
not prove that a prefix is originated, accepted by policy, or installed.

## Faster troubleshooting habits and reasons

Start with one affected prefix and one affected router. A route problem becomes
hard to isolate when the first command is a complete routing-table dump.

1. Check the BGP summary first, but use it only to classify the session state.
   If the session is down, investigate transport, TCP, authentication, or peer
   configuration. If it is established, move immediately to the prefix.
2. Run `show ip bgp <prefix>` and `show ip route <prefix>` on the affected
   router. The first command checks BGP knowledge. The second command checks
   route installation. This distinguishes a missing advertisement from an
   invalid next hop or policy decision.
3. Walk toward the originator one hop at a time. At each boundary, ask whether
   the previous router advertises the route and whether the next router has it.
   This avoids changing a route reflector when the originator never created the
   route.
4. On the originating router, check the local RIB before BGP. A BGP `network`
   statement needs an exact local route. The blackhole route is expected here.
   It satisfies that condition without creating a path to a real network.
5. Check the address family configuration only after the RIB and BGP-table
   results disagree. This keeps configuration inspection evidence-led instead
   of guessing from the topology.
6. Use a soft outbound refresh after an origin or policy correction. It sends
   an updated advertisement without tearing down the eBGP session. A hard reset
   hides whether the repair worked without disruption.
7. Verify the route at E1, P1, and P3. The three views prove origination,
   eBGP reception and advertisement, then route reflection. A green result at
   only one hop is incomplete evidence.

See [DEVICE-TRANSCRIPT.md](DEVICE-TRANSCRIPT.md) for the complete device
output from the controlled fault-and-restore cycle. It suppresses only these
repeated local FRR startup-warning lines:

```text
% Can't open configuration file /etc/frr/vtysh.conf due to 'No such file or directory'.
Configuration file[/etc/frr/frr.conf] processing failure: 11
```

## Live troubleshooting transcript

The commands below ran on a Containerlab host. The transcript suppresses two
repeated local FRR startup-warning lines. The remaining output is from the
live devices.

### 1. Check the affected P3 route

```bash
docker exec clab-ibgp-rr-p3 vtysh -c "show ip bgp 203.0.113.0/24"
docker exec clab-ibgp-rr-p3 vtysh -c "show ip route 203.0.113.0/24"
```

Observed output:

```text
% Network not in table

% Network not in table
```

The client has neither a BGP route nor an installed IP route. The next check is
not a peer reset. The BGP summaries still show the route-reflector sessions as
established.

### 2. Check E1's local prerequisite and BGP state

```bash
docker exec clab-ibgp-rr-e1 vtysh -c "show ip route 203.0.113.0/24"
docker exec clab-ibgp-rr-e1 vtysh -c "show ip bgp 203.0.113.0/24"
docker exec clab-ibgp-rr-e1 vtysh -c "show ip bgp neighbor 172.16.1.1 advertised-routes"
```

Observed output:

```text
Routing entry for 203.0.113.0/24
  Known via "static", distance 1, metric 0, best
  Last update 5d01h28m ago
  Flags: Recursion Selected RR Distance
  Status: Installed
  * unreachable (blackhole), weight 1

% Network not in table

BGP table version is 4, local router ID is 10.0.0.21, vrf id 0
Default local pref 100, local AS 65001

     Network          Next Hop            Metric LocPrf Weight Path

Total number of prefixes 0, total number of paths 0
```

The static blackhole route is expected. It makes the documentation prefix valid
for BGP origination while avoiding accidental forwarding to a real network. The
failure is between the local RIB and the BGP table.

### 3. Inspect the originating address family

```bash
docker exec clab-ibgp-rr-e1 vtysh -c "show running-config"
```

Relevant observed output:

```text
router bgp 65001
 bgp router-id 10.0.0.21
 no bgp ebgp-requires-policy
 no bgp default ipv4-unicast
 neighbor 172.16.1.1 remote-as 65000
 !
 address-family ipv4 unicast
  neighbor 172.16.1.1 activate
 exit-address-family
```

The address family has the peer activation but no statement that originates the
local documentation prefix into BGP.

### 4. Restore origination and refresh the outbound advertisement

```bash
docker exec clab-ibgp-rr-e1 vtysh \
  -c "configure terminal" \
  -c "router bgp 65001" \
  -c "address-family ipv4 unicast" \
  -c "network 203.0.113.0/24 route-map SET-COMM" \
  -c "end" \
  -c "clear ip bgp 172.16.1.1 soft out"
```

This makes a live-only correction. It does not write the running configuration
to the lab bind mount.

### 5. Verify the propagation path

```bash
docker exec clab-ibgp-rr-e1 vtysh -c "show ip bgp 203.0.113.0/24"
docker exec clab-ibgp-rr-e1 vtysh -c "show ip bgp neighbor 172.16.1.1 advertised-routes"
docker exec clab-ibgp-rr-p1 vtysh -c "show ip bgp 203.0.113.0/24"
docker exec clab-ibgp-rr-p3 vtysh -c "show ip bgp 203.0.113.0/24"
```

Observed output:

```text
E1:
BGP routing table entry for 203.0.113.0/24, version 5
Paths: (1 available, best #1, table default)
  Advertised to peers:
  172.16.1.1
  Local
    0.0.0.0 from 0.0.0.0 (10.0.0.21)
      Origin IGP, metric 0, weight 32768, valid, sourced, local, best
      Community: 65001:100

E1 advertised routes:
     Network          Next Hop            Metric LocPrf Weight Path
 *>  203.0.113.0/24   0.0.0.0                  0             0 i

P1:
BGP routing table entry for 203.0.113.0/24, version 5
Paths: (1 available, best #1, table default)
  Advertised to peers:
  10.0.0.11 10.0.0.12 172.16.1.2
  65001
    172.16.1.2 from 172.16.1.2 (10.0.0.21)
      Origin IGP, metric 0, valid, external, best
      Community: 65001:100

P3:
BGP routing table entry for 203.0.113.0/24, version 12
Paths: (2 available, best #1, table default)
  65001
    10.0.0.1 (metric 20) from 10.0.0.11 (10.0.0.1)
      Origin IGP, localpref 100, valid, internal, multipath, best
      Community: 65001:100
      Originator: 10.0.0.1, Cluster list: 10.0.0.11
  65001
    10.0.0.1 (metric 20) from 10.0.0.12 (10.0.0.1)
      Origin IGP, localpref 100, valid, internal, multipath
      Community: 65001:100
      Originator: 10.0.0.1, Cluster list: 10.0.0.12
```

P3 receives two reflected paths, one through each route reflector. The
community survives the eBGP edge and iBGP reflection path.

## Completion criteria

The exercise is restored only when `verify-restored.sh` exits zero. It proves
that P3 learns the route and its expected community. Do not use the BGP summary
alone as restoration evidence.
