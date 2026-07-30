# Enterprise iBGP Spine–Leaf Lab

This is the production-style lab entry point. `netlab` generates the Containerlab topology, startup configurations, Ansible inventory, addressing, and validation tests from `topology.yml`.

## Architecture

```text
                    iBGP AS 65000

             S1 (RR)-------------S2 (RR)
              |  \  \           /  /  |
              |   \  \         /  /   |
              L1   L2   L3    L4       |
               \___ each leaf connects to both RRs ___/

        OSPF area 0 underlay | loopback iBGP overlay
```

- Two SR Linux spines are redundant route reflectors.
- Four SR Linux leaves are clients of both reflectors; leaves do not peer directly.
- OSPF provides loopback reachability over every leaf–spine link.
- Each leaf originates a unique `/24`, making route reflection and failure behavior easy to inspect.
- Every switch has SSH, JSON-RPC, HTTPS, and gNMI on a dedicated management network.
- SSH is also forwarded to localhost ports `2201`, `2202`, `2211`–`2214` for access from outside the Docker management subnet.

## Install the wrapper

Use a Python virtual environment so netlab and its Ansible dependencies do not modify system Python:

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install --upgrade pip networklab
netlab install -y ansible grpc
```

Docker Desktop WSL integration must be enabled before deployment. Confirm both commands work:

```bash
docker version
containerlab version
```

## Deploy and verify

```bash
cd enterprise-fabric
netlab create
netlab up
netlab validate
netlab report mgmt
```

The SR Linux image is public but large; the first pull can take several minutes. `netlab up` produces `hosts.yml`, `ansible.cfg`, `clab.yml`, and a topology snapshot. These are generated artifacts and should not be hand-edited.

## Use it like a managed network

```bash
# Netlab chooses SSH and credentials from its generated inventory
netlab connect S1
netlab connect L1

# Forwarded SSH port, useful from the Containerlab host
ssh -p 2201 admin@localhost

# Platform-independent show command
netlab connect L1 --show bgp summary

# Generated Ansible inventory and management-service test
ansible-inventory -i hosts.yml --graph
ansible-playbook -i hosts.yml automation/reachability.yml

# Save device configurations through netlab's Ansible workflow
netlab collect
```

Set the SR Linux credentials in `.env` before you start telemetry. Use lab-only credentials and do not expose management ports beyond a trusted host.

## Telemetry stack

Start this only after `netlab up`, because Compose joins the `netlab_mgmt` Docker network:

```bash
cp .env.example .env
docker compose -f observability/compose.yml config
docker compose -f observability/compose.yml up -d
docker compose -f observability/compose.yml logs -f telegraf
```

- Grafana: <http://localhost:3000>, using `GRAFANA_ADMIN_PASSWORD` from `.env`
- InfluxDB: <http://localhost:8086>, using `INFLUXDB_ADMIN_PASSWORD` from `.env`
- Telegraf subscribes to OpenConfig interface counters/state and BGP neighbor state over gNMI.

The Compose file binds both web ports to localhost. Grafana's InfluxDB datasource is provisioned automatically; build dashboards from the `interfaces`, `interface_state`, and `bgp_neighbors` measurements.

## Troubleshooting drills

1. Disable one leaf uplink and compare OSPF, BGP next hops, and Grafana interface counters.
2. Stop one route reflector; prove every leaf retains a session to the other RR.
3. Break OSPF authentication or area assignment on one link and work from link state to BGP symptoms.
4. Apply a route policy that rejects one leaf prefix; compare Adj-RIB-In, Loc-RIB, and reflected routes.
5. Introduce an MTU mismatch, BGP timer mismatch, or bad peer address and capture the evidence.
6. Use `netlab capture`, `netlab collect`, and Ansible before/after snapshots to document each incident.

Useful checks:

```bash
netlab graph -t bgp -f rr bgp.svg
netlab exec --show ospf neighbor
netlab exec --show bgp summary
netlab capture L1 ethernet-1/1
```

## Cleanup

```bash
docker compose -f observability/compose.yml down
netlab down --cleanup
```

Add `-v` to `docker compose down` only when you intentionally want to delete Grafana and InfluxDB lab data.
