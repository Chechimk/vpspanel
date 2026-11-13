# VPSPanel vs ADMRufu2.0: gap analysis

ADMRufu behaviour comes from [ADMRUFU-FULL-STRUCTURE.md](ADMRUFU-FULL-STRUCTURE.md)
(observed in the running panel on 2026-11-08). "VPSPanel before" is v0.2.0 on
`main` (commit `18e1e74`). The last column records what the `develop` branch
does now and how it was verified; it is filled in from the test runs described
in the README.

Priority: **P1** = needed for the same day-to-day experience, done in this
branch; **P2** = useful, planned next; **P3** = not planned (closed-source
protocol, unsafe behaviour, or not applicable).

Observation marks for the ADMRufu column follow the structure document:
🔬 observed and tested, ✅ observed, ⚠️ observed broken, ❔ not observed.

## Layout and navigation

| Feature | ADMRufu2.0 | VPSPanel before | Gap / required work | Pri | Now |
|---|---|---|---|---|---|
| Frame | 🔬 60 columns, red double-line borders, centred bold title, `[n]>` items (green number, red `>`), red dashed group separators | Width 40–64, own colours, no groups | Re-draw every screen in the same layout and colours | P1 | Done |
| Footer | 🔬 `[0] Back` plus extra actions on the same line (e.g. `[13] Uninstall`) | `[0] Back  [x] Exit panel` | Footer actions per screen; keep `x` as a hidden shortcut | P1 | Done |
| Finished action | 🔬 status lines `task.....OK/Failed`, then `>> Press Enter to continue <<` | `ok`/`err` lines, "Press Enter" | Same pattern | P1 | Done |
| Dashboard | 🔬 reseller line, OS/IP/date/time box, optional disk+CPU, RAM, swap boxes, ACTIVE/EXPIRED/LOCKED/TOTAL counters | Fixed key/value rows incl. RAM, swap, disk, CPU, load | Same blocks, each one switchable | P1 | Done |
| Main menu order | 🔬 SSH accounts, [Xray accounts], [WireGuard accounts], Protocols, Extras, API & bots, Script settings, Language, Uninstall; bottom bar `[0] Leave VPS`, `Exit script`, `Reboot VPS` | Fixed 1–10 list, Panel settings, 0 = Exit | Xray/WireGuard account items appear only when installed; same bottom bar | P1 | Done |
| `0` on main menu | 🔬 ends the SSH session | exits the panel | Same as ADMRufu (log out), with the panel-exit item next to it | P1 | Done |
| Language menu | 🔬 Spanish/English | English only | Not applicable: VPSPanel is English-only by design | P3 | — |
| Script settings | 🔬 counters, system info, disk/CPU, RAM, swap toggles; auto-start | Panel settings: auto-start, system info, defaults, log, update, about | Add the dashboard toggles; keep update/about/defaults | P1 | Done |

## SSH / Dropbear accounts

| Feature | ADMRufu2.0 | VPSPanel before | Gap / required work | Pri | Now |
|---|---|---|---|---|---|
| New user | 🔬 name, password, days, limit; Enter saves / Retry / Back | name, password, days, limit | Same flow incl. Retry/Back confirmation | P1 | Done |
| Temporary user | 🔬 minutes; optional menu item | hours | Minutes; hidden unless enabled in account settings | P1 | Done |
| Remove / renew | 🔬 pick by number; renew sets today + N days | pick; renew **adds** N days | Renew = today + N days (same as ADMRufu) | P1 | Done |
| Edit user | 🔬 password + limit in one step | two separate items | One "Edit user" item | P1 | Done |
| Lock / unlock | 🔬 one toggle | one toggle | — | — | Same |
| General password | 🔬 ON/OFF + password; new users skip the password prompt | — | Implement | P1 | Done |
| Details | 🔬 table with password | table (no passwords: VPSPanel never stores them in plain text) | Keep hashes only; table layout like ADMRufu | P1 | Done |
| Online monitor | 🔬 paged table name/online/limit | refreshing list | Same columns | P1 | Done |
| Limiter | 🔬 ⚠️ expired + multi-login toggles and logs, but **enforcement failed** (`libip.so` not found) | expired + multi-login toggles, logs, auto-delete; enforcement tested | Keep VPSPanel's working guard | — | Better |
| Delete expired / all | ✅ | ✅ | — | — | Same |
| Backups | 🔬 auto-backup toggle, create, restore, delete; JSON with plain-text passwords | create, restore, delete, list (hashes) | Auto-backup timer; **import ADMRufu `.admrufu` backups** for migration | P1 | Done |
| Alphanumeric password rule | 🔬 removes PAM strength checks | panel passwords are set by root and are not PAM-checked | Not needed; documented | P3 | — |
| Account-manager settings | 🔬 show user list per action, select by name, show temp option, local-time dates | — | Implement (list toggles, select mode, temp option, time zone) | P1 | Done |
| HWID / TOKEN modes | 🔬 HWID = Linux user named after the HWID; ❔ client auth | — | Needs the client-side behaviour first | P2 | Coming Soon |
| Password storage | 🔬 plain text in world-readable `/etc/passwd` | hashed only | Keep VPSPanel's | — | Better |

## Protocols

| Protocol | ADMRufu2.0 | VPSPanel before | Gap / required work | Pri | Now |
|---|---|---|---|---|---|
| List screen | 🔬 two columns with `[ON]/[OFF]`, port summary at top | one column, ON/OFF/-- and ports | Two columns + port summary | P1 | Done |
| SSH | 🔬 several ports, banner (pre-login, post-login with USER/EXP/DAYS), root access, start/stop/restart; auto-applies keep-alive | ports, banner, root access | Post-login banner with USER/EXP/DAYS | P2 | Coming Soon (ports, pre-login banner, root access unchanged) |
| Dropbear | 🔬 several ports, manual edit, banner, status/restart/start-stop | one port | Several ports, edit, status | P1 | Done |
| SOCKS Python "direct" | 🔬 port → target, response code (200/101), custom header, mini-banner, several ports | WebSocket/HTTP proxy, port → target, always 101 | Response code, custom header, banner | P1 | Done |
| SOCKS Python "simple/public" | 🔬 open HTTP CONNECT proxy to any host | — | CONNECT mode **limited to this server's own ports** (an open proxy is abusable) | P1 | Done |
| Python 2 variants | 🔬 | — | Python 2 is end-of-life; not offered | P3 | — |
| Stunnel | 🔬 per-port, cert, logs | multiple ports, cert choice, live log | — | — | Same |
| SlowDNS (dnstt) | 🔬 NS domain, target, key pair, 53→5300 redirect | Coming Soon | Build `dnstt-server` (public domain) from source; same settings | P1 | Done |
| WS-EPRO | 🔬 closed binary | WebSocket proxy covers it | — | P3 | Covered |
| UDP-Custom | 🔬 closed binary, DNAT of all UDP ports | Coming Soon | No open-source server with the same client protocol identified | P3 | Coming Soon |
| UDP-Hysteria v2 | 🔬 SSH-account login (`user:password`), obfs on by default, port-hopping range | shared password, optional obfs | Log in with panel accounts; port hopping; obfs default on | P1 | Done |
| Hysteria v1 | ✅ offered | — | v1 is deprecated upstream | P3 | — |
| BadVPN-UDPGW | 🔬 several ports on 127.0.0.1 | Coming Soon | Build `badvpn-udpgw` (BSD) from source | P1 | Done |
| Squid | 🔬 open proxy (`allow all`), deny lists, edit includes, logs | restricted to this server, live log | Keep restriction; add log views | P1 | Done |
| OpenVPN | 🔬 TCP/UDP, port, cipher, DNS, login with SSH accounts (PAM), one client file | Coming Soon | Implement with easy-rsa + PAM plugin | P1 | Done |
| Checkuser | 🔬 `GET /` online count, `POST /checkuser` expiry; UTC/local; DDMMYYYY/epoch | Coming Soon | Original Python service with the same API | P1 | Done |
| ATKEN, HCR, BHTTP, SSHGO | ✅ closed binaries | — | — | P3 | Not planned |
| FileBrowser | ✅ | — | Open-source; low priority | P2 | Coming Soon |
| Xray protocols | 🔬 VMess, VLESS, SOCKS, Trojan, Shadowsocks | VLESS, VMess | Add Trojan, Shadowsocks (AEAD + 2022), SOCKS5, HTTP, Hysteria2 (Xray), MASQUE, Tunnel | P1 | Done |
| Xray transports | 🔬 TCP (+HTTP camouflage), gRPC, WebSocket, XHTTP; TLS on/off | WS, WS+TLS, TCP+TLS | gRPC and XHTTP, TLS on/off for each | P1 | Done (plus HTTPUpgrade, mKCP, XHTTP over HTTP/3, Vision, VLESS Encryption; see XRAY-COMPATIBILITY.md) |
| Xray REALITY | 🔬 not offered | — | REALITY with generated keys, short IDs, SpiderX (beyond ADMRufu) | P1 | Done |
| Xray users | 🔬 per inbound, expiry, link + client JSON, reset stats | all inbounds, expiry, links | Client JSON; QR | P1 | Done |
| Xray traffic stats | 🔬 timer every 30 s | — | Stats API + per-user totals | P2 | Coming Soon |
| Xray view/edit JSON, logs | 🔬 | — | Add | P1 | Done |
| WireGuard | 🔬 port, edit, NAT fix, clients with QR | port, edit, clients with QR, NAT re-detect | — | — | Same |

## Extra tools

| Feature | ADMRufu2.0 | VPSPanel before | Gap / required work | Pri | Now |
|---|---|---|---|---|---|
| SSL certificates | 🔬 acme.sh: Let's Encrypt, ZeroSSL, manual paste, zip URL; activate per cert | certbot standalone, self-signed | Manual (paste) and .zip certificates | P2 | Coming Soon |
| Kernel acceleration | ✅ choose from available algorithms | BBR on/off | Choose any available algorithm | P1 | Done |
| Maintenance | ✅ RAM/disk box, clean RAM, clean disk, scheduled tasks | clean RAM/disk, swap | Scheduled RAM clean | P2 | Coming Soon |
| Torrent / keyword / port blocking | 🔬 rules on all server OUTPUT | rules on panel-user traffic only, rule view | Keep scoped rules | — | Same (scoped) |
| Fail2ban | 🔬 ban time, find time, attempts, manual edit | ban time, find time, attempts, manual edit, unban | — | — | Same |
| DDoS protection | 🔬 ⚠️ ports, attempts, block minutes, whitelist; service crashed (`libpcap`) | Coming Soon | iptables connection-rate limit with the same four settings | P1 | Done |
| Time zone | 📦 list | set / UTC | — | — | Same |
| Speedtest | 🔬 Ookla CLI | speedtest-cli | — | — | Same |
| Plugins | 🔬 named shell scripts as commands | Coming Soon | Implement | P2 | Coming Soon |

## API and bots

| Feature | ADMRufu2.0 | VPSPanel before | Gap | Pri | Now |
|---|---|---|---|---|---|
| API | 🔬 Unix socket, `/server /ssh /token /hwid` | Coming Soon | — | P2 | Coming Soon |
| Telegram / WhatsApp bots | ❔ not installed | Coming Soon | — | P2 | Coming Soon |

## Things VPSPanel deliberately does differently

- **Passwords are never stored in plain text** (ADMRufu keeps them in
  `/etc/passwd` and its backups).
- **No open proxies**: Squid and the CONNECT proxy only reach this server.
- **Blocking rules only affect panel accounts**, not the server's own traffic.
- **SSH is never changed silently**: ADMRufu rewrites keep-alive and port
  settings when the SSH screen is opened; VPSPanel only changes what you pick,
  checks it with `sshd -t` and rolls back on error.
- **No forced reboot, apt-source replacement or auto-update on login.**

## Verification of the `develop` branch (2026-11-08)

`tests/run.sh` passed **265 of 265** checks (116 of them for Xray) on fresh Ubuntu 22.04 and Ubuntu
24.04 containers (systemd, privileged, OpenSSH with global password login
off, as on cloud images). Verified with **real clients and traffic**:

| Protocol | Client used | Result |
|---|---|---|
| OpenSSH, Dropbear (2 ports) | OpenSSH client, panel account | tunnel works; wrong password refused; login limit and lock close sessions |
| Direct proxy 101 and 200 + custom header | raw HTTP payloads, split payload | correct responses, then SSH/Dropbear banner |
| CONNECT proxy | OpenSSH through `nc -X connect` | tunnel works; other ports refused (403) |
| Stunnel, Squid | openssl s_client, raw CONNECT | TLS then SSH; Squid refuses other hosts |
| SlowDNS | `dnstt-client` built from the same source | SSH tunnel through dnstt works |
| OpenVPN (TCP) | OpenVPN 2.x client, panel account | connects; wrong password gets AUTH_FAILED; client file has no private key |
| Hysteria2 | official Hysteria2 client, panel account or shared password, obfs; also the panel's share links imported as-is | traffic works; wrong password, missing obfs, expired and locked accounts refused |
| Xray | official Xray client from the panel's client JSON | traffic works for VLESS WS, VLESS XHTTP, VMess WS, VLESS gRPC+TLS, Trojan TCP+TLS, Shadowsocks; unknown UUID refused |
| Checkuser | curl | `GET /` count, `POST /checkuser` expiry, 404 for unknown users |
| DDoS protection | 12 rapid connections from one IP | about 5 accepted, the rest dropped, block listed and cleared |
| WireGuard | `wg` | server and client peers created/removed (no client handshake) |

**Not verified:** BadVPN UDP relay with a real udpgw client (the service
builds, listens and restarts), UDP port hopping for Hysteria2 (the redirect
rule is created, but local tests do not pass through PREROUTING), Let's
Encrypt issuance (needs a public domain), Debian 11/12 full suite (the
one-command installer was tested on Debian 12 earlier), and behaviour on a
real VPS kernel (BBR, WireGuard handshakes).
