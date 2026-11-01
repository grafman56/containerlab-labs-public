#!/usr/bin/env python3
import sys

from pymodbus.client import ModbusTcpClient

host = sys.argv[1] if len(sys.argv) > 1 else "192.0.2.1"
client = ModbusTcpClient(host, port=5020, timeout=3)

if not client.connect():
    raise SystemExit(f"Could not connect to {host}:5020")

try:
    for label, method, field, expected in (
        ("Coils", client.read_coils, "bits", [True, False]),
        ("Discrete inputs", client.read_discrete_inputs, "bits", [True, False]),
        ("Holding registers", client.read_holding_registers, "registers", [120, 60]),
        ("Input registers", client.read_input_registers, "registers", [230, 42]),
    ):
        response = method(address=0, count=2, device_id=1)
        if response.isError():
            raise SystemExit(f"{label}: Modbus exception: {response}")
        values = getattr(response, field)[:2]
        print(f"{label} 0-1: {values}")
        if values != expected:
            raise SystemExit(f"{label}: expected {expected}, got {values}")
finally:
    client.close()
