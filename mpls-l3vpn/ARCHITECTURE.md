# Architecture: why the lab looks like this

Each decision, then the general rule behind it.

## IS-IS and LDP in the core, BGP only on the PEs
The P routers run IS-IS and LDP and nothing else. They forward on labels and hold
no customer route. A customer prefix exists only in the PE VRFs and in VPNv4.
`verify.sh` checks that a P router has no customer route.
*Rule: put state at the edge. The core should know how to reach the edge, and nothing else.*

## Two labels on every customer packet
The PE pushes a VPN label that names the VRF at the far PE, and a transport label
that gets the packet there. The P routers see only the transport label.
`verify.sh` reads the label stack on the PE VRF route.
*Rule: use one label for "where" and one for "who". The core only needs "where".*

## Overlapping customer prefixes
Both customers use `10.10.1.0/24` and `10.10.2.0/24`. A route distinguisher makes each
one unique in VPNv4. A route target decides which VRF imports it. The lab checks
that each customer's `10.10.2.0/24` comes from its own site 2.
*Rule: a design that works only with unique addresses has not been tested as a VPN.*

## Two P routers and two PEs
Each PE has two equal-cost paths to the other. This shows ECMP over labelled paths
and gives the failure tests a path to remove. A third P router would not show
anything new.
*Rule: build the smallest topology that can show the thing you study.*

## IS-IS level 2 only
Every core router is level 2. There is no area hierarchy, because the lab is too
small for one to help.
*Rule: add a hierarchy when the flooding domain is a problem, not before.*

## The start script builds the kernel VRFs
`scripts/mpls-node.sh` enables MPLS, builds the Linux VRFs, then starts FRR. FRR
reads `frr.conf` after the interfaces and VRFs already exist, so the config does
not race the setup.
*Rule: build the objects a config refers to before the config loads.*

## The four core configs are generated
`pe1`, `pe2`, `p1` and `p2` differ only in addresses, the IS-IS ID, the BGP peer
and the VRF list. One data file (`ansible/core.yml`) and one template produce all
four. The customer configs are not generated, because they are stand-ins and
change rarely.
*Rule: generate the files that repeat a pattern. Leave the one-off files alone.*

## The first run proved the template
Before any change, the template rendered the four existing hand-written configs and
`--check --diff` showed no difference.
*Rule: prove a generator by making it reproduce the current state before it changes anything.*

## Drift check with `--check --diff`
The playbook writes files with the `template` module. In check mode it shows the
difference and changes nothing. A hand edit in `configs/` shows as drift on the
next run.
*Rule: make the safe mode the same command with one flag.*

## The playbook calls `verify.sh`, and does not repeat it
The lab already has an end-to-end check. The playbook runs it, so there is one
definition of "healthy".
*Rule: one check, one place.*

## The playbook writes files and does not touch a router
Kernel VRFs are created at container start, so a new customer needs a redeploy
anyway. A live-apply step would add a second path to the same result, and a way to
leave a router different from its file.
*Rule: do not add a second way to change state until the first one is too slow.*

## `verify.sh` captures output before it searches it
`cmd | grep -q` makes `grep` exit on the first match, and `cmd` can then die of
SIGPIPE. With `pipefail` that read as a failure in 8 of 30 runs of the MPLS
forwarding check. In a negative test (`! cmd | grep -q`) the same race can pass
when a route leaked. The script now stores the output first, then searches it.
*Rule: a check that passes or fails at random is worse than no check. Capture first, then test.*
