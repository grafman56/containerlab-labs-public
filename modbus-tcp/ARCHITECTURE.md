# Architecture

The lab pairs the existing PyModbus simulator and client with the official
OpenPLC Runtime v4 image and a small dynamic tank process. The sample
simulator provides static Modbus registers and a web UI. The tank process
provides a live level register and pump coil over Modbus/TCP. The runtime
provides an IEC 61131-3 execution target, controlled and debugged from the
OpenPLC Editor. The PLC's editor API is exposed on host loopback only.

The getting-started guide explains the boundaries: the editor runs on the
engineer's PC, the runtime and tank model run as containers, and the Arduino
board is separate physical hardware. Modbus frames are real network traffic
between simulated devices, but the exercise has no physical sensors or
actuators.

The simulator uses TCP/5020 inside the topology. Only its UI is published, and
only on host loopback. This keeps the Modbus service off the LAN while leaving
the UI available through SSH forwarding.

The tank and PLC use fixed addresses on the lab's private Containerlab
management network. The Modbus ports are not published on the host or LAN.
The Editor project maps a holding register to tank level and a coil to pump
control.

General principle: keep a training lab's protocol traffic inside its topology,
and expose only the management surface needed to use it.
