# Architecture: why the lab looks like this

Each decision, then the general rule behind it. The base design reasons (BGP-free core,
two labels, overlapping prefixes, generated configs) are in
[`../mpls-l3vpn/ARCHITECTURE.md`](../mpls-l3vpn/ARCHITECTURE.md). This file covers what
changes with segment routing.

## Same topology, different transport
The lab keeps the `mpls-l3vpn` layout and swaps only the label distribution. A
difference in behavior then comes from SR and not from a new topology.
*Rule: change one thing at a time, so you know what caused a difference.*

## IS-IS carries the labels, and LDP is gone
Each router advertises a node SID for its loopback in IS-IS. Every router then knows
every label from the IGP, with no second protocol and no label-distribution sessions.
`verify.sh` checks that no LDP session exists, so a leftover LDP config cannot hide a
broken SR setup.
*Rule: when a feature replaces another, test that the old one is really off.*

## The label is the index plus the block base
The SRGB is 16000-23999 on every router, and each node has an index. `pe2` has index 2,
so every router reaches it with label 16002. `verify.sh` expects exactly that value on
both equal-cost paths and in the VRF label stack (`16002/<VPN label>`).
*Rule: use the same block on every router. Then a label means the same thing everywhere.*

## One template, with a switch
The generated configs come from the same template as `mpls-l3vpn`. A router with a
`sid` gets SR and no LDP. A router without one gets LDP. The change did not alter the
LDP lab's output: its drift check still showed no difference.
*Rule: when you extend a generator, prove the old output did not change.*

## The SR variant is a separate lab
It has its own name, container prefix and management subnet, so it can run next to
`mpls-l3vpn`. A flag in one lab would make each check depend on which mode is on.
*Rule: two clear labs are easier to check than one lab with modes.*

## No SR-TE, no TI-LFA, no SRv6
Paths follow the IS-IS shortest path. The lab shows SR transport for a VPN and ECMP over
SR labels. Traffic engineering policy is a separate topic and needs a larger topology to
show anything.
*Rule: name what the lab cannot show.*

## An unexplained first-boot failure is recorded, not hidden
On the first deploy, the IS-IS adjacencies came up but SR data never appeared in the
LSPs, until the SRGB line was entered by hand. Four later clean deploys converged in
about 31 seconds with no step. The README lists the symptom and the fix.
*Rule: write down a failure you cannot explain, with the evidence and the workaround.*
