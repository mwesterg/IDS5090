#!/usr/bin/env bash
# SSH/X2Go sin redirección de puertos. Ejecutar con sudo en una terminal del PC.
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/install_server.sh"

tailscale_backend_state() {
  local status_json
  status_json="$(tailscale status --json 2>/dev/null)" || status_json=''
  python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("BackendState", "Unknown"))
except (ValueError, AttributeError):
    print("Unknown")' <<< "$status_json"
}

authenticate_tailscale() {
  local state
  state="$(tailscale_backend_state)"
  if [[ "$state" == Running ]]; then
    info 'Tailscale ya está autenticado y conectado; no se necesita un enlace nuevo.'
    echo 'IP privada del servidor:'
    tailscale ip -4
    echo 'Puedes revisar el equipo en https://login.tailscale.com/admin/machines'
    return 0
  fi
  if [[ "$state" == NeedsMachineAuth ]]; then
    warn 'El equipo ya inició sesión, pero necesita aprobación del administrador de Tailscale.'
    echo 'Aprueba el equipo en https://login.tailscale.com/admin/machines y vuelve a ejecutar el instalador.'
    return 1
  fi
  info "Conectando Tailscale (estado: $state)"
  echo 'Si hace falta iniciar sesión, el siguiente comando mostrará un enlace y un código QR.'
  echo 'Abre ese enlace en un navegador. El comando esperará hasta 2 minutos.'
  echo 'Si no aparece el enlace, revisa los mensajes de conexión que siguen.'
  if ! tailscale up --qr --timeout=120s; then
    warn 'Tailscale no completó la conexión. Revisa: sudo tailscale status'
    echo 'Registro del servicio: sudo journalctl -u tailscaled -n 50 --no-pager'
    echo 'Reintentar solo la conexión: sudo bash install_tailscale.sh --login-only'
    return 1
  fi
  state="$(tailscale_backend_state)"
  [[ "$state" == Running ]] || {
    warn "Tailscale todavía no está conectado (estado: $state)."
    echo 'Si requiere aprobación: https://login.tailscale.com/admin/machines'
    return 1
  }
}

main_tailscale() {
  if [[ "${1:-}" == --help ]]; then
    echo 'Uso: sudo bash install_tailscale.sh [--login-only]'
    echo 'Instala Tailscale + SSH/X2Go/XFCE. Debes autenticar el servidor con tu cuenta.'
    echo 'Usar solo si tu institución permite Tailscale. No invita alumnos ni cambia políticas externas.'
    echo '--login-only: inicia el servicio y conecta/autentica sin reinstalar paquetes ni configurar SSH.'
    return
  fi
  [[ $# -eq 0 || ( $# -eq 1 && "$1" == --login-only ) ]] || die 'Argumento desconocido. Consulta --help.'
  [[ "$EUID" -eq 0 ]] || die 'Ejecuta con sudo en una terminal normal/local del PC.'
  [[ -t 0 ]] || die 'Se requiere una terminal interactiva para autenticar Tailscale.'
  if [[ "${1:-}" == --login-only ]]; then
    command -v tailscale >/dev/null || die 'Tailscale no está instalado; ejecuta el instalador completo.'
    systemctl enable --now tailscaled
    authenticate_tailscale
    return
  fi
  source /etc/os-release
  [[ "${ID:-}" == pop || "${ID:-}" == ubuntu ]] || die 'Solo se admite Pop!_OS/Ubuntu.'
  local codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  [[ "$codename" == jammy || "$codename" == noble ]] || die 'Solo se admite Ubuntu base 22.04/24.04.'
  exec 9>/run/lock/ids-usuarios.lock
  flock -n 9 || die 'Otro gestor/instalador está en ejecución.'
  info 'Instalando SSH/X2Go/XFCE y Tailscale (sin cambiar NVIDIA/CUDA)'
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg openssl openssh-server \
    x2goserver x2goserver-xsession xfce4-session xfce4-panel xfwm4 \
    xfdesktop4 xfce4-settings xfce4-terminal thunar xfce4-appfinder \
    dbus-x11 xauth x11-apps x11-xserver-utils python3 python3-venv python3-pip
  if ! command -v tailscale >/dev/null; then
    local downloads
    downloads="$(mktemp -d)"
    curl --proto '=https' --tlsv1.2 -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$codename.noarmor.gpg" -o "$downloads/key.gpg"
    curl --proto '=https' --tlsv1.2 -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$codename.tailscale-keyring.list" -o "$downloads/tailscale.list"
    gpg --show-keys "$downloads/key.gpg" >/dev/null
    install -d -m 755 /usr/share/keyrings
    install -m 644 "$downloads/key.gpg" /usr/share/keyrings/tailscale-archive-keyring.gpg
    install -m 644 "$downloads/tailscale.list" /etc/apt/sources.list.d/tailscale.list
    rm -rf -- "$downloads"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale
  fi
  systemctl enable --now tailscaled
  authenticate_tailscale
  # Mantener OpenSSH normal: X2Go autentica con la contraseña Linux del alumno.
  tailscale set --ssh=false
  local tail_ip
  tail_ip="$(tailscale ip -4)"
  python3 - "$tail_ip" <<'PY'
import ipaddress, sys
assert ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network('100.64.0.0/10')
PY
  configure_student_network '100.64.0.0/10'
  info "IP privada Tailscale del servidor: $tail_ip"
  echo "Importar: sudo bash $SCRIPT_DIR/usr_mgr.sh --linux-only --import usuarios.txt"
  echo "X2Go: host $tail_ip, puerto 22, sesión XFCE y usuario/contraseña Linux individual."
  echo 'En la consola Tailscale comparte SOLO este PC con cada alumno y limita su acceso a TCP 22.'
  echo 'No se han invitado alumnos ni cambiado políticas de acceso externas o UFW.'
  echo 'Prueba desde otro dispositivo antes de distribuir acceso al curso.'
  systemctl --no-pager is-active tailscaled ssh
  tailscale status
  if ! nvidia-smi; then warn 'Verificar driver y acceso GPU desde el host antes de entrenar.'; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main_tailscale "$@"; fi
