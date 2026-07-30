# Wireless RADIUS and 802.1X Lab

This lab teaches the enterprise access pattern: a supplicant joins an AP, the
AP relays EAP to RADIUS, and RADIUS returns the access decision. It uses two
virtual radios from the host `mac80211_hwsim` kernel module, `hostapd`,
`wpa_supplicant`, and FreeRADIUS 3.2.7.

The lab validates WPA2-Enterprise PEAP with MSCHAPv2. It is a safe first step
before EAP-TLS, certificate lifecycle, dynamic VLANs, MAB, and physical AP
controller work.

The supplicant validates the FreeRADIUS test CA. The certificate chain exists
only for this lab and must not be reused outside it.

## Scope and limits

This is an authentication lab. It does not simulate RF power, channel overlap,
roaming, RRM, vendor controller behavior, or a switch port-security ASIC.
It generates an ephemeral RADIUS shared secret and user password under `/run`.
It does not store credentials in Git.

The AP and supplicant share the Containerlab host network namespace so they can
use the two simulated radios. The lifecycle script owns the kernel module and
refuses to run if another hwsim lab is active.

The lifecycle script detects the configuration root in the pinned FreeRADIUS
image. It supports image layouts under `/etc/freeradius` or `/etc/raddb`.

## Deploy and remove

The lifecycle script changes host kernel state. Run this lab only on a dedicated host with no other `mac80211_hwsim` user.

```bash
cd wireless-radius-8021x
sudo ./lifecycle.sh pre-deploy
sudo containerlab deploy -t wireless-radius-8021x.clab.yml
sudo ./lifecycle.sh post-deploy
sudo ./verify.sh
sudo ./lifecycle.sh pre-destroy
sudo containerlab destroy -t wireless-radius-8021x.clab.yml --cleanup
sudo ./lifecycle.sh post-destroy
```

## Verification

The deploy task succeeds only when `verify.sh` finds both the supplicant EAP
success event and a FreeRADIUS `Access-Accept`. For investigation, capture
EAPOL on `wlan0` or `wlan1`, and capture UDP 1812 from the AP namespace.

```bash
tcpdump -nni wlan0 ether proto 0x888e
tcpdump -nni any udp port 1812
```

Run the fixed destroy template after each session. It is the only supported
cleanup path.
