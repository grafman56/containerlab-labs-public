# P2 Inbound Policy Block

This controller runbook documents a controlled iBGP-RR incident captured on
2026-07-28. It tests the difference between a healthy BGP session and a route
that local inbound policy rejects. Give the learner only [ticket.md](ticket.md).
The complete annotated device evidence is in
[DEVICE-TRANSCRIPT.md](DEVICE-TRANSCRIPT.md).

## Scope and safety

- Target topology: `ibgp-rr` only.
- Target container: `clab-ibgp-rr-p2`.
- Affected prefix: `203.0.113.0/24`.
- Baseline source: `origin/main` commit `5947b16` before this scenario branch.
- Operations path: your own Containerlab host. Run the
  scripts through `user@containerlab-host`; do not use the scripts against another
  host or a persistent production device.
- The fault changes live FRR state only. Do not run `write memory`.
- The scenario adds one prefix-list and one route map, then attaches that route
  map inbound to P2's two route-reflector peers.
- The route-reflector sessions remain established by design.
- `restore.sh` removes both policy sequences and both attachments. It then
  refreshes inbound routes without resetting BGP.
- Run the scripts on the Containerlab host. Set `LAB` only when the deployed
  topology prefix differs from `clab-ibgp-rr`.

The lab uses a documentation prefix. Prove BGP and RIB state. Do not claim an
end-host reachability test for an address that has no attached service.

## Controller sequence

```bash
cd break-tests/ibgp-rr/inbound-policy-block
./launch.sh
./verify-fault.sh
# Give the learner ticket.md.
./restore.sh
./verify-restored.sh
```

The launch and restore scripts both use BGP soft inbound refreshes. A soft
refresh requests or reprocesses updates without tearing down the BGP session.
Do not hard-reset a working session only to test policy.

## Diagnostic method

Start at P2 and follow the route in the receive direction:

1. Check `show ip bgp summary`. Numeric `State/PfxRcd` values prove each peer
   session is established. A zero route count identifies the fault class.
2. Check `show ip bgp 203.0.113.0/24` and `show ip route 203.0.113.0/24`.
   This separates a missing BGP path from an installed-route problem.
3. Check `show ip bgp neighbor 10.0.0.2 advertised-routes` on an RR. If the RR
   advertises the route but P2 lacks it, inspect P2 inbound policy.
4. Check `show route-map <name>` and `show ip prefix-list <name>` on P2. Read
   the route-map action and sequence order, not only the prefix-list action.
5. Check the peer attachment in `show running-config`. A policy can exist but
   have no BGP effect until a neighbor applies it in the correct direction.
6. After correction, prove P2 has two reflected paths and the expected
   `65001:100` community. Then prove the named policy and attachment are gone.

## What the learner should find

The injected prefix list permits `203.0.113.0/24` as a match object. Route-map
sequence 10 then denies matching routes. The unqualified permit sequence 20
would permit all other routes, but it never runs for the matched prefix.

The same policy attaches inbound to both RR sessions. P2 therefore rejects both
otherwise-valid reflected paths. The RRs continue to advertise the prefix and
the BGP sessions remain established.

## Faster isolation tips

- Treat a numeric BGP summary state as a session health result, not a route
  delivery result.
- Compare `PfxRcd` across redundant peers. A single zero can show a degraded
  path. Both zeros suggest a shared upstream source or a local policy applied
  to both peers.
- Compare one direct BGP boundary. The RR advertised-routes view and the P2
  accepted route view locate the route disappearance faster than a full-table
  review.
- Use policy hit counters when available. The captured route map shows BGP
  sequence 10 invoked twice, which matches the two RR peers.
- Preserve the distinction between `show ... routes` and `received-routes`.
  FRR's pre-policy `received-routes` view requires inbound soft
  reconfiguration. The accepted BGP table and route-map counters are enough
  for this scenario.

## Cleanup caveats

A residual `permit 20` route-map sequence with no match clauses permits all
routes. It is not the active fault after sequence 10 is removed, but leaving it
attached creates confusing policy state. A residual prefix list is also easy to
misread later.

Remove the two neighbor attachments and the complete unused policy as one
repair. Do not delete unrelated route maps or prefix lists with similar names.
Use the exact names in the scenario scripts. Verify the running configuration
has no `LAB-BLOCK-EDGE-IN` text before you close the incident.

## Evidence and completion

[DEVICE-TRANSCRIPT.md](DEVICE-TRANSCRIPT.md) records actual fault and recovery
output. The capture suppresses only the repeated local FRR startup-warning
pair. It preserves route counters, policy hit counts, BGP route output, and
recovery evidence.

The exercise is restored only when both checks pass:

```bash
./verify-restored.sh
../../ibgp-rr/verify.sh
```

The first proves P2 recovery and policy cleanup. The normal verifier proves the
wider OSPF and route-reflection baseline.
