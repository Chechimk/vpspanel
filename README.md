# VPSPanel

An independent terminal panel for running an SSH/VPN tunnel service on an
Ubuntu or Debian VPS. Its screens, menu order and workflows follow the
ADMRufu2.0 panel as observed in a running installation
([docs/ADMRUFU-FULL-STRUCTURE.md](docs/ADMRUFU-FULL-STRUCTURE.md)), but every
line of code is original. It is English-only and needs no activation key.

> **Status: v0.3.0 (development branch `develop`).** Everything listed under
> "Implemented" was tested in disposable Ubuntu 22.04 and 24.04 containers,
> with real client traffic wherever a client could be run (see "Testing").
> Items marked *Coming Soon* in the menu are not implemented yet; selecting
> one says so and changes nothing. Try VPSPanel on a test server before using
> it in production.

## One-Command Installation

Log in to your Ubuntu 20.04+ or Debian 11+ server over SSH and run:

```bash
sudo apt-get update -y && sudo apt-get install -y curl && curl -fsSLo vpspanel-install.sh https://raw.githubusercontent.com/Chechimk/vpspanel/main/quick-install.sh && sudo bash vpspanel-install.sh
```

Then open the panel with `menu`. No activation key is needed.

[`quick-install.sh`](quick-install.sh) installs git, downloads the latest
`main` branch into a temporary folder and runs `install.sh` from it (see
"Install" below for what that changes). It stops with a clear message, and
without changing anything, if the system is unsupported or the download
fails. If VPSPanel is already installed, it asks before updating it (accounts
and settings are always kept); add `--update` to update without being asked.

If you are logged in as root on a system without `sudo`, run the same command
with every `sudo ` removed.

### Trying the development branch

To install or update from the `develop` branch on a **test server**:

```bash
curl -fsSLo vpspanel-install.sh https://raw.githubusercontent.com/Chechimk/vpspanel/develop/quick-install.sh && sudo VPSPANEL_BRANCH=develop bash vpspanel-install.sh
```

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
  accounts) and the unprivileged `vpspanel-svc` system user (runs Xray,
  Hysteria2 and SlowDNS)
- enables `vpspanel-guard.timer`, which enforces account expiry and login
  limits every minute
- appends a validated `Match Group vpsusers` block to `sshd_config`, so panel
  accounts can log in with a password for tunnels only (no shell)

It does **not** change SSH ports, root login, existing firewall rules or other
users. Protocols are installed only when you choose them in the menu.

To update, use Script settings → Update panel (or run the one-command install
again). To remove, use Uninstall panel. Uninstalling keeps SSH ports and
root-login settings, so you can't be locked out.

## Menu

The main menu shows a live dashboard (OS, IP, date and time, disk and CPU,
RAM, swap, and ACTIVE / EXPIRED / LOCKED / TOTAL / ONLINE account counters;
each block can be switched off in Script settings), then:

```
[1]> MANAGE ACCOUNTS (SSH/DROPBEAR)
[2]> MANAGE ACCOUNTS (V2RAY/XRAY)      shown once Xray is installed
[3]> MANAGE ACCOUNTS (WIREGUARD)       shown once WireGuard is installed
-----
[n]> PROTOCOL CONFIGURATION
[n]> EXTRA TOOLS
-----
[n]> API AND BOTS                       Coming Soon
-----
[n]> SCRIPT SETTINGS
-----
[n]> [!] UNINSTALL PANEL
[0] LOG OUT OF VPS   [n] EXIT PANEL   [n] REBOOT VPS
```

As in ADMRufu, `0` on the main menu closes the SSH session; *Exit panel*
returns to the shell. On every other screen `0` goes back, and `x` leaves the
panel from anywhere.

| Screen | Options |
|---|---|
| SSH accounts | New user, temporary user (minutes; shown when enabled), remove, renew (today + days), edit (password + connections), lock/unlock, general password, details of all users, online monitor, account limiter, delete expired, delete all, user backups (incl. daily auto-backup and **import of ADMRufu `.admrufu` backups**), account manager settings (user lists, select by name, temporary-user option, UTC/server dates, defaults) |
| Protocol configuration | Two-column list with `[ON]`/`[OFF]` and a port summary: SSH settings, Dropbear, SOCKS/WS proxy, Stunnel, SlowDNS, UDP-Custom *(Coming Soon)*, UDP-Hysteria, BadVPN-UDPGW, Squid, OpenVPN, Checkuser, FileBrowser *(Coming Soon)*, V2Ray/Xray, WireGuard |
| Extra tools | SSL certificates, SSH/Dropbear banner, root password and access, kernel acceleration (BBR or any available algorithm), maintenance (RAM/disk/swap), torrent/port/keyword blocking, Fail2ban, DDoS protection, time zone, speedtest, plugin scripts *(Coming Soon)* |
| Script settings | Dashboard blocks on/off, auto-start at login, panel name, system details, panel log, update, about |

## Implemented

| Area | What works |
|---|---|
| SSH accounts | Linux users in `vpsusers` with no shell; passwords are stored only as system hashes. Expiry, login limits (enforced every minute), lock/unlock, temporary users deleted after N minutes, general password, backups with password hashes, ADMRufu backup import |
| OpenSSH | Change ports. The port you are connected through can't be removed, and the change is checked with `sshd -t` and rolled back on error. Ubuntu socket activation is handled |
| Dropbear | Several ports, manual edit, banner, status/restart/start-stop (distribution `dropbear-bin`) |
| SOCKS/WS proxy | Original Python 3 proxy, one systemd instance per port. **Direct** mode: answers the HTTP/WebSocket payload with a chosen status (200, 101, ...), optional custom header and mini-banner, then relays to SSH/Dropbear; split payloads handled. **CONNECT** mode: HTTP CONNECT limited to this server's own ports (never an open proxy) |
| Stunnel | TLS ports in front of SSH/Dropbear, several ports, certificate choice, logs |
| SlowDNS | `dnstt-server` built from a pinned, commit-verified source tag (Go toolchain from go.dev, SHA-256 verified); NS domain, target port, key pairs (new or your own), UDP 53 → 5300 redirect |
| UDP-Hysteria | Official Hysteria2 release, SHA-256 verified. **Clients log in with their panel SSH account** (`user:password`, checked by the local `vpspanel-authd`, which also refuses expired and locked accounts), Salamander obfuscation on by default, optional port-hopping range, or a single shared password (default: a random UUID). Separate address and SNI, so a link can point at an IP while presenting a domain. Share links (`hysteria2://...`) are tested by importing them into the official client; every new account gets its own link |
| BadVPN-UDPGW | Built from the pinned upstream source (checksum verified); several ports on 127.0.0.1 |
| Squid | HTTP CONNECT proxy restricted to this server only. Logs. The original config is restored on removal |
| OpenVPN | TCP or UDP, port, cipher, DNS choice. **Clients log in with their panel SSH account** (PAM; expired and locked accounts are refused). One client file, which contains no private key |
| Checkuser | Same HTTP API as ADMRufu (`GET /` online count, `POST /checkuser {"user":...}` expiry as DDMMYYYY or epoch, UTC or server time); runs unprivileged |
| V2Ray / Xray | Official Xray-core release, SHA-256 verified, unprivileged. VLESS, VMess, Trojan, Shadowsocks over TCP, WebSocket, gRPC or XHTTP, TLS on or off. Users are added to every inbound with expiry; share links, QR codes and a complete client JSON. View/edit JSON, logs |
| WireGuard | Server with NAT, clients with config + QR code, port change, NAT re-detection |
| SSL | Let's Encrypt via certbot (auto-renewal refreshes service copies) and self-signed certificates |
| Security | Torrent/keyword and spam-port blocking that only affects panel traffic, UFW helpers, Fail2ban (your own IP is never banned), DDoS protection (new connections per minute per IP, block minutes, whitelist) |
| System | Live dashboard, BBR/congestion control, time zone, RAM/disk cleanup, swap file, speedtest, root password/login policy, auto-start at login |

## Coming Soon

UDP-Custom, FileBrowser, HWID/token account modes, Xray traffic accounting
and REALITY, SSH post-login banner with account details, manually pasted
certificates, scheduled tasks, plugin scripts, REST API, Telegram bot,
WhatsApp bot. Details are in [docs/ROADMAP.md](docs/ROADMAP.md).

## Command line

```bash
vpspanel help
vpspanel create alice Secret123 30 2   # 30 days, 2 simultaneous logins
vpspanel trial  temp1 Secret123 60     # temporary user, deleted after 60 minutes
vpspanel renew  alice 30               # expiry = today + 30 days
vpspanel import-admrufu /root/ADMRufu/userSSH/backups_users_DATE.admrufu
vpspanel list
vpspanel backup
```

## Layout

| Path | Purpose |
|---|---|
| `bin/menu` | Interactive panel (dashboard + all menus) |
| `bin/vpspanel` | Command-line interface; also used by the guard timer |
| `bin/vpspanel-wsproxy` | SOCKS/WebSocket/HTTP proxy |
| `bin/vpspanel-authd` | Account check for Hysteria2 (127.0.0.1 only) |
| `bin/vpspanel-checkuser` | Checkuser HTTP service |
| `bin/vpspanel-dropbear` | Dropbear launcher |
| `lib/common.sh` | Paths, config, colours, prompts, validation |
| `lib/ui.sh` | Menu framework (frames, footers, two columns, Back/Exit, Coming Soon) |
| `lib/accounts.sh` | SSH account database, enforcement, backups, ADMRufu import |
| `lib/system.sh` | Host info, ports, OpenSSH settings, BBR, time zone, maintenance |
| `modules/*.sh` | One file per protocol or tool |
| `systemd/` | Guard service and timer |
| `install.sh`, `quick-install.sh`, `update.sh`, `uninstall.sh` | Lifecycle scripts |
| `tests/run.sh` | Test suite |
| `docs/` | ADMRufu structure, gap analysis, roadmap |

## Testing

`tests/run.sh` must run as root on a **disposable** machine or container,
because it creates and deletes accounts, services and firewall rules. It
covers:

- syntax checks and shellcheck
- a crawl of every menu, checking that every option leads to real code
- scripted keyboard navigation through a pseudo-terminal (Back, Exit, invalid
  input, Coming Soon, toggles, Retry/Back on save, dashboard blocks)
- the account lifecycle, temporary users, auto-backup and ADMRufu import
- real SSH tunnels through OpenSSH, Dropbear (two ports), the direct proxy,
  the CONNECT proxy, Stunnel, Squid and SlowDNS (with a real `dnstt-client`)
- real client traffic through OpenVPN, Hysteria2 and Xray (VLESS WS, VLESS
  XHTTP, VMess WS, VLESS gRPC+TLS, Trojan TCP+TLS, Shadowsocks), each logging
  in with a panel account or user, and refusals for wrong credentials
- login-limit enforcement, Checkuser API, DDoS rate limiting, WireGuard

```bash
sudo bash tests/run.sh             # full suite (disposable machine only)
sudo bash tests/run.sh nav         # menus only
bash tests/run.sh static           # syntax checks only, safe anywhere
```

## License and independence

VPSPanel contains no ADMRufu2.0 code, binaries, translation catalogs or
artwork. The ADMRufu panel was run in a disposable container with the owner's
license to observe its behaviour; the observations are documented in
[docs/ADMRUFU-FULL-STRUCTURE.md](docs/ADMRUFU-FULL-STRUCTURE.md) and compared
in [docs/VPSPANEL-GAP-ANALYSIS.md](docs/VPSPANEL-GAP-ANALYSIS.md).
Third-party software is installed from the distribution's repositories or
from official upstream sources at install time, and is never bundled:
Dropbear (MIT), stunnel (GPL-2.0+), Squid (GPL-2.0+), OpenVPN (GPL-2.0),
easy-rsa (GPL-2.0), Xray-core (MPL-2.0), Hysteria (MIT), dnstt (public
domain), BadVPN (BSD-3-Clause), WireGuard tools (GPL-2.0), certbot
(Apache-2.0), Fail2ban (GPL-2.0+), speedtest-cli (Apache-2.0).
