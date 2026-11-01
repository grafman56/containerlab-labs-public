# Annotated P2 Inbound-Policy Transcript

This file contains device output collected during a controlled fault-and-restore
cycle on a Containerlab host on 2026-07-28. The capture suppresses only the repeated local
FRR startup-warning pair. All route, policy, and counter output below is from
the live devices.

## 0. Inject the controlled fault

**What this changes:** The prefix list matches only the documentation prefix.
Route-map sequence 10 denies that match. Sequence 20 permits all other routes.
The route map applies inbound to both RR sessions, then a soft inbound refresh
reprocesses their received updates without resetting BGP.

```bash
docker exec clab-ibgp-rr-p2 vtysh \
  -c "configure terminal" \
  -c "ip prefix-list LAB-BLOCK-EDGE-IN seq 10 permit 203.0.113.0/24" \
  -c "route-map LAB-BLOCK-EDGE-IN deny 10" \
  -c "match ip address prefix-list LAB-BLOCK-EDGE-IN" \
  -c "route-map LAB-BLOCK-EDGE-IN permit 20" \
  -c "router bgp 65000" \
  -c "address-family ipv4 unicast" \
  -c "neighbor 10.0.0.11 route-map LAB-BLOCK-EDGE-IN in" \
  -c "neighbor 10.0.0.12 route-map LAB-BLOCK-EDGE-IN in" \
  -c "end" \
  -c "clear ip bgp 10.0.0.11 soft in" \
  -c "clear ip bgp 10.0.0.12 soft in"
```

```text
Fault injected. Run ./verify-fault.sh before issuing ticket.md.
PASS: P2 lacks the edge prefix while both RR sessions remain established
```

**Caveat:** This is controller-only material. Give a learner `ticket.md`, not
the fault command or this transcript.

## 1. Check P2 BGP session counters

**What this checks:** Whether P2 lost BGP transport or lost accepted prefixes.

**Why this comes first:** A numeric `State/PfxRcd` value means the BGP session
is established. A zero prefix count points to route propagation or policy, not
TCP, authentication, or neighbor activation.

```bash
docker exec clab-ibgp-rr-p2 vtysh -c "show ip bgp summary"
```

```text
IPv4 Unicast Summary:
BGP router identifier 10.0.0.2, local AS number 65000 VRF default vrf-id 0
BGP table version 26
RIB entries 0, using 0 bytes of memory
Peers 2, using 46 KiB of memory

Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
10.0.0.11       4      65000      7608      7569       26    0    0 5d05h56m            0        0 N/A
10.0.0.12       4      65000      7608      7569       26    0    0 5d05h56m            0        0 N/A

Total number of neighbors 2
```

**Finding:** Both RR sessions are established, but P2 accepts zero prefixes
from both. A link or BGP-session repair would not address this symptom.

**Fast triage:** Compare redundant peers. A zero on one RR and a normal count
on the other suggests one path is degraded. Zero from both points toward a
shared origin, shared policy, or local inbound policy.

## 2. Check the affected BGP and IP route

**What this checks:** Whether P2 lacks the prefix in BGP, or knows it but fails
to install it in the IP RIB.

```bash
docker exec clab-ibgp-rr-p2 vtysh -c "show ip bgp 203.0.113.0/24"
docker exec clab-ibgp-rr-p2 vtysh -c "show ip route 203.0.113.0/24"
```

```text
% Network not in table

% Network not in table
```

**Finding:** P2 has no accepted BGP path and no installed route. The next check
is the direct RR-to-P2 boundary, not recursive next-hop resolution.

## 3. Prove that RR1 still advertises the prefix

**What this checks:** Whether the route reaches the route reflector and exits
RR1 toward P2.

```bash
docker exec clab-ibgp-rr-rr1 \
  vtysh -c "show ip bgp neighbor 10.0.0.2 advertised-routes"
```

```text
BGP table version is 26, local router ID is 10.0.0.11, vrf id 0
Default local pref 100, local AS 65000

     Network          Next Hop            Metric LocPrf Weight Path
 *>i 203.0.113.0/24   10.0.0.1                 0    100      0 65001 i

Total number of prefixes 1, total number of paths 1
```

**Finding:** RR1 advertises the prefix. The missing route is therefore at P2
inbound processing, or on the P2-to-RR1 BGP boundary. P2 has the same result
from both RRs, so inspect P2 policy before changing either RR.

## 4. Inspect P2 inbound policy

**What this checks:** Whether a prefix list and route map match and deny the
service prefix after the peer advertises it.

```bash
docker exec clab-ibgp-rr-p2 \
  vtysh -c "show route-map LAB-BLOCK-EDGE-IN"
docker exec clab-ibgp-rr-p2 \
  vtysh -c "show ip prefix-list LAB-BLOCK-EDGE-IN"
```

```text
BGP:
route-map: LAB-BLOCK-EDGE-IN Invoked: 2 (0 milliseconds total) Optimization: enabled Processed Change: true
 deny, sequence 10 Invoked 2 (0 milliseconds total)
  Match clauses:
    ip address prefix-list LAB-BLOCK-EDGE-IN
  Action:
    Exit routemap
 permit, sequence 20 Invoked 0 (0 milliseconds total)
  Match clauses:
  Action:
    Exit routemap

BGP: ip prefix-list LAB-BLOCK-EDGE-IN: 1 entries
   seq 10 permit 203.0.113.0/24
```

**Finding:** The BGP policy ran twice, once for each RR. Sequence 10 matched
and denied the target prefix twice. Sequence 20 did not run because route maps
stop at the first matching sequence.

**Caveat:** The prefix-list `permit` means the list matches the prefix. The
route-map action determines whether the BGP policy permits or denies it. Do
not judge the result from the prefix-list action alone.

## 5. Restore the baseline and refresh inbound routes

**What this changes:** It deletes the two route-map sequences and the
prefix-list sequence, removes both inbound attachments, then refreshes inbound
routes. The soft refresh applies the corrected policy without resetting either
BGP session.

```bash
docker exec clab-ibgp-rr-p2 vtysh \
  -c "configure terminal" \
  -c "no route-map LAB-BLOCK-EDGE-IN deny 10" \
  -c "no route-map LAB-BLOCK-EDGE-IN permit 20" \
  -c "no ip prefix-list LAB-BLOCK-EDGE-IN seq 10" \
  -c "router bgp 65000" \
  -c "address-family ipv4 unicast" \
  -c "no neighbor 10.0.0.11 route-map LAB-BLOCK-EDGE-IN in" \
  -c "no neighbor 10.0.0.12 route-map LAB-BLOCK-EDGE-IN in" \
  -c "end" \
  -c "clear ip bgp 10.0.0.11 soft in" \
  -c "clear ip bgp 10.0.0.12 soft in"
```

**Caveat:** Do not remove only `permit 20` while the route map remains attached.
An empty or missing policy is hard to reason about and can differ across
platforms. Remove the attachment and the complete unused policy as one scoped
cleanup.

## 6. Verify redundant recovery and cleanup

**What this checks:** Whether P2 receives both reflected paths, retains the
expected community, and has no residual named policy.

```bash
docker exec clab-ibgp-rr-p2 vtysh -c "show ip bgp 203.0.113.0/24"
docker exec clab-ibgp-rr-p2 vtysh -c "show running-config" \
  | grep -E "LAB-BLOCK-EDGE-IN|route-map .* in" || true
```

```text
BGP routing table entry for 203.0.113.0/24, version 27
Paths: (2 available, best #1, table default)
  Not advertised to any peer
  65001
    10.0.0.1 (metric 20) from 10.0.0.11 (10.0.0.1)
      Origin IGP, metric 0, localpref 100, valid, internal, multipath, best (Neighbor IP)
      Community: 65001:100
      Originator: 10.0.0.1, Cluster list: 10.0.0.11
  65001
    10.0.0.1 (metric 20) from 10.0.0.12 (10.0.0.1)
      Origin IGP, metric 0, localpref 100, valid, internal, multipath
      Community: 65001:100
      Originator: 10.0.0.1, Cluster list: 10.0.0.12
```

The policy-check command produced no output. P2 has two reflected paths and no
remaining `LAB-BLOCK-EDGE-IN` object or inbound route-map attachment.
