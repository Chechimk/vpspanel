# ADMRufu2.0 → VPSPanel menu map

> **Superseded.** This first map was built from translation catalogs and
> string tables only. The panel has since been installed and explored; the
> observed structure is in [ADMRUFU-FULL-STRUCTURE.md](ADMRUFU-FULL-STRUCTURE.md),
> which takes precedence wherever the two differ.

This document records how the ADMRufu2.0 menu is organised and where each part
lives in VPSPanel. VPSPanel uses it only as an organisational reference. Every
VPSPanel screen is original Bash code. No ADMRufu binary, source, translation
catalog, banner or artwork is included in or derived into this repository.

## How the original was inspected

The ADMRufu2.0 checkout (`gitlab.com/rufu99/admrufu2.0`) holds 56 compiled
ELF executables and shared libraries (`sbin/*`, `slib/*`, `bin/*`, `install`)
plus a few small shell scripts (`install.sh`, `bashrc`, `isRoot`). It has no
readable menu source code. The structure below was recovered from:

1. **gettext catalogs** (`locale/en/LC_MESSAGES/*.po`): the label strings for
   26 modules.
2. **Readable string tables in the binaries**: menu titles, item labels, and
   the names of the sub-programs that each menu launches, in the order they
   appear in the binary.
3. **`bashrc`**: the shell aliases (`menu`, `monitor`, `api`, `tgbot`,
   `wsbot`, `update-adm`, `remove-adm`).

### Verification levels

| Mark | Meaning |
|------|---------|
| ✅ | **Verified**: the label and the sub-program it launches were both found in the menu's string table. |
| 🟡 | **Label verified, order inferred**: the label exists, but numbering is generated at runtime by a compiled list renderer (`libmenuList.so`). The order shown is the order of strings in the binary, which usually matches the source order but is not guaranteed. |
| ❔ | **Needs investigation**: the behaviour is compiled and could not be confirmed without running the original panel, which this audit did not do. |

**Not verifiable from the files:** exact item numbering, the colours,
borders, spacing and box-drawing characters (drawn by compiled `libcolor.so`,
`libcentrarTXT.so` and `libmenuList.so`), and the content of the remote
license check. Every ADMRufu module contains the strings "requires installing
a license" and "the installation is not official", and `libconfMenu.so` reads
`/etc/ADMRufuLIC`. VPSPanel has no license or activation step.

## Main menu

ADMRufu `sbin/menu`: dashboard with date/time, RAM (total, in use, free, cache,
buffer), disk, CPU cores, and an account counter (active, expired, blocked,
total) 🟡

| # | ADMRufu item (launches) | | VPSPanel | Status |
|---|---|---|---|---|
| 1 | Manage accounts SSH/Dropbear (`userSSH`) | 🟡 | 1 Manage accounts (SSH/Dropbear) | Implemented |
| 2 | Manage accounts V2Ray/Xray (`userRay`) | 🟡 | 2 Manage accounts (V2Ray/Xray) | Implemented |
| 3 | Manage accounts WireGuard (`wgClient`) | 🟡 | 3 Manage accounts (WireGuard) | Implemented |
| 4 | Protocol configuration (`protocolos`) | 🟡 | 4 Protocol configuration | Implemented (partly Coming Soon) |
| 5 | Extra tools (built into `menu`) | 🟡 | 5 Extra tools | Implemented (partly Coming Soon) |
| 6 | Configure API and bots | 🟡 | 6 API and bots | Coming Soon |
| 7 | Script configuration | 🟡 | 7 Panel settings | Implemented |
| 8 | Language | 🟡 | (none) | VPSPanel is English-only |
| 9 | Uninstall panel | 🟡 | 8 Uninstall panel | Implemented |
| — | Exit VPS / Exit script / Restart VPS | 🟡 | 9 Log out of VPS · 10 Reboot VPS · 0 Exit | Implemented |

## 1. Manage accounts (SSH/Dropbear)

ADMRufu `sbin/userSSH` (+ its own `sbin/useradd`). Item labels in string-table order 🟡:

| ADMRufu item | VPSPanel item | Status |
|---|---|---|
| New user | 1 New user | Implemented |
| Create temporary user | 2 Create temporary user | Implemented |
| Remove user | 3 Remove user | Implemented |
| Renew user | 4 Renew user | Implemented |
| Edit user | 5 Change password | Implemented |
| Edit traffic use and limits | 6 Change connection limit | Implemented (traffic quotas: Coming Soon) |
| Lock/unlock user | 7 Lock / unlock user | Implemented |
| Configure general password | (none) | Not planned: tied to ADMRufu's HWID/token modes |
| Details of all users | 8 User details | Implemented |
| Connected-user monitor (`onlineUser`) | 9 Online users monitor | Implemented |
| Account limiter (expired-account limiter, multi-login limiter, their logs) | 10 Account limiter | Implemented |
| Delete expired users | 11 Delete expired users | Implemented |
| Delete all users | 12 Delete all users | Implemented |
| User backups (create, restore, delete, auto-backups) | 13 User backups | Implemented (auto-backups: Coming Soon) |
| Switch SSH / HWID / Token mode | 14 Account mode (HWID/Token) | Coming Soon |
| Show temporary-user option, display date in time zone | (none) | ❔ settings screen not fully recoverable |

## 2. Manage accounts (V2Ray/Xray)

ADMRufu `sbin/userRay` ✅ (catalog `userRay.po`): new user, delete user, renew
user, user information, and an "inbound selector".

VPSPanel: 1 New user · 2 Remove user · 3 Renew user · 4 User details and share
links · 5 List users. All implemented. Each user is added to every VLESS/VMess
inbound, and the guard timer removes users when they expire.

## 3. Manage accounts (WireGuard)

ADMRufu `sbin/wgClient` 🟡: new client, remove client, view client list.

VPSPanel: 1 New client · 2 Remove client · 3 List clients · 4 Show client
config / QR code. All implemented.

## 4. Protocol configuration

ADMRufu `sbin/protocolos` ✅ launches these sub-programs, in this order:
`sshManager, dropBear, socksPY, Stunnel, Slowdns, wsEpro, udp-custom,
udp-hysteria, badvpn, Squid, openVPN, checkuser, aToken, fileBrowser,
v2rayManager, sshGo, WgAdmin, HCRCustom, BHTTPtunel`

| ADMRufu module | Sub-menu items (from catalog / strings) | VPSPanel | Status |
|---|---|---|---|
| sshManager ✅ | change SSH port, start/stop, restart, install/uninstall OpenSSH, banner, root access, systemd-socket warning | 1 SSH (OpenSSH) | Implemented: ports with lock-out protection, restart, status, panel-user access policy |
| dropBear ✅ | redefine ports, manual config, start at boot, status, restart, start/stop, uninstall, install, banner | 2 Dropbear | Implemented |
| socksPY ✅ | Python SOCKS/HTTP proxy ports, custom 101 response, redirect port, logs | 3 WebSocket / HTTP proxy | Implemented (own Python 3 proxy) |
| wsEpro ✅ | WS-Epro proxy, redirect port, logs | 3 WebSocket / HTTP proxy | Same module as above |
| Stunnel ✅ | add/remove/modify SSL port, nano config, start at boot, status, start/stop, restart, logs, uninstall, certificates | 4 Stunnel (SSL/TLS) | Implemented |
| Slowdns ✅ | DNSTT install, NS domain, traffic port, key pair, status, logs | 5 SlowDNS (DNSTT) | Coming Soon |
| udp-custom ✅ | port, iptables range, status, logs | 6 UDP Custom | Coming Soon (the original is a closed binary, so an open replacement is needed) |
| udp-hysteria ✅ | port, iptables range, OBFS, domain/cert, status, logs | 7 Hysteria2 | Implemented (official open-source Hysteria2 server, shared password + optional obfuscation) |
| badvpn ✅ | UDPGW ports, status, logs | 8 BadVPN UDPGW | Coming Soon |
| Squid ✅ | add/remove port, ACL, access, caching, hostname, reload, logs, uninstall | 9 Squid proxy | Implemented (locked to this server only: no open proxy) |
| openVPN ✅ | install (port/proto/cipher/DNS), client .ovpn, RSA keys, nano configs, status, logs | 10 OpenVPN | Coming Soon |
| v2rayManager ✅ | install V2Ray/Xray, add/remove inbound, view/edit JSON, access/error logs, status, restart, start/stop, reconfigure, uninstall | 11 V2Ray / Xray | Implemented (Xray-core, VLESS/VMess over WS or TCP, optional TLS) |
| WgAdmin 🟡 | install, port, nano config, NAT fix, status, restart, start/stop, reinstall, uninstall | 12 WireGuard | Implemented |
| checkuser ✅ | checkuser HTTP service, logs | 13 Checkuser | Coming Soon |
| aToken ✅ | online token authentication, hash containers | (none) | Not planned (part of the HWID/token licensing model) |
| fileBrowser ✅ | web file manager | (none) | Not planned |
| sshGo 🟡, HCRCustom 🟡, BHTTPtunel 🟡 | proprietary tunnel servers (port, redirect, frames, poll timeout, banner) | (none) | Not planned: no open-source equivalent identified |

## 5. Extra tools

ADMRufu `sbin/menu` "extra tools" ✅, which launches `sslManager, banner,
ActiveRoot, firewall, fail2banManager, DDosManager, timeZone, speedtest,
plugScript, bbrAdmin`, plus built-in system maintenance.

| ADMRufu item | VPSPanel item | Status |
|---|---|---|
| SSL certificate manager (acme.sh, ZeroSSL) | 1 SSL certificate manager | Implemented (Let's Encrypt with certbot, plus self-signed) |
| SSH/Dropbear banner manager | 2 SSH/Dropbear banner | Implemented |
| Set root password and access | 3 Root password & access | Implemented |
| System maintenance (clean RAM/cache, clean disk, scheduled tasks) | 4 System maintenance | Implemented (scheduled tasks: Coming Soon) |
| Block torrent, ports and keywords | 5 Block torrent, ports & keywords | Implemented (own iptables chain, plus UFW helpers) |
| Kernel acceleration (BBR) | 6 BBR acceleration | Implemented |
| Fail2ban manager | 7 Fail2ban | Implemented |
| DDoS protection | 8 DDoS protection | Coming Soon |
| Modify time zone | 9 Time zone | Implemented |
| Speedtest (Ookla) | 10 Speedtest | Implemented (open-source `speedtest-cli`) |
| Plugin scripts | 11 Plugin scripts | Coming Soon |

## 6. API and bots

ADMRufu ✅: API installer (`apiMenu`: status, restart, start/stop, reinstall,
uninstall, user list), Telegram bot (`bottelegram`: ID, token, logs,
start/stop), WhatsApp bot (`botWhatsapp`: QR or number pairing, allowed
numbers).

VPSPanel: 1 REST API · 2 Telegram bot · 3 WhatsApp bot. All Coming Soon.

## 7. Script configuration → Panel settings

ADMRufu ✅: auto-start script, system information (system info, connection and
account counter, RAM, swap, disk and CPU), language, task scheduler.

| ADMRufu item | VPSPanel item | Status |
|---|---|---|
| Auto-start script at login | 1 Auto-start panel at login | Implemented |
| System information (5 views) | 2 System information | Implemented |
| (none) | 3 Account defaults | Implemented |
| (none) | 4 Panel log | Implemented |
| update-adm alias | 5 Update panel | Implemented |
| Language | (none) | English only |
| Task scheduler | 6 Scheduled tasks | Coming Soon |

## Navigation conventions

- ADMRufu: each screen shows a "Back/Return" entry and "Enter an option" ✅.
  Whether "0" is the Back key is ❔ (drawn at runtime).
- VPSPanel: `0` is Back in every submenu and Exit in the main menu. `x` exits
  the panel from any screen. Invalid input shows an error and redraws the
  screen.
