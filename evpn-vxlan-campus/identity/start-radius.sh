#!/usr/bin/env bash
# usage: start-radius.sh <ip/cidr> <role-dir> [--eap]
#
# Starts one FreeRADIUS instance in foreground debug mode, logging to
# /tmp/radius.log. Debug mode on purpose: the log is the teaching surface, and
# it shows the full attribute set of every request and reply.
set -uo pipefail
addr=$1
role=$2
eap=${3:-}

# The realm this server owns, used for its certificate name.
case "$role" in
  nac)        realm=campus.edu ;;
  idp-remote) realm=remote.edu ;;
  *)          realm=lab.invalid ;;
esac

/cfg/wait-for-link.sh eth1

ip address replace "$addr" dev eth1
ip link set eth1 up
ip route replace 10.0.0.0/8 via "${addr%.*}.1"

# Announce ourselves before anyone asks. With ARP suppression on, the leaf
# answers ARP out of the EVPN type-2 routes and never floods -- so an endpoint
# that has never spoken has no type-2, and is unreachable from any other leaf.
# A real server is chatty and this happens by itself; an idle lab node is not.
# This is the "silent host" failure mode, and it is worth causing on purpose
# once: comment this out and watch RADIUS time out instead of fail.
nohup /cfg/keepalive.sh "${addr%.*}.1" >/dev/null 2>&1 &
sleep 2

cp "/cfg/${role}/clients.conf" /etc/freeradius/3.0/clients.conf
cp "/cfg/${role}/proxy.conf"   /etc/freeradius/3.0/proxy.conf
cp "/cfg/${role}/authorize"    /etc/freeradius/3.0/mods-config/files/authorize

# Only the servers that terminate an EAP tunnel need a certificate. The
# roaming-operator proxy never does: it forwards EAP it cannot read.
#
# Each institution generates its OWN CA here, which is the real situation. It
# is also why a client must be told which CA and which server name to expect
# -- eduroam CAT and MDM exist to deliver exactly that, and a client that
# trusts "any valid cert" is the one an evil twin harvests credentials from.
if [ "$eap" = "--eap" ]; then
  # Give the certificate a realistic name before generating it. Debian's
  # bootstrap produces CN=localhost, which works but teaches the wrong thing:
  # a supplicant cannot usefully pin "localhost". Naming it after the
  # institution is what makes ca_cert plus domain_suffix_match meaningful on
  # the client, and that pair is the only thing standing between a user and an
  # evil twin SSID harvesting their credentials.
  # Name the certificate after the institution. Section-aware, because
  # server.cnf has three commonName lines and two of them are CA policy
  # directives (`commonName = supplied`); rewriting those breaks signing with
  # the gloriously unhelpful "invalid type in 'policy' configuration".
  #
  # Always start from the pristine template stashed in the image, so running
  # this twice is the same as running it once.
  REALM="$realm" python3 - <<'CERTCNF'
import os
realm = os.environ["REALM"]
base = "/etc/freeradius/3.0/certs/"

def patch(fn, cn, section="[server]"):
    src = open(base + fn + ".orig").read().split("\n")
    out, cur = [], None
    for line in src:
        t = line.strip()
        if t.startswith("[") and t.endswith("]"):
            cur = t.replace(" ", "")
        if cur == section.replace(" ", ""):
            if line.split("=")[0].strip() == "commonName":
                line = 'commonName\t\t= "%s"' % cn
            elif line.split("=")[0].strip() == "emailAddress":
                line = "emailAddress\t\t= admin@%s" % realm
        if cur == "[alt_names]" and line.split("=")[0].strip() == "DNS.1":
            line = "DNS.1 = %s" % cn
        out.append(line)
    open(base + fn, "w").write("\n".join(out))

# A SAN matters: wpa_supplicant's domain_suffix_match prefers dNSName, and a
# certificate with only a CN is the kind of thing that works until a client
# gets strict about it.
patch("server.cnf", "radius." + realm)
patch("ca.cnf", "ca." + realm, section="[certificate_authority]")
CERTCNF

  # Point EAP at the certificate we just generated.
  #
  # Debian's freeradius package ships the eap module pointing at the SNAKEOIL
  # certificate -- /etc/ssl/certs/ssl-cert-snakeoil.pem, CN=localhost -- and
  # ca_file at the system trust store. EAP then works perfectly, right up
  # until a client actually verifies the server, at which point it fails with
  # "unknown CA" from the client and nothing useful on the server.
  #
  # That is worth dwelling on, because eduroam REQUIRES clients to pin the CA
  # and the server name. A campus that never configures supplicant profiles
  # properly will never notice this is wrong, and the devices that do verify
  # are the ones protected from an evil twin. Shipping snakeoil means every
  # client is trained to accept any certificate.
  sed -i \
    -e 's|^\([[:space:]]*\)private_key_file = .*|\1private_key_file = ${certdir}/server.pem|' \
    -e 's|^\([[:space:]]*\)certificate_file = .*|\1certificate_file = ${certdir}/server.pem|' \
    -e 's|^\([[:space:]]*\)ca_file = .*|\1ca_file = ${certdir}/ca.pem|' \
    /etc/freeradius/3.0/mods-enabled/eap

  # Let the inner reply out of the tunnel -- BUT ONLY AT THE SERVICE PROVIDER.
  #
  # With PEAP the authorization comes back from the inner-tunnel virtual
  # server, Tunnel-Private-Group-ID included, which is the whole dynamic VLAN
  # mechanism. Debian ships `use_tunneled_reply = no`, so those attributes are
  # DISCARDED: authentication succeeds, the client associates, everything
  # looks healthy, and the station silently sits in the access point's default
  # VLAN instead of the one the NAC chose. Nothing logs an error, because
  # nothing went wrong -- the attributes were simply never asked for.
  #
  # Now the part that is easy to get wrong. Turning this on at an IDENTITY
  # PROVIDER has a different effect: the inner reply includes User-Name, so
  # the home institution copies the real username into the Access-Accept and
  # hands it to every visited site it ever roams to. That defeats the
  # anonymous outer identity it was so careful about -- the username does not
  # travel in the clear on the way in, and then walks out in the reply.
  #
  # So: the SP needs it, to act on its own local VLAN decision. The IdP must
  # not have it. verify-identity.sh catches the mistake.
  # Set it explicitly either way. Skipping the edit is not the same as setting
  # it to no: the file persists in the container, so a node that was once
  # started in another role keeps the old value.
  if [ "$role" = "nac" ]; then tunreply=yes; else tunreply=no; fi
  sed -i "s|^\\([[:space:]]*\\)use_tunneled_reply = .*|\\1use_tunneled_reply = ${tunreply}|" \
    /etc/freeradius/3.0/mods-enabled/eap

  # Non-fatal on purpose: a server with no certificate still starts and still
  # proxies, and failing the whole node here would hide that from you.
  # Always build from scratch.
  #
  # Re-running the bootstrap over a certs directory that already has output
  # gives you a MISMATCHED set: the Makefile rebuilds some artifacts and not
  # others, so you end up with a server certificate signed by a CA key that
  # no longer matches ca.pem -- while both still carry the same subject DN.
  # The error is "unable to get local issuer certificate", which sends you
  # looking at the client. `openssl verify -CAfile ca.pem server.pem` failing
  # on the server itself is the quickest way to prove it is not the client.
  # destroycerts also removes dh, and regenerating a 2048-bit safe prime on
  # every deploy makes the node look hung for minutes. Keep the one baked
  # into the image.
  ( cd /etc/freeradius/3.0/certs \
      && make destroycerts >/dev/null 2>&1 \
      && cp dh.orig dh ) || true

  if ! ( cd /etc/freeradius/3.0/certs && make >/tmp/certs.log 2>&1 ); then
    echo "WARNING: certificate generation failed, see /tmp/certs.log" >&2
  fi

  # The bootstrap writes the certificates as root, but freeradius drops to the
  # freerad user before it reads them, so EAP dies with
  # "Failed reading certificate file ... Permission denied" and the module
  # fails to instantiate. Debian's Makefile only fixes up server.key.
  chgrp -R freerad /etc/freeradius/3.0/certs 2>/dev/null || true
  chmod -R g+rX    /etc/freeradius/3.0/certs 2>/dev/null || true

  # Publish this institution's CA where the supplicants can pin it. Each
  # institution has its OWN CA, which is the real situation -- eduroam CAT and
  # MDM exist to deliver the right one to devices nobody administers.
  cp /etc/freeradius/3.0/certs/ca.pem "/cfg/sta/${role}-ca.pem" 2>/dev/null || true
fi

# The visited site decides where a visitor lands.
#
# idp-remote deliberately returns no VLAN: a home institution does not get to
# choose a segment on someone else's campus. So the Service Provider has to
# assign one locally, which is exactly what a ClearPass enforcement policy
# does. Anything that was proxied -- i.e. not our own realm -- goes to the
# visitor VLAN, and that decision is made here, after the proxy reply comes
# back, not by the far end.
if [ "$role" = "nac" ]; then
  python3 - <<'POSTAUTH'
p = '/etc/freeradius/3.0/sites-enabled/default'
lines = open(p).read().split('\n')
snippet = [
 '\tif (&Realm && &Realm != "campus.edu") {',
 '\t\tupdate reply {',
 '\t\t\t&Tunnel-Type := VLAN',
 '\t\t\t&Tunnel-Medium-Type := IEEE-802',
 '\t\t\t&Tunnel-Private-Group-Id := "30"',
 '\t\t}',
 '\t}',
]
if '&Tunnel-Private-Group-Id := "30"' not in '\n'.join(lines):
    for i, l in enumerate(lines):
        if l.strip() == 'post-auth {':
            lines[i+1:i+1] = snippet
            break
    open(p, 'w').write('\n'.join(lines))
POSTAUTH
fi

exec freeradius -X > /tmp/radius.log 2>&1
