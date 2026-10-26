"""Root-free parser and provisioning tests; Linux account mutations are stubbed."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Scripts(unittest.TestCase):
    def run_bash(self, code, *args):
        return subprocess.run(["bash", "-c", code, "test", *map(str, args)],
                              capture_output=True, text=True)

    def test_syntax_and_help(self):
        for script in ("usr_mgr.sh", "install_server.sh", "install_tailscale.sh", "install_hub.sh", "install_lab.sh"):
            result = subprocess.run(["bash", "-n", str(ROOT / script)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run(["bash", str(ROOT / script), "--help"], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_parser(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "users.txt"
            for content, expected in [
                (b"# class\r\n  alumno01  \r\nalumno02 # note\r\nalumno01", 0),
                (b"alumno01\nbad name\n", 1),
                (b"alumno01\n$(touch injected)\n", 1),
                (b"servidor\n", 1),
                (b"# empty\n", 1),
                (b"ab\n", 1),
            ]:
                path.write_bytes(content)
                result = subprocess.run(["bash", str(ROOT / "usr_mgr.sh"), "--import", str(path), "--dry-run"],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                if expected == 0:
                    self.assertIn("Usuarios únicos válidos: 2", result.stdout)
                    self.assertEqual(result.stdout.count("  alumno01\n"), 1)

    def test_import_with_real_pki_and_stubbed_accounts(self):
        with tempfile.TemporaryDirectory() as temp:
            code = r'''
set -euo pipefail
source "$1/usr_mgr.sh"
EASYRSA_DIR="$2/easy-rsa"
OVPN_DIR="$2/server"
PROFILE_DIR="$2/profiles"
CRL_FILE="$OVPN_DIR/crl.pem"
export EASYRSA_BATCH=1 EASYRSA_ALGO=ec EASYRSA_CURVE=secp384r1
mkdir -p "$EASYRSA_DIR" "$OVPN_DIR" "$PROFILE_DIR"
cp -a /usr/share/easy-rsa/. "$EASYRSA_DIR/"
(cd "$EASYRSA_DIR"; ./easyrsa init-pki; ./easyrsa build-ca nopass; ./easyrsa gen-crl)
cp "$EASYRSA_DIR/pki/ca.crt" "$OVPN_DIR/ca.crt"
cp "$EASYRSA_DIR/pki/crl.pem" "$CRL_FILE"
openvpn --genkey tls-crypt "$OVPN_DIR/tls-crypt.key"
printf 'student01\nstudent02\nstudent01\n' > "$2/users.txt"
# Stubs ensure no actual accounts, homes or passwords are modified.
is_managed_user() { return 1; }
id() { return 1; }
getent() { return 1; }
ensure_vpn_host() { VPN_HOST=vpn.example.org; }
# Separate path variable: function arguments are the useradd arguments.
ACCOUNT_LOG="$2/accounts.log"
useradd() { printf '%s\n' "$*" >> "$ACCOUNT_LOG"; }
chmod() { if [[ "$*" == '700 /home/'* ]]; then return 0; fi; command chmod "$@"; }
chpasswd() { cat > /dev/null; }
usermod() { return 0; }
import_students "$2/users.txt"
[[ $(wc -l < "$ACCOUNT_LOG") == 2 ]]
credentials=("$PROFILE_DIR"/credenciales-*.tsv)
[[ $(stat -c %a "${credentials[0]}") == 600 ]]
for u in student01 student02; do
  [[ $(stat -c %a "$PROFILE_DIR/$u.ovpn") == 600 ]]
  grep -q 'BEGIN ENCRYPTED PRIVATE KEY' "$PROFILE_DIR/$u.ovpn"
  openssl verify -CAfile "$OVPN_DIR/ca.crt" "$EASYRSA_DIR/pki/issued/$u.crt"
  password=$(awk -F '\t' -v u="$u" '$1 == u && $2 != "" {print $2}' "${credentials[0]}")
  printf '%s\n' "$password" | openssl pkey -in "$EASYRSA_DIR/pki/private/$u.key" -passin stdin -noout
  ! openssl pkey -in "$EASYRSA_DIR/pki/private/$u.key" -passin pass: -noout 2>/dev/null
  grep -q '^remote vpn.example.org 1194$' "$PROFILE_DIR/$u.ovpn"
done
# All existing complete managed users are skipped, producing no more accounts.
is_managed_user() { return 0; }
import_students "$2/users.txt"
[[ $(wc -l < "$ACCOUNT_LOG") == 2 ]]
# Conflict preflight must abort before creating the first account.
printf 'student03\nconflict01\n' > "$2/conflicts.txt"
id() { [[ "$1" == conflict01 ]]; }
is_managed_user() { return 1; }
if import_students "$2/conflicts.txt"; then exit 1; fi
[[ $(wc -l < "$ACCOUNT_LOG") == 2 ]]
# Certificate failure stops the batch and locks the partially created account.
printf '#!/bin/sh\nexit 1\n' > "$EASYRSA_DIR/easyrsa"
printf 'student04\nstudent05\n' > "$2/failure.txt"
LOCK_LOG="$2/locks.log"
usermod() { printf '%s\n' "$*" >> "$LOCK_LOG"; }
if import_students "$2/failure.txt"; then exit 1; fi
grep -Fxq -- '-L -e 1 student04' "$LOCK_LOG"
[[ $(wc -l < "$ACCOUNT_LOG") == 3 ]]
[[ ! -e "$PROFILE_DIR/student04.ovpn" ]]
'''
            result = self.run_bash(code, ROOT, temp)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_linux_import_without_pki(self):
        with tempfile.TemporaryDirectory() as temp:
            code = r'''
set -euo pipefail
source "$1/usr_mgr.sh"
ACCESS_MODE=linux
PROFILE_DIR="$2/credentials"
EASYRSA_DIR="$2/missing-pki"
mkdir -p "$PROFILE_DIR"
printf 'student01\nstudent02\n' > "$2/users.txt"
is_managed_user() { return 1; }
id() { return 1; }
getent() { return 1; }
ACCOUNT_LOG="$2/accounts.log"
useradd() { echo created >> "$ACCOUNT_LOG"; }
chmod() { if [[ "$*" == '700 /home/'* ]]; then return 0; fi; command chmod "$@"; }
chpasswd() { cat > /dev/null; }
ensure_vpn_host() { echo 'Unexpected VPN lookup' >&2; return 1; }
import_students "$2/users.txt"
[[ $(wc -l < "$ACCOUNT_LOG") == 2 ]]
[[ ! -e "$EASYRSA_DIR" ]]
credentials=("$PROFILE_DIR"/credenciales-*.tsv)
[[ $(stat -c %a "${credentials[0]}") == 600 ]]
[[ $(awk -F '\t' '$4 == "creado" {n++} END {print n}' "${credentials[0]}") == 2 ]]
is_managed_user() { return 0; }
import_students "$2/users.txt"
[[ $(wc -l < "$ACCOUNT_LOG") == 2 ]]
'''
            result = self.run_bash(code, ROOT, temp)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_ssh_source_restriction(self):
        with tempfile.TemporaryDirectory() as temp:
            code = r'''
set -euo pipefail
source "$1/install_server.sh"
SSH_SNIPPET="$2/students.conf"
STUDENT_NETWORK='100.64.0.0/10'
GROUP=$(id -gn)
# Only a temporary snippet is written; systemd changes are stubbed.
install() { return 0; }
systemctl() { return 0; }
sshd() { return 0; }
configure_ssh_x2go
ssh-keygen -q -t ed25519 -N '' -f "$2/hostkey"
printf 'HostKey %s\nUsePAM yes\nPasswordAuthentication no\nInclude %s\n' "$2/hostkey" "$SSH_SNIPPET" > "$2/sshd.conf"
inside=$(/usr/sbin/sshd -T -f "$2/sshd.conf" -C "user=$(id -un),addr=100.64.0.2,host=client")
outside=$(/usr/sbin/sshd -T -f "$2/sshd.conf" -C "user=$(id -un),addr=192.0.2.2,host=client")
[[ "$inside" == *'passwordauthentication yes'* ]]
[[ "$inside" == *'allowtcpforwarding yes'* ]]
[[ "$outside" == *'passwordauthentication no'* ]]
[[ "$outside" == *'pubkeyauthentication no'* ]]
[[ "$outside" == *'kbdinteractiveauthentication no'* ]]
'''
            result = self.run_bash(code, ROOT, temp)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


    def test_hub_profiles_with_real_certificates(self):
        with tempfile.TemporaryDirectory() as temp:
            code = r'''
set -euo pipefail
source "$1/install_hub.sh"
PKI_HOME="$2/ca"
BASE="$2/server"
PROFILES="$2/profiles"
mkdir -p "$PKI_HOME" "$BASE" "$PROFILES"
cp -a /usr/share/easy-rsa/. "$PKI_HOME/"
export EASYRSA_BATCH=1 EASYRSA_ALGO=ec EASYRSA_CURVE=secp384r1
(cd "$PKI_HOME"; ./easyrsa init-pki; ./easyrsa build-ca nopass; ./easyrsa build-client-full labpc nopass; EASYRSA_PASSOUT=pass:student-test-pass ./easyrsa build-client-full student01)
cp "$PKI_HOME/pki/ca.crt" "$BASE/ca.crt"
openvpn --genkey tls-crypt "$BASE/tls-crypt.key"
PUBLIC_HOST=152.74.19.95
PORT=443
TRANSPORT=tcp
validate_endpoint
export_profile labpc
export_profile student01
python3 - "$PROFILES" <<'PY'
from pathlib import Path
import subprocess, sys
root = Path(sys.argv[1])
for name in ('labpc', 'student01'):
    profile = root / (name + '.ovpn')
    text = profile.read_text()
    assert profile.stat().st_mode & 0o777 == 0o600
    assert 'proto tcp-client\nremote 152.74.19.95 443\n' in text
    assert 'verify-x509-name servidor name\n' in text
    for tag in ('ca', 'cert', 'key'):
        (root / tag).write_text(text.split('<' + tag + '>\n')[1].split('</' + tag + '>')[0])
    subprocess.run(['openssl', 'verify', '-purpose', 'sslclient', '-CAfile', str(root/'ca'), str(root/'cert')], check=True)
    password = 'student-test-pass' if name == 'student01' else ''
    subprocess.run(['openssl', 'pkey', '-in', str(root/'key'), '-passin', 'pass:' + password, '-noout'], check=True)
    assert ('BEGIN ENCRYPTED PRIVATE KEY' in text) == (name == 'student01')
PY
# Existing exports are immutable; a failed overwrite preserves the original.
cp "$PROFILES/student01.ovpn" "$2/original"
if (export_profile student01); then exit 1; fi
cmp "$PROFILES/student01.ovpn" "$2/original"
for name in labpc servidor '../bad' 'bad name'; do
  if valid_name "$name"; then exit 1; fi
done
for bad in 0 65536 '443;bad'; do
  if (PORT="$bad"; validate_endpoint); then exit 1; fi
done
'''
            result = self.run_bash(code, ROOT, temp)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_ssh_migration_and_rollback(self):
        for scenario in ('valid', 'custom', 'invalid'):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temp:
                code = r'''
set -euo pipefail
source "$1/install_server.sh"
SSH_SNIPPET="$2/students.conf"
GROUP=$(id -gn)
STUDENT_NETWORK=100.64.0.0/10
render_student_ssh > "$SSH_SNIPPET"
if [[ "$3" == custom ]]; then echo '# custom policy' >> "$SSH_SNIPPET"; fi
cp "$SSH_SNIPPET" "$2/original"
ssh-keygen -q -t ed25519 -N '' -f "$2/hostkey"
printf 'HostKey %s\nUsePAM yes\nInclude %s\n' "$2/hostkey" "$SSH_SNIPPET" > "$2/sshd.conf"
SCENARIO="$3"
TEST_CONFIG="$2/sshd.conf"
sshd() { [[ "$SCENARIO" != invalid ]] && /usr/sbin/sshd -t -f "$TEST_CONFIG"; }
STUDENT_NETWORK=10.77.0.0/24
if (migrate_student_ssh "$STUDENT_NETWORK"); then result=0; else result=$?; fi
if [[ "$SCENARIO" != valid ]]; then
  [[ "$result" != 0 ]]
  cmp "$SSH_SNIPPET" "$2/original"
else
  [[ "$result" == 0 ]]
  backup=("$SSH_SNIPPET".backup-*)
  cmp "${backup[0]}" "$2/original"
  inside=$(/usr/sbin/sshd -T -f "$TEST_CONFIG" -C "user=$(id -un),addr=10.77.0.10,host=client")
  outside=$(/usr/sbin/sshd -T -f "$TEST_CONFIG" -C "user=$(id -un),addr=100.64.0.2,host=client")
  [[ "$inside" == *'passwordauthentication yes'* && "$inside" == *'allowtcpforwarding yes'* ]]
  [[ "$outside" == *'passwordauthentication no'* && "$outside" == *'pubkeyauthentication no'* ]]
fi
'''
                result = self.run_bash(code, ROOT, temp, scenario)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_tailscale_login_states(self):
        for state in ("Running", "NeedsLogin", "NeedsMachineAuth", "Failure", "Unknown"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as temp:
                code = r'''
set -euo pipefail
source "$1/install_tailscale.sh"
STATE_FILE="$2/state"
CALL_LOG="$2/calls"
scenario="$3"
printf '%s' "$scenario" > "$STATE_FILE"
tailscale() {
  case "$1" in
    status)
      current=$(cat "$STATE_FILE")
      if [[ "$current" == Unknown ]]; then return 1; fi
      printf '{"BackendState":"%s"}\n' "$current"
      ;;
    ip) echo '100.64.0.10' ;;
    up)
      printf '%s\n' "$*" >> "$CALL_LOG"
      [[ "$*" == 'up --qr --timeout=120s' ]] || return 1
      [[ "$scenario" != Failure ]] || return 1
      echo 'LOGIN_URL_FROM_TAILSCALE'
      printf Running > "$STATE_FILE"
      ;;
    *) return 1 ;;
  esac
}
if authenticate_tailscale; then result=0; else result=$?; fi
case "$scenario" in
  Running) [[ "$result" == 0 && ! -e "$CALL_LOG" ]] ;;
  NeedsMachineAuth) [[ "$result" != 0 && ! -e "$CALL_LOG" ]] ;;
  NeedsLogin|Unknown) [[ "$result" == 0 && -s "$CALL_LOG" ]] ;;
  Failure) [[ "$result" != 0 && -s "$CALL_LOG" ]] ;;
esac
'''
                result = self.run_bash(code, ROOT, temp, state)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                if state == "Running":
                    self.assertIn("ya está autenticado", result.stdout)
                elif state == "NeedsMachineAuth":
                    self.assertIn("admin/machines", result.stdout)
                elif state == "Failure":
                    self.assertIn("--login-only", result.stdout)
                else:
                    self.assertIn("LOGIN_URL_FROM_TAILSCALE", result.stdout)


if __name__ == "__main__":
    unittest.main()
