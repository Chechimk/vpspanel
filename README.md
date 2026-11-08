# VPSPanel

An independent terminal panel for running an SSH/VPN tunnel service on an
Ubuntu or Debian VPS. Its menu structure follows the familiar ADMRufu2.0 layout
(see [docs/ADMRUFU-MENU-MAP.md](docs/ADMRUFU-MENU-MAP.md)), but the whole
codebase is original. It is English-only and needs no activation key.

> **Status: v0.2.0, early development.** Everything listed under "Implemented"
> was tested in disposable Ubuntu 22.04 and 24.04 containers (see "Testing"
> below). That includes real traffic through OpenSSH, Dropbear, the WebSocket
> proxy, Stunnel, Squid and the official Xray binary (VLESS+WS, VMess+WS+TLS,
> VLESS+TCP+TLS). **Hysteria2** is the exception: GitHub kept returning
> HTTP 504 for its binary during testing, so the module was checked with a
> stand-in binary and real Hysteria2 traffic is still unverified. Items marked
> *Coming Soon* in the menu are not implemented yet. Selecting one says so and
> changes nothing. Try VPSPanel on a test server before using it in
> production.

## Install

```bash
git clone https://github.com/Chechimk/vpspanel.git
cd vpspanel
sudo bash install.sh
menu
```

Requires Ubuntu 20.04+ or Debian 11+ with systemd and root access.

The installer:
- installs a few distribution packages (curl, jq, python3, iptables, ...)
- copies the panel to `/opt/vpspanel` and keeps settings in `/etc/vpspanel`
- creates the `menu` and `vpspanel` commands, the `vpsusers` group (panel
  accounts) and the unprivileged `vpspanel-svc` system user (runs Xray and
  Hysteria2)
- enables `vpspanel-guard.timer`, which enforces account expiry and login
  limits every minute
- appends a validated `Match Group vpsusers` block to `sshd_config`, so panel
  accounts can log in with a password for tunnels only (no shell)

It does **not** change SSH ports, root login, existing firewall rules or other
users.

To update, use Panel settings → Update panel. To remove, use Uninstall panel.
Uninstalling keeps SSH ports and root-login settings, so you can't be locked
out.

## Menu

```
1  Manage accounts (SSH/Dropbear)   new, temporary, remove, renew, password,
                                    connection limit, lock, details, online
                                    monitor, account limiter, delete expired,
                                    delete all, backups
2  Manage accounts (V2Ray/Xray)     new, remove, renew, details + share links
3  Manage accounts (WireGuard)      new client, remove, list, config / QR code
4  Protocol configuration           SSH, Dropbear, WebSocket/HTTP proxy,
                                    Stunnel, Hysteria2, Squid, V2Ray/Xray,
                                    WireGuard (+ Coming Soon items)
5  Extra tools                      SSL certificates, banner, root access,
                                    maintenance, blocking rules, BBR, Fail2ban,
                                    time zone, speedtest
6  API and bots                     Coming Soon
7  Panel settings                   auto-start, system information, account
                                    defaults, log, update, about
8  Uninstall panel   9  Log out of VPS   10  Reboot VPS   0  Exit
```

On every screen, `0` goes back and `x` exits the panel.

## Implemented

| Area | What works |
|---|---|
| SSH accounts | Linux users in `vpsusers` with no shell. Expiry, trial hours, login limits (enforced every minute), lock/unlock, backup/restore with password hashes |
| OpenSSH | Change ports. The port you are connected through can't be removed, and the change is checked with `sshd -t` and rolled back on error. Ubuntu socket activation is handled |
| Dropbear | Install, port, restart, uninstall (distribution `dropbear-bin`) |
| WebSocket / HTTP proxy | Original Python 3 proxy. Answers an HTTP/WebSocket payload with `101` and relays to SSH/Dropbear. Handles split payloads. One systemd instance per port |
| Stunnel | TLS ports in front of SSH/Dropbear, multiple ports, certificate choice |
| Squid | HTTP CONNECT proxy restricted to this server only (never an open proxy). The original config is restored on removal |
| V2Ray / Xray | Official Xray-core release, SHA-256 verified, runs as the unprivileged `vpspanel-svc` user. VLESS/VMess over WS, WS+TLS or TCP+TLS. Users added to every inbound, `vless://`/`vmess://` links, expiry enforced. Recent Xray versions mark VMess and WebSocket as deprecated (XHTTP is on the roadmap) and clients need a real certificate (Let's Encrypt) for TLS |
| Hysteria2 | Official release, SHA-256 verified. Shared password, optional Salamander obfuscation, `hysteria2://` link |
| WireGuard | Server with NAT, clients with config + QR code, port change, NAT re-detection |
| SSL | Let's Encrypt via certbot (auto-renewal refreshes service copies) and self-signed certificates |
| Security | Torrent/keyword and spam-port blocking in a dedicated iptables chain that only affects panel traffic, UFW helpers, Fail2ban (your own IP is never banned) |
| System | Live dashboard (RAM, CPU, disk, swap, load, account counters), BBR, time zone, RAM/disk cleanup, swap file, speedtest, root password/login policy, auto-start at login |

## Coming Soon

SlowDNS (DNSTT), UDP Custom, BadVPN UDPGW, OpenVPN, Checkuser, HWID/token
account modes, traffic quotas, automatic backups, DDoS protection, scheduled
tasks, plugin scripts, REST API, Telegram bot, WhatsApp bot. Details are in
[docs/ROADMAP.md](docs/ROADMAP.md).

## Command line

```bash
vpspanel help
vpspanel create alice Secret123 30 2   # 30 days, 2 simultaneous logins
vpspanel list
vpspanel backup
```

## Layout

| Path | Purpose |
|---|---|
| `bin/menu` | Interactive panel (dashboard + all menus) |
| `bin/vpspanel` | Command-line interface; also used by the guard timer |
| `bin/vpspanel-dropbear`, `bin/vpspanel-wsproxy` | Service launchers |
| `lib/common.sh` | Paths, config, colours, prompts, validation |
| `lib/ui.sh` | Menu framework (Back/Exit, Coming Soon, service helpers) |
| `lib/accounts.sh` | SSH account database and enforcement |
| `lib/system.sh` | Host info, OpenSSH settings, BBR, time zone, maintenance |
| `modules/*.sh` | One file per protocol or tool |
| `systemd/` | Guard service and timer |
| `install.sh`, `update.sh`, `uninstall.sh` | Lifecycle scripts |
| `tests/run.sh` | Test suite |
| `docs/` | ADMRufu menu map and roadmap |

## Testing

`tests/run.sh` must run as root on a **disposable** machine or container,
because it creates and deletes accounts and services. It covers:

- syntax checks and shellcheck
- a crawl of every menu, checking that every option leads to real code
- scripted keyboard navigation through a pseudo-terminal (Back, Exit, invalid
  input, Coming Soon)
- the account lifecycle, plus real SSH tunnels through OpenSSH, Dropbear, the
  WebSocket proxy, Stunnel and Squid
- login-limit enforcement and each protocol module's install and uninstall

```bash
sudo bash tests/run.sh          # full suite (disposable machine only)
bash tests/run.sh static        # syntax checks only, safe anywhere
```

## License and independence

VPSPanel contains no ADMRufu2.0 code, binaries, translation catalogs or
artwork. The menu organisation was studied as a reference only (see
[docs/ADMRUFU-MENU-MAP.md](docs/ADMRUFU-MENU-MAP.md)). Third-party software
is installed from the distribution's repositories or from the official
upstream releases at install time, and is never bundled: Dropbear (MIT),
stunnel (GPL-2.0+), Squid (GPL-2.0+), Xray-core (MPL-2.0), Hysteria (MIT),
WireGuard tools (GPL-2.0), certbot (Apache-2.0), Fail2ban (GPL-2.0+),
speedtest-cli (Apache-2.0).
