#!/usr/bin/env bash
# Linux accounts for the WireGuard + SSH/X2Go lab; VPN peers are managed in the GUI.
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/remote_access.sh"

say() { printf '\n%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
read_var() { local __name="$1" __prompt="$2"; IFS= read -r -p "$__prompt" "$__name"; }
valid_name() { [[ "$1" =~ ^[a-z][a-z0-9_-]{2,30}$ ]]; }

require_environment() {
  [[ "$EUID" -eq 0 ]] || fail 'Ejecuta con sudo.'
  local command
  for command in useradd openssl chpasswd flock; do
    command -v "$command" >/dev/null || fail "Falta $command."
  done
  groupadd -f "$GROUP"
  install -d -m 700 "$CREDENTIAL_DIR" "$ARCHIVE_DIR"
}

is_managed_user() {
  id "$1" &>/dev/null && id -nG "$1" | tr ' ' '\n' | grep -Fxq "$GROUP" \
    && [[ "$(id -u "$1")" -ge 1000 ]] \
    && [[ "$(getent passwd "$1" | cut -d: -f6)" == "/home/$1" ]]
}

add_student() {
  local u
  say '=== AGREGAR ALUMNO ==='
  read_var u 'Usuario nuevo (ej. alumno01): '
  valid_name "$u" || { say 'Nombre inválido: minúsculas, números, _ o -, longitud 3-31.'; return; }
  if id "$u" &>/dev/null || getent group "$u" >/dev/null || [[ -e "/home/$u" || -L "/home/$u" ]]; then
    say 'Ya existe esa cuenta, grupo o HOME. Revisa antes de crear el alumno.'
    return
  fi
  useradd -m -U -s /bin/bash -G "$GROUP" "$u" || return
  if ! chmod 700 "/home/$u" || ! passwd "$u"; then
    usermod -L -e 1 "$u" || true
    say 'Falló la preparación; cuenta bloqueada. Revisa antes de reactivar.'
    return
  fi
  say "Alumno creado: $u. Conexión X2Go: IP WireGuard del laboratorio, puerto 22, XFCE."
}

list_students() {
  say "=== ALUMNOS DEL GRUPO $GROUP ==="
  local entry gid accounts members u count=0 pass status unavailable=0
  if ! entry="$(getent group "$GROUP")"; then
    say "El grupo $GROUP no existe o no se puede consultar."
    return
  fi
  gid="$(printf '%s\n' "$entry" | cut -d: -f3)"
  if ! accounts="$(getent passwd)"; then
    accounts=''
    say 'No se pudo consultar el registro de cuentas para incluir miembros por grupo principal.'
  fi
  members="$(
    {
      printf '%s\n' "$entry" | cut -d: -f4 | tr ',' '\n'
      printf '%s\n' "$accounts" | awk -F: -v gid="$gid" '$4 == gid {print $1}'
    } | LC_ALL=C sort -u
  )"
  if [[ -z "$members" ]]; then say 'No hay cuentas registradas en el grupo.'; return; fi
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    count=$((count + 1))
    pass='sin cuenta'
    if id "$u" &>/dev/null; then
      if status="$(passwd -S "$u" 2>/dev/null)"; then
        pass="$(printf '%s\n' "$status" | awk '{print $2}')"
        pass="${pass:-no disponible}"
      else
        pass='no disponible'
        unavailable=1
      fi
    fi
    printf '%-22s contraseña=%s\n' "$u" "$pass"
  done < <(printf '%s\n' "$members" | tr ',' '\n')
  say "Total listado: $count | L = contraseña bloqueada; consulta chage -l para expiración."
  if (( unavailable )); then
    say 'No se pudo consultar algún estado de contraseña. Ejecuta el listado con sudo para comprobarlo.'
  fi
}

suspend_student() {
  local u answer
  say '=== SUSPENDER CUENTA (REVERSIBLE) ==='
  read_var u 'Alumno a suspender: '
  valid_name "$u" && is_managed_user "$u" || { say 'No es una cuenta gestionada.'; return; }
  say 'Se bloqueará Linux y se cerrarán sus sesiones. Retira el peer WireGuard por separado en la GUI.'
  read_var answer "Confirmar suspensión de $u [s/N]: "
  [[ "$answer" == s || "$answer" == S ]] || return
  usermod -L -e 1 "$u"
  loginctl terminate-user "$u" 2>/dev/null || true
  pkill -TERM -u "$u" 2>/dev/null || true
  say 'Cuenta Linux suspendida.'
}

reactivate_student() {
  local u
  say "=== REACTIVAR CUENTA LINUX ==="
  read_var u "Alumno a reactivar: "
  valid_name "$u" && is_managed_user "$u" || { say "No es una cuenta gestionada por este script."; return; }
  usermod -e '' "$u"
  usermod -U "$u" 2>/dev/null || { say "No se puede desbloquear la contraseña (posiblemente no tenga contraseña). Usa passwd $u."; return; }
  say "Cuenta Linux reactivada. El acceso WireGuard se gestiona por separado en su GUI."
}

remove_student() {
  local u confirm homedir archived timestamp
  say '=== ELIMINAR ALUMNO (CONSERVA HOME) ==='
  read_var u 'Alumno a eliminar: '
  valid_name "$u" && is_managed_user "$u" || { say 'No es una cuenta gestionada.'; return; }
  homedir="/home/$u"
  say "Se cerrarán sus sesiones, eliminará la cuenta y archivará HOME en $ARCHIVE_DIR."
  say 'Retira el peer WireGuard por separado en la GUI del servidor público.'
  read_var confirm "Escribe exactamente ELIMINAR $u para continuar: "
  [[ "$confirm" == "ELIMINAR $u" ]] || { say 'Cancelado.'; return; }
  usermod -L -e 1 "$u"
  loginctl terminate-user "$u" 2>/dev/null || true
  pkill -TERM -u "$u" 2>/dev/null || true
  sleep 1
  pkill -KILL -u "$u" 2>/dev/null || true
  if ! userdel "$u"; then
    say 'userdel falló; la cuenta quedó bloqueada. Revisa procesos antes de reintentar.'
    return
  fi
  if [[ -d "$homedir" && ! -L "$homedir" ]]; then
    timestamp="$(date +%Y%m%d-%H%M%S)"
    archived="$ARCHIVE_DIR/${u}-${timestamp}"
    if mv -- "$homedir" "$archived"; then
      chmod 700 "$archived"
      say "Archivos conservados en: $archived"
    else
      say "No se pudieron archivar sus archivos; siguen en $homedir."
    fi
  fi
  say 'Cuenta Linux eliminada. El acceso VPN se administra por separado en la GUI.'
}

usage() {
  cat <<'EOF'
Uso: sudo bash usr_mgr.sh [--list | --import usuarios.txt [--dry-run]]
     bash usr_mgr.sh --help

Sin argumentos: menú de cuentas Linux SSH/X2Go. Opción 6: importar un TXT.
--list muestra miembros por grupo principal y suplementario, sin duplicados.
TXT: un usuario por línea, 3-31 caracteres; minúsculas, números, _ o -.
Admite líneas vacías, comentarios #, CRLF y nombres duplicados.
--dry-run valida la lista sin privilegios ni cambios en el sistema.
La importación guarda contraseñas individuales en TSV privados bajo
/root/credenciales-alumnos. No crea ni elimina peers de WireGuard;
adminístralos por separado en la GUI del servidor público.
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
  local file="$1" dry_run="${2:-false}" u password credentials
  local added=0 skipped=0 failures=0
  local -a pending=()
  parse_user_file "$file" || return 1
  say "Usuarios únicos válidos: ${#IMPORT_USERS[@]}"
  if [[ "$dry_run" == true ]]; then
    printf '  %s\n' "${IMPORT_USERS[@]}"
    say 'Vista previa: no se han modificado cuentas.'
    return 0
  fi
  for u in "${IMPORT_USERS[@]}"; do
    if is_managed_user "$u"; then
      say "Omitido (cuenta ya gestionada): $u"
      skipped=$((skipped + 1))
      continue
    fi
    if id "$u" &>/dev/null || getent group "$u" >/dev/null || [[ -e "/home/$u" || -L "/home/$u" ]]; then
      say "Conflicto: $u ya tiene cuenta, grupo o HOME. Revisa antes de importar."
      failures=$((failures + 1))
    else
      pending+=("$u")
    fi
  done
  (( failures == 0 )) || return 1
  (( ${#pending[@]} > 0 )) || { say "Sin cuentas nuevas; omitidas: $skipped"; return 0; }
  credentials="$(mktemp "$CREDENTIAL_DIR/credenciales-$(date +%Y%m%d-%H%M%S)-XXXXXXXX.tsv")" || return 1
  printf 'usuario\tcontraseña\testado\n' > "$credentials" || return 1
  chmod 600 "$credentials" || return 1
  say "Contraseñas privadas en $credentials (no se muestran en pantalla)."
  for u in "${pending[@]}"; do
    password="$(openssl rand -hex 18)" || return 1
    printf '%s\t%s\tpendiente_verificar\n' "$u" "$password" >> "$credentials" || return 1
    if ! useradd -m -U -s /bin/bash -G "$GROUP" "$u"; then
      say "Falló useradd para $u. Revisa $credentials antes de reintentar."
      return 1
    fi
    if ! chmod 700 "/home/$u" || ! printf '%s:%s\n' "$u" "$password" | chpasswd; then
      usermod -L -e 1 "$u" || true
      say "Falló la preparación de $u; cuenta bloqueada. Importación detenida."
      return 1
    fi
    unset password
    printf '%s\t\tcreado\n' "$u" >> "$credentials" || return 1
    added=$((added + 1))
  done
  say "Importación terminada: creados=$added, omitidos=$skipped. Credenciales: $credentials"
  say 'Entrega a cada alumno su propia contraseña y la IP WireGuard del laboratorio.'
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
    --list)
      [[ $# -eq 1 ]] || { usage; return 1; }
      list_students; return ;;
    --import)
      [[ $# -eq 2 || ( $# -eq 3 && "$3" == --dry-run ) ]] || { usage; return 1; }
      if [[ "${3:-}" == --dry-run ]]; then import_students "$2" true; return; fi
      ;;
    '') [[ $# -eq 0 ]] || { usage; return 1; } ;;
    *) usage; return 1 ;;
  esac
  [[ "$EUID" -eq 0 ]] || fail 'Ejecuta con sudo.'
  exec 9>/run/lock/ids-usuarios.lock
  flock -n 9 || fail 'Otro gestor/instalador está en ejecución.'
  require_environment
  if [[ "${1:-}" == --import ]]; then import_students "$2"; return; fi
  local choice file
  while :; do
    printf '\n=========== CUENTAS DE ALUMNOS SSH / X2Go ===========\n'
    printf '1) Agregar alumno\n2) Listar alumnos\n3) Suspender cuenta Linux\n'
    printf '4) Reactivar cuenta Linux\n5) Eliminar alumno y archivar HOME\n'
    printf '6) Importar alumnos desde TXT\n0) Salir\n'
    read_var choice 'Opción: '
    case "$choice" in
      1) add_student ;;
      2) list_students ;;
      3) suspend_student ;;
      4) reactivate_student ;;
      5) remove_student ;;
      6) read_var file 'Ruta del TXT: '; import_students "$file" || say 'Importación detenida; revisa los errores.' ;;
      0) return ;;
      *) say 'Opción inválida.' ;;
    esac
  done
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
