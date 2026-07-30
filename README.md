# Containerlab Network Labs

Portable Containerlab and netlab exercises for enterprise routing and modern data-center fabrics.

## Requirements

- Native Linux or WSL2 with Docker access
- Containerlab 0.77 or newer
- Python 3.10 or newer for `enterprise-fabric`

Each lab pins its container images. The FRR labs use FRR 10.7.0.

## Labs

- `ibgp-rr/`: OSPF underlay, redundant iBGP route reflectors, and an eBGP edge.
- `evpn-vxlan/`: two-spine, two-leaf EVPN/VXLAN fabric.
- `sdwan-dual-transport/`: dual ISP transport with GRE overlays and failover.
- `cin-rphy-transport/`: redundant Remote PHY transport and a read-only Ansible probe.
- `enterprise-fabric/`: netlab-managed SR Linux fabric with optional telemetry.
- `wireless-radius-8021x/`: virtual Wi-Fi AP, supplicant, and FreeRADIUS authentication.

## Start a lab

Read the lab README before deployment. The FRR labs use this lifecycle:

```bash
cd ibgp-rr
sudo -E containerlab deploy -t ibgp-rr.clab.yml
./verify.sh
sudo -E containerlab destroy -t ibgp-rr.clab.yml --cleanup
```

Run only the deploy and destroy commands for the lab that you selected. Do not use broad Docker cleanup commands on a host that runs other workloads.

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
