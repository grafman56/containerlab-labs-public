# One image for every identity-lab role.
#
# Separate images per role would mean separate builds to keep in step, and the
# package sets overlap almost completely. The roles are chosen by which config
# the node is given, not by which image it runs:
#
#   nac / fed / idp-remote   FreeRADIUS
#   edge-a1                  hostapd, driver=wired  (wired 802.1X)
#   ap-a1                    hostapd, driver=nl80211 (WPA2-Enterprise over the air)
#   sta-*                    wpa_supplicant, wired and wireless
#   ddi                      Kea DHCP + BIND9  ("BlueCat" stand-in)
#
# Every node therefore also has tcpdump and iproute2, which is the point: you
# can capture on any hop without rebuilding anything.
FROM debian:12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      freeradius \
      freeradius-utils \
      hostapd \
      wpasupplicant \
      iw \
      wireless-tools \
      kea-dhcp4-server \
      bind9 \
      bind9-utils \
      bind9-dnsutils \
      iproute2 \
      bridge-utils \
      tcpdump \
      iputils-ping \
      isc-dhcp-client \
      isc-dhcp-relay \
      procps \
      nftables \
      jq \
      python3-minimal \
      openssl \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Both ship masked or auto-started on Debian; the lab drives them by hand so
# that every start is visible in a log you asked for.
# Keep pristine copies of the certificate templates. start-radius.sh rewrites
# them per institution, and editing an already-edited file is how you end up
# with "invalid type in 'policy' configuration".
RUN for f in server.cnf ca.cnf; do \
      cp "/etc/freeradius/3.0/certs/$f" "/etc/freeradius/3.0/certs/$f.orig"; \
    done

# Generate the Diffie-Hellman parameters once, here, instead of on every
# deploy. They are not secret and not per-institution, and a 2048-bit safe
# prime takes long enough that a node looks hung while it works.
RUN cd /etc/freeradius/3.0/certs && make dh && cp dh dh.orig

RUN rm -f /etc/hostapd/hostapd.conf \
    && find /etc/systemd -name 'freeradius*' -delete 2>/dev/null || true

CMD ["sleep", "infinity"]
