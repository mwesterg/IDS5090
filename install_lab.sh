#!/usr/bin/env bash
# Lab PC: outbound OpenVPN client plus local SSH/X2Go student accounts.
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/install_server.sh"

main_lab() {
  if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    echo 'Usage: sudo bash install_lab.sh /secure/path/labpc.ovpn'
    echo 'Run on the Pop!_OS/Ubuntu lab PC. Connects outbound to the public hub.'
    echo 'Migrates an unchanged installer-managed SSH snippet to 10.77.0.0/24 with a backup.'
    return
  fi
  [[ $# == 1 && -s "$1" ]] || die 'Provide the labpc.ovpn profile generated on the public hub.'
  [[ "$EUID" == 0 ]] || die 'Run with sudo on the lab PC.'
  . /etc/os-release
  [[ "$ID" == pop || "$ID" == ubuntu ]] || die 'Lab installer supports Pop!_OS/Ubuntu.'
  [[ "$VERSION_ID" == 22.04 || "$VERSION_ID" == 24.04 ]] || die 'Supported lab releases: 22.04/24.04.'
  local profile dest=/etc/openvpn/client/ids-lab.conf
  profile=$(realpath -- "$1")
  # Profiles are privileged OpenVPN configuration: accept only the trusted hub export.
  grep -Fxq client "$profile" || die 'Not a client profile.'
  grep -Fxq 'verify-x509-name servidor name' "$profile" || die 'Unexpected hub identity.'
  grep -q 'BEGIN ENCRYPTED PRIVATE KEY' "$profile" && die 'Use the unattended labpc profile, not a student profile.'
  if [[ -e "$dest" ]]; then
    cmp -s "$profile" "$dest" || die "A different $dest exists; review it before replacement."
  fi
  exec 9>/run/lock/ids-usuarios.lock
  flock -n 9 || die 'Another installer/account manager is running.'
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    openvpn openssh-server openssl x2goserver x2goserver-xsession \
    xfce4-session xfce4-panel xfwm4 xfdesktop4 xfce4-settings xfce4-terminal \
    thunar xfce4-appfinder dbus-x11 xauth x11-apps x11-xserver-utils \
    python3 python3-venv python3-pip
  install -d -m 755 /etc/openvpn/client
  if [[ "$profile" != "$dest" ]]; then install -m 600 "$profile" "$dest"; fi
  configure_student_network 10.77.0.0/24 --migrate-managed
  systemctl enable --now openvpn-client@ids-lab
  echo 'Lab VPN service started; confirm the tunnel actually connected:'
  ip -4 -brief address
  journalctl -u openvpn-client@ids-lab -n 20 --no-pager
  echo 'Expected lab VPN address: 10.77.0.2. Service startup alone does not prove connectivity.'
  echo 'Permit TCP 22 from 10.77.0.0/24 on the VPN interface in the lab firewall.'
  echo 'Create Linux accounts here with: sudo bash usr_mgr.sh --linux-only --import usuarios.txt'
  echo 'Create corresponding VPN certificates separately on the hub with install_hub.sh add-student.'
  echo 'Existing Tailscale and legacy OpenVPN services were left running; retire them after testing the new path.'
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main_lab "$@"; fi
