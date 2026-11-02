# Two-Site Campus Lab

> **Note: the VLAN-to-VNI mapping is not an FRR setting.** FRR has no VLAN
> object. It reads the VNIs that exist in the Linux kernel and advertises them.
> The scripts in `scripts/` build that mapping into each node as one bridge plus
> one VXLAN device per VNI, with untagged host ports, so no VLAN number reaches
> the dataplane. Run `./labctl show vlan-vni [NODE|all]` to see what a node
> holds. `DATAPLANE.md` explains why.

A virtual campus network with two sites, run with Containerlab. Each site has an
EVPN-VXLAN data-center fabric, a building on a traditional OSPF network, a
firewall and an internet link. It also has Wi-Fi with 802.1X login, DHCP and DNS.

You can use it to:

- learn how EVPN-VXLAN, OSPF areas and border failover work, by breaking them
- watch a user log in, get an address, and get a firewall rule applied
- test automation against the same network that a script would see in production

The routers run FRRouting. Each site firewall is an FRR node with nftables, and
a PAN-OS XML API emulator sits beside it and mirrors it (see
[the demo](#the-demo)). No packet from this lab goes to a real firewall.

## What you need

- A Linux machine or VM. Debian 13 is tested. **Stock WSL2 does not work**:
  its kernel has no `mac80211_hwsim`, which the virtual Wi-Fi needs. Check your
  machine with `sudo modprobe mac80211_hwsim`. No error means it works.
- 8 GB RAM and 4 CPUs. The lab runs 35 containers and uses about 3.5 GB.
- 10 GB of free disk space for images.
- Docker. If you do not have it: `curl -fsSL https://get.docker.com | sh`, then
  add yourself to the `docker` group and log in again.
- Containerlab 0.77 or newer. If you do not have it:
  `curl -sL https://containerlab.dev/setup | sudo -E bash -s "all"`
- `python3` and `git`.
- `sudo` without a password prompt. Containerlab needs root to make network
  namespaces. Test with `sudo -n true`. No output means it works.

## Quick start

Use two terminals. In the first, get the lab and start it:

```sh
git clone https://github.com/grafman56/containerlab-labs-public
cd containerlab-labs-public/evpn-vxlan-campus
./labctl up
```

`up` takes about 25 seconds. On the first run it also builds two small images,
so allow a few minutes. Then check that everything works:

```sh
./labctl verify
```

This takes about 2.5 minutes. It waits for OSPF and EVPN to settle, so you can
run it right after `up`. It prints `PASS`, or the first thing that failed.

In the second terminal, start the firewall emulator. It needs only `python3`:

```sh
git clone https://github.com/grafman56/panos-emu-public
cd panos-emu-public
PANOS_LAB_FW=clab-evpn-vxlan-campus-fw-a PANOS_LAB_HOSTNAME=fw-a python3 panos_emulator.py
```

`PANOS_LAB_FW` makes the emulator copy the real lab firewall: its interfaces,
zones, routes and BGP sessions. Leave it running. Back in the first terminal, run the demo:

```sh
./demo.sh
```

The demo takes about 2.5 minutes. It prints `PASS` at the end. You can run it
again at any time. When you are done:

```sh
./labctl down
```

If the emulator is not on `127.0.0.1:8080`, give the demo its address:
`./demo.sh http://HOST:PORT`.

## Words used in this lab

| Word | Meaning |
|---|---|
| EVPN | A way to share MAC and IP addresses between switches, using BGP. |
| VXLAN | A tunnel that carries Layer 2 traffic across a Layer 3 network. |
| VTEP | A switch that starts or ends a VXLAN tunnel. |
| VNI | The number that names one VXLAN network. 1010 is one VLAN stretched across both sites. |
| Leaf, spine | Leaves connect to hosts. Spines connect the leaves to each other. |
| Border leaf | A leaf that connects the fabric to the firewall and the internet. |
| OSPF area | A group of routers that share one OSPF database. Area 0 is the core. |
| NAC | The server that checks a login (802.1X) and says which VLAN the user gets. |
| DDI | The DHCP and DNS server. |

## Topology

```text
                 SITE A                              SITE B
  inet-a (AS65100)                                    inet-b (AS65200)
        | eBGP                                    eBGP |
       fw-a                                            fw-b
     /      \                                        /      \
  bdr-a    bdr-a2                                  bdr-b    bdr-b2
     |  \   /  |                                    |  \   /  |
dist-a1-spine1a  spine2a ==== site link ==== spine1b  spine2b-dist-b1
   |     |  \  /  |                            |  \  /  |     |
acc-a1 leaf1a    leaf2a                     leaf1b    leaf2b  acc-b1
   |     |         |                           |         |     |
user-a1 host1    host2                       host3     host4  user-b1

AREA 1          <------------ AREA 0 ------------>        AREA 2
totally stubby       fabric underlay + core               NSSA
```

![Two-campus EVPN-VXLAN topology](assets/evpn-vxlan-campus-topology.svg)

- Each site has two spines, two leaves and two border leaves. The two sites
  join over one link between `spine2a` and `spine1b`.
- The fabric uses OSPF area 0 underneath. Eight switches (four leaves, four
  border leaves) run EVPN, and each one peers with all the others. The spines
  only forward traffic. They do not run BGP.
- Each site also has a building (`dist-a1`, `dist-b1`) on its own OSPF area.
  Building A1 is a totally stubby area. Building B1 is an NSSA, because it has
  its own internet provider (`inet-res`).
- Each border leaf has a link to the site firewall. The firewall has the link to
  the internet provider.
- Host 1 and host 3 are on the same VLAN (VNI 1010) in different sites. Host 1
  and host 4 are on different VLANs in different sites, so they route.

Most spine switches in real networks act as BGP route reflectors. This lab
does not use any, so you can see every session. The `ibgp-rr` lab in this
repository shows the reflector design. [ARCHITECTURE.md](ARCHITECTURE.md)
explains this and the other design choices.

## The demo

`./demo.sh` follows one user, `jsmith`, through four systems that each know part
of the story:

1. the fabric (which MAC is on which switch)
2. the NAC (who logged in)
3. the DDI (which address each device got)
4. the firewall (which address belongs to which user and role)

At each step, `./labctl reconcile` compares the four and reports where they
disagree. The demo makes a change, shows the finding, fixes it, and shows the
finding clear.

| Step | What happens | What `reconcile` shows |
|---|---|---|
| 1-2 | Devices get addresses. The NAC knows `jsmith`. The firewall does not. | `UNPUBLISHED` |
| 3-4 | `publish` sends the user and role tags to the firewall. A rule that allows ssh from `role:staff` now matches. | clean |
| 5-6 | The NAC moves `jsmith` to the visitor VLAN, then back. | `WRONG_SEGMENT`, then clean |
| 7-8 | The wired laptop logs off. `publish --expire` removes its entry, and the rule stops matching. | `STALE_PUBLICATION`, then clean |
| 9-10 | Someone adds a wrong role tag on the firewall. `publish` replaces it. | `WRONG_TAG`, then clean |
| 11 | The demo restores everything. | no `CRITICAL` |

Two `NO_ADDRESS` warnings stay on screen the whole time. The visitor has no DHCP
lease in this lab. This is known and is not a failure.

The demo shortens the MAC ageing time on the bridges to 30 seconds, so step 6
takes about one minute instead of five.

The demo uses the real zones of `fw-a`: `campus`, `guest` and `internet`. Try
these against the emulator while the lab runs:

```sh
curl -s -G http://127.0.0.1:8080/api --data-urlencode type=op \
  --data-urlencode 'cmd=<show><routing><protocol><bgp><peer/></bgp></protocol></routing></show>'
```

Then shut a session on `fw-a` and run it again. The peer changes to `Idle`:

```sh
docker exec clab-evpn-vxlan-campus-fw-a vtysh -c "conf t" -c "router bgp 65301" -c "neighbor 198.51.100.5 shutdown"
docker exec clab-evpn-vxlan-campus-fw-a vtysh -c "conf t" -c "router bgp 65301" -c "no neighbor 198.51.100.5 shutdown"
```

Why four systems? The fabric and the NAC know devices by MAC address. The
firewall knows them by IP address. Only the DHCP lease links the two.
[reconcile/README.md](reconcile/README.md) has the details, and
[identity/README.md](identity/README.md) explains the login, the visitor
federation and the DHCP part.

## Commands

```sh
./labctl check             # check the files, without starting anything
./labctl up                # start the lab
./labctl verify            # all checks, about 2.5 minutes
./labctl verify-identity   # only the login, VLAN and firewall checks, about 80 seconds
./labctl show vlan-vni     # kernel and zebra view of the VXLAN dataplane
./labctl reconcile         # compare the four systems, read only
./labctl status            # show the containers
./labctl down              # stop and remove the lab
```

`verify` checks OSPF neighbors, seven established EVPN peers on each of the
eight switches, host-to-host reachability inside a VLAN and across VLANs, the
internet, and the order of default routes (primary border, secondary border,
then the other site).

To publish to a firewall by hand, or to use a real PAN-OS firewall in place of
the emulator, add `--panos URL` to `./labctl publish` and `./labctl reconcile`.
Without `--panos`, the lab uses an nftables firewall stand-in. See
`reconcile/README.md`.

## Things to try

- Shut the firewall link on `bdr-a` and watch traffic move to `bdr-a2`:
  `docker exec clab-evpn-vxlan-campus-bdr-a vtysh -c "conf t" -c "router bgp 65000 vrf TENANT-A" -c "neighbor 198.51.100.1 shutdown"`
- Shut the site link. Each site keeps working alone, and the EVPN mesh splits.
- On `dist-a1`, change `area 1 stub no-summary` to `area 1 stub`. Then look at
  the routing table on `acc-a1`. One route becomes many.
- Shut `spine1a:eth1`. `leaf1a` keeps its EVPN sessions through `spine2a`.
- [POLICY-EXERCISES.md](POLICY-EXERCISES.md) has exercises for prefix lists,
  route maps, local preference and communities.

Leave a few seconds between link changes. In one test, 24 flaps in two minutes
caused packet loss between the sites. Traffic recovered on its own, but once it
took more than 15 seconds after the last flap.

## Address plan

| Role | Addresses |
|---|---|
| Site A fabric links | `10.0.0.0/24`, one `/31` per link |
| Site B fabric links | `10.0.1.0/24`, one `/31` per link |
| Site link | `10.0.2.0/31` |
| Building A1 | `10.0.3.0/24` links, loopbacks `10.255.2.x`, users `10.101.10.0/24` |
| Building B1 | `10.0.4.0/24` links, loopbacks `10.255.3.x`, users `10.102.10.0/24` |
| B1 research link | `198.51.100.8/31`, `inet-res` loopback `203.0.113.3` |
| Spine loopbacks | `10.255.255.1` to `10.255.255.4` |
| Leaf VTEPs | `10.255.0.1` to `10.255.0.4` |
| Border VTEPs | `10.255.1.1` (A primary), `.3` (A secondary), `.2` (B primary), `.4` (B secondary) |
| Border to firewall, campus | `198.51.100.0/31` and `.16/31` (A), `.2/31` and `.20/31` (B) |
| Border to firewall, visitor | `198.51.100.10/31` and `.18/31` (A) |
| ISP loopbacks | `203.0.113.1` (A), `203.0.113.2` (B) |
| VNI 1010 | `10.10.10.0/24`, gateway `10.10.10.1` |
| VNI 1020 | `10.20.20.0/24`, gateway `10.20.20.1` |
| L3 VNI for `TENANT-A` | `4100` |

## Known limits and gotchas

- **The VLAN-to-VNI mapping is not in the FRR config.** FRR has no command for
  it. The scripts in `scripts/` build it with Linux bridges and VXLAN devices.
  To change a mapping, edit the scripts, not `configs/*.conf`.
- Each `vtysh` command prints `Can't open configuration file
  /etc/frr/vtysh.conf`. It is harmless.
- No EVPN multihoming. Each host connects to one leaf.
- The two sites are one EVPN domain and one OSPF domain. A real campus might
  use EVPN multi-site to give each site its own failure domain.
- Each site has one firewall and one ISP. The lab tests border-switch failover,
  not firewall or provider failover. Containerlab cannot model the MC-LAG that
  real switch pairs use.
- The buildings reach each other and the underlay. They do not reach the
  tenant VRFs or the internet. Joining them needs a firewall or fusion router,
  and this lab leaves that out on purpose.
- The link MTU is 1500, so VXLAN leaves about 1450 for payload. Raise the MTU
  on the fabric links before you test large packets.
- Each ISP node advertises one loopback. There is no internet routing table.
- The firewall nodes are FRR with nftables. They are not PAN-OS. The emulator
  shows their interfaces, zones, routes, BGP sessions and session count in
  PAN-OS format, so `show` commands match the lab. It cannot change them: a
  BGP change sent to the API does not reach FRR, and the rulebase is separate
  from the nftables rules.

## More reading

- [ARCHITECTURE.md](ARCHITECTURE.md): why the lab is built this way
- [identity/README.md](identity/README.md): 802.1X, the visitor login, DHCP and DNS
- [reconcile/README.md](reconcile/README.md): the comparison tool
- [POLICY-EXERCISES.md](POLICY-EXERCISES.md): routing policy exercises
