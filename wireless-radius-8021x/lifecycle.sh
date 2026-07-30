#!/usr/bin/env bash
set -euo pipefail

readonly lab='wireless-radius-8021x'
readonly radius="clab-${lab}-radius"
readonly ap="clab-${lab}-ap"
readonly client="clab-${lab}-client"
readonly state_dir="/run/${lab}"
readonly source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: $0 pre-deploy|post-deploy|pre-destroy|post-destroy" >&2
  exit 2
}

[[ $# == 1 ]] || usage

write_runtime_config() {
  umask 077
  install -d -m 0700 "$state_dir"
  openssl rand -hex 24 > "$state_dir/radius-secret"
  openssl rand -hex 18 > "$state_dir/user-password"
  local radius_secret user_password
  radius_secret=$(<"$state_dir/radius-secret")
  user_password=$(<"$state_dir/user-password")

  cat > "$state_dir/clients.conf" <<EOF
client clab_host {
    ipaddr = 172.101.1.1
    secret = ${radius_secret}
}
EOF
  cat > "$state_dir/authorize" <<EOF
wireless-user Cleartext-Password := "${user_password}"
EOF
  cat > "$state_dir/hostapd.conf" <<EOF
interface=wlan0
driver=nl80211
ssid=lab-8021x
hw_mode=g
channel=1
wpa=2
wpa_key_mgmt=WPA-EAP
rsn_pairwise=CCMP
ieee8021x=1
auth_server_addr=172.101.1.10
auth_server_port=1812
auth_server_shared_secret=${radius_secret}
EOF
  cat > "$state_dir/wpa_supplicant.conf" <<EOF
ctrl_interface=/run/wpa_supplicant
network={
    ssid="lab-8021x"
    key_mgmt=WPA-EAP
    eap=PEAP
    identity="wireless-user"
    password="${user_password}"
    ca_cert="/run/ca.pem"
    phase2="auth=MSCHAPV2"
}
EOF
}

generate_session_certificates() {
  umask 077
  openssl req -x509 -new -nodes -newkey rsa:2048 \
    -keyout "$state_dir/ca.key" \
    -out "$state_dir/ca.pem" \
    -days 30 \
    -subj '/CN=wireless-radius-8021x lab CA'
  openssl req -new -nodes -newkey rsa:2048 \
    -keyout "$state_dir/server.key" \
    -out "$state_dir/server.csr" \
    -subj '/CN=radius.wireless.lab'
  cat > "$state_dir/server.ext" <<EOF
[v3_server]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:radius.wireless.lab
EOF
  openssl x509 -req \
    -in "$state_dir/server.csr" \
    -CA "$state_dir/ca.pem" \
    -CAkey "$state_dir/ca.key" \
    -CAcreateserial \
    -out "$state_dir/server.crt" \
    -days 30 \
    -sha256 \
    -extfile "$state_dir/server.ext" \
    -extensions v3_server
  cat "$state_dir/server.key" "$state_dir/server.crt" > "$state_dir/server.pem"
}

radius_config_dir() {
  docker exec "$radius" sh -c '
    for candidate in /etc/freeradius/3.2 /etc/freeradius/3.0 /etc/freeradius /etc/raddb; do
      if [ -d "$candidate" ]; then
        printf "%s" "$candidate"
        exit 0
      fi
    done
    exit 1
  '
}

case "$1" in
  pre-deploy)
    [[ ! -e "$state_dir" ]] || { echo "$state_dir already exists" >&2; exit 1; }
    ! lsmod | awk '{print $1}' | grep -qx mac80211_hwsim || {
      echo 'mac80211_hwsim is already loaded; preserve the existing lab' >&2
      exit 1
    }
    docker build --tag wireless-lab-tools:1.0.0 "$source_dir"
    modprobe mac80211_hwsim radios=2
    [[ -d /sys/class/net/wlan0 && -d /sys/class/net/wlan1 ]] || {
      modprobe -r mac80211_hwsim
      echo 'mac80211_hwsim did not create wlan0 and wlan1' >&2
      exit 1
    }
    write_runtime_config
    generate_session_certificates
    ;;
  post-deploy)
    [[ -f "$state_dir/radius-secret" ]] || { echo 'missing pre-deploy state' >&2; exit 1; }
    radius_dir=$(radius_config_dir) || {
      echo 'could not find the FreeRADIUS configuration directory' >&2
      exit 1
    }
    docker cp "$state_dir/clients.conf" "$radius:${radius_dir}/clients.conf"
    docker cp "$state_dir/authorize" "$radius:${radius_dir}/mods-config/files/authorize"
    docker cp "$state_dir/ca.pem" "$radius:${radius_dir}/certs/ca.pem"
    docker cp "$state_dir/server.pem" "$radius:${radius_dir}/certs/server.pem"
    docker exec "$radius" chown 101:101 \
      "${radius_dir}/clients.conf" \
      "${radius_dir}/mods-config/files/authorize" \
      "${radius_dir}/certs/ca.pem" \
      "${radius_dir}/certs/server.pem"
    docker exec "$radius" freeradius -XC
    docker exec -d "$radius" sh -c 'freeradius -X > /run/freeradius.log 2>&1'
    docker cp "$state_dir/hostapd.conf" "$ap:/run/hostapd.conf"
    docker cp "$state_dir/wpa_supplicant.conf" "$client:/run/wpa_supplicant.conf"
    docker cp "$state_dir/ca.pem" "$client:/run/ca.pem"
    docker exec -d "$ap" sh -c 'hostapd -dd /run/hostapd.conf > /run/hostapd.log 2>&1'
    docker exec -d "$client" sh -c 'wpa_supplicant -dd -i wlan1 -c /run/wpa_supplicant.conf > /run/wpa_supplicant.log 2>&1'
    ;;
  pre-destroy)
    docker exec "$ap" pkill hostapd 2>/dev/null || true
    docker exec "$client" pkill wpa_supplicant 2>/dev/null || true
    docker exec "$radius" pkill freeradius 2>/dev/null || true
    ;;
  post-destroy)
    [[ -d "$state_dir" ]] || { echo "missing $state_dir" >&2; exit 1; }
    modprobe -r mac80211_hwsim
    rm -rf "$state_dir"
    ;;
  *) usage ;;
esac
