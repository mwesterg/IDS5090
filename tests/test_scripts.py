"""Root-free Linux-account and SSH policy tests. System mutations are stubbed."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Scripts(unittest.TestCase):
    def test_syntax_and_help(self):
        for script in ("usr_mgr.sh", "install_wireguard.sh"):
            result = subprocess.run(["bash", "-n", str(ROOT / script)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run(["bash", str(ROOT / script), "--help"], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        result = subprocess.run(["bash", "-n", str(ROOT / "lib/remote_access.sh")], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def run_bash(self, code, *args):
        return subprocess.run(["bash", "-c", code, "test", *map(str, args)],
                              capture_output=True, text=True)

    def test_parser(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "users.txt"
            for content, expected in [
                (b"# class\r\n  alumno01  \r\nalumno02 # note\r\nalumno01", 0),
                (b"alumno01\nbad name\n", 1),
                (b"alumno01\n$(touch injected)\n", 1),
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

    def test_import_creates_private_credentials_and_skips_existing(self):
        with tempfile.TemporaryDirectory() as temp:
            code = r'''
set -euo pipefail
source "$1/usr_mgr.sh"
CREDENTIAL_DIR="$2/credentials"
mkdir -p "$CREDENTIAL_DIR"
printf 'student01\nstudent02\n' > "$2/users.txt"
is_managed_user() { return 1; }
id() { return 1; }
getent() { return 1; }
ACCOUNT_LOG="$2/accounts.log"
useradd() { echo created >> "$ACCOUNT_LOG"; }
chmod() { if [[ "$*" == '700 /home/'* ]]; then return 0; fi; command chmod "$@"; }
chpasswd() { cat > /dev/null; }
import_students "$2/users.txt"
[[ $(wc -l < "$ACCOUNT_LOG") == 2 ]]
credentials=("$CREDENTIAL_DIR"/credenciales-*.tsv)
[[ $(stat -c %a "${credentials[0]}") == 600 ]]
[[ $(awk -F '\t' '$3 == "creado" {n++} END {print n}' "${credentials[0]}") == 2 ]]
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
source "$1/lib/remote_access.sh"
SSH_SNIPPET="$2/students.conf"
STUDENT_NETWORK='10.66.0.0/24'
GROUP=$(id -gn)
# Only a temporary snippet is written; systemd changes are stubbed.
install() { return 0; }
systemctl() { return 0; }
sshd() { return 0; }
configure_ssh_x2go
ssh-keygen -q -t ed25519 -N '' -f "$2/hostkey"
printf 'HostKey %s\nUsePAM yes\nPasswordAuthentication no\nInclude %s\n' "$2/hostkey" "$SSH_SNIPPET" > "$2/sshd.conf"
inside=$(/usr/sbin/sshd -T -f "$2/sshd.conf" -C "user=$(id -un),addr=10.66.0.10,host=client")
outside=$(/usr/sbin/sshd -T -f "$2/sshd.conf" -C "user=$(id -un),addr=192.0.2.2,host=client")
[[ "$inside" == *'passwordauthentication yes'* ]]
[[ "$inside" == *'allowtcpforwarding yes'* ]]
[[ "$outside" == *'passwordauthentication no'* ]]
[[ "$outside" == *'pubkeyauthentication no'* ]]
[[ "$outside" == *'kbdinteractiveauthentication no'* ]]
'''
            result = self.run_bash(code, ROOT, temp)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_ssh_migration_and_rollback(self):
        for scenario in ('valid', 'custom', 'invalid'):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temp:
                code = r'''
set -euo pipefail
source "$1/lib/remote_access.sh"
SSH_SNIPPET="$2/students.conf"
GROUP=$(id -gn)
STUDENT_NETWORK=10.66.0.0/24
render_student_ssh > "$SSH_SNIPPET"
if [[ "$3" == custom ]]; then echo '# custom policy' >> "$SSH_SNIPPET"; fi
cp "$SSH_SNIPPET" "$2/original"
ssh-keygen -q -t ed25519 -N '' -f "$2/hostkey"
printf 'HostKey %s\nUsePAM yes\nInclude %s\n' "$2/hostkey" "$SSH_SNIPPET" > "$2/sshd.conf"
SCENARIO="$3"
TEST_CONFIG="$2/sshd.conf"
sshd() { [[ "$SCENARIO" != invalid ]] && /usr/sbin/sshd -t -f "$TEST_CONFIG"; }
STUDENT_NETWORK=10.67.0.0/24
if (migrate_student_ssh "$STUDENT_NETWORK"); then result=0; else result=$?; fi
if [[ "$SCENARIO" != valid ]]; then
  [[ "$result" != 0 ]]
  cmp "$SSH_SNIPPET" "$2/original"
else
  [[ "$result" == 0 ]]
  backup=("$SSH_SNIPPET".backup-*)
  cmp "${backup[0]}" "$2/original"
  inside=$(/usr/sbin/sshd -T -f "$TEST_CONFIG" -C "user=$(id -un),addr=10.67.0.10,host=client")
  outside=$(/usr/sbin/sshd -T -f "$TEST_CONFIG" -C "user=$(id -un),addr=10.66.0.10,host=client")
  [[ "$inside" == *'passwordauthentication yes'* && "$inside" == *'allowtcpforwarding yes'* ]]
  [[ "$outside" == *'passwordauthentication no'* && "$outside" == *'pubkeyauthentication no'* ]]
fi
'''
                result = self.run_bash(code, ROOT, temp, scenario)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_conflicts_abort_before_creating_any_account(self):
        with tempfile.TemporaryDirectory() as temp:
            code = r'''
set -euo pipefail
source "$1/usr_mgr.sh"
printf 'newstudent\nexistingstudent\n' > "$2/users.txt"
is_managed_user() { return 1; }
id() { [[ "$1" == existingstudent ]]; }
getent() { return 1; }
useradd() { echo unexpected > "$2/created"; }
if import_students "$2/users.txt"; then exit 1; fi
[[ ! -e "$2/created" ]]
'''
            result = self.run_bash(code, ROOT, temp)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_password_failure_blocks_account_and_stops_batch(self):
        with tempfile.TemporaryDirectory() as temp:
            code = r'''
set -euo pipefail
source "$1/usr_mgr.sh"
CREDENTIAL_DIR="$2"
printf 'firststudent\nsecondstudent\n' > "$2/users.txt"
is_managed_user() { return 1; }
id() { return 1; }
getent() { return 1; }
ACCOUNT_LOG="$2/accounts"
LOCK_LOG="$2/locked"
useradd() { echo "$*" >> "$ACCOUNT_LOG"; }
chmod() { if [[ "$*" == '700 /home/'* ]]; then return 0; fi; command chmod "$@"; }
chpasswd() { cat >/dev/null; return 1; }
usermod() { echo "$*" >> "$LOCK_LOG"; }
if import_students "$2/users.txt"; then exit 1; fi
[[ $(wc -l < "$ACCOUNT_LOG") == 1 ]]
grep -Fxq -- '-L -e 1 firststudent' "$LOCK_LOG"
credentials=("$CREDENTIAL_DIR"/credenciales-*.tsv)
! grep -q 'creado' "${credentials[0]}"
'''
            result = self.run_bash(code, ROOT, temp)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_managed_account_guard(self):
        for scenario in ('managed', 'system', 'foreign_group', 'foreign_home'):
            with self.subTest(scenario=scenario):
                code = r'''
set -euo pipefail
source "$1/usr_mgr.sh"
SCENARIO="$2"
id() {
  case "$1" in
    -nG) if [[ "$SCENARIO" == foreign_group ]]; then echo unrelated; else echo "$GROUP"; fi ;;
    -u) if [[ "$SCENARIO" == system ]]; then echo 0; else echo 1001; fi ;;
    *) return 0 ;;
  esac
}
getent() {
  if [[ "$SCENARIO" == foreign_home ]]; then
    echo 'student:x:1001:1001::/root:/bin/bash'
  else
    echo 'student:x:1001:1001::/home/student:/bin/bash'
  fi
}
if is_managed_user student; then result=0; else result=$?; fi
if [[ "$SCENARIO" == managed ]]; then [[ "$result" == 0 ]]; else [[ "$result" != 0 ]]; fi
'''
                result = self.run_bash(code, ROOT, scenario)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
