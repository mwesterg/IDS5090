"""Root-free WireGuard profile, preservation and status tests. No real VPN keys."""
import base64
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
# Synthetic fixed byte sequences, only for parser tests; not deployment credentials.
PRIVATE = base64.b64encode(bytes(range(32))).decode()
PUBLIC = base64.b64encode(bytes(range(32, 64))).decode()
PRESHARED = base64.b64encode(bytes(range(64, 96))).decode()
PROFILE = f"""[Interface]
PrivateKey = {PRIVATE}
Address = 10.66.0.2/32
[Peer]
PublicKey = {PUBLIC}
PresharedKey = {PRESHARED}
Endpoint = vpn.example.org:51820
AllowedIPs = 10.66.0.0/24
PersistentKeepalive = 25
"""


class WireGuard(unittest.TestCase):
    def validate(self, text, network="10.66.0.0/24"):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / "lab.conf"
            config.write_text(text)
            result = subprocess.run(["bash", str(ROOT / "install_wireguard.sh"),
                                     "--check-config", str(config), "--student-network", network],
                                    capture_output=True, text=True)
            for key in (PRIVATE, PUBLIC, PRESHARED):
                self.assertNotIn(key, result.stdout + result.stderr)
            return result

    def test_valid_split_tunnel_and_snatted_source(self):
        for network in ("10.66.0.0/24", "10.66.0.1/32"):
            result = self.validate(PROFILE, network)
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(result.stdout)
            self.assertEqual(data["addresses"], ["10.66.0.2/32"])
            self.assertEqual(data["student_network"], network)
            self.assertEqual(data["warnings"], [])
            self.assertFalse(data["requires_resolvconf"])

    def test_ipv6_profile(self):
        text = PROFILE.replace("10.66.0.2/32", "fd42:66::2/128").replace(
            "10.66.0.0/24", "fd42:66::/64").replace("vpn.example.org:51820", "[2001:db8::1]:51820")
        result = self.validate(text, "fd42:66::/64")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_profiles_requiring_review_are_rejected(self):
        cases = {
            "full tunnel": PROFILE.replace("10.66.0.0/24", "0.0.0.0/0"),
            "no return route": PROFILE.replace("10.66.0.0/24", "10.66.0.1/32"),
            "hook": PROFILE.replace("[Peer]", "PostUp = echo DO_NOT_EXECUTE\n[Peer]"),
            "routing override": PROFILE.replace("[Peer]", "Table = off\n[Peer]"),
            "save config": PROFILE.replace("[Peer]", "SaveConfig = true\n[Peer]"),
            "bad private key": PROFILE.replace(PRIVATE, "DO_NOT_DISCLOSE_MALFORMED_SECRET"),
            "missing endpoint": PROFILE.replace("Endpoint = vpn.example.org:51820\n", ""),
            "bad port": PROFILE.replace(":51820", ":65536"),
            "bad IPv6 endpoint": PROFILE.replace("vpn.example.org:51820", "[::::]:51820"),
            "invalid address": PROFILE.replace("10.66.0.2/32", "INVALID_ADDRESS"),
            "duplicate key": PROFILE.replace("Address =", f"PrivateKey = {PRIVATE}\nAddress ="),
            "overlapping routes": PROFILE.replace("10.66.0.0/24", "10.66.0.0/24,10.66.0.1/32"),
        }
        for name, text in cases.items():
            with self.subTest(name=name):
                result = self.validate(text)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("DO_NOT_DISCLOSE_MALFORMED_SECRET", result.stdout + result.stderr)
                self.assertNotIn("Traceback", result.stderr)

    def test_dns_and_keepalive_report(self):
        result = self.validate(PROFILE.replace("[Peer]", "DNS = 10.66.0.1\n[Peer]").replace(
            "PersistentKeepalive = 25", "PersistentKeepalive = 0"))
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertTrue(data["requires_resolvconf"])
        self.assertTrue(data["warnings"])

    def test_existing_profiles_are_preserved_and_private(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            (path / "source.conf").write_text(PROFILE)
            code = r'''
set -euo pipefail
source "$1/install_wireguard.sh"
# Stub ownership only, retaining actual private file permissions/copy operations.
chown() { return 0; }
install() { command install -m 600 -- "${@: -2}"; }
wireguard_install_profile "$2/source.conf" "$2/target.conf"
[[ $(stat -c %a "$2/target.conf") == 600 ]]
wireguard_install_profile "$2/source.conf" "$2/target.conf"
printf '\n# changed profile\n' >> "$2/source.conf"
if (wireguard_install_profile "$2/source.conf" "$2/target.conf"); then exit 1; fi
! cmp -s "$2/source.conf" "$2/target.conf"
ln -s "$2/target.conf" "$2/link.conf"
if (wireguard_install_profile "$2/source.conf" "$2/link.conf"); then exit 1; fi
'''
            result = subprocess.run(["bash", "-c", code, "test", str(ROOT), temp],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((path / "target.conf").read_text(), PROFILE)

    def test_handshake_status_does_not_disclose_keys(self):
        for scenario in ("fresh", "stale", "never", "absent", "inactive"):
            with self.subTest(scenario=scenario):
                code = r'''
set -euo pipefail
source "$1/install_wireguard.sh"
SCENARIO="$2"
systemctl() { [[ "$SCENARIO" != inactive ]]; }
ip() { return 0; }
wg() {
  [[ "$*" == 'show ids-wg latest-handshakes' ]] || return 1
  case "$SCENARIO" in
    fresh|inactive) printf 'PUBLIC_KEY_SHOULD_NOT_APPEAR\t%s\n' "$(date +%s)" ;;
    stale) printf 'PUBLIC_KEY_SHOULD_NOT_APPEAR\t1\n' ;;
    never) printf 'PUBLIC_KEY_SHOULD_NOT_APPEAR\t0\n' ;;
    absent) return 1 ;;
  esac
}
if wireguard_status ids-wg; then result=0; else result=$?; fi
if [[ "$SCENARIO" == fresh ]]; then [[ "$result" == 0 ]]; else [[ "$result" != 0 ]]; fi
'''
                result = subprocess.run(["bash", "-c", code, "test", str(ROOT), scenario],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("PUBLIC_KEY_SHOULD_NOT_APPEAR", result.stdout + result.stderr)

    def test_interface_names_cannot_escape_config_directory(self):
        for value in ("../wg0", "wg0;id", "wg 0", "x" * 16):
            result = subprocess.run(["bash", str(ROOT / "install_wireguard.sh"),
                                     "--status", "--interface", value], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Invalid WireGuard interface name", result.stderr)


if __name__ == "__main__":
    unittest.main()
