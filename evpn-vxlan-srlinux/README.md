# Small EVPN-VXLAN fabric on SR Linux

Two spines, two leaves, three segments. It exists for one reason: on a real
network OS the VLAN to VNI binding is configuration you can read and change, not
a kernel object you have to reconstruct.

```
VLAN 10  VNI 1010  VRF tenant   staff
VLAN 20  VNI 1020  VRF tenant   services
VLAN 30  VNI 1030  VRF guest    visitor
        VNI 4100  VRF tenant   transit
        VNI 4200  VRF guest    transit
```

The fabric is management-plane only in spirit: OSPF area 0 underlay, iBGP with
both spines as route reflectors, EVPN address family everywhere. `topology.yml`
is the whole lab. There is no per-node config file to maintain.

## Before you start

- netlab with the containerlab provider, and the `srlinux` image pulled
- about 6 GB free. Each SR Linux node is roughly 1 to 1.5 GB, and this lab has
  four of them plus three Linux hosts
- do not run this beside the campus lab if the campus lab needs
  `mac80211_hwsim`; neither lab here uses radios, so this one is safe on a
  smaller host

Check free memory first. `netlab create` prints the node list and the addressing
plan without starting anything.

## Run it

```sh
cd evpn-vxlan-srlinux
netlab create            # build netlab.snapshot.yml and the clab topology
netlab up                # deploy and configure
netlab validate          # OSPF full, EVPN sessions established
netlab connect l1        # sr_cli on a leaf
netlab down --cleanup    # remove containers and the management network
```

## See the binding

On a leaf:

```sh
netlab connect l1
info network-instance staff
```

That prints the committed configuration for the segment, including the VLAN and
the `vni`. The same object comes back from state with `show network-instance
staff`. `info network-instance tenant` shows the VRF and its transit VNI.

The exact state path for the VXLAN interface differs between SR Linux releases.
`info` always works, because the binding is configuration and not telemetry.

From the host, without entering the node:

```sh
docker exec l1 sr_cli "info network-instance staff"
```

## Change a mapping

Edit `topology.yml`, change one `vni`, and run `netlab up` again. That is the
whole workflow, and it is the point of having this lab: the mapping is a data
file, not four shell scripts.

## What this lab does not do

- no 802.1X, no RADIUS, no DHCP, no firewall. The hosts are Linux containers
  with static addresses on access ports
- no border gateway, no internet edge, no multi-site
- it is not a replacement for `evpn-vxlan-campus`. That lab covers the identity
  edge, the firewall handoff and the reconciliation tooling

## Where the wireless and User-ID work goes

Three stages, smallest first:

1. This lab. Prove the fabric and the binding, and use it as the target for
   automation and telemetry. Done when `netlab validate` passes.
2. User-ID against this fabric. The PAN emulator and `publish.py` are host-side
   and do not care which NOS runs the fabric. What is missing is a reader: the
   `reconcile` fabric register calls `vtysh` on each leaf. An SR Linux reader
   (`docker exec <leaf> sr_cli "show network-instance ..."`, or gNMI) is the
   work, about one file.
3. The real wireless edge. `edge-a1`, the AP, the two stations and the NAC come
   from `evpn-vxlan-campus/identity`, attached to one leaf as an 802.1Q trunk.
   That needs `cap_add: NET_ADMIN, NET_RAW` on those containers and the hwsim
   radio attach step, so it is a containerlab job, not a netlab one. Do it as a
   separate change after stages 1 and 2 work.
