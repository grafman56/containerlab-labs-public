# iBGP RR Ansible policy template

This template manages the known-good P1 edge policy in the `ibgp-rr` lab.
It targets only `clab-ibgp-rr-p1` on the Containerlab host.

The policy models a common enterprise boundary:

- accept only `203.0.113.0/24` from the external AS 65001 peer;
- set local preference to 150 for that approved customer route;
- export to the route reflectors only routes marked `65001:100`; and
- deny unmatched inbound and outbound edge routes explicitly.

`policy_state=audit` is the default and makes no configuration change. It checks
the running configuration for each expected object and BGP neighbor attachment.
Use `policy_state=present` only after a scoped deployment of this lab. The apply
path uses soft inbound and outbound refreshes. It does not reset BGP sessions.

```bash
ansible-playbook -i inventory.yml playbooks/edge_policy.yml
ansible-playbook -i inventory.yml playbooks/edge_policy.yml -e policy_state=present
```

Run `../verify.sh` after an apply. The normal verifier proves that the edge
prefix and its community reach P3 through both route reflectors.

## Access fabric

`playbooks/access_fabric.yml` manages only `sw1` and `sw2` through Docker on
the Containerlab host. It keeps VLANs 120, 121, and 122 on the fixed trunk.
The default audit reports bridge VLAN and MAC state without changing a switch.

```bash
ansible-playbook -i inventory.yml playbooks/access_fabric.yml
ansible-playbook -i inventory.yml playbooks/access_fabric.yml -e access_state=present
```

The present path replaces only the `br-access` bridge on each access switch.
Run `../verify.sh` after an apply.

Copy `inventory.example.yml` to `inventory.yml` and set your SSH user and Containerlab host first. `inventory.yml` is not tracked.
