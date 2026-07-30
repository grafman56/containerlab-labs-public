# CIN RPA probes

This is the first read-only CIN management probe. It runs from an Ansible
controller that can SSH to the Containerlab host and reports each RPA's
RPD-facing interfaces.

For each RPA/RPD association, the report contains:

- the RPA interface name;
- all live IPv4 addresses/prefix lengths on that interface;
- administrative, carrier, and operational state; and
- the expected RPD association.

The association is explicit topology intent in `inventory.example.yml`. The FRR lab
has no LLDP agent, so it cannot discover the remote node name dynamically.
The live interface IP/state is collected from the running container. A
production RPA implementation can replace or augment this intent with parsed
LLDP/CDP or a vendor API, while keeping the same report format.

## Run

This setup makes no configuration changes. From an Ansible controller with
SSH access to the Containerlab host:

```bash
cd cin-rphy-transport/ansible
cp inventory.example.yml inventory.yml
# Edit ansible_host and ansible_user for the Containerlab host.
ansible-playbook -i inventory.yml playbooks/rpa_interface_probe.yml
```

Expected healthy lab associations:

| RPA | Interface | RPD | IPv4 |
| --- | --- | --- | --- |
| rpa1 | eth3 | rpd1 | 10.10.4.1/31 |
| rpa1 | eth4 | rpd2 | 10.10.5.1/31 |
| rpa2 | eth3 | rpd1 | 10.10.4.3/31 |
| rpa2 | eth4 | rpd2 | 10.10.5.3/31 |

## Test the transformation

The filter has a fixture captured from the live `rpa1` interface data and can
be tested without Ansible:

```bash
python3 -m unittest tests/test_rpa_probe_rows.py -v
```
