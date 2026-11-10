# EVPN multihoming (ESI-LAG) on SR Linux

A small lab to test EVPN multihoming. One host connects to two leaves with an LACP
bond. The leaves share one Ethernet Segment, and they coordinate through EVPN. There
is no MLAG peer link.

It also shows the VLAN to VNI mapping on the device, with one command.

It has 2 SR Linux leaves, 2 FRR spines and 3 Linux hosts. It runs on one 8 GB host.

## Quick start

You need a Linux host with Docker, Containerlab and netlab. See [Requirements](#requirements).

```sh
export PATH=~/netlab-venv/bin:$PATH ANSIBLE_COLLECTIONS_PATH=~/netlab-venv
cd evpn-esi-srlinux
netlab up          # about 90 seconds
./post-up.sh       # required after every netlab up
./verify.sh        # ends with: ALL PASS
./demo.sh          # a guided tour, about 2 minutes
```

To shut down: `netlab down --cleanup`.

## Topology

```
            s1 (FRR)                 s2 (FRR)        spines: OSPF underlay, EVPN route reflectors
           /        \               /        \       (they never see a VLAN, a VNI or an ESI)
          /          +-------------+          \
         /          /               \          \
   l1 (SR Linux) --+                 +-- l2 (SR Linux)   leaves: VLAN to VNI, LAG, Ethernet Segment
     |        \                           /        |     (each leaf links to both spines)
     |         \__ eth1        eth2 __/            |
    h1              h3 (bond0, 802.3ad)           h2
 (single-homed)     lag1 / es1 on both leaves   (single-homed)
```

| Node | Image | Role |
|---|---|---|
| `s1`, `s2` | FRR | OSPF underlay and EVPN route reflectors, AS 65000 |
| `l1`, `l2` | Nokia SR Linux | Leaves. VXLAN, EVPN, `lag1` on `ethernet-1/4`, Ethernet Segment `es1` |
| `h1` | Linux | Single-homed to `l1`. `10.10.10.21` |
| `h2` | Linux | Single-homed to `l2`. `10.10.10.22` |
| `h3` | Linux | Dual-homed to `l1` and `l2`. `bond0`, `10.10.10.23` |

| Item | Value |
|---|---|
| VLAN | 10, name `staff`, subnet `10.10.10.0/24` |
| VNI | 1010 |
| MAC-VRF on the leaves | `vlan10` |
| ESI | `00:01:01:01:01:01:01:01:01:01` (same on both leaves) |
| LACP system ID | `00:00:00:00:10:10` (same on both leaves) |
| Multihoming mode | all-active |
| Management network | `172.22.20.0/24` |

The lab is Layer 2 only. There is no gateway and no VRF. ESI is a Layer 2 feature, so
Layer 3 would only add noise.

## Concepts in this lab

**Ethernet Segment (ES).** The set of links that connect one host to more than one
leaf. The ESI is its ID. Both leaves use the same ESI, so the rest of the fabric treats
them as one attachment point.

**Why the LACP system ID must match.** The host sees one LACP partner only if both
leaves use the same system ID. If they differ, the host sees two switches and bundles
only one link.

**Route types.**

| Type | Name | What it does here |
|---|---|---|
| 4 | Ethernet Segment | The leaves find each other and elect the Designated Forwarder (DF) |
| 1 per-ES (tag 4294967295) | Auto-Discovery | Mass withdraw. If a leaf loses the ES, one route withdrawal tells every leaf |
| 1 per-EVI (tag 0) | Auto-Discovery | Aliasing. A remote leaf can send to either member, even if it learned the MAC from one |
| 2 | MAC/IP | Where the host MAC is. Both leaves advertise it |

**DF election.** Only one leaf forwards BUM traffic (broadcast, unknown unicast,
multicast) toward the host, to stop duplicates. The default election picks the DF per
VLAN. Unicast uses both links.

**All-active vs single-active.** All-active: both links carry traffic. Single-active:
one link carries traffic and the other waits. The host must match the mode (see
[Gotchas](#gotchas)).

## Requirements

| Item | Detail |
|---|---|
| Host | Linux with Docker. About 4 GB free RAM. `labs.toml` refuses less |
| Containerlab | 0.77 or newer |
| netlab | In a venv. Tested with 26.10 |
| Ansible | `ansible-core` below 2.21 |
| Host kernel | The `bonding` module must be loaded: `sudo modprobe bonding` |
| Images | `ghcr.io/nokia/srlinux` (netlab pulls it) and FRR 10.7 |

Install netlab like this:

```sh
python3 -m venv ~/netlab-venv
~/netlab-venv/bin/pip install networklab "ansible-core<2.21" ruamel.yaml paramiko ansible-pylibssh
~/netlab-venv/bin/ansible-galaxy collection install -p ~/netlab-venv/ansible_collections \
    nokia.srlinux ansible.netcommon community.general ansible.utils
sudo apt install sshpass
```

The `modprobe` does not survive a reboot. To keep it:
`echo bonding | sudo tee /etc/modules-load.d/bonding.conf`.

## Run it

Work on the Containerlab host. Access to the nodes is `docker exec`:

```sh
docker exec -it clab-evpn-esi-l1 sr_cli        # SR Linux CLI (admin / NokiaSrl1!)
docker exec -it clab-evpn-esi-h3 sh            # the dual-homed host
docker exec clab-evpn-esi-s1 vtysh -c "show bgp l2vpn evpn summary"
```

| Script | What it does |
|---|---|
| `post-up.sh` | Builds the LAG and the Ethernet Segment on both leaves, and the bond on `h3`. Waits for LACP |
| `verify.sh` | Checks the whole lab. Breaks each leaf port in turn and restores it. Prints PASS or FAIL per line |
| `demo.sh` | Narrated tour. `PAUSE=1 ./demo.sh` waits for Enter between steps |
| `show-es.sh` | Read-only. ES state, DF, route counts, and the bond |
| `show-vni.sh` | Read-only. The VLAN to VNI mapping on each leaf |

## Look at the VLAN to VNI mapping

```sh
./show-vni.sh
```

```
== l1
  vxlan0.10   VNI 1010
  vlan10     mac-vrf
```

`vlan10` is the MAC-VRF. `vxlan0.10` is the VXLAN interface, and VLAN 10 maps to VNI 1010.
Three views, from least to most detail:

```sh
docker exec clab-evpn-esi-l1 sr_cli "show tunnel-interface vxlan-interface brief"
docker exec clab-evpn-esi-l1 sr_cli "info network-instance vlan10"
docker exec clab-evpn-esi-l1 sr_cli "info flat from running tunnel-interface vxlan0 vxlan-interface * ingress vni"
```

To change the VNI, edit `vni:` in `topology.yml` and run `netlab up` again, then
`./post-up.sh`.

## Look at the Ethernet Segment

```sh
./show-es.sh
docker exec clab-evpn-esi-l1 sr_cli "show system network-instance ethernet-segments"
docker exec clab-evpn-esi-l1 sr_cli "show system network-instance ethernet-segments detail"
docker exec clab-evpn-esi-l1 sr_cli "show network-instance default protocols bgp routes evpn route-type 4 summary"
docker exec clab-evpn-esi-l1 sr_cli "show network-instance default protocols bgp routes evpn route-type 1 summary"
docker exec clab-evpn-esi-l1 sr_cli "show network-instance vlan10 bridge-table mac-table all"
```

Read the first one like this:

```
es1 is up, all-active
  Peers    : 10.255.0.12, 10.255.0.11
  Interface: lag1
     vlan10
      Candidates : 10.255.0.11 (DF), 10.255.0.12
```

`Peers` are the other leaves on the segment. `(DF)` marks the elected forwarder for that VLAN.

## Things to try

Tests 1 to 5 were run on this lab. The results below are what was seen. Restore the state when you finish.

**1. Cut a link.** `demo.sh` does this. By hand:

```sh
docker exec -i clab-evpn-esi-l1 sr_cli <<'EOF'
enter candidate
set / interface ethernet-1/4 admin-state disable
commit now
EOF
```

Check that `h3` marks `eth1` down, that `h1` and `h2` still reach `10.10.10.23`, and that `l2` is now
the only DF candidate. Set `admin-state enable` to restore.

**2. See which link carries which traffic.** Read the receive counters on `h3`
before and after a ping from each host:

```sh
rx() { docker exec clab-evpn-esi-h3 cat /sys/class/net/$1/statistics/rx_packets; }
a1=$(rx eth1); a2=$(rx eth2)
docker exec clab-evpn-esi-h1 ping -c 20 -i 0.2 -q 10.10.10.23
echo "eth1 +$(( $(rx eth1) - a1 ))  eth2 +$(( $(rx eth2) - a2 ))"
```

Seen: 20 pings from `h1` arrive on `eth1` (the link to `l1`, the leaf `h1` is on). 20 pings from
`h2` arrive on `eth2`. A leaf sends to a local ES member first, so each host uses the
link on its own leaf. A few extra packets on the other link are LACP and ARP.

**3. Switch to single-active.** On both leaves:

```sh
docker exec -i clab-evpn-esi-l1 sr_cli <<'EOF'
enter candidate
set / system network-instance protocols evpn ethernet-segments bgp-instance 1 ethernet-segment es1 multi-homing-mode single-active
commit now
EOF
```

Repeat on `l2`. `show system network-instance ethernet-segments` now says `single-active`.
**Pings to `h3` fail.** The host still sends on both links, and the non-DF leaf drops
the traffic. This is the expected result. Single-active needs a host that uses one link at a time
(active-backup bonding). Set `multi-homing-mode all-active` on both leaves to restore.

**4. Break the shared ESI.** Set a different ESI on `l2` only:

```sh
docker exec -i clab-evpn-esi-l2 sr_cli <<'EOF'
enter candidate
set / system network-instance protocols evpn ethernet-segments bgp-instance 1 ethernet-segment es1 esi 00:02:02:02:02:02:02:02:02:02
commit now
EOF
```

Seen: each leaf lists only itself as a peer, and each is the DF. The segment has split
in two. Pings to `h3` still work, because unicast does not need the DF. The DF election exists
to stop duplicate BUM traffic, and a split segment loses it. Set the old ESI to restore.

**5. Break the shared LACP system ID.** Set `lag1 lag lacp system-id-mac` to another value
on `l2` only.

Seen: `h3` puts `eth1` and `eth2` in different aggregators. `bond0` uses one aggregator and
the other link is not bundled. Pings still work, on one link only. Check
`/proc/net/bonding/bond0`. Set `00:00:00:00:10:10` again to restore. LACP takes about 20
seconds to bundle again.

## Gotchas

| Symptom | Cause and fix |
|---|---|
| `post-up.sh` fails on `echo +bond0 > ... bonding_masters` | The host kernel has no `bonding` module loaded. `sudo modprobe bonding` on the host |
| The bond shows round-robin mode | The host image has BusyBox `ip`, which ignores bond options. `post-up.sh` sets them in sysfs. Do not replace it with `ip link add ... mode 802.3ad` |
| LACP does not bundle, `lag1` says `lower-layer-down` | The port in the config is not the port Containerlab cabled. Check `clab.yml` for the `l1:e1-N` that goes to `h3`. Do not set `ifname` on SR Linux ports in `topology.yml`: netlab configures the name you set, but Containerlab still cables the next free port |
| `post-up.sh` fails with `leafref ... bgp-vpn bgp-instance 1 does not exist` | The ES needs the BGP-VPN instance first. The script sets it. Keep that line |
| `untagged only configurable if vlan-tagging enabled` | A LAG subinterface with `encap untagged` needs `vlan-tagging true` on `lag1` |
| `aggregate-id present on interface, subinterface not configurable` | netlab configured the port as a routed port. The script deletes `ethernet-1/4.0` first |
| Pings to `h3` fail after switching to single-active | Expected. See test 3 |
| `netlab up` says the directory is locked | An earlier lab is still up here. `netlab down --cleanup` |
| `netlab initial` says `connection plugin 'paramiko' was not found` | `ansible-core` is 2.21 or newer. Install `"ansible-core<2.21"` |
| A new `netlab up` removed the LAG | Expected. netlab rebuilds the leaves. Run `./post-up.sh` again |
| Do not `docker stop` a node | Its links are lost, and a restart does not bring them back |

## Files

| File | What it is |
|---|---|
| `topology.yml` | The fabric for netlab: nodes, VLAN, VNI, links, validation |
| `post-up.sh` | Run after `netlab up`: LAG, Ethernet Segment, host bond |
| `verify.sh` | End-to-end check, including both failure tests |
| `demo.sh` | The narrated tour |
| `show-es.sh`, `show-vni.sh` | Read-only views |
| `ARCHITECTURE.md` | Why each decision was made |

## Limits and fidelity

- **SR Linux in a container is a software switch.** It has no ASIC. Timers and convergence
  numbers are not hardware numbers.
- **Two leaves only.** A remote leaf that learns the host MAC from one member and then uses aliasing to
  reach the other needs a third leaf. This lab shows the routes (type 1 per-EVI and per-ES), not
  a remote leaf acting on them.
- **Layer 2 only.** No gateway, no VRF, no symmetric IRB, no type 5 routes.
- **One ES, one VLAN.** The DF election has one VLAN to work on.
- **No netlab ESI.** netlab 26.10 has an EVPN multihoming plugin, but it has no SR Linux
  template. `post-up.sh` holds the SR Linux config, so `netlab up` alone does not give you ESI.
- **Lab credentials.** `admin` / `NokiaSrl1!` are lab-only. Do not expose the nodes.
- **Not tested in WSL2.** It was run on a Debian VM with Docker.
