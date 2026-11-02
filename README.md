# Containerlab Network Labs

Portable Containerlab and netlab exercises for enterprise routing and modern data-center fabrics.

This repository is the network estate. Industrial control labs, including the
Modbus and PLC work that used to live here, are in
Industrial-Controls.

## Requirements

- Native Linux or WSL2 with Docker access
- Containerlab 0.77 or newer
- Python 3.10 or newer for `enterprise-fabric`

Each lab pins its container images. The FRR labs use FRR 10.7.0.

## Labs

| Lab | What it shows |
| --- | --- |
| **Routing** | |
| `ibgp-rr/` | OSPF underlay, redundant iBGP route reflectors, eBGP ISP edge, access VLANs 120-122, Ansible policy templates |
| `sdwan-dual-transport/` | Two ISP transports, GRE overlays, eBGP, policy-based failover |
| `break-tests/` | Troubleshooting drills for `ibgp-rr`: fault, runbook, and device transcript |
| **EVPN-VXLAN** (see the VLAN-to-VNI note in each README) | |
| `evpn-vxlan/` | 2 spines, 2 leaves, eBGP underlay, symmetric IRB, BGP policy |
| `evpn-vxlan-ospf/` | Same overlay over an OSPF underlay, with an external eBGP edge |
| `evpn-vxlan-fabric/` | 4 spines, 10 leaves |
| `evpn-vxlan-campus/` | Two-site campus: NAC, DHCP/DNS, firewall identity publication, read-only reconciliation tool |
| `evpn-vxlan-srlinux/` | SR Linux leaves and a firewall node. Read the VLAN to VNI mapping on the device, publish it as User-ID tags to the PAN-OS emulator, and make a rule written in the API change real traffic |
| **Other** | |
| `enterprise-fabric/` | netlab-managed SR Linux fabric with gNMI telemetry (Telegraf, InfluxDB, Grafana) |
| `cin-rphy-transport/` | Remote PHY cable transport with a read-only Ansible probe |
| `wireless-radius-8021x/` | Virtual Wi-Fi AP and supplicant with FreeRADIUS (WPA2-Enterprise) |
| `docsis-pnm-poc/` | Runner for a locally built CableLabs ns-3 DOCSIS image |

## Companion projects

[panos-emu-public](https://github.com/grafman56/panos-emu-public) is a small PAN-OS XML API emulator (stdlib Python, no packets). The campus lab can publish user and role tags to it and reconcile against it, in place of the nftables stand-in. The `evpn-vxlan-srlinux` lab is built around it. The other labs run without it.

## Run a lab

`labs.toml` lists every lab. `./labctl` reads it (details in `docs/lifecycle.md`):

```bash
./labctl list
./labctl up ibgp-rr       # deploy, then run verify.sh
./labctl down ibgp-rr     # destroy only this lab
```

To drive a remote host with Ansible, see `ansible/README.md`.

`enterprise-fabric` uses netlab, and `wireless-radius-8021x` loads a kernel module, so read their READMEs first. Do not run broad Docker cleanup commands on a host that runs other workloads.

## Static checks

Run the repository checks without starting a lab:

```bash
./validate-repository.sh
```

## Repository rules

- Keep topology, configuration, setup scripts, and verification in each lab directory.
- Pin container images. Do not use floating `latest` tags.
- Use relative paths so a clone runs on another host.
- Keep runtime directories, local inventory files, and secrets out of Git.
