#!/usr/bin/env bash
# Public Ubuntu/Debian OpenVPN hub; no student Linux accounts or GPU packages.
set -Eeuo pipefail
umask 077
BASE=/etc/openvpn/server/ids-hub
PKI_HOME=/root/ids-openvpn
PROFILES=/root/ids-vpn-profiles
HUB_CONF=/etc/openvpn/server/ids-hub.conf
HUB_SERVICE=openvpn-server@ids-hub
PUBLIC_HOST=''
PORT=443
TRANSPORT=tcp
DCO_DIRECTIVE=disable-dco

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
valid_name() { [[ "$1" =~ ^[a-z][a-z0-9_-]{2,30}$ && "$1" != servidor && "$1" != labpc ]]; }
valid_host() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ && "$1" != *..* && ${#1} -le 253 ]]; }
validate_endpoint() {
  valid_host "$PUBLIC_HOST" || die 'Use a public IPv4 address or DNS hostname, without a scheme or port.'
  [[ "$PORT" =~ ^[0-9]{1,5}$ ]] && (( 10#$PORT > 0 && 10#$PORT <= 65535 )) || die 'Invalid port.'
  [[ "$TRANSPORT" == tcp || "$TRANSPORT" == udp ]] || die 'Transport must be tcp or udp.'
}
usage() {
  cat <<'EOF'
On the PUBLIC Ubuntu/Debian server (OpenVPN >= 2.5):
  sudo bash install_hub.sh init PUBLIC_HOST [PORT=443] [tcp|udp]
  sudo bash install_hub.sh add-student USERNAME
  sudo bash install_hub.sh revoke USERNAME
  sudo bash install_hub.sh renew-crl
  sudo bash install_hub.sh status
Run init once. It creates a separate encrypted CA and an unattended labpc profile.
Student private keys are encrypted; Easy-RSA prompts for their passphrases.
No existing OpenVPN instance, firewall ruleset or Linux account is replaced.
VPN subnet: 10.77.0.0/24; lab PC: 10.77.0.2; student pool: .10-.250.
Ensure this subnet does not overlap either site's or any client's networks.
EOF
}
render_server() {
  local proto="$TRANSPORT"
  [[ "$proto" != tcp ]] || proto=tcp-server
  cat <<EOF
port $PORT
proto $proto
dev tunids
dev-type tun
topology subnet
server 10.77.0.0 255.255.255.0 nopool
ifconfig-pool 10.77.0.10 10.77.0.250 255.255.255.0
client-config-dir $BASE/ccd
ccd-exclusive
ca $BASE/ca.crt
cert $BASE/servidor.crt
key $BASE/servidor.key
crl-verify $BASE/crl.pem
tls-crypt $BASE/tls-crypt.key
dh none
tls-version-min 1.2
remote-cert-tls client
verify-client-cert require
data-ciphers AES-256-GCM:AES-128-GCM
$DCO_DIRECTIVE
keepalive 10 60
persist-key
persist-tun
user nobody
group nogroup
verb 3
# No client-to-client: inter-client traffic MUST traverse the kernel firewall.
# No redirect-gateway, NAT or routes to the institutional LAN.
EOF
}
render_firewall() {
  cat <<'EOF'
add table inet ids_vpn
flush table inet ids_vpn
table inet ids_vpn {
  chain input {
    type filter hook input priority -10; policy accept;
    iifname "tunids" drop
  }
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "tunids" oifname "tunids" ip saddr 10.77.0.0/24 ip daddr 10.77.0.2 tcp dport 22 ct state new,established accept
    iifname "tunids" oifname "tunids" ip saddr 10.77.0.2 ip daddr 10.77.0.0/24 tcp sport 22 ct state established accept
    iifname "tunids" drop
    oifname "tunids" drop
  }
}
EOF
}
load_endpoint() {
  [[ -s "$PKI_HOME/endpoint" ]] || die 'Initialize the hub first.'
  read -r PUBLIC_HOST PORT TRANSPORT < "$PKI_HOME/endpoint"
  validate_endpoint
}
export_profile() {
  local name="$1" proto="$TRANSPORT" tmp
  [[ "$proto" != tcp ]] || proto=tcp-client
  [[ ! -e "$PROFILES/$name.ovpn" ]] || die 'Profile already exists; it will not be overwritten.'
  tmp=$(mktemp "$PROFILES/.profile.XXXXXXXX")
  {
    cat <<EOF
client
dev tun
proto $proto
remote $PUBLIC_HOST $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name servidor name
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM
auth-nocache
verb 3
<ca>
EOF
    cat "$BASE/ca.crt"
    printf '</ca>\n<cert>\n'
    openssl x509 -in "$PKI_HOME/pki/issued/$name.crt" -outform PEM
    printf '</cert>\n<key>\n'
    cat "$PKI_HOME/pki/private/$name.key"
    printf '\n</key>\n<tls-crypt>\n'
    cat "$BASE/tls-crypt.key"
    printf '\n</tls-crypt>\n'
  } > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$PROFILES/$name.ovpn"
  printf 'Private profile: %s/%s.ovpn\n' "$PROFILES" "$name"
}
publish_crl() {
  (cd "$PKI_HOME"; EASYRSA_CRL_DAYS=180 ./easyrsa gen-crl)
  local tmp
  tmp=$(mktemp "$BASE/.crl.XXXXXXXX")
  install -m 644 "$PKI_HOME/pki/crl.pem" "$tmp"
  mv "$tmp" "$BASE/crl.pem"
}
init_hub() {
  PUBLIC_HOST="$1"; PORT="${2:-443}"; TRANSPORT="${3:-tcp}"
  validate_endpoint
  . /etc/os-release
  [[ "$ID" == ubuntu || "$ID" == debian ]] || die 'Hub installer supports Ubuntu/Debian.'
  [[ ! -e "$HUB_CONF" && ! -e "$BASE" && ! -e "$PKI_HOME" && ! -e "$PROFILES" ]] || die 'Hub material already exists. Preserve it; do not reinitialize the CA.'
  if command -v ss >/dev/null && [[ -n "$(ss -H -ln"${TRANSPORT:0:1}" "sport = :$PORT")" ]]; then
    die "Port $PORT/$TRANSPORT is already in use. Choose a free port."
  fi
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y openvpn easy-rsa nftables openssl iproute2
  local version
  version=$(openvpn --version | sed -n '1s/^OpenVPN \([^ ]*\).*/\1/p')
  dpkg --compare-versions "$version" ge 2.5 || die 'OpenVPN >= 2.5 is required.'
  # 2.5 has no DCO; newer releases must disable it to enforce kernel filtering.
  if ! openvpn --help | grep -- --disable-dco >/dev/null; then
    DCO_DIRECTIVE='# OpenVPN 2.5: no DCO support'
  fi
  install -d -m 755 "$BASE" "$BASE/ccd"
  install -d -m 700 "$PKI_HOME" "$PROFILES"
  cp -a /usr/share/easy-rsa/. "$PKI_HOME/"
  printf '%s %s %s\n' "$PUBLIC_HOST" "$PORT" "$TRANSPORT" > "$PKI_HOME/endpoint"
  (
    cd "$PKI_HOME"
    ./easyrsa init-pki
    echo 'Choose and securely record the encrypted CA passphrase.'
    EASYRSA_REQ_CN=IDS-Remote-Hub EASYRSA_BATCH=1 ./easyrsa build-ca
    EASYRSA_BATCH=1 ./easyrsa build-server-full servidor nopass
    EASYRSA_BATCH=1 ./easyrsa build-client-full labpc nopass
  )
  install -m 644 "$PKI_HOME/pki/ca.crt" "$BASE/ca.crt"
  install -m 644 "$PKI_HOME/pki/issued/servidor.crt" "$BASE/servidor.crt"
  install -m 600 "$PKI_HOME/pki/private/servidor.key" "$BASE/servidor.key"
  openvpn --genkey tls-crypt "$BASE/tls-crypt.key"
  chmod 600 "$BASE/tls-crypt.key"
  publish_crl
  printf 'ifconfig-push 10.77.0.2 255.255.255.0\n' > "$BASE/ccd/labpc"
  chmod 644 "$BASE/ccd/labpc"
  render_server > "$HUB_CONF"
  render_firewall > "$BASE/firewall.nft"
  nft --check --file "$BASE/firewall.nft"
  cat > /etc/systemd/system/ids-vpn-firewall.service <<EOF
[Unit]
Description=IDS VPN forwarding restrictions
After=nftables.service ufw.service
Before=$HUB_SERVICE.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f $BASE/firewall.nft
[Install]
WantedBy=multi-user.target
EOF
  install -d -m 755 /etc/systemd/system/"$HUB_SERVICE.service.d"
  cat > /etc/systemd/system/"$HUB_SERVICE.service.d"/firewall.conf <<'EOF'
[Unit]
Requires=ids-vpn-firewall.service
After=ids-vpn-firewall.service
EOF
  printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/90-ids-vpn.conf
  sysctl -p /etc/sysctl.d/90-ids-vpn.conf
  systemctl daemon-reload
  systemctl enable --now ids-vpn-firewall.service "$HUB_SERVICE"
  export_profile labpc
  echo "Allow inbound $PORT/$TRANSPORT in the host and provider/router firewalls."
  echo 'Existing forward chains must also permit tunids -> tunids TCP 22 to 10.77.0.2 and established replies.'
  echo 'Securely transfer labpc.ovpn to the lab PC, then run install_lab.sh there.'
}
main() {
  case "${1:---help}" in -h|--help) usage; return ;; esac
  [[ "$EUID" -eq 0 ]] || die 'Run with sudo.'
  exec 9>/run/lock/ids-hub.lock
  flock -n 9 || die 'Another hub operation is running.'
  case "$1" in
    init) [[ $# -ge 2 && $# -le 4 ]] || die 'Usage: init PUBLIC_HOST [PORT] [tcp|udp]'; init_hub "${@:2}" ;;
    add-student)
      [[ $# == 2 ]] && valid_name "$2" || die 'Use a lowercase student name (3-31 characters); labpc and servidor are reserved.'
      load_endpoint
      [[ ! -e "$PKI_HOME/pki/issued/$2.crt" && ! -e "$PKI_HOME/pki/private/$2.key" && ! -e "$BASE/ccd/$2" && ! -e "$PROFILES/$2.ovpn" ]] || die 'Identity already exists; use a new name.'
      (cd "$PKI_HOME"; EASYRSA_BATCH=1 ./easyrsa build-client-full "$2")
      export_profile "$2"
      install -m 644 /dev/null "$BASE/ccd/$2"
      ;;
    revoke)
      [[ $# == 2 ]] && { valid_name "$2" || [[ "$2" == labpc ]]; } || die 'Usage: revoke USERNAME (or labpc)'
      load_endpoint
      (cd "$PKI_HOME"; EASYRSA_BATCH=1 ./easyrsa revoke "$2")
      publish_crl
      systemctl restart "$HUB_SERVICE"
      echo 'Certificate revoked. Restart disconnected all VPN clients; lock the Linux account on the lab PC separately.'
      ;;
    renew-crl) [[ $# == 1 ]] || die 'No extra arguments.'; load_endpoint; publish_crl ;;
    status)
      systemctl --no-pager status "$HUB_SERVICE" ids-vpn-firewall.service
      openssl crl -in "$BASE/crl.pem" -noout -nextupdate
      nft list table inet ids_vpn
      ;;
    *) usage; return 1 ;;
  esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
