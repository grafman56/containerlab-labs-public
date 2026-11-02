# The EVPN dataplane: where VLAN to VNI actually lives

This note answers one question: why can you not see the VLAN to VNI mapping in
this lab, and what does it take to see it?

Short answer: FRR does not hold that mapping, and this lab's dataplane has no
VLAN number in it. Both are fixable, and neither needs a vendor image.

## The finding

FRR is a control plane. It has no VLAN object, no bridge object and no VXLAN
device of its own. Zebra reads the kernel over netlink, finds the VXLAN devices
and the bridges they belong to, and advertises a VNI for each one. A VTEP switch
keeps the same mapping in its own configuration database, so on that switch the
mapping is a line you can read and change.

This lab builds the dataplane in `scripts/setup-leaf.sh`: one bridge, one VXLAN
device and one SVI per VNI, with host ports untagged. That model is the
"traditional VXLAN device" model from the FRR dataplane guide. It has no VLAN
number anywhere, so there is nothing for a VLAN column to show.

Two things follow, and both are visible on a running leaf. Each leaf builds
`vxbr10`, `vxbr20` and `vxlan4100` this way, so no port has anything but the
kernel's default VLAN:

```
leaf1a# bridge -d vlan show
port              vlan-id
br10              1 PVID Egress Untagged
vxbr10            1 PVID Egress Untagged
br20              1 PVID Egress Untagged
vxbr20            1 PVID Egress Untagged
```

The tenant VLAN that the reference design uses, VLAN 10 and VLAN 20, does not
exist in the dataplane at all. The only place 10 and 20 appear is bridge naming
and the 802.1Q trunk to `edge-a1`.

`show evpn vni` carries a VLAN column, and on this dataplane it is empty of
meaning. The counts and the remote VTEP number depend on your run, so read the
last three columns:

```
VNI        Type  VxLAN IF   # MACs  # ARPs  # Remote VTEPs  Tenant VRF  VLAN  BRIDGE
1010       L2    vxbr10     ...     ...     ...             TENANT-A    1     br10
1020       L2    vxbr20     ...     ...     ...             TENANT-A    1     br20
4100       L3    vxlan4100  ...     ...     ...             TENANT-A    1     br4100
```

Zebra maps each VNI to an SVI. For a bridge that is not VLAN aware, zebra treats
the bridge itself as the SVI, and it takes the VLAN number from the kernel's
default pvid. The column is real, and it is honest, and it is useless here:
three VNIs in two VRFs all claim VLAN 1.

The mapping itself is correct. Traffic works. `verify.sh` passes. What is
missing is that the mapping is a fact about an interface name, not a fact
anybody can query.

## The model that keeps the binding

The kernel can hold the binding explicitly. Make the VXLAN device a single
VXLAN device, put it in a VLAN-aware bridge, turn on `vlan_tunnel`, and bind
each VLAN to a VNI with `tunnel_info`:

```sh
ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
ip link add vxlan0 type vxlan dstport 4789 local 10.255.0.1 \
  nolearning external vnifilter
ip link set vxlan0 master br0
ip link set br0 up
ip link set vxlan0 up
bridge link set dev vxlan0 vlan_tunnel on neigh_vlan_suppress on learning off

# one MAC-VRF: VLAN 10 carries VNI 1010
bridge vlan add dev br0 vid 10 self
bridge vlan add dev vxlan0 vid 10
bridge vni add vni 1010 dev vxlan0
bridge vlan add dev vxlan0 vid 10 tunnel_info id 1010
bridge vlan add dev vxlan0 vid 10 neigh_suppress on

# the SVI is a VLAN subinterface of the bridge, not a bridge of its own
ip link add vlan10 link br0 type vlan id 10
ip link set vlan10 address 02:00:00:00:10:01
ip link set vlan10 master TENANT-A
ip addr add 10.10.10.1/24 dev vlan10
ip link set vlan10 up

# the access port: untagged on VLAN 10
ip link set eth3 master br0
bridge vlan add dev eth3 vid 10 pvid untagged

# the trunk to the access switch: tagged
ip link set eth4 master br0
bridge vlan add dev eth4 vid 10
bridge vlan add dev eth4 vid 30
```

The same commands on a throwaway network namespace produce this, and this is the
table the lab has never been able to show:

```
# bridge vlan tunnelshow
port              vlan-id    tunnel-id
vxlan0            10         1010
                  20         1020
                  1410       4100

# bridge vni show
dev               vni                group/remote
vxlan0            1010
                  1020
                  4100
```

`bridge vlan tunnelshow` is the command. It is the only command in iproute2
that prints this table, and it reads the `tunnel_info` you set above.

Zebra then fills the VLAN column from the same netlink data, because the VNI now
maps to a VLAN subinterface instead of to the bridge. `show evpn vni` reads:

```
VNI        Type  VxLAN IF  # MACs  # ARPs  # Remote VTEPs  Tenant VRF  VLAN  BRIDGE
1010       L2    vxlan0    ...     ...     ...             TENANT-A    10    br0
1020       L2    vxlan0    ...     ...     ...             TENANT-A    20    br0
4100       L3    vxlan0    ...     ...     ...             TENANT-A    1410  br0
```

Three VNIs, one VXLAN device, one bridge, three VLANs.

## What this costs

The dataplane moves from one bridge per VNI to one bridge for the node. Every
leaf script and border script changes, and every `interface br10` in
`configs/*.conf` becomes `interface vlan10`. The trade is:

- the mapping is a command you can run and a table you can read
- the config states the mapping in a reviewable form, one line per VLAN
- one VXLAN device per node instead of one per VNI, which is what every modern
  NOS builds and what scales past a handful of VNIs
- an access port behaves like an access port, with a pvid, instead of an
  untagged bridge member

The risks, in order:

1. ARP suppression. The anycast gateways in this lab depend on it. On a
   VLAN-aware bridge you need `neigh_vlan_suppress on` at the port and
   `neigh_suppress on` per VLAN, or the VNI stops answering from the type-2
   table. The `neigh_suppress` you set with `bridge link set` covers the
   non-VLAN-aware case only.
2. The L3VNI needs a VLAN of its own, and a VLAN ID is 12 bits. VNI 4100 cannot
   be its own VLAN. Bind it to 1410 and 1420 and keep the VNI where it belongs,
   in the route target and the type-5 route.
3. The order of the commands matters. `tunnel_info` fails with `Invalid
   argument` if the VLAN is not already on the VXLAN device, and adding a VLAN
   to a port fails with `Operation not supported` if the port is not already in
   the bridge.

None of this changes the control plane. `advertise-all-vni`, the type-2 and
type-5 routes, the VRFs, the route targets and the local preference policy stay
exactly as they are.

## Reading the mapping today

`./labctl show vlan-vni <node>` prints the kernel view and the zebra view of one
node. On the current dataplane it says so plainly instead of printing a VLAN
column that means nothing:

```
./labctl show vlan-vni leaf1a
./labctl show vlan-vni all      # every VTEP, to show the fabric agrees
```

## Where a real VTEP keeps it

The reason this lab feels wrong is that every other platform treats the binding
as configuration. That is the difference to show in a demo.

| Platform | Config statement | Show command |
|---|---|---|
| Arista EOS | `vxlan vlan 1010 vni 1010` under `interface Vxlan1` | `show vxlan vlan vni` |
| Juniper Junos | `vlans VNI-1010 { vlan-id 10; vxlan { vni 1010; } }` | `show vlans`, `show ethernet-switching vxlan-tunnel-end-point` |
| Cisco NX-OS | `vlan 10` then `vn-segment 1010` | `show nve vni`, `show vlan id 10` |
| Nokia SR Linux | VLAN and VNI on the MAC-VRF's VXLAN interface, in `info` | `info from state network-instance` |
| FRR plus the Linux kernel | `bridge vlan add dev vxlan0 vid 10 tunnel_info id 1010` | `bridge vlan tunnelshow` |

FRR is the only row where the statement lives in a shell script and not in the
routing configuration. That is not a defect in FRR. FRR has no forwarding plane
of its own, so the binding belongs to the kernel, and the kernel has a command
for it.

## If the demo needs a vendor CLI

Two options, and they answer different questions.

Run the campus lab on the SVD dataplane. This keeps 35 nodes, 8 VTEPs, the
identity edge, the firewall and the reconciliation, and adds a real VLAN to VNI
table, a real VLAN column and a dataplane that matches the reference design.
This is the change with the highest value per hour, and it needs no image, no
licence and no extra RAM.

Add one small lab with a vendor NOS beside it if the point of the demo is the
vendor CLI verbatim. Arista cEOS-lab gives `show vxlan vlan vni` and the exact
config statement, at about 1 to 2 GB of RAM per node. Nokia SR Linux is the same
idea with a free image. Cisco Nexus 9000v and Juniper vJunos need a vendor
account and 8 GB or more per node, which rules them out on a 3 GB lab host. None
of these images may be committed to this repository.

Do not replace the campus lab with a vendor NOS. Eight VTEPs plus a border pair
plus 27 other nodes needs more RAM than the lab host has, and the identity and
reconciliation work in this lab depends on the FRR nodes being Linux hosts.

## Commands for the demo

```sh
./labctl show vlan-vni leaf1a          # dataplane and control plane on one node
./labctl show vlan-vni all             # every VTEP, same table

docker exec clab-evpn-vxlan-campus-leaf1a vtysh -c "show evpn vni"
docker exec clab-evpn-vxlan-campus-leaf1a vtysh -c "show vrf vni"
docker exec clab-evpn-vxlan-campus-leaf1a vtysh -c "show evpn mac vni 1010"
docker exec clab-evpn-vxlan-campus-leaf1a bridge vlan tunnelshow
docker exec clab-evpn-vxlan-campus-leaf1a bridge fdb show dev vxlan0
```

The last two are the kernel view. They are the answer to "where is the
mapping", and they are the two commands a vendor CLI is imitating.
