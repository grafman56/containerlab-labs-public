# Modbus TCP lab

This lab contains a PyModbus simulator and client, an OpenPLC Runtime v4 soft
PLC, and a dynamic tank process. The sample simulator and client use
`192.0.2.1` and `192.0.2.2`. The tank process is `172.100.120.10`; the PLC is
`172.100.120.11`. Both Modbus servers listen on TCP/5020 inside the lab. The
simulator UI is at `http://127.0.0.1:8502`. The OpenPLC Editor connects to the
PLC at `https://127.0.0.1:8443` through an SSH tunnel.

## Requirements

**New to the lab? Start with [GETTING_STARTED.md](GETTING_STARTED.md).** It
shows which parts are simulations, how the PLC and tank exchange data, and
how to run the first control exercise.

- Containerlab and Docker on the lab host
- Ansible on the control host
- Access to the `containerlab_hosts` inventory

## Lifecycle

Deploy, verify, and destroy with the repository driver:

```bash
./labctl up modbus-tcp        # builds the simulator image, deploys, runs verify.sh
./labctl down modbus-tcp      # destroys only this topology
```

If you change the topology, destroy this lab through the playbook before you
deploy it again. Containerlab 0.77 does not apply changed node lists in place.

## Read registers and capture traffic

Run the sample client, which reads two values from all four Modbus data blocks:

```bash
ssh user@containerlab-host \
  'docker exec clab-modbus-tcp-client python /lab/client.py 192.0.2.1'
```

Use EdgeShark/Wireshark to capture on `client` interface `eth1`, with display
filter `tcp.port == 5020`. Or capture in the client container:

```bash
ssh user@containerlab-host \
  'docker exec clab-modbus-tcp-client tcpdump -i eth1 -w /tmp/modbus.pcap tcp port 5020'
```

The simulator UI is bound to localhost on the Containerlab host, so reach it
through an SSH tunnel:

```bash
ssh -L 8502:127.0.0.1:8502 -L 8443:127.0.0.1:8443 \
  user@containerlab-host
```

Then open `http://127.0.0.1:8502`. The lab does not expose Modbus TCP to the
LAN.

The Runtime v4 API is not a browser HMI. Use the OpenPLC Editor to create,
upload, run, and debug IEC 61131-3 programs. Its HTTPS port is published on
localhost only. Destroying and recreating the topology removes the runtime's
program and users.
