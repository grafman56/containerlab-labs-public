# EVPN-VXLAN on SR Linux with a PAN-OS emulator

A small campus-style fabric for two jobs at the same time:

1. **See a real VLAN to VNI mapping** on a network OS (Nokia SR Linux). You read it
   from the device, with one command, and you can change it with a one-line edit.
2. **Work with a Palo Alto firewall API.** A PAN-OS emulator holds the firewall's
   zones, User-ID mappings, tags and security rules. A script publishes who is
   where, using the VNI as a tag. Another script pushes the rules into a real
   data path, so a ping proves the rule works.

It is small on purpose. It has 2 SR Linux leaves, 2 FRR spines, 1 firewall node and
4 hosts. It runs on one 8 GB host. It is more than a spreadsheet because packets
really cross the fabric and the firewall.

## Quick start

You need a Linux host with Docker, Containerlab and netlab (install steps are in
[Requirements](#requirements)). Then, about 5 minutes:

```sh
# Once: get both repositories and build the firewall image
# (HTTP, so no SSH key is needed)
mkdir -p ~/labs && cd ~/labs
git clone https://github.com/grafman56/containerlab-labs-public.git
git clone https://github.com/grafman56/panos-emu-public.git
docker build -t campus-firewall:1.0.0 containerlab-labs-public/evpn-vxlan-campus/firewall

# Terminal 1: the PAN-OS emulator (leave it running)
cd ~/labs/panos-emu-public
PANOS_DATA=data/srlinux-lab.json python3 panos_emulator.py

# Terminal 2: the lab
export PATH=~/netlab-venv/bin:$PATH ANSIBLE_COLLECTIONS_PATH=~/netlab-venv
cd ~/labs/containerlab-labs-public/evpn-vxlan-srlinux
netlab up          # about 90 seconds
./post-up.sh       # required after every netlab up
./verify.sh        # ends with: ALL PASS
./demo.sh          # a guided tour, about 2 minutes
```

If `verify.sh` ends with `ALL PASS`, the fabric, the firewall and the emulator work
together. Then read [Walkthrough](#walkthrough). To shut down: press Ctrl-C in
terminal 1, and run `netlab down --cleanup` in terminal 2.

Contents: [Quick start](#quick-start) · [Topology](#topology) · [Concepts](#concepts-in-this-lab) ·
[Requirements](#requirements) · [Run it](#run-it) · [Look at the mapping](#look-at-the-vlan-to-vni-mapping) ·
[Walkthrough](#walkthrough) · [The PAN-OS emulator](#the-pan-os-emulator-and-how-it-fits) ·
[Files](#files) · [Troubleshooting](#troubleshooting) · [Limits](#limits-and-fidelity)

## Topology

```
              s1 (FRR) ------- s2 (FRR)        spines: OSPF underlay, EVPN route reflectors
             /       \       /       \         (they never see a VLAN or a VNI)
    l1 (SR Linux)               l2 (SR Linux)  leaves: the VLAN to VNI mapping lives here
     |       |                   |      |  |   l2 is also the border leaf
    h1      h4                  h2     h3  |
  staff   services            staff  visitor |
                                  tenant VRF |  guest VRF
                                  (eBGP)     |  (eBGP)
                                     \       /
                                      fw  (zones: tenant, guest)
```

| Segment | VLAN | VNI | VRF | Subnet | Hosts |
|---|---|---|---|---|---|
| staff | 10 | 1010 | tenant | 10.10.10.0/24 | h1 (.21, on l1), h2 (.22, on l2) |
| services | 20 | 1020 | tenant | 10.20.20.0/24 | h4 (.24, on l1) |
| visitor | 30 | 1030 | guest | 10.30.30.0/24 | h3 (.23, on l2) |
| tenant transit | - | 4100 | tenant | - | routing between leaves |
| guest transit | - | 4200 | guest | - | routing between leaves |

| Node | Image | Role |
|---|---|---|
| `s1`, `s2` | FRR 10.7 | Underlay (OSPF area 0) and EVPN route reflectors, AS 65000 |
| `l1`, `l2` | Nokia SR Linux | Leaves, AS 65000. VXLAN, EVPN, symmetric IRB. `l2` also hands off to `fw` |
| `fw` | `campus-firewall:1.0.0` (FRR + nftables) | The data path of the firewall, AS 65100 |
| `h1` to `h4` | Linux | Test hosts with one address each |
| PAN-OS emulator | `panos_emulator.py` | The firewall API. It runs beside the lab, not in it |

Fabric links use 10.0.0.0/24 in /31 blocks. Loopbacks use 10.255.0.0/24 (`s1` .1,
`s2` .2, `l1` .11, `l2` .12, `fw` .31). The management network is 172.21.20.0/24.
The `fw` links to `l2` are 10.0.0.10/31 (tenant) and 10.0.0.12/31 (guest).

## Concepts in this lab

You can skip this if you know EVPN and PAN-OS. It explains the one idea the lab is built around.

**VLAN, VNI, VRF.** A VLAN is a Layer 2 segment on one switch. A VNI is the number
that carries that segment across the VXLAN tunnel between leaves. A VRF is a
separate routing table. In this lab VLAN 10 is VNI 1010 and lives in VRF `tenant`.

**Symmetric IRB.** Each VRF has its own transit VNI (4100 and 4200). A routed packet
is sent to the remote leaf inside that VNI. Every leaf routes in and out, so leaves
only need the VLANs that they serve.

**EVPN route types you will meet.** Type 2 carries a host MAC and IP (a host behind
a leaf). Type 3 builds the flood list. Type 5 carries an IP prefix (for example
the default route that `l2` learns from `fw`).

**Where the VNI stops.** The firewall never sees a VNI. It sees a routed link. So
the chain is:

```
VLAN 10 -> VNI 1010 -> VRF tenant -> routed link on l2 -> fw interface -> zone tenant
```

Each arrow is configuration. The VNI ends at the border leaf. To let the firewall
use it anyway, `publish.py` sends the VNI as a **tag** with each User-ID login.
A rule can then say "source tag `vni:1010`" and hold no prefix.

**What BGP does here, and what it does not.** BGP between `l2` and `fw` carries
prefixes, one session per VRF. It does not carry users. Who is behind an address is
User-ID, and that comes from the PAN-OS API.

## Requirements

| Item | Detail |
|---|---|
| Host | Linux with Docker. About 6 GB free RAM. `labs.toml` refuses less. Tested on the lab host. Not tested in WSL2 |
| Containerlab | 0.77 or newer |
| netlab | Installed in a venv. See below |
| Ansible | `ansible-core` **below 2.21**. 2.21.5 failed with `connection plugin 'paramiko' was not found`. 2.20.10 works. Only this one pair was tested |
| `sshpass` | netlab uses it for `netlab validate` |
| Images | `ghcr.io/nokia/srlinux` (netlab pulls it), FRR 10.7, `python:3.13-alpine`, and `campus-firewall:1.0.0` |
| Emulator | [panos-emu-public](https://github.com/grafman56/panos-emu-public), on the same host. Python 3.12 (older 3.x probably works), no packages |

Install netlab the way the lab host was set up:

```sh
python3 -m venv ~/netlab-venv
~/netlab-venv/bin/pip install networklab "ansible-core<2.21" ruamel.yaml paramiko ansible-pylibssh
~/netlab-venv/bin/ansible-galaxy collection install -p ~/netlab-venv/ansible_collections \
    nokia.srlinux ansible.netcommon community.general ansible.utils
sudo apt install sshpass
```

Before any `netlab` command in a shell:

```sh
export PATH=~/netlab-venv/bin:$PATH ANSIBLE_COLLECTIONS_PATH=~/netlab-venv
```

Build the firewall image once (the campus lab uses the same one):

```sh
docker build -t campus-firewall:1.0.0 ../evpn-vxlan-campus/firewall
```

## Run it

You work on the Containerlab host. From another machine, use SSH and Docker, the
same way as the other labs:

```sh
ssh -tt user@lab-host 'docker exec -it clab-evpn-srlinux-l1 sr_cli'
ssh user@lab-host 'cd labs/evpn-vxlan-srlinux && ./verify.sh'
```

**1. Deploy the lab** (about 90 seconds):

```sh
cd evpn-vxlan-srlinux
netlab up
```

**2. Run the post-up step** (every time after `netlab up`):

```sh
./post-up.sh
```

It does three things that netlab does not: it loads the firewall's zones, it makes
`fw` send each VRF a default route only, and it points each host's default route at
its leaf. Without it the hosts cannot leave their subnet.

**3. Start the PAN-OS emulator** in a second terminal. Pick one mode. If you have not
cloned it, see the [Quick start](#quick-start):

```sh
cd ~/labs/panos-emu-public

# A. Mirror mode. The emulator reads the running fw node. Needs Docker access.
PANOS_LAB_FW=clab-evpn-srlinux-fw PANOS_LAB_HOSTNAME=fw python3 panos_emulator.py

# B. Fixture. Fixed values that match this lab. No Docker, no running lab needed.
PANOS_DATA=data/srlinux-lab.json python3 panos_emulator.py
```

Both listen on port 8080. Mode A shows real interfaces, routes and BGP state, and
it follows changes. Mode B always shows BGP as `Established`. Everything below
(User-ID, rules, policy match, `sync-fw.py`) works the same in both.

**4. Check it**:

```sh
netlab validate     # OSPF is full and both EVPN sessions are up on each leaf
./verify.sh         # the full end-to-end check. It prints PASS or FAIL per line
./demo.sh           # a narrated walkthrough, about 2 minutes. PAUSE=1 waits for Enter
```

**5. Shut down**:

```sh
netlab down --cleanup
```

To reach the emulator from your own machine, use `http://lab-host:8080/`. It has no
login by default, so keep it on a trusted network.

## Look at the VLAN to VNI mapping

This is the main reason the leaves run SR Linux. The mapping is configuration that
you read on the device. You do not rebuild it from the kernel.

```sh
./show-vni.sh
```

```
== l2
  vxlan0.10   VNI 1010
  vxlan0.30   VNI 1030
  vxlan0.100  VNI 4100
  vxlan0.101  VNI 4200
  guest      ip-vrf
  tenant     ip-vrf
  vlan10     mac-vrf
  vlan30     mac-vrf
```

On a leaf, three views, from least to most detail:

```sh
docker exec clab-evpn-srlinux-l2 sr_cli "show tunnel-interface vxlan-interface brief"
docker exec clab-evpn-srlinux-l2 sr_cli "info network-instance vlan10"
docker exec clab-evpn-srlinux-l2 sr_cli "info flat from running tunnel-interface vxlan0 vxlan-interface * ingress vni"
```

How to read it. SR Linux names each Layer 2 instance (a MAC-VRF) `vlan<id>`, so VLAN
10 is `vlan10`. That instance holds the access port, the IRB and the VXLAN interface.
The VNI is on the tunnel interface: `vxlan0.10` carries VNI 1010. The number after the
dot is the VLAN id, which is how this lab names it.

**Change a mapping.** Edit `vni:` under the VLAN in `topology.yml`, then run
`netlab up` again. Check with `./show-vni.sh`.

## Walkthrough

`./demo.sh` runs this for you. Doing it by hand teaches more.

**1. The fabric works.** Same VLAN across two leaves, then routing between VLANs:

```sh
docker exec clab-evpn-srlinux-h1 ping -c2 10.10.10.22   # h1 on l1 to h2 on l2, one VNI (1010)
docker exec clab-evpn-srlinux-h1 ping -c2 10.20.20.24   # VLAN 10 to VLAN 20, routed in VRF tenant
```

**2. The firewall starts closed.** Zones exist and nothing crosses between them:

```sh
docker exec clab-evpn-srlinux-h1 ping -c2 10.30.30.23   # tenant to guest: blocked
```

**3. Tell the firewall who is where.**

```sh
./publish.py
```

```
h1  10.10.10.21  alice@lab.local     vlan:10 vni:1010 vrf:tenant
h2  10.10.10.22  bob@lab.local       vlan:10 vni:1010 vrf:tenant
h3  10.30.30.23  visitor1@lab.local  vlan:30 vni:1030 vrf:guest
h4  10.20.20.24  carol@lab.local     vlan:20 vni:1020 vrf:tenant
```

For each host it reads the IP from the host, the VLAN and VRF from the leaf, and
the VNI from the leaf's `vxlan0` interface. Then it sends one User-ID message
(login plus tags) to the emulator. See what the firewall now knows:

```sh
curl -s -G localhost:8080/api --data-urlencode type=op \
  --data-urlencode 'cmd=<show><user><ip-user-mapping><all/></ip-user-mapping></user></show>'
curl -s -G localhost:8080/api --data-urlencode type=op \
  --data-urlencode 'cmd=<show><object><registered-ip><all/></registered-ip></object></show>'
```

**4. Write a rule in the PAN-OS API.** Allow ICMP from zone `tenant` to zone
`guest`, only from addresses tagged `vni:1010`:

```sh
A=localhost:8080/api
curl -s -G $A --data-urlencode type=config --data-urlencode action=set \
  --data-urlencode "xpath=security/rules/entry[@name='vni1010-to-guest']" \
  --data-urlencode "element=<entry name='vni1010-to-guest'><source>tenant</source><destination>guest</destination><application>icmp</application><source-tag><member>vni:1010</member></source-tag><action>allow</action></entry>"
curl -s -X POST --data-urlencode type=commit $A
```

Ask the firewall what it would do, before any packet moves:

```sh
curl -s -G $A --data-urlencode type=op --data-urlencode 'cmd=<test><security-policy-match><from>tenant</from><to>guest</to><source>10.10.10.21</source><destination>10.30.30.23</destination><application>icmp</application></security-policy-match></test>'
```

`10.10.10.21` (VNI 1010) matches your rule. Change the source to `10.20.20.24`
(VNI 1020) and it falls to `interzone-default`, which denies.

**5. Push the committed rules into the data path, then test the traffic.**

```sh
./sync-fw.py
docker exec clab-evpn-srlinux-h1 ping -c2 10.30.30.23   # allowed
docker exec clab-evpn-srlinux-h2 ping -c2 10.30.30.23   # allowed (VNI 1010 on the other leaf)
docker exec clab-evpn-srlinux-h4 ping -c2 10.30.30.23   # blocked (VNI 1020, no matching rule)
docker exec clab-evpn-srlinux-h3 ping -c2 10.10.10.21   # blocked (guest to tenant, no rule)
docker exec clab-evpn-srlinux-fw nft list chain inet zones zone_policy   # packet counters per rule
```

**Things to try next**
- Tag a host differently in `publish.py`, run it again, run `sync-fw.py`, and watch the rule's address set change.
- Change a rule to `source-user alice@lab.local`. Only `h1` can then reach `h3`.
- Change the rule's `action` to `deny` and sync. Check the counter.
- Edit a VNI in `topology.yml`, run `netlab up`, run `./publish.py` and see the tag follow.
- Fail an uplink and watch the fabric survive it:
  ```sh
  docker exec clab-evpn-srlinux-s1 vtysh -c "conf t" -c "interface eth1" -c "shutdown"   # s1 to l1
  docker exec clab-evpn-srlinux-h1 ping -c3 10.10.10.22                                  # still works, via s2
  docker exec clab-evpn-srlinux-l1 sr_cli "show network-instance default protocols ospf neighbor"   # one neighbor left
  docker exec clab-evpn-srlinux-s1 vtysh -c "conf t" -c "interface eth1" -c "no shutdown"
  ```
  Do not `docker stop` a node. Its links are lost, and a restart does not bring them back.

## The PAN-OS emulator, and how it fits

The emulator answers the PAN-OS XML API and keeps state. It does **not** forward
packets and has no App-ID. So the lab has two halves that must agree:

| | The emulator | The `fw` node |
|---|---|---|
| Is | The management plane: API, candidate and running config, User-ID, policy match | The data path: FRR for BGP, nftables for packets |
| Knows | Zones, rules, user mappings, tags | Interfaces, routes, which packets to pass |
| You use it for | PAN-OS API practice, automation, policy tests | Proving with a ping that a rule works |

`sync-fw.py` joins them. It reads the emulator's **committed** rules plus its tags and
user mappings, and rewrites one nftables chain (`zone_policy`) on `fw`. A rule on
`source-tag vni:1010` becomes "source address is one of the addresses tagged
`vni:1010`". It also clears the firewall's connection table, so a changed rule
applies at once. A real firewall would age old sessions out instead.

The sync is one way (emulator to `fw`) and runs when you run it. If you edit a rule
and do not sync, the emulator and the data path disagree. That is by design here: it
shows why a real firewall's policy and its data plane are one device.

What `sync-fw.py` understands: source and destination zones, the applications `icmp`,
`ssh`, `dns`, `web-browsing` and `ssl`, `source-tag`, `source-user`, and the actions
`allow` and `deny`. Rules are first match wins. An unknown application is skipped
and not guessed. A rule that names a tag or user nobody holds right now adds nothing.

The emulator's own documents are the reference for the API: `README.md` (the XML API),
`TRAINING.md` (exercises and what to re-check on a real firewall) and
`ARCHITECTURE.md`.

## Files

| File | What it is |
|---|---|
| `topology.yml` | The whole fabric for netlab: nodes, VLANs and their VNIs, VRFs, links, validation |
| `post-up.sh` | Run after `netlab up`: fw zones, fw default-route-only, host default routes |
| `fw-zones.nft` | Base firewall ruleset: two zones (`tenant_ifaces`, `guest_ifaces`) and default deny. The set names `<zone>_ifaces` are how the emulator finds zones in mirror mode |
| `publish.py` | Reads IP, VLAN, VRF and VNI from the lab, sends User-ID logins and tags to the emulator. `--clear` removes them |
| `sync-fw.py` | Pushes the emulator's committed rules into `fw`. `--dry-run` prints the nftables commands |
| `show-vni.sh` | Prints the VLAN to VNI table for each leaf |
| `verify.sh` | End-to-end check. Exits non-zero on any failure |
| `demo.sh` | The narrated walkthrough. It resets its own rule, so it is safe to repeat |
| `ARCHITECTURE.md` | Why each decision was made |

`publish.py` and `sync-fw.py` have a built-in self-check that runs on every start.
Every script that talks to the emulator uses `127.0.0.1:8080`. For another address, set `PANOS_URL` for `verify.sh` and `demo.sh`, or pass `--url` to `publish.py` and `sync-fw.py`.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `netlab initial` says `connection plugin 'paramiko' was not found` | `ansible-core` is 2.21 or newer. Install `"ansible-core<2.21"` |
| `netlab validate` says `No such file: sshpass` | `sudo apt install sshpass` |
| `netlab create` says the directory is locked | An earlier lab is still up here. `netlab down --cleanup`, or remove `netlab.lock` if you are sure nothing runs |
| Hosts cannot ping outside their subnet | `./post-up.sh` was not run after `netlab up` |
| Tenant to guest is blocked after you added a rule | The rule is in the emulator only. Commit it, then `./sync-fw.py`. Check with `--dry-run` that the rule produced a line |
| `sync-fw.py` adds no rule for a tag rule | Nobody holds that tag now. Run `./publish.py`. Logins and tags in the emulator can also expire (45 minutes for logins) |
| A rule change does not seem to apply | An old connection matched `ct state established`. `sync-fw.py` clears the table. If you edit nftables by hand, run `conntrack -F` in `fw` |
| Packets bounce between `l1` and `l2` | OSPF is running inside a VRF. `topology.yml` sets `ospf: false` on both VRFs. Keep it |
| `verify.sh` fails on the emulator checks | The emulator is not on port 8080, or was started without mirror mode or the fixture |
| Port 8080 already in use | Another emulator runs on this host. Use it, or set `PANOS_PORT` |
| An `sr_cli` command gives `Unknown token` | SR Linux syntax differs between releases. `info flat from running ...` is the most stable form |
| Editing `fw-zones.nft` seems to do nothing | `post-up.sh` copies it into `fw` with `docker cp`. Run `./post-up.sh` again |

Useful commands:

```sh
docker exec -it clab-evpn-srlinux-l2 sr_cli                          # SR Linux CLI (admin / NokiaSrl1!)
docker exec clab-evpn-srlinux-l2 sr_cli "show network-instance tenant protocols bgp neighbor"
docker exec -it clab-evpn-srlinux-fw vtysh                           # FRR on the firewall
docker exec clab-evpn-srlinux-fw nft list ruleset                    # what the firewall passes
docker exec clab-evpn-srlinux-s1 vtysh -c "show bgp l2vpn evpn summary"
docker exec -it clab-evpn-srlinux-h1 sh                              # a host
```

The nodes have no SSH from the LAN. Reach them through the host with `docker exec`.

## Limits and fidelity

- **The emulator is not a PAN-OS.** It has no dataplane, no App-ID, no URL
  filtering. The element names for some operational commands come from memory. See
  "Check these on a real firewall" in its `TRAINING.md`.
- **Tags match a rule directly here.** On a real firewall a rule matches an address
  object or a dynamic address group, and the group's filter holds the tag. The same
  idea, one more object to create.
- **Policy is two systems.** The emulator holds the policy and `fw` enforces a
  translation of it. `sync-fw.py` covers only the features listed above.
- **User names are lab data.** The `HOSTS` table in `publish.py` stands in for a NAC
  or an identity provider. There is no 802.1X, RADIUS or DHCP. The campus lab
  (`evpn-vxlan-campus`) covers those.
- **One firewall, one border leaf.** No HA pair, no second border, no internet edge,
  no multi-site.
- **The leaves use unicast gateways.** Each leaf has its own address on a VLAN (.11
  or .12), and a host uses the one on its own leaf. A distributed anycast gateway
  is not configured.
- **No packet capture or telemetry.** Use `tcpdump` in a node's namespace if you
  need it.
- **Logins expire.** The emulator times a User-ID login out after 45 minutes by
  default. Run `./publish.py` again.
