#!/usr/bin/env python3
import sys
import time

from pymodbus.client import ModbusTcpClient


host = sys.argv[1]
client = ModbusTcpClient(host, port=5020, timeout=3)
if not client.connect():
    raise SystemExit(f"Could not connect to tank at {host}:5020")

try:
    response = client.read_holding_registers(0, count=1, device_id=1)
    if response.isError():
        raise SystemExit(f"Could not read tank level: {response}")
    start = response.registers[0]
    response = client.write_coil(0, True, device_id=1)
    if response.isError():
        raise SystemExit("Could not turn on the simulated pump")
    time.sleep(0.8)
    response = client.read_holding_registers(0, count=1, device_id=1)
    if response.isError():
        raise SystemExit(f"Could not read tank level: {response}")
    rising = response.registers[0]
    if rising <= start:
        raise SystemExit(f"Tank level did not rise with pump on: {start} -> {rising}")
    response = client.write_coil(0, False, device_id=1)
    if response.isError():
        raise SystemExit("Could not turn off the simulated pump")
    time.sleep(0.8)
    response = client.read_holding_registers(0, count=1, device_id=1)
    if response.isError():
        raise SystemExit(f"Could not read tank level: {response}")
    falling = response.registers[0]
    if falling >= rising:
        raise SystemExit(f"Tank level did not fall with pump off: {rising} -> {falling}")
    print(f"Tank level follows pump: {start} -> {rising} -> {falling}")
finally:
    client.close()
