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
./post-up.sh              # load fw zones, set host default routes, as-override on fw
netlab validate           # OSPF full, EVPN established

# in panos-emu-public (separate terminal):
PANOS_LAB_FW=clab-evpn-srlinux-fw PANOS_LAB_HOSTNAME=fw python3 panos_emulator.py

./publish.py              # login + vlan/vni/vrf tags for h1..h4 -> emulator
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
# fabric: stretched L2, inter-VLAN, then through the firewall
docker exec clab-evpn-srlinux-h1 ping -c2 10.10.10.22   # same VLAN, other leaf
docker exec clab-evpn-srlinux-h1 ping -c2 10.20.20.24   # VLAN 10 -> 20, IRB
docker exec clab-evpn-srlinux-h1 ping -c2 10.30.30.23   # tenant -> guest, via fw: allowed
docker exec clab-evpn-srlinux-h3 ping -c2 10.10.10.21   # guest -> tenant: dropped by fw

# emulator: a rule that matches the VNI tag, then ask who matches
# (see panos-emu-public/TRAINING.md for set/commit and security-policy-match)
```

Example rule: source zone `tenant`, destination `guest`, `source-tag vni:1010`.
`h1` (VNI 1010) matches it. `h4` (VNI 1020) hits `interzone-default`.

## Gotchas

- The leaves and `fw` are in different ASNs, but `l2` peers with `fw` in two VRFs
  from one AS. `fw` re-advertises each zone's prefixes to the other, with 65000 in
  the path, and the leaf drops them as a loop. `post-up.sh` sets `as-override` on
  `fw`. `allowas-in` on the leaf also works.
- Hosts get their default route from `post-up.sh`. netlab leaves it on the mgmt network.
- The nftables policy and the emulator rulebase are two separate things. A rule
  added in the emulator does not change what `fw` forwards. Keep them in step by hand.
- User-ID names come from `HOSTS` in `publish.py`. A NAC would supply them.
- SR Linux `show` syntax changes between releases. `info flat from running` is stable.

## What this lab does not do

No 802.1X, RADIUS or DHCP, no multi-site, no internet edge. For those see
`evpn-vxlan-campus`. For the emulator's limits see its README.
