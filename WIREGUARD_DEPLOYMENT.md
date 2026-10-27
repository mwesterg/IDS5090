# Existing WireGuard server + GPU lab peer

Lab administrator contact: [mwestermeyer@udec.cl](mailto:mwestermeyer@udec.cl).

WireGuard is the current planned access method. The public VPN already exists;
its real configuration has **not yet been supplied**. No WireGuard service,
address, route, key or firewall change has been applied by this work.

```text
Student: individual WireGuard peer + X2Go
                 |
       Existing public WireGuard server
       (forwards permitted student -> lab traffic)
                 |
Lab PC: dedicated outbound WireGuard peer + OpenSSH + XFCE + GPU
```

The lab and students connect out to the public server. The lab router needs no
inbound port forwarding. The network must allow outbound UDP to the actual
WireGuard endpoint; UDP on a chosen port is not HTTPS even if its number is 443.
A successful WireGuard connection on some other device does not prove UDP is
allowed from the lab network.

## 1. Information needed before activation

Obtain a **dedicated lab peer** from the VPN administrator. An existing personal
profile must not be reused simultaneously on the lab and student machines.
Keep its private key and any preshared key outside Git and transfer it privately.
Also establish:

- The public server endpoint and UDP port.
- The assigned lab VPN address(es), and individual addresses for each student/device.
- The exact student source CIDR that SSH on the lab will see. It can be the VPN
  network, a narrower student pool, or the hub's VPN address `/32` if it applies
  source NAT. The source CIDR is not the public server IP and not necessarily
  the subnet containing the lab's own address.
- Whether the hub permits peer-to-peer forwarding, how its firewall isolates
  students, and whether it preserves source addresses or applies SNAT.
- Any DNS, full-tunnel routing or custom commands included in the supplied file.
- Any conflicting routes/interfaces on this PC or student devices.

No VPN subnet has been assigned in these scripts. `10.66.0.x` below is an illustrative topology only. The templates contain
placeholders and cannot be activated as supplied.

## 2. Prepare dependencies now (optional administrator action)

On the lab PC, in a local administrator terminal:

```bash
cd ~/IDS_remote
sudo bash install_wireguard.sh --prepare
```

This installs WireGuard tools and SSH/X2Go/XFCE/Python dependencies. It does
not install a VPN profile, change the student SSH network or start a WireGuard
interface. Package installation may start the distribution's SSH/X2Go services.
The NVIDIA driver, CUDA, PyTorch, existing accounts and GPU usage policy remain
separate. These scripts support Pop!_OS/Ubuntu 22.04/24.04 on the lab.

## 3. Review the supplied profile when available

The lab uses standard `wg-quick` configuration. Examples for review:

- `wireguard/lab.conf.example`: a lab peer connects to the existing public server.
- `wireguard/student.conf.example`: a distinct student/device peer routes to the lab.

Replace placeholders only after the actual network and peer assignments are
known. Do not commit completed profiles. `.gitignore` excludes `.conf` files and
backups, retaining `.conf.example` templates. Check `git status` before staging
private files under any other name.

Validate without root or networking changes (replace the path and CIDR):

```text
bash install_wireguard.sh --check-config /secure/path/lab.conf --student-network REAL_STUDENT_SOURCE_CIDR
```

The output includes only addresses, source network, peer count and warnings;
private/preshared keys are never printed. Validation checks key encoding,
endpoints, route coverage and known directives; it cannot verify server-side
peer registration, reachability, route conflicts on the host or firewall access.

The automatic installation path accepts explicit, non-overlapping VPN routes.
It deliberately stops for default routes (`0.0.0.0/0`, `::/0`), shell hooks,
custom routing directives, duplicate directives and `SaveConfig=true`. Those
profiles require review before use because they can change host routing or run
privileged commands. Do not remove directives blindly to make a check pass.
A supplied DNS setting requires working `resolvconf` integration on this lab;
the installer does not replace the host DNS manager to satisfy it.

For a lab behind NAT, set `PersistentKeepalive = 25` on its public-server peer
unless the VPN administrator specifies otherwise. The checker warns when the
peer carrying student traffic lacks keepalive. The lab's peer `AllowedIPs` must
cover the student source CIDR for replies. Student `AllowedIPs` must include the
lab VPN address; for a lab-only route use its `/32` (IPv4) or `/128` (IPv6).

## 4. Public server integration (existing server, manual review)

Use the existing WireGuard GUI on the public server to create/register a
separate lab peer and one peer per student device, then export each .conf
privately. No public-server shell access is required by the lab installer.
The GUI name is not yet known, so no product-specific controls are assumed.
Do not initialize a new VPN or replace its interface configuration. The VPN
administrator must register each separate lab/student public key and address
in the existing WireGuard instance. An example source-preserving IPv4 topology:

```text
Hub VPN address:           10.66.0.1
Lab peer VPN address:      10.66.0.2/32
Student peer VPN address:  10.66.0.10/32
Hub's lab-peer AllowedIPs: 10.66.0.2/32
Hub's student AllowedIPs:  10.66.0.10/32 (one unique /32 per student/device)
Lab's hub AllowedIPs:     10.66.0.0/24 (or narrower required routes)
Student hub AllowedIPs:   10.66.0.2/32
```

The hub must forward between peers and permit student -> lab TCP 22 plus return
traffic in its **forwarding** firewall. Enable the appropriate IP forwarding
for the chosen address families, for example `net.ipv4.ip_forward=1` for IPv4.
Traffic usually enters and leaves the same WireGuard interface. An input rule
for TCP 22 on the hub does not grant forwarding to the lab. Adapt the existing
nftables/iptables/UFW policy rather than adding conflicting firewall systems.
Block unwanted student-to-student traffic according to the lab's policy.

On the lab, permit TCP 22 arriving on the actual WireGuard interface, from the
actual student source network to the lab VPN address. Preserve trusted
administrative access. The installer does not change firewall policies. If the
hub uses SNAT, use its actual translated source address in the lab's SSH and
firewall rules and ensure the return route includes that address. Broad access
rules on the existing hub are not narrowed automatically by this project.

If the GUI does not expose forwarding or firewall controls, ask its server
administrator to verify the existing rules. Open endpoint ports alone do not
prove that students can reach the lab. These changes are not automated because its configuration,
permissions and other users are not yet known. Connecting only the lab peer to
a server that provides Internet access is insufficient for student -> lab access.

## 5. Install the reviewed lab profile; activation is separate

After dependency preparation and successful validation:

```text
sudo bash install_wireguard.sh --install /secure/path/lab.conf --student-network REAL_STUDENT_SOURCE_CIDR
```

Optional `--interface NAME` selects a Linux interface, default `ids-wg`.
It must be 1-15 letters/digits/underscores/hyphens, starting with a letter/digit.
The profile is stored root-owned with mode 600 in `/etc/wireguard/NAME.conf`.
A different existing profile or symlink destination is refused. An identical
profile is retained with private permissions. Installation refuses an already
active target interface, so changes can be scheduled with local access.

The installer prepares SSH/X2Go for Linux accounts. It backs up/migrates only
an unchanged installer-managed student SSH snippet to the supplied source CIDR. Custom policies require manual
review. Migration validates SSH before reload and restores the previous snippet
if validation fails. This SSH policy change can affect old VPN student access;
perform migration locally and retain administrative access.

No WireGuard interface is started or enabled by `--install`. After reviewing
routes, source CIDR, hub forwarding and firewalls, activate locally:

```bash
sudo systemctl enable --now wg-quick@ids-wg
sudo bash install_wireguard.sh --status
```

For a different interface, use its matching unit and `--status --interface NAME`.
`wg-quick@...` being active does not prove a tunnel handshake or SSH reachability.
The status command reports handshake ages without printing keys; no recent
handshake causes a nonzero result. A recent handshake establishes reachability
to the hub, not student-to-lab routing. On failure, inspect:

```bash
sudo journalctl -u wg-quick@ids-wg -n 50 --no-pager
ip -brief address
ip route
```

Do not publish logs or full profiles containing private keys. Avoid `wg showconf`
and `wg show ... dump` when collecting diagnostics because they expose secrets.
To stop/disable only this interface if needed:

```bash
sudo systemctl disable --now wg-quick@ids-wg
```

A stop does not undo SSH migration or delete the installed profile. Backups of
the managed SSH snippet live beside it under `/etc/ssh/sshd_config.d/`.
Existing VPN services are not stopped; review overlapping routes before starting
WireGuard and retire unused services after a tested migration.

## 6. Provision students and test

Linux account creation stays on the lab, separately from VPN peer management:

```bash
cp usuarios.example.txt usuarios.txt
# Replace examples with the real course list.
bash usr_mgr.sh --import usuarios.txt --dry-run
sudo bash usr_mgr.sh --import usuarios.txt
```

Each student also needs a separately registered WireGuard peer, unique key and
address from the public server's WireGuard GUI. The user manager does not generate those
profiles or modify the hub. Distribute each student's own VPN profile and Linux
credentials privately. Import passwords live under `/root/credenciales-alumnos/`.

Before distributing access, use a device outside the lab LAN to test:

1. Student and lab have a recent handshake with the public server.
2. Student can reach TCP 22 at the **lab's actual WireGuard IP**, including return
   traffic through the hub. Failure of ICMP ping alone does not prove SSH is blocked.
3. X2Go connects with the assigned Linux user/password and session type XFCE.
4. SSH host-key fingerprint matches the administrator's trusted copy.
5. Two students have distinct HOME/DISPLAY values, working SFTP and GPU access.
6. The intended Python environment runs a small CUDA operation and backward pass.

See `ADMINISTRATOR_GUIDE.txt` for account operations/GPU checks and
`CLIENT_GUIDE.txt` for client installation and everyday use. Suspending/deleting
Linux users and removing WireGuard peers are separate administrative tasks.
Removing one must not be assumed to revoke the other. Revoke the peer in the
public server GUI and save the change so it persists.

## References

- [WireGuard quick start](https://www.wireguard.com/quickstart/)
- [WireGuard installation](https://www.wireguard.com/install/)
- [wg-quick manual](https://git.zx2c4.com/wireguard-tools/tree/src/man/wg-quick.8)
- [wg manual](https://git.zx2c4.com/wireguard-tools/tree/src/man/wg.8)
