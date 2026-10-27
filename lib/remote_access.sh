#!/usr/bin/env bash
# Shared SSH/X2Go policy for the WireGuard lab. Sourced by the installers/manager.
# Keep the deployed group name so existing student memberships remain valid.
GROUP='alumnosvpn'
CREDENTIAL_DIR='/root/credenciales-alumnos'
ARCHIVE_DIR='/root/archivos-alumnos'
STUDENT_NETWORK=''
SSH_SNIPPET='/etc/ssh/sshd_config.d/00-00-ids-students.conf'

info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33mAVISO: %s\033[0m\n' "$*" >&2; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

render_student_ssh() {
  cat <<__SSH_CONF__
# Mantener el acceso administrativo existente; contraseñas solo para alumnos por VPN.
PermitRootLogin no
PubkeyAuthentication yes
X11Forwarding yes
AllowTcpForwarding yes
Match Group $GROUP Address $STUDENT_NETWORK
    PasswordAuthentication yes
Match Group $GROUP Address *,!$STUDENT_NETWORK
    PasswordAuthentication no
    PubkeyAuthentication no
    KbdInteractiveAuthentication no
Match all
__SSH_CONF__
}

configure_ssh_x2go() {
  info 'Configurando acceso SSH/X2Go'
  install -d -m 755 /etc/ssh/sshd_config.d
  if [[ -e "$SSH_SNIPPET" ]]; then
    warn "El archivo $SSH_SNIPPET ya existe; no se sobrescribirá."
  else
    render_student_ssh > "$SSH_SNIPPET"
    chmod 644 "$SSH_SNIPPET"
  fi
  if ! sshd -t; then
    warn "La configuración SSH no pasó la validación. Comprueba $SSH_SNIPPET."
    die 'Se detiene antes de recargar SSH.'
  fi
  systemctl enable --now ssh
  systemctl reload ssh
  # Servicio auxiliar opcional de limpieza de sesiones (el inicio de sesión se hace por SSH).
  local unit
  for unit in x2goserver.service x2gocleansessions.service; do
    if systemctl list-unit-files "$unit" --no-legend | grep -q "^$unit"; then
      systemctl enable --now "$unit" || warn "No se pudo activar $unit (revisar registro)."
    fi
  done
  info 'OpenSSH y X2Go listos para sesiones XFCE'
}

migrate_student_ssh() {
  local cidr="$1" old_cidr backup
  old_cidr=$(awk -v g="$GROUP" '$1 == "Match" && $2 == "Group" && $3 == g && $4 == "Address" && $5 !~ /!/ {print $5}' "$SSH_SNIPPET")
  [[ -n "$old_cidr" && "$old_cidr" != *$'\n'* ]] || die 'No se reconoce el snippet SSH existente.'
  cmp -s "$SSH_SNIPPET" <(STUDENT_NETWORK="$old_cidr" render_student_ssh) || die 'El snippet SSH contiene cambios manuales; adapta la red manualmente.'
  backup=$(mktemp "$SSH_SNIPPET.backup-XXXXXXXX")
  cp -p "$SSH_SNIPPET" "$backup"
  render_student_ssh > "$SSH_SNIPPET"
  if ! sshd -t; then
    cp -p "$backup" "$SSH_SNIPPET"
    die 'La nueva configuración SSH es inválida; se restauró la anterior.'
  fi
  info "Red SSH migrada a $cidr; respaldo: $backup"
}

configure_student_network() {
  [[ "$EUID" -eq 0 ]] || die 'Ejecuta con sudo desde una terminal del PC.'
  local cidr="$1"
  python3 - "$cidr" <<'PY'
import ipaddress, sys
network = ipaddress.ip_network(sys.argv[1], strict=True)
if network.prefixlen == 0:
    raise ValueError('No se admite una red de origen universal')
PY
  command -v x2gostartagent >/dev/null || die 'Instala x2goserver y x2goserver-xsession primero.'
  command -v startxfce4 >/dev/null || die 'Instala XFCE primero.'
  groupadd -f "$GROUP"
  STUDENT_NETWORK="$cidr"
  SSH_SNIPPET='/etc/ssh/sshd_config.d/00-00-ids-students.conf'
  if [[ -e "$SSH_SNIPPET" ]]; then
    if ! grep -Fxq "Match Group $GROUP Address $cidr" "$SSH_SNIPPET"; then
      # Replace only an exact installer-generated snippet; preserve custom policies.
      migrate_student_ssh "$cidr"
    fi
  fi
  configure_ssh_x2go
  install -d -m 700 "$CREDENTIAL_DIR" "$ARCHIVE_DIR"
  info "SSH/X2Go preparado para alumnos desde $cidr"
  echo 'La VPN/red privada, rutas y firewall deben permitir TCP 22 hasta este PC.'
  echo 'Prueba un alumno desde fuera de la red antes de distribuir el acceso al curso.'
}
