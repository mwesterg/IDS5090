#!/usr/bin/env bash
# Gestión interactiva de alumnos para OpenVPN + SSH + X2Go (Ubuntu 24.04)
# Ejecutar con: sudo bash gestor_alumnos_vpn.sh
# Requiere: servidor OpenVPN y PKI Easy-RSA creados previamente.
set -Eeuo pipefail
umask 077

# Ajustar si se usaron rutas/nombres distintos en la instalación inicial.
EASYRSA_DIR="/root/easy-rsa"
OVPN_DIR="/etc/openvpn/server"
SERVER_CN="servidor"
VPN_PORT="1194"
VPN_PROTO="udp"
VPN_SERVICE="openvpn-server@server"
GROUP="alumnosvpn"
PROFILE_DIR="/root/perfiles-openvpn"
ARCHIVE_DIR="/root/archivos-alumnos"
VPN_HOST_FILE="/etc/gestor-alumnos-vpn.host"
CRL_FILE="$OVPN_DIR/crl.pem"
ACCESS_MODE='openvpn'

say()  { printf '\n%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
read_var() { local __name="$1" __prompt="$2"; IFS= read -r -p "$__prompt" "$__name"; }

valid_name() { [[ "$1" =~ ^[a-z][a-z0-9_-]{2,30}$ && "$1" != "$SERVER_CN" ]]; }
valid_host() { [[ -n "$1" && "$1" =~ ^[A-Za-z0-9.-]+$ && "$1" != -* ]]; }

require_environment() {
  [[ "$EUID" -eq 0 ]] || fail "Ejecuta con sudo."
  if [[ "$ACCESS_MODE" == linux ]]; then
    command -v useradd >/dev/null || fail 'Falta useradd.'
    command -v openssl >/dev/null || fail 'Falta openssl.'
    groupadd -f "$GROUP"
    install -d -m 700 "$PROFILE_DIR" "$ARCHIVE_DIR"
    return
  fi
  [[ -x "$EASYRSA_DIR/easyrsa" ]] || fail "No existe $EASYRSA_DIR/easyrsa. Revisa EASYRSA_DIR."
  [[ -f "$EASYRSA_DIR/pki/ca.crt" ]] || fail "Falta el certificado CA en Easy-RSA."
  [[ -f "$OVPN_DIR/server.conf" ]] || fail "Falta $OVPN_DIR/server.conf."
  [[ -f "$OVPN_DIR/ca.crt" && -f "$OVPN_DIR/tls-crypt.key" ]] || fail "Faltan ca.crt o tls-crypt.key del servidor."
  [[ -f "$CRL_FILE" ]] || fail "Falta $CRL_FILE. Configura antes la revocación."
  # Exigir CRL activo: sin esto, revocar un certificado no bloquearía la VPN.
  awk -v path="$CRL_FILE" '$1 == "crl-verify" && $2 == path {ok=1} END {exit !ok}' \
     "$OVPN_DIR/server.conf" || fail "server.conf debe incluir: crl-verify $CRL_FILE"
  command -v useradd >/dev/null || fail "Falta useradd"
  command -v openssl >/dev/null || fail "Falta openssl"
  groupadd -f "$GROUP"
  install -d -m 700 "$PROFILE_DIR" "$ARCHIVE_DIR"
}

ensure_vpn_host() {
  local host=""
  if [[ -s "$VPN_HOST_FILE" ]]; then
    IFS= read -r host < "$VPN_HOST_FILE"
  fi
  if ! valid_host "$host"; then
    say "Dirección pública de la VPN (IP o DNS, sin https://)"
    read_var host "Dirección: "
    valid_host "$host" || { say "Dirección inválida."; return 1; }
    printf '%s\n' "$host" > "$VPN_HOST_FILE"
    chmod 600 "$VPN_HOST_FILE"
  fi
  VPN_HOST="$host"
}

is_managed_user() {
  id "$1" &>/dev/null && id -nG "$1" | tr ' ' '\n' | grep -Fxq "$GROUP" \
    && [[ "$(id -u "$1")" -ge 1000 ]] \
    && [[ "$(getent passwd "$1" | cut -d: -f6)" == "/home/$1" ]]
}

make_profile() {
  local u="$1" dest tmp
  dest="$PROFILE_DIR/$u.ovpn"
  [[ ! -e "$dest" ]] || { say "El perfil ya existe: $dest"; return 1; }
  [[ -f "$EASYRSA_DIR/pki/issued/$u.crt" && -f "$EASYRSA_DIR/pki/private/$u.key" ]] || return 1
  tmp="$(mktemp "$PROFILE_DIR/.${u}.XXXXXXXX")"
  {
    cat <<EOF
client
dev tun
proto $VPN_PROTO
remote $VPN_HOST $VPN_PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name $SERVER_CN name
data-ciphers AES-256-GCM:AES-128-GCM
auth-nocache
verb 3
<ca>
EOF
    cat "$OVPN_DIR/ca.crt" || { rm -f -- "$tmp"; return 1; }
    printf '</ca>\n<cert>\n'
    openssl x509 -in "$EASYRSA_DIR/pki/issued/$u.crt" -outform PEM || { rm -f -- "$tmp"; return 1; }
    printf '</cert>\n<key>\n'
    cat "$EASYRSA_DIR/pki/private/$u.key" || { rm -f -- "$tmp"; return 1; }
    printf '\n</key>\n<tls-crypt>\n'
    cat "$OVPN_DIR/tls-crypt.key" || { rm -f -- "$tmp"; return 1; }
    printf '\n</tls-crypt>\n'
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || return 1
  mv "$tmp" "$dest" || return 1
  say "Perfil OpenVPN creado (privado): $dest"
}

add_student() {
  local u
  say "=== AGREGAR ALUMNO ==="
  read_var u "Usuario nuevo (ej. alumno01): "
  valid_name "$u" || { say "Nombre inválido: usa minúsculas, números, _ o -, longitud 3-31."; return; }
  if id "$u" &>/dev/null; then say "Ese usuario de Linux ya existe."; return; fi
  if [[ -e "$EASYRSA_DIR/pki/issued/$u.crt" || -e "$EASYRSA_DIR/pki/private/$u.key" ]]; then
    say "El identificador ya existe en Easy-RSA. Usa otro (los certificados revocados no se reutilizan)."; return
  fi
  if [[ "$ACCESS_MODE" == openvpn ]]; then ensure_vpn_host || return; fi
  say "Creando cuenta Linux sin sudo, con HOME privado."
  useradd -m -U -s /bin/bash -G "$GROUP" "$u" || return
  chmod 700 "/home/$u"
  if ! passwd "$u"; then
    say "No se configuró contraseña. Se revertirá la cuenta nueva."
    userdel -r "$u" || true
    return
  fi
  if [[ "$ACCESS_MODE" == linux ]]; then
    say "Alumno creado: $u. Usa la dirección del servidor por la VPN/red privada, sesión XFCE."
    return
  fi
  say "Easy-RSA solicitará la contraseña de la clave VPN y de la CA si corresponde."
  if ! ( cd "$EASYRSA_DIR" && ./easyrsa build-client-full "$u" ); then
    say "Falló el certificado. La cuenta Linux sigue creada: revisar manualmente antes de reintentar."
    return
  fi
  if ! make_profile "$u"; then
    say "El certificado existe, pero falló el .ovpn. Revisar archivos antes de continuar."
    return
  fi
  say "Alumno creado: $u"
  say "SSH / X2Go: $u@10.8.0.1  (SSH 22, sesión XFCE)"
  say "Entrega solo a este alumno: $PROFILE_DIR/$u.ovpn"
}

list_students() {
  say "=== ALUMNOS DEL GRUPO $GROUP ==="
  local members u count=0
  members="$(getent group "$GROUP" | cut -d: -f4 || true)"
  if [[ -z "$members" ]]; then say "No hay cuentas registradas en el grupo."; return; fi
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    count=$((count+1))
    local pass="sin cuenta" cert="sin certificado" profile="no"
    if id "$u" &>/dev/null; then pass="$(passwd -S "$u" | awk '{print $2}')"; fi
    [[ -f "$EASYRSA_DIR/pki/issued/$u.crt" ]] && cert="emitido (revisar revocaciones)"
    [[ -f "$PROFILE_DIR/$u.ovpn" ]] && profile="sí"
    printf '%-22s contraseña=%-3s  VPN=%-30s  perfil=%s\n' "$u" "$pass" "$cert" "$profile"
  done < <(printf '%s' "$members" | tr ',' '\n')
  say "Total listado: $count | 'L' = contraseña bloqueada; la cuenta puede estar expirada además."
}

suspend_student() {
  local u
  say "=== SUSPENDER CUENTA (REVERSIBLE) ==="
  read_var u "Alumno a suspender: "
  valid_name "$u" && is_managed_user "$u" || { say "No es una cuenta gestionada por este script."; return; }
  say "La suspensión bloquea el acceso Linux (SSH/X2Go), pero NO revoca el certificado VPN."
  read_var answer "Confirmar suspensión de $u [s/N]: "
  [[ "$answer" == "s" || "$answer" == "S" ]] || return
  usermod -L -e 1 "$u"
  loginctl terminate-user "$u" 2>/dev/null || true
  pkill -TERM -u "$u" 2>/dev/null || true
  say "Cuenta Linux suspendida. Para bloquear también la VPN permanentemente, elimínala."
}

reactivate_student() {
  local u
  say "=== REACTIVAR CUENTA LINUX ==="
  read_var u "Alumno a reactivar: "
  valid_name "$u" && is_managed_user "$u" || { say "No es una cuenta gestionada por este script."; return; }
  usermod -e '' "$u"
  usermod -U "$u" 2>/dev/null || { say "No se puede desbloquear la contraseña (posiblemente no tenga contraseña). Usa passwd $u."; return; }
  say "Cuenta reactivada. El certificado VPN debe seguir vigente."
}

remove_student() {
  local u confirm homedir archived timestamp
  say "=== ELIMINAR ALUMNO (IRREVERSIBLE PARA SU CERTIFICADO) ==="
  read_var u "Alumno a eliminar: "
  valid_name "$u" && is_managed_user "$u" || { say "No es una cuenta gestionada por este script."; return; }
  if [[ "$ACCESS_MODE" == linux ]] && [[ -e "$EASYRSA_DIR/pki/issued/$u.crt" ]]; then
    say 'Existe un certificado OpenVPN para esta cuenta. Revócalo con el gestor en modo OpenVPN antes de eliminarla.'
    return
  fi
  if [[ "$ACCESS_MODE" == openvpn ]]; then
  [[ -f "$EASYRSA_DIR/pki/issued/$u.crt" ]] || {
    say "No se encontró un certificado emitido para $u: se canceló para evitar dejar VPN activa sin control."; return;
  }
  fi
  homedir="/home/$u"
  say "Se cerrarán sus sesiones y se eliminará la cuenta Linux."
  say "Su carpeta personal NO se borrará: se moverá a $ARCHIVE_DIR."
  if [[ "$ACCESS_MODE" == openvpn ]]; then
    say 'Se revocará el certificado y reiniciará OpenVPN, desconectando temporalmente a los demás estudiantes.'
  else
    say 'El acceso a la VPN/red privada se retira por separado con su administrador.'
  fi
  read_var confirm "Escribe exactamente ELIMINAR $u para continuar: "
  [[ "$confirm" == "ELIMINAR $u" ]] || { say "Cancelado."; return; }

  if [[ "$ACCESS_MODE" == openvpn ]]; then
  say "1/5: Revocando certificado..."
  if ! (cd "$EASYRSA_DIR" && EASYRSA_BATCH=1 ./easyrsa revoke "$u"); then
    say "No se pudo revocar. No se eliminará la cuenta Linux."; return;
  fi
  say "2/5: Actualizando la CRL..."
  if ! (cd "$EASYRSA_DIR" && ./easyrsa gen-crl); then
    say "Error crítico: la PKI está revocada pero no se pudo actualizar la CRL."
    say "Ejecuta manualmente ./easyrsa gen-crl y publica crl.pem."
    usermod -L -e 1 "$u" || true
    return
  fi
  local tmp
  tmp="$(mktemp "$OVPN_DIR/.crl.pem.XXXXXXXX")"
  install -m 644 "$EASYRSA_DIR/pki/crl.pem" "$tmp"
  mv -f "$tmp" "$CRL_FILE"
  chmod 644 "$CRL_FILE"
  fi

  say "3/5: Deshabilitando y cerrando sesiones..."
  usermod -L -e 1 "$u"
  loginctl terminate-user "$u" 2>/dev/null || true
  pkill -TERM -u "$u" 2>/dev/null || true
  sleep 1
  pkill -KILL -u "$u" 2>/dev/null || true

  if [[ "$ACCESS_MODE" == openvpn ]]; then
  say "4/5: Reiniciando OpenVPN para cortar conexiones VPN antiguas..."
  if ! systemctl restart "$VPN_SERVICE"; then
    say "ATENCIÓN: no se pudo reiniciar OpenVPN. Comprueba inmediatamente:"
    say "  systemctl status $VPN_SERVICE"
    say "La cuenta Linux quedó bloqueada y el certificado consta como revocado."
    say "Se pospone el borrado de la cuenta para permitir resolver el error."
    return
  fi
  fi

  say "5/5: Eliminando cuenta y archivando HOME..."
  if ! userdel "$u"; then
    say "VPN revocada, pero userdel falló. Revisa procesos y cuenta manualmente."
    return
  fi
  if [[ -d "$homedir" && ! -L "$homedir" ]]; then
    timestamp="$(date +%Y%m%d-%H%M%S)"
    archived="$ARCHIVE_DIR/${u}-${timestamp}"
    if mv -- "$homedir" "$archived"; then
      chmod 700 "$archived"
      say "Archivos conservados en: $archived"
    else
      say "No se pudieron archivar sus archivos. Siguen en $homedir."
    fi
  fi
  rm -f -- "$PROFILE_DIR/$u.ovpn"
  say 'Cuenta eliminada. Revisa los mensajes anteriores sobre archivo del HOME y acceso VPN/relay.'
}

usage() {
  cat <<'EOF'
Uso: sudo bash usr_mgr.sh [--linux-only | --openvpn] [--import usuarios.txt [--dry-run]]
     bash usr_mgr.sh --help

Sin argumentos: menú interactivo. Opción 6: importar un TXT.
TXT: un usuario por línea (3-31 caracteres, minúsculas, números, _ o -).
Se permiten líneas vacías, comentarios # y archivos Windows (CRLF).
--dry-run valida el TXT sin privilegios, cuentas ni certificados nuevos.
La importación genera contraseñas individuales y claves VPN cifradas.
Las contraseñas se guardan SOLO en un TSV privado dentro de /root/perfiles-openvpn.
Easy-RSA puede pedir la contraseña de la CA para cada certificado.
--linux-only crea cuentas sin certificados (VPN/red privada); guarda
credenciales en /root/credenciales-alumnos.
--openvpn fuerza el modo original con certificados.
EOF
}

parse_user_file() {
  local file="$1" line number=0 errors=0
  local -A seen=()
  IMPORT_USERS=()
  [[ -f "$file" && -r "$file" ]] || { say "No se puede leer: $file"; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    number=$((number + 1))
    line="${line%$'\r'}"
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue
    if ! valid_name "$line"; then
      printf 'Línea %s: usuario inválido: %s\n' "$number" "$line" >&2
      errors=$((errors + 1))
      continue
    fi
    [[ -z "${seen[$line]:-}" ]] || continue
    seen[$line]=1
    IMPORT_USERS+=("$line")
  done < "$file"
  (( errors == 0 )) || return 1
  (( ${#IMPORT_USERS[@]} > 0 )) || { say 'El TXT no contiene usuarios.'; return 1; }
}

import_students() {
  local file="$1" dry_run="${2:-false}" u password credentials passfile profile
  local added=0 skipped=0 failures=0
  local -a pending=()
  parse_user_file "$file" || return 1
  say "Usuarios únicos válidos: ${#IMPORT_USERS[@]}"
  if [[ "$dry_run" == true ]]; then
    printf '  %s\n' "${IMPORT_USERS[@]}"
    say 'Vista previa: no se han modificado cuentas ni certificados. No verifica la PKI.'
    return 0
  fi
  # Preflight completo antes de crear la primera cuenta. No adoptar cuentas ajenas.
  for u in "${IMPORT_USERS[@]}"; do
    if [[ "$ACCESS_MODE" == linux ]] && is_managed_user "$u"; then
      say "Omitido (cuenta ya gestionada): $u"
      skipped=$((skipped + 1))
      continue
    fi
    if is_managed_user "$u" && [[ -s "$PROFILE_DIR/$u.ovpn" && -s "$EASYRSA_DIR/pki/private/$u.key" ]] \
      && openssl verify -CAfile "$OVPN_DIR/ca.crt" -CRLfile "$CRL_FILE" -crl_check \
           "$EASYRSA_DIR/pki/issued/$u.crt" >/dev/null 2>&1; then
      say "Omitido (ya gestionado, con certificado válido): $u"
      skipped=$((skipped + 1))
      continue
    fi
    if id "$u" &>/dev/null || getent group "$u" >/dev/null \
      || [[ -e "/home/$u" || -L "/home/$u" || -e "$PROFILE_DIR/$u.ovpn" \
         || -e "$EASYRSA_DIR/pki/issued/$u.crt" || -e "$EASYRSA_DIR/pki/private/$u.key" \
         || -e "$EASYRSA_DIR/pki/reqs/$u.req" ]]; then
      say "Conflicto: $u ya tiene cuenta, grupo, HOME o archivos PKI/perfil. Revisa antes de importar."
      failures=$((failures + 1))
    else
      pending+=("$u")
    fi
  done
  (( failures == 0 )) || return 1
  (( ${#pending[@]} > 0 )) || { say "Sin cuentas nuevas; omitidas: $skipped"; return 0; }
  if [[ "$ACCESS_MODE" == openvpn ]]; then ensure_vpn_host || return 1; fi
  credentials="$(mktemp "$PROFILE_DIR/credenciales-$(date +%Y%m%d-%H%M%S)-XXXXXXXX.tsv")" || return 1
  printf 'usuario\tcontraseña\tperfil\testado\n' > "$credentials" || return 1
  chmod 600 "$credentials" || return 1
  say "Contraseñas privadas en $credentials (no se muestran en pantalla)."
  for u in "${pending[@]}"; do
    password="$(openssl rand -hex 18)" || return 1
    profile='-'
    if [[ "$ACCESS_MODE" == openvpn ]]; then profile="$PROFILE_DIR/$u.ovpn"; fi
    # Registrar antes de las mutaciones permite recuperar una importación interrumpida.
    printf '%s\t%s\t%s\tpendiente_verificar\n' "$u" "$password" "$profile" >> "$credentials" || return 1
    if ! useradd -m -U -s /bin/bash -G "$GROUP" "$u"; then
      say "Falló useradd para $u. Importación detenida; revisa $credentials."
      return 1
    fi
    if ! chmod 700 "/home/$u" || ! printf '%s:%s\n' "$u" "$password" | chpasswd; then
      usermod -L -e 1 "$u" || true
      say "Falló la preparación de $u; cuenta bloqueada. Importación detenida."
      return 1
    fi
    if [[ "$ACCESS_MODE" == linux ]]; then
      unset password
      printf '%s\t\t-\tcreado\n' "$u" >> "$credentials" || return 1
      added=$((added + 1))
      continue
    fi
    # Usar un FD evita pasar contraseñas como argumentos, variables de entorno o archivos temporales.
    exec {passfile}<<< "$password"
    if ! (cd "$EASYRSA_DIR" && EASYRSA_BATCH=1 EASYRSA_PASSOUT="file:/dev/fd/$passfile" \
        ./easyrsa build-client-full "$u"); then
      exec {passfile}<&-
      usermod -L -e 1 "$u" || true
      say "Falló el certificado de $u; cuenta bloqueada. Conserva la PKI para revisar; no reimportes sin resolver el conflicto."
      return 1
    fi
    exec {passfile}<&-
    unset password
    if ! make_profile "$u"; then
      usermod -L -e 1 "$u" || true
      say "Falló el perfil de $u; cuenta bloqueada. Revisa PKI/perfil antes de reintentar."
      return 1
    fi
    printf '%s\t\t%s\tcreado\n' "$u" "$PROFILE_DIR/$u.ovpn" >> "$credentials" || return 1
    added=$((added + 1))
  done
  say "Importación terminada: creados=$added, omitidos=$skipped. Credenciales: $credentials"
  if [[ "$ACCESS_MODE" == openvpn ]]; then
    say 'Entrega a cada alumno únicamente su propia contraseña y su propio .ovpn.'
  else
    say 'Entrega a cada alumno su propia contraseña y la dirección privada del servidor.'
  fi
}

main() {
  if [[ -r /etc/ids-remote-access.mode ]] && [[ "$(cat /etc/ids-remote-access.mode)" == linux ]]; then
    ACCESS_MODE=linux
  fi
  case "${1:-}" in
    --linux-only) ACCESS_MODE=linux; shift ;;
    --openvpn) ACCESS_MODE=openvpn; shift ;;
  esac
  if [[ "$ACCESS_MODE" == linux ]]; then PROFILE_DIR=/root/credenciales-alumnos; fi
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
    --import)
      [[ $# -eq 2 || ( $# -eq 3 && "$3" == --dry-run ) ]] || { usage; return 1; }
      if [[ "${3:-}" == --dry-run ]]; then import_students "$2" true; return; fi
      ;;
    '') [[ $# -eq 0 ]] || { usage; return 1; } ;;
    *) usage; return 1 ;;
  esac
  [[ "$EUID" -eq 0 ]] || fail 'Ejecuta con sudo.'
  # Una sola operación administrativa a la vez sobre cuentas/PKI.
  exec 9>/run/lock/ids-usuarios.lock
  flock -n 9 || fail 'Otro gestor de alumnos está en ejecución.'
  require_environment
  if [[ "${1:-}" == --import ]]; then import_students "$2"; return; fi
  while :; do
    printf '\n=========== GESTOR DE ALUMNOS VPN / X2Go ===========\n'
    printf 'Modo de acceso: %s\n' "$ACCESS_MODE"
    printf '1) Agregar alumno\n'
    printf '2) Listar alumnos\n'
    printf '3) Suspender cuenta Linux (reversible)\n'
    printf '4) Reactivar cuenta Linux\n'
    printf '5) Eliminar alumno (revoca certificado en modo OpenVPN; conserva HOME)\n'
    printf '6) Importar alumnos desde un TXT\n'
    printf '0) Salir\n'
    local choice
    read_var choice 'Opción: '
    case "$choice" in
      1) add_student ;;
      2) list_students ;;
      3) suspend_student ;;
      4) reactivate_student ;;
      5) remove_student ;;
      6) local file; read_var file 'Ruta del TXT: '; import_students "$file" || say 'Importación detenida; revisa los errores.' ;;
      0) exit 0 ;;
      *) say 'Opción inválida.' ;;
    esac
  done
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
