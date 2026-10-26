#!/usr/bin/env bash
# Instalador interactivo OpenVPN Community + SSH + X2Go/XFCE
# Pop!_OS 22.04 / 24.04 LTS. NO modifica el escritorio COSMIC, los drivers NVIDIA ni CUDA.
# Diseñado para ser compatible con gestor_alumnos_vpn.sh.
# Ejecutar desde una sesión administrativa/local: sudo bash instalar_servidor_popos_vpn_x2go.sh
set -Eeuo pipefail
umask 077

OVPN_DIR='/etc/openvpn/server'
EASYRSA_DIR='/root/easy-rsa'
VPN_PROFILE_DIR='/root/perfiles-openvpn'
ARCHIVE_DIR='/root/archivos-alumnos'
VPN_HOST_FILE='/etc/gestor-alumnos-vpn.host'
VPN_SERVICE='openvpn-server@server'
SSH_SNIPPET='/etc/ssh/sshd_config.d/00-alumnos-x2go.conf'
VPN_PORT='1194'
VPN_NETWORK='10.8.0.0'
VPN_MASK='255.255.255.0'
VPN_SERVER='10.8.0.1'
VPN_INTERFACE='tun0'
GROUP='alumnosvpn'
PUBLIC_HOST=''
LOGFILE=''
COMPLETE_INCOMPLETE=false
STUDENT_NETWORK='10.8.0.0/24'

info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33mAVISO: %s\033[0m\n' "$*" >&2; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
prompt() { local __var="$1" __message="$2"; IFS= read -r -p "$__message" "$__var"; }
yes_no() {
  local ans=''
  prompt ans "$1 [s/N]: "
  [[ "$ans" == s || "$ans" == S || "$ans" == si || "$ans" == SI || "$ans" == sí || "$ans" == Sí ]]
}
validate_host() {
  local host="$1"
  [[ -n "$host" && ${#host} -le 253 && "$host" =~ ^[[:alnum:]][[:alnum:].-]*$ && "$host" != *..* ]]
}
cleanup_failure() {
  local exit_status="$?"
  warn "El instalador terminó con código $exit_status. Revisa la salida anterior. No se ha revertido automáticamente ninguna modificación parcial."
  exit "$exit_status"
}
trap cleanup_failure ERR

require_system() {
  [[ "$EUID" -eq 0 ]] || die 'Ejecuta este script como root (sudo bash ...).'
  [[ -r /etc/os-release ]] || die 'No se detectó /etc/os-release.'
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == 'pop' ]] || die "Se detectó '${PRETTY_NAME:-desconocido}', no Pop!_OS. Instalación cancelada."
  case "${VERSION_ID:-}" in
    '22.04'|'24.04') ;;
    *) die "Pop!_OS ${VERSION_ID:-desconocido} no está validado para este instalador. Revisa y adapta antes de usar." ;;
  esac
  command -v apt-get >/dev/null || die 'Falta apt-get.'
  command -v systemctl >/dev/null || die 'Falta systemctl.'
  [[ -t 0 ]] || die 'Se requiere una terminal interactiva (stdin).'
  info "Sistema detectado: $PRETTY_NAME"
  echo 'Instalación prevista:'
  echo '  - OpenVPN Community, red 10.8.0.0/24 y puerto UDP 1194.'
  echo '  - OpenSSH y X2Go + sesión gráfica XFCE por alumno.'
  echo '  - PKI Easy-RSA, CRL y carpetas compatibles con el gestor de alumnos.'
  echo '  - Configuración opcional de firewall UFW.'
  echo '  - NO cambia COSMIC/GNOME, el display manager, NVIDIA ni CUDA.'
  echo
  if [[ -e "$OVPN_DIR/server.conf" ]]; then
    if [[ "$COMPLETE_INCOMPLETE" != true ]]; then
      die "Ya existe $OVPN_DIR/server.conf. Usa --check, --repair-existing o --complete-incomplete según corresponda."
    fi
    local file
    for file in ca.crt servidor.crt servidor.key crl.pem tls-crypt.key; do
      [[ ! -e "$OVPN_DIR/$file" && ! -L "$OVPN_DIR/$file" ]] \
        || die "Existe $OVPN_DIR/$file. No se regenerará una instalación con claves/certificados; usa --repair-existing."
    done
    warn 'Se completará la instalación sin certificados. Se respaldará y reemplazará server.conf.'
  fi
  if [[ -e "$EASYRSA_DIR/pki" ]]; then
    die "Ya existe una PKI Easy-RSA en $EASYRSA_DIR/pki. Para evitar mezclar identidades se cancela. Revisa si tu gestor ya tiene certificados y configura manualmente en ese caso."
  fi
  yes_no '¿Confirmas la instalación en este equipo?' || { echo 'Cancelado.'; exit 0; }
}

ask_network() {
  info 'Dirección pública para los perfiles VPN'
  echo 'Escribe una IP pública o dominio DNS, sin http:// y sin :1194.'
  echo 'Ejemplo: vpn.miuniversidad.cl o 203.0.113.25 (solo ilustrativos).'
  prompt PUBLIC_HOST 'IP pública o dominio: '
  validate_host "$PUBLIC_HOST" || die 'IP/dominio inválido. No incluyas protocolo, espacios ni puerto.'
  echo
  echo 'IMPORTANTE: esta dirección debe apuntar al PC Pop!_OS, y UDP 1194 debe estar abierto/redirigido en el router.'
  echo 'Si hay CGNAT o la universidad bloquea la entrada, necesitarás una VPS u otra topología.'
  yes_no "¿Continuar usando $PUBLIC_HOST?" || { echo 'Cancelado.'; exit 0; }
}

install_packages() {
  info 'Instalando dependencias (no se modificará el escritorio físico)'
  apt-get update
  if ! apt-cache show x2goserver >/dev/null 2>&1; then
    die 'El paquete x2goserver no está en los repositorios APT activos. Habilita el componente universe de Ubuntu de forma apropiada para Pop!_OS y vuelve a ejecutar.'
  fi
  # Paquetes XFCE específicos: evita metapaquetes de escritorios completos y cambios de display manager.
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    openvpn easy-rsa openssh-server \
    x2goserver x2goserver-xsession \
    xfce4-session xfce4-panel xfwm4 xfdesktop4 xfce4-settings xfce4-terminal \
    thunar xfce4-appfinder \
    dbus-x11 xauth x11-apps x11-xserver-utils \
    ufw ca-certificates openssl git curl \
    python3 python3-venv python3-pip pipx
  [[ -x /usr/share/easy-rsa/easyrsa ]] || die 'No se encuentra /usr/share/easy-rsa/easyrsa.'
  [[ -x /usr/sbin/sshd ]] || die 'No se ha instalado sshd.'
}

create_ca() {
  info 'Generación de la autoridad certificadora (CA) y certificados OpenVPN'
  install -d -m 700 "$EASYRSA_DIR"
  cp -a /usr/share/easy-rsa/. "$EASYRSA_DIR/"
  cd "$EASYRSA_DIR"
  [[ -x ./easyrsa ]] || die 'No existe el ejecutable ./easyrsa.'
  echo 'Easy-RSA te pedirá una contraseña para proteger la clave de la CA.'
  echo 'Guárdala en un lugar seguro: la necesitarás al agregar o revocar estudiantes.'
  ./easyrsa init-pki
  ./easyrsa build-ca
  echo
  echo 'Se creará el certificado del servidor (CN=servidor).'
  ./easyrsa build-server-full servidor nopass
  echo 'Generando la lista de certificados revocados (CRL)...'
  EASYRSA_CRL_DAYS=180 ./easyrsa gen-crl
  [[ -f pki/ca.crt && -f pki/private/ca.key && -f pki/issued/servidor.crt && -f pki/private/servidor.key && -f pki/crl.pem ]] \
    || die 'Faltan archivos de la PKI tras generar los certificados.'
}

configure_openvpn() {
  info 'Configurando OpenVPN'
  install -d -m 755 "$OVPN_DIR"
  # La CRL se relee tras bajar privilegios a nobody; debe poder atravesar el directorio.
  chmod 755 "$OVPN_DIR"
  install -m 644 "$EASYRSA_DIR/pki/ca.crt" "$OVPN_DIR/ca.crt"
  install -m 644 "$EASYRSA_DIR/pki/issued/servidor.crt" "$OVPN_DIR/servidor.crt"
  install -m 600 "$EASYRSA_DIR/pki/private/servidor.key" "$OVPN_DIR/servidor.key"
  install -m 644 "$EASYRSA_DIR/pki/crl.pem" "$OVPN_DIR/crl.pem"
  openvpn --genkey tls-crypt "$OVPN_DIR/tls-crypt.key"
  chmod 600 "$OVPN_DIR/tls-crypt.key"
  if [[ -e "$OVPN_DIR/server.conf" ]]; then
    local backup
    backup="$(mktemp "$OVPN_DIR/server.conf.backup-XXXXXXXX")"
    cp -p -- "$OVPN_DIR/server.conf" "$backup"
    info "Configuración anterior respaldada: $backup"
  fi
  cat > "$OVPN_DIR/server.conf" <<'__OVPN_CONF__'
# VPN docente: clientes hacia el propio servidor, sin comunicacion cliente-cliente.
port 1194
proto udp
dev tun0
topology subnet
server 10.8.0.0 255.255.255.0
ca /etc/openvpn/server/ca.crt
cert /etc/openvpn/server/servidor.crt
key /etc/openvpn/server/servidor.key
dh none

tls-crypt /etc/openvpn/server/tls-crypt.key
tls-version-min 1.2
remote-cert-tls client
verify-client-cert require
data-ciphers AES-256-GCM:AES-128-GCM
crl-verify /etc/openvpn/server/crl.pem

# No push redirect-gateway, no client-to-client: solo acceden a 10.8.0.1.
keepalive 10 120
persist-key
persist-tun
user nobody
group nogroup
verb 3
__OVPN_CONF__
  chmod 640 "$OVPN_DIR/server.conf"
  install -d -m 700 "$VPN_PROFILE_DIR" "$ARCHIVE_DIR"
  printf '%s\n' "$PUBLIC_HOST" > "$VPN_HOST_FILE"
  chmod 600 "$VPN_HOST_FILE"
  groupadd -f "$GROUP"
  systemctl enable --now "$VPN_SERVICE"
  systemctl is-active --quiet "$VPN_SERVICE" || die "OpenVPN no quedó activo. Comprueba: journalctl -u $VPN_SERVICE -n 80"
  info 'OpenVPN está activo'
}

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

configure_firewall() {
  info 'Firewall UFW (opcional, recomendado)'
  echo 'Reglas a añadir: permitir UDP 1194 por Internet y SSH TCP 22 solo desde la VPN (tun0).'
  echo 'El resto de puertos entrantes se bloquearán si se activan las políticas por defecto.'
  echo 'No se eliminarán reglas UFW preexistentes; revísalas para evitar SSH público.'
  echo
  if ! yes_no '¿Quieres configurar/activar UFW ahora?'; then
    warn 'UFW no modificado. Protege el puerto SSH: nunca lo expongas públicamente sin controles adecuados.'
    return 0
  fi
  local admin_cidr=''
  echo 'Si administras el equipo por SSH fuera de la VPN, indica tu IP/CIDR administrativo.'
  echo 'Si trabajas con acceso físico, puedes dejarlo en blanco.'
  prompt admin_cidr 'IP/CIDR administrativo opcional (ej. 192.168.1.0/24): '
  if [[ -n "$admin_cidr" ]]; then
    # Validación a través de Python ipaddress (sin shell parsing de IP).
    if ! python3 - "$admin_cidr" <<'__PYIP__'
import ipaddress, sys
try:
    ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError:
    sys.exit(1)
__PYIP__
    then
      die 'CIDR inválido. Se aborta antes de cambiar UFW.'
    fi
  elif [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" ]]; then
    die 'Parece que estás administrando por SSH. No se activará UFW sin definir una IP/CIDR de administración.'
  fi
  echo 'Los siguientes comandos modificarán el firewall actual. No se desharán automáticamente.'
  yes_no '¿Confirmas el cambio de UFW y sus políticas por defecto?' || { warn 'UFW no modificado.'; return 0; }
  ufw allow "$VPN_PORT"/udp comment 'OpenVPN alumnos'
  ufw allow in on "$VPN_INTERFACE" from 10.8.0.0/24 to "$VPN_SERVER" port 22 proto tcp comment 'SSH-X2Go alumnos'
  if [[ -n "$admin_cidr" ]]; then
    ufw allow from "$admin_cidr" to any port 22 proto tcp comment 'SSH admin de confianza'
  fi
  ufw default deny incoming
  ufw default allow outgoing
  if ! ufw status | grep -q '^Status: active'; then
    # No usar 'ufw --force enable' sin el consentimiento anterior.
    ufw --force enable
  fi
  ufw status verbose
  warn 'Revisa que ninguna regla antigua permita SSH 22 desde Internet (ufw status numbered).'
}

final_report() {
  info 'RESUMEN DE LA INSTALACIÓN'
  echo "Pop!_OS: $(. /etc/os-release; echo "$PRETTY_NAME")"
  echo "VPN:          $PUBLIC_HOST:$VPN_PORT/udp"
  echo "IP privada:   $VPN_SERVER"
  echo "Servicio VPN: $VPN_SERVICE"
  echo "SSH/X2Go:    $VPN_SERVER:22, sesión XFCE"
  echo "Certificados: $EASYRSA_DIR/pki"
  echo "Perfiles:     $VPN_PROFILE_DIR"
  echo "Grupo:        $GROUP"
  echo "Host VPN:     $VPN_HOST_FILE"
  echo
  echo 'Comprobaciones:'
  systemctl --no-pager --plain is-active "$VPN_SERVICE" || true
  systemctl --no-pager --plain is-active ssh || true
  ip -4 addr show "$VPN_INTERFACE" 2>/dev/null || warn 'No se puede consultar tun0 (verifica OpenVPN).'
  echo
  echo 'Siguientes pasos:'
  echo '1) Asegura IP pública / NAT: redirigir UDP 1194 al PC Pop!_OS.'
  echo '2) Importa alumnos: sudo bash usr_mgr.sh --import usuarios.txt'
  echo '3) Crea un alumno de prueba y entrega únicamente su perfil .ovpn.'
  echo '4) Alumno Windows: OpenVPN Connect + X2Go Client; host 10.8.0.1, SSH 22, XFCE.'
  echo '5) Verifica con dos alumnos simultáneos que usan distintos $DISPLAY y HOME.'
  echo '6) Respalda la CA (especialmente ca.key) cifrada y fuera del servidor.'
  echo '7) Para instalar apps por alumno: ~/.local, pipx o python -m venv; NO conceder sudo.'
  echo
  echo 'Nota: OpenVPN no garantiza conectividad desde Internet sin IP pública/puerto abierto.'
  echo 'Nota: Los usuarios normales NO son contenedores; pueden leer archivos globalmente legibles y usar /tmp.'
  echo 'Nota: La CRL caduca: renovarla antes de su nextUpdate (ver README.md).'
  echo 'Nota: La GPU se comparte sin cuotas ni cola; verificar nvidia-smi como alumno antes de entrenar.'
}

usage() {
  cat <<'EOF'
Uso: sudo bash install_server.sh                   Instalación nueva interactiva
     sudo bash install_server.sh --check           Diagnóstico sin cambios
     sudo bash install_server.sh --repair-existing Valida PKI, configura SSH/X2Go y arranca servicios
     sudo bash install_server.sh --complete-incomplete Completa una configuración sin PKI ni claves
     sudo bash install_server.sh --institutional-access CIDR Configura SSH/X2Go para una VPN aprobada
     sudo bash install_server.sh --student-network CIDR Configura SSH/X2Go para una red privada

--repair-existing conserva certificados, claves, server.conf y firewall existentes.
Si falta material criptográfico o caducó la CRL, se detiene antes de cambiar servicios.
--complete-incomplete exige que no exista PKI ni material criptográfico desplegado;
respalda server.conf y continúa la instalación nueva con confirmaciones interactivas.
No instala ni actualiza drivers NVIDIA/CUDA.
--institutional-access requiere el CIDR de origen que verá SSH desde la VPN/relay;
no configura la VPN externa, no cambia firewall y no emite certificados OpenVPN.
EOF
}

check_material() {
  local file bad=0
  for file in server.conf ca.crt servidor.crt servidor.key crl.pem tls-crypt.key; do
    if [[ ! -s "$OVPN_DIR/$file" ]]; then
      warn "Falta o no se puede leer: $OVPN_DIR/$file"
      bad=1
    fi
  done
  (( bad == 0 )) || return 1
  # Esta reparación solo admite el esquema de rutas y red del instalador.
  local directive value
  while read -r directive value; do
    if ! awk -v key="$directive" -v value="$value" \
        '$1 == key && $2 == value {ok=1} END {exit !ok}' "$OVPN_DIR/server.conf"; then
      warn "server.conf requiere revisión: se esperaba $directive $value"
      bad=1
    fi
  done <<EOF
ca $OVPN_DIR/ca.crt
cert $OVPN_DIR/servidor.crt
key $OVPN_DIR/servidor.key
crl-verify $OVPN_DIR/crl.pem
tls-crypt $OVPN_DIR/tls-crypt.key
server 10.8.0.0
EOF
  openssl verify -purpose sslserver -CAfile "$OVPN_DIR/ca.crt" -CRLfile "$OVPN_DIR/crl.pem" \
    -crl_check "$OVPN_DIR/servidor.crt" || bad=1
  openssl crl -in "$OVPN_DIR/crl.pem" -noout -nextupdate || bad=1
  local cert_pub key_pub
  cert_pub="$(openssl x509 -in "$OVPN_DIR/servidor.crt" -pubkey -noout)" || return 1
  key_pub="$(openssl pkey -in "$OVPN_DIR/servidor.key" -passin pass: -pubout)" || return 1
  [[ "$cert_pub" == "$key_pub" ]] || { warn 'La clave y el certificado del servidor no coinciden.'; bad=1; }
  (( bad == 0 ))
}

check_existing() {
  local bad=0 unit
  info 'Diagnóstico (solo lectura; ejecutar fuera del sandbox con sudo)'
  check_material || bad=1
  for unit in "$VPN_SERVICE" ssh; do
    systemctl --no-pager is-active "$unit" || bad=1
  done
  /usr/sbin/sshd -t || bad=1
  ip -brief address || bad=1
  ss -lntu || bad=1
  ufw status verbose || bad=1
  nvidia-smi || { warn 'GPU no disponible. Comprobar driver y acceso a dispositivos en el host.'; bad=1; }
  return "$bad"
}

repair_existing() {
  [[ "$EUID" -eq 0 ]] || die 'Ejecuta con sudo en una terminal del PC.'
  check_material || die 'Configuración existente incompleta/inválida. No se regeneraron claves. Consulta README.md.'
  command -v x2gostartagent >/dev/null || die 'Falta x2goserver.'
  command -v startxfce4 >/dev/null || die 'Falta XFCE.'
  install -d -m 755 "$OVPN_DIR"
  chmod 755 "$OVPN_DIR"
  chmod 644 "$OVPN_DIR/crl.pem"
  groupadd -f "$GROUP"
  configure_ssh_x2go
  systemctl enable --now "$VPN_SERVICE"
  check_existing
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
      [[ "${2:-}" == --migrate-managed ]] || die "Ya existe $SSH_SNIPPET con otra red; revísalo antes de cambiar el CIDR."
      # Replace only an exact installer-generated snippet; preserve custom policies.
      migrate_student_ssh "$cidr"
    fi
  fi
  configure_ssh_x2go
  install -d -m 700 /root/credenciales-alumnos "$ARCHIVE_DIR"
  printf 'linux\n' > /etc/ids-remote-access.mode
  chmod 600 /etc/ids-remote-access.mode
  info "SSH/X2Go preparado para alumnos desde $cidr"
  echo 'El gestor seleccionará cuentas sin certificados por defecto.'
  echo 'La VPN/red privada, rutas y firewall deben permitir TCP 22 hasta este PC.'
  echo 'Prueba un alumno desde fuera de la red antes de distribuir el acceso al curso.'
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
    --check) check_existing; return ;;
    --repair-existing) repair_existing; return ;;
    --complete-incomplete) COMPLETE_INCOMPLETE=true ;;
    --institutional-access|--student-network)
      [[ $# -eq 2 ]] || die 'Uso: --student-network CIDR'
      configure_student_network "$2"; return ;;
    '') ;;
    *) usage; return 1 ;;
  esac
  require_system
  ask_network
  install_packages
  create_ca
  configure_openvpn
  configure_ssh_x2go
  configure_firewall
  final_report
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
