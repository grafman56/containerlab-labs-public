# iBGP-RR Break Tests

Store iBGP route-reflector fault scenarios in one subdirectory per scenario.
Each scenario directory must include:

- `RUNBOOK.md` for the controller, not the learner;
- `ticket.md` with only the simulated NOC or customer report;
- a scoped staging artifact for the faulted lab source;
- `verify-fault.sh` that proves the fault before the ticket is issued; and
- `verify-restored.sh` that proves the normal state after recovery.

The controller runbook must identify the baseline revision and the exact fixed
Semaphore template. It must also state the expected customer impact, safe
rollback, and live evidence needed before and after the exercise.

Do not add a scenario to this directory until its staging and restoration paths
are verified. The normal `ibgp-rr/` directory remains the known-good baseline.

## Available scenarios

- [`missing-originated-prefix/`](missing-originated-prefix/) checks the path
  from a local route on E1 through eBGP, route reflection, and the P3 BGP RIB.
- [`inbound-policy-block/`](inbound-policy-block/) keeps BGP sessions healthy
  while an inbound P2 route policy rejects the edge prefix from both route
  reflectors.
