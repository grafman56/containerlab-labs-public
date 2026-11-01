#!/usr/bin/env python3
"""Small Modbus/TCP tank model for the OpenPLC training exercise."""

import socketserver
import struct
import threading
import time


class Tank:
    def __init__(self):
        self.lock = threading.Lock()
        self.level = 25
        self.pump = False

    def run(self):
        while True:
            time.sleep(0.25)
            with self.lock:
                self.level = max(0, min(100, self.level + (1 if self.pump else -1)))


tank = Tank()


def receive_exact(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            return None
        data.extend(chunk)
    return bytes(data)


class ModbusHandler(socketserver.BaseRequestHandler):
    def handle(self):
        while True:
            header = receive_exact(self.request, 7)
            if header is None:
                return
            transaction, protocol, length, unit = struct.unpack(">HHHB", header)
            if protocol != 0 or not 2 <= length <= 254:
                return
            pdu = receive_exact(self.request, length - 1)
            if pdu is None:
                return
            response = self.process(pdu)
            reply = struct.pack(">HHHB", transaction, 0, len(response) + 1, unit) + response
            self.request.sendall(reply)

    @staticmethod
    def process(pdu):
        function = pdu[0]
        if function in (1, 3) and len(pdu) == 5:
            address, quantity = struct.unpack(">HH", pdu[1:5])
            if address != 0 or quantity != 1:
                return bytes((function | 0x80, 2))
            with tank.lock:
                value = tank.pump if function == 1 else tank.level
            if function == 1:
                return bytes((function, 1, int(value)))
            return bytes((function, 2)) + struct.pack(">H", value)
        if function == 5 and len(pdu) == 5:
            address, value = struct.unpack(">HH", pdu[1:5])
            if address != 0:
                return bytes((function | 0x80, 2))
            if value not in (0, 0xFF00):
                return bytes((function | 0x80, 3))
            with tank.lock:
                tank.pump = value == 0xFF00
            return pdu
        return bytes((function | 0x80, 1))


class ModbusServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    threading.Thread(target=tank.run, daemon=True).start()
    with ModbusServer(("0.0.0.0", 5020), ModbusHandler) as server:
        print("Tank Modbus/TCP server listening on 0.0.0.0:5020", flush=True)
        server.serve_forever()
