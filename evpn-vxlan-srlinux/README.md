# EVPN-VXLAN on SR Linux with a PAN-OS emulator

A small campus-style fabric to practise two things together:

1. Read a real VLAN to VNI mapping on a network OS.
2. Publish User-ID and tags to a PAN-OS XML API, keyed on that mapping.

```
VLAN 10  VNI 1010  VRF tenant   staff      h1 (l1)  h2 (l2)
VLAN 20  VNI 1020  VRF tenant   services   h4 (l1)
VLAN 30  VNI 1030  VRF guest    visitor    h3 (l2)
         VNI 4100  VRF tenant   transit
         VNI 4200  VRF guest    transit
```

```
        s1 (FRR) ---- s2 (FRR)       spines: OSPF underlay, EVPN route reflectors
        /      \     /      \
   l1 (SR Linux)      l2 (SR Linux)  leaves: the VLAN to VNI binding lives here
    h1  h4             h2  h3  |  |
                               |  +-- eBGP, VRF guest  --+
                               +----- eBGP, VRF tenant --+-- fw (zones tenant, guest)
```

`l2` is also the border leaf. `fw` is FRR plus nftables. It forwards packets and
holds the zone policy. The PAN-OS emulator mirrors `fw` and holds the API,
User-ID and rules. The emulator does not forward packets.

The chain to keep in mind: **VLAN -> VNI -> VRF -> border-leaf link -> firewall
interface -> zone**. The firewall never sees a VNI. `publish.py` carries it as a tag.

## Before you start

- A host with Containerlab, `netlab`, Ansible (`ansible-core` below 2.21: 2.21
  dropped the `paramiko` connection plugin netlab uses), `sshpass`, and the
  `campus-firewall:1.0.0` image (built from `evpn-vxlan-campus/firewall`).
- About 6 GB free RAM: two SR Linux nodes, three FRR nodes, four hosts.
- The emulator ([panos-emu-public](https://github.com/grafman56/panos-emu-public))
  on the same host, in mirror mode. Zone names come from `fw-zones.nft`.

## Run it

```sh
cd evpn-vxlan-srlinux
netlab up                 # deploy and configure
./post-up.sh              # load fw zones, fw default-route-only to the fabric, host default routes
netlab validate           # OSPF full, EVPN established
./demo.sh                 # narrated walkthrough, about 2 minutes (PAUSE=1 waits for Enter)
./verify.sh               # VNIs, pings, fw zones, tags, policy match (needs the emulator)

# in panos-emu-public (separate terminal):
PANOS_LAB_FW=clab-evpn-srlinux-fw PANOS_LAB_HOSTNAME=fw python3 panos_emulator.py

./publish.py              # login + vlan/vni/vrf tags for h1..h4 -> emulator
./sync-fw.py              # push the emulator's committed rules into fw's nftables
netlab down --cleanup
```

Run from another machine: `ssh -tt user@host 'docker exec -it clab-evpn-srlinux-l1 sr_cli'`.

## See the binding

```sh
./show-vni.sh                                       # VNI table for both leaves
docker exec clab-evpn-srlinux-l1 sr_cli "info network-instance vlan10"
docker exec clab-evpn-srlinux-l1 sr_cli "show tunnel-interface vxlan-interface brief"
```

SR Linux names each MAC-VRF `vlan<id>`. The VNI sits on `vxlan0.<id>`. To change a
mapping, edit `vni` in `topology.yml` and run `netlab up` again.

## Try it

```sh
# fabric: stretched L2 and inter-VLAN
docker exec clab-evpn-srlinux-h1 ping -c2 10.10.10.22   # same VLAN, other leaf
docker exec clab-evpn-srlinux-h1 ping -c2 10.20.20.24   # VLAN 10 -> 20, IRB

# firewall: default deny until a rule is committed and synced
docker exec clab-evpn-srlinux-h1 ping -c2 10.30.30.23   # tenant -> guest: dropped

# emulator: a rule that matches the VNI tag, then ask who matches
# (see panos-emu-public/TRAINING.md for set/commit and security-policy-match)
```

Add the rule: source zone `tenant`, destination `guest`, application `icmp`,
`source-tag vni:1010`, action allow. Commit it, then `./sync-fw.py`. Now `h1` and
`h2` (VNI 1010) reach `h3`, `h4` (VNI 1020) does not, and `h3` still cannot
reach back. `./verify.sh` does exactly this and checks each result.

## Gotchas

- `fw` starts with default deny between zones. Nothing crosses until a rule is
  committed in the emulator and `./sync-fw.py` runs.
- The sync is one way, emulator to `fw`, and runs when you run it. A rule edited
  in the emulator does not change `fw` until then. It supports zones, a few
  applications (icmp, ssh, dns, web-browsing, ssl), `source-tag`, `source-user`.
- `fw` sends each VRF only a default route. `post-up.sh` sets it.
- OSPF is off inside the VRFs (`ospf: false`). With it on, netlab loops routes
  between OSPF and the fw BGP session.
- Hosts get their default route from `post-up.sh`. netlab leaves it on the mgmt network.
- User-ID names come from `HOSTS` in `publish.py`. A NAC would supply them.
  Logins time out after 45 minutes in the emulator. Run `./publish.py` again.
- SR Linux `show` syntax changes between releases. `info flat from running` is stable.

## What this lab does not do

No 802.1X, RADIUS or DHCP, no multi-site, no internet edge. For those see
`evpn-vxlan-campus`. For the emulator's limits see its README.
