#!/usr/bin/env bash
# Existing public WireGuard hub -> lab peer -> SSH/X2Go; no hub changes here.
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/remote_access.sh"

wireguard_usage() {
  cat <<'EOF'
Usage:
  sudo bash install_wireguard.sh --prepare
  bash install_wireguard.sh --check-config /secure/lab.conf --student-network VPN_CIDR
  sudo bash install_wireguard.sh --install /secure/lab.conf --student-network VPN_CIDR [--interface ids-wg]
  sudo bash install_wireguard.sh --status [--interface ids-wg]

--prepare installs dependencies only; no WireGuard config or SSH policy changes.
--check-config validates locally without root, execution of hooks or key output.
--install installs a private profile and configures SSH/X2Go; DOES NOT start VPN.
The CIDR is the actual student source network SSH sees, not the public endpoint.
After reviewing routes: sudo systemctl enable --now wg-quick@ids-wg
Requires Pop!_OS/Ubuntu 22.04/24.04. Does not configure the public hub or student peers.
EOF
}

wireguard_target() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,14}$ ]] || die 'Invalid WireGuard interface name (1-15 characters).'
  printf '/etc/wireguard/%s.conf\n' "$1"
}

wireguard_install_profile() {
  local profile="$1" dest="$2"
  [[ ! -L "$dest" ]] || die 'Refusing a symbolic-link destination.'
  if [[ -e "$dest" ]]; then
    cmp -s -- "$profile" "$dest" || die 'A different WireGuard profile already exists; review it before replacement.'
    chown root:root "$dest"
    chmod 600 "$dest"
  else
    install -o root -g root -m 600 -- "$profile" "$dest"
  fi
}

wireguard_status() {
  local interface="$1" bad=0
  systemctl --no-pager is-active "wg-quick@$interface" || bad=1
  ip -brief address show dev "$interface" || bad=1
  # Never use showconf or dump: they can disclose private/preshared keys.
  wg show "$interface" latest-handshakes | python3 -c '
import sys, time
rows = [line.split() for line in sys.stdin if line.strip()]
if not rows:
    print("No peer handshake information available")
    sys.exit(1)
stale = False
for index, row in enumerate(rows, 1):
    age = int(time.time()) - int(row[1]) if int(row[1]) else None
    print(f"Peer {index}: " + (f"last handshake {age} seconds ago" if age is not None else "no handshake yet"))
    stale |= age is None or age > 180
sys.exit(int(stale))' || bad=1
  echo 'A recent handshake proves only hub reachability; test student -> lab TCP 22 separately.'
  return "$bad"
}

main_wireguard() {
  local action="${1:---help}" profile='' network='' interface=ids-wg summary dest
  case "$action" in
    --help|-h) wireguard_usage; return ;;
    --prepare|--status) shift ;;
    --install|--check-config)
      [[ $# -ge 2 ]] || die 'Provide the lab WireGuard configuration path.'
      profile="$2"; shift 2 ;;
    *) wireguard_usage; return 1 ;;
  esac
  while (( $# )); do
    [[ $# -ge 2 ]] || die 'Missing option value.'
    case "$1" in
      --student-network) network="$2" ;;
      --interface) interface="$2" ;;
      *) die 'Unknown option; see --help.' ;;
    esac
    shift 2
  done
  dest="$(wireguard_target "$interface")"
  if [[ "$action" == --install || "$action" == --check-config ]]; then
    [[ -n "$network" ]] || die 'Provide --student-network with the real source CIDR.'
    summary="$(python3 "$SCRIPT_DIR/wireguard_config.py" "$profile" --student-network "$network")"
    printf '%s\n' "$summary"
    [[ "$action" != --check-config ]] || return 0
  fi
  [[ "$EUID" == 0 ]] || die 'Run this action with sudo on the lab PC.'
  if [[ "$action" == --status ]]; then wireguard_status "$interface"; return; fi
  source /etc/os-release
  [[ "$ID" == pop || "$ID" == ubuntu ]] || die 'Supports Pop!_OS/Ubuntu only.'
  [[ "$VERSION_ID" == 22.04 || "$VERSION_ID" == 24.04 ]] || die 'Supported releases: 22.04/24.04.'
  exec 9>/run/lock/ids-usuarios.lock
  flock -n 9 || die 'Another installer/account manager is running.'
  if [[ "$action" == --prepare ]]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      wireguard-tools iproute2 openssh-server openssl x2goserver x2goserver-xsession \
      xfce4-session xfce4-panel xfwm4 xfdesktop4 xfce4-settings xfce4-terminal \
      thunar xfce4-appfinder dbus-x11 xauth x11-apps x11-xserver-utils \
      python3 python3-venv python3-pip
    echo 'Dependencies prepared. Supply the real lab WireGuard profile and student source CIDR next.'
    return
  fi
  command -v wg-quick >/dev/null || die 'Run --prepare first (wg-quick missing).'
  command -v x2gostartagent >/dev/null || die 'Run --prepare first (X2Go missing).'
  command -v startxfce4 >/dev/null || die 'Run --prepare first (XFCE missing).'
  if python3 -c 'import json,sys; sys.exit(not json.load(sys.stdin)["requires_resolvconf"])' <<< "$summary"; then
    command -v resolvconf >/dev/null || die 'Profile DNS requires resolvconf integration; review DNS with the VPN administrator before installation.'
  fi
  # Do not reconfigure routing or SSH around an already-live WireGuard interface.
  if ip link show dev "$interface" >/dev/null 2>&1; then
    die 'Target interface is already active; schedule changes locally before rerunning --install.'
  fi
  install -d -o root -g root -m 700 /etc/wireguard
  wireguard_install_profile "$profile" "$dest"
  configure_student_network "$network"
  echo "Profile installed privately in $dest; WireGuard was NOT started or enabled."
  echo "After reviewing hub routes/firewall, activate locally: sudo systemctl enable --now wg-quick@$interface"
  echo "Check: sudo bash install_wireguard.sh --status --interface $interface"
  echo 'Create accounts: sudo bash usr_mgr.sh --import usuarios.txt'
  echo 'Existing VPN services and firewall policies were left unchanged. Verify route conflicts before starting.'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main_wireguard "$@"; fi
