"""Ansible filter for turning `ip -j addr show` into RPA-to-RPD probe rows."""


def rpa_probe_rows(interfaces, rpd_interfaces):
    """Return observed RPD-facing interface state with topology intent."""
    rows = []
    for interface in interfaces:
        interface_name = interface.get("ifname")
        if interface_name not in rpd_interfaces:
            continue

        ipv4 = [
            f"{address['local']}/{address['prefixlen']}"
            for address in interface.get("addr_info", [])
            if address.get("family") == "inet"
        ]
        flags = interface.get("flags", [])
        rows.append(
            {
                "interface": interface_name,
                "rpd": rpd_interfaces[interface_name],
                "ipv4": ipv4,
                "admin_up": "UP" in flags,
                "carrier_up": "LOWER_UP" in flags,
                "operstate": interface.get("operstate", "UNKNOWN"),
            }
        )

    return sorted(rows, key=lambda row: row["interface"])


class FilterModule:
    """Expose filters to Ansible."""

    def filters(self):
        return {"rpa_probe_rows": rpa_probe_rows}
