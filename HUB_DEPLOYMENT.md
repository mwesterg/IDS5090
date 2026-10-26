# Public OpenVPN hub + lab PC

The public Ubuntu/Debian server runs OpenVPN and holds the CA. The lab PC and
student devices connect to it as clients. Student Linux accounts, XFCE and GPU
jobs stay on the lab PC. No inbound port or router change is needed at the lab.

```text
Student OpenVPN client ──┐
                        ├── public hub: TCP 443 (default)
Lab PC outbound VPN ────┘
Student X2Go ── VPN via hub ──> lab PC 10.77.0.2:22
```

The fixed VPN network is `10.77.0.0/24`: hub `.1`, lab `.2`, student pool
`.10`–`.250`. Check for overlapping networks at both sites and on student devices
before installation. This deployment supports one lab PC. The scripts use new
configuration paths and preserve the legacy `openvpn-server@server` instance.

## 1. Prepare the public server

Use Ubuntu 22.04/24.04 or Debian 11+ with systemd, root/sudo and a TUN device.
The hub requires OpenVPN 2.5+. With newer releases, it explicitly disables DCO
so inter-client traffic traverses the kernel firewall. Copy/clone this repository
to your public server at `152.74.19.95` and run:

```bash
sudo bash install_hub.sh init 152.74.19.95 443 tcp
```

The endpoint can also be a DNS hostname pointing at this public IP.
TCP 443 must be free: it cannot also serve HTTPS on the same address with this
configuration. To use another allowed port/transport, choose it at initialization,
for example `init YOUR_PUBLIC_HOST 1194 udp`. Every exported profile uses that
endpoint. A forwarded port alone does not establish that the lab permits outbound
OpenVPN: test it. TCP 443 carries OpenVPN, not HTTPS, and protocol filtering or an
HTTPS-only proxy can block it. Obtain an institution-approved path if required.
TCP VPN transport can also reduce interactive performance on lossy links.

Easy-RSA asks for an encrypted CA passphrase and again when signing certificates
or generating the CRL. Record it securely and back up `/root/ids-openvpn` encrypted
off the hub. The server key and unattended lab PC key are unencrypted and must
remain private. Initialization refuses existing hub material. If interrupted,
inspect the partial installation and recover it; do not delete a CA to retry.

Paths:

| Material | Location on public server |
| --- | --- |
| CA and issued certificates | `/root/ids-openvpn/pki` |
| Private exported profiles | `/root/ids-vpn-profiles` |
| OpenVPN configuration | `/etc/openvpn/server/ids-hub.conf` |
| Deployed keys, CRL and client-specific configuration | `/etc/openvpn/server/ids-hub/` |
| VPN service | `openvpn-server@ids-hub` |
| Dedicated firewall service | `ids-vpn-firewall` |

Allow the selected inbound port in the public server's host firewall, provider
security group and router forwarding as applicable. The installer adds a dedicated
`inet ids_vpn` nftables table without flushing existing tables. It enables IPv4
forwarding persistently. It drops VPN traffic to the hub itself and forwards only
TCP 22 to the lab PC and established replies. It blocks student-to-student traffic,
Internet forwarding and direct VPN forwarding to the institutional LAN. Linux
accounts still have the lab PC's normal network access; they are not sandboxes.
It pushes no default route
or DNS settings and applies no NAT. `client-to-client` must remain disabled.

Existing firewall chains may still drop permitted traffic: an nftables accept
does not override a later drop in another chain. If UFW is active, allow the chosen
public port and the permitted forwarding path, for example:

```bash
sudo ufw allow 443/tcp
sudo ufw route allow in on tunids out on tunids from 10.77.0.0/24 to 10.77.0.2 port 22 proto tcp
```

Preserve administrative SSH access. Integrate equivalent rules if using another
firewall manager. Firewall tools that flush rules can remove the dedicated table;
after such changes restore it with `sudo systemctl restart ids-vpn-firewall` and
verify `sudo nft list table inet ids_vpn`. Do not enable the distribution's nftables
service with a default flush ruleset just for this project. If the hub already
provides routing for other services, review the global forwarding change first.

## 2. Connect the lab PC

Securely copy **only** `/root/ids-vpn-profiles/labpc.ovpn` to the lab PC. Treat it as
a credential; it permits unattended reconnection. Never give it to students. Use
only the trusted profile exported by your hub: OpenVPN profiles are privileged
configuration and can contain executable hooks. Keep copies outside the repository.

On the Pop!_OS/Ubuntu 22.04/24.04 lab PC:

```bash
cd ~/IDS_remote
sudo bash install_lab.sh /secure/path/labpc.ovpn
```

This installs OpenVPN, SSH, X2Go and XFCE and starts `openvpn-client@ids-lab` at
boot. It selects Linux-only account management and permits student authentication
from `10.77.0.0/24`. It can migrate an exact, unmodified installer-generated
`00-00-ids-students.conf` from Tailscale to the VPN subnet, saving a backup. If the
snippet was customized it stops for manual review. Existing Linux accounts and
passwords remain usable. Drivers, CUDA and the physical desktop are unchanged.

If UFW is active on the lab, permit SSH from the VPN:

```bash
sudo ufw allow in on tun0 from 10.77.0.0/24 to 10.77.0.2 port 22 proto tcp
```

Check the actual interface first with `ip -4 -brief address`: another running VPN
can cause the lab tunnel to be `tun1` rather than `tun0`. Adjust the rule to match.
There is no lab IP forwarding requirement; students connect to the PC itself.

Verify connection rather than relying on a running process:

```bash
sudo systemctl status openvpn-client@ids-lab ssh --no-pager
sudo journalctl -u openvpn-client@ids-lab -n 60 --no-pager
ip -4 -brief address
sudo sshd -T -C user=alumno01,addr=10.77.0.10,host=client
```

Expect `Initialization Sequence Completed`, address `10.77.0.2`, and password
authentication enabled for a real student in `alumnosvpn`. If there is no tunnel,
check server logs, port forwarding, outbound policy, certificate validity and CRL.
The old incomplete local OpenVPN server is not needed. After validating the new
path using local/independent administrative access, optionally retire unused services:

```bash
sudo systemctl disable --now tailscaled openvpn-server@server
```

Run that only if those services have no other users. No keys or configurations
need to be deleted, and neither installer stops them automatically.

## 3. Enroll students in two places

On the **lab PC**, prepare the real class list and create Linux accounts:

```bash
cp usuarios.example.txt usuarios.txt
# Edit usuarios.txt with the real assigned usernames.
bash usr_mgr.sh --linux-only --import usuarios.txt --dry-run
sudo bash usr_mgr.sh --linux-only --import usuarios.txt
```

Keep the private credential TSV under `/root/credenciales-alumnos/` on the lab PC.
Do not run the legacy `usr_mgr.sh --openvpn` workflow on the hub: it couples VPN
certificates to local Linux accounts and is intended for the older single-PC setup.

On the **public hub**, issue an individual VPN certificate/profile for each student:

```bash
sudo bash install_hub.sh add-student alumno01
```

Choose a student-specific private-key passphrase when Easy-RSA asks. It is separate
from the student's Linux password and the administrator's CA passphrase. The command
creates no Linux account on the hub. Deliver only that student's `.ovpn`, key
passphrase and lab Linux credentials privately. Each student needs a unique profile;
the reserved `labpc` identity cannot be issued as a student. Names are not reused,
including revoked identities. Use a new VPN name for replacements if necessary;
the VPN certificate name and Linux account name need not match.

Students import their profile into an OpenVPN client and keep it connected while
using X2Go: host `10.77.0.2`, SSH port `22`, session `XFCE`, Linux username/password.
The public hub address is the VPN endpoint, not the X2Go destination. Provide the
lab's SSH host-key fingerprint through a trusted channel:

```bash
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

## 4. Validate before class use

Test from outside the lab LAN with two individual student profiles. Confirm X2Go
login, separate HOME/DISPLAY, SFTP and actual GPU execution. Confirm TCP 22 to
`10.77.0.2` works while other lab ports, hub services and student-to-student access
are blocked. Ping is blocked by design; use SSH to test the permitted path. Check
that normal Internet traffic still uses each client's usual connection.

On the hub:

```bash
sudo bash install_hub.sh status
sudo journalctl -u openvpn-server@ids-hub -n 80 --no-pager
sudo ss -lntup
```

On the lab, run `nvidia-smi` and the GPU computation test in README.md from a student
session. VPN connectivity does not validate the driver/framework or GPU scheduling.

## 5. Withdraw access and maintain the CRL

Block the Linux account on the lab using `sudo bash usr_mgr.sh --linux-only`.
Revoke the corresponding VPN identity on the public hub separately:

```bash
sudo bash install_hub.sh revoke alumno01
```

Revocation publishes a new CRL and restarts the hub, disconnecting all VPN clients
briefly so revoked sessions are terminated. The lab reconnects automatically;
students may need to reconnect their clients. Revoking `labpc` is supported for a
compromised lab profile, but disconnects the lab until a replacement identity is
prepared manually with the reserved fixed address. Linux suspension alone does
not revoke VPN credentials; VPN revocation alone does not lock a Linux account.

The CRL lasts 180 days. Renew it before expiry with the CA passphrase available:

```bash
sudo bash install_hub.sh renew-crl
sudo openssl crl -in /etc/openvpn/server/ids-hub/crl.pem -noout -nextupdate
```

Back up CA material and monitor certificate expiration too. A lost `tls-crypt` key
requires new profiles; do not regenerate a CA as a routine repair.

Protocol and routing reference: [OpenVPN manual](https://openvpn.net/community-docs/community-articles/openvpn-2-6-manual/).
