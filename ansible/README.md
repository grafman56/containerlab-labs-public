# Ansible: run a lab on a Containerlab host

`containerlab-operations.yml` runs `./labctl` from a checkout of this repository on the Containerlab host. It handles one lab per run. `labs.toml` is the list of labs, so adding a lab needs no change here.

## Set up

1. On the host, install Docker and Containerlab, clone this repository, and allow passwordless `sudo` for your user (`./labctl doctor` checks this).
2. On the control machine, install Ansible, then copy the inventory and edit it:

```bash
cp inventory.example.yml inventory.yml
```

`inventory.yml` is not tracked by Git. If the checkout is not at `~/containerlab-labs-public`, add `-e containerlab_source=/path/to/checkout`.

## Run

```bash
ansible-playbook -i inventory.yml containerlab-operations.yml -e containerlab_operation=inspect
ansible-playbook -i inventory.yml containerlab-operations.yml \
  -e containerlab_operation=deploy -e containerlab_lab=ibgp-rr
ansible-playbook -i inventory.yml containerlab-operations.yml \
  -e containerlab_operation=destroy -e containerlab_lab=ibgp-rr
```

| Operation | What it runs |
| --- | --- |
| `inspect` | `./labctl status [lab]` |
| `deploy` | `./labctl doctor`, `./labctl up <lab>`, then `./labctl verify <lab>` |
| `verify` | `./labctl verify <lab>` |
| `destroy` | `./labctl down <lab>` (only that lab's topology) |

`enterprise-fabric` uses netlab, and `labctl` refuses to deploy it. See its README.
