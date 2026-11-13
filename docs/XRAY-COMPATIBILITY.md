# Xray manager: compatibility table and behaviour

VPSPanel's Xray manager (`modules/xray.sh`) only offers combinations that
Xray-core accepts and that actually carry traffic. The rules below come from
the official documentation (<https://xtls.github.io/en/config/transport.html>,
the inbound/outbound pages and `Xray-docs-next`) and were checked against
**Xray-core v26.11.9** with `xray run -test` and real client traffic.

The table lives in code as associative arrays at the top of
`modules/xray.sh` (`XR_PROTO_METHODS`, `XR_PROTO_SECURITY`,
`XR_METHOD_SECURITY`, `xr_flow_allowed`). The wizard builds its menus from
those arrays and `xr_check` validates every save against them, so a future
Xray release is supported by editing the table, not the menus.

## Layers

| Layer | Field | Options in the panel |
|---|---|---|
| Proxy protocol | `protocol` | VLESS, VMess, Trojan, Shadowsocks, Hysteria2 (Xray-native), MASQUE |
| Auxiliary inbound | `protocol` | SOCKS5, HTTP proxy, Tunnel (dokodemo-door) |
| Transport | `streamSettings.method` | RAW, XHTTP, gRPC, WebSocket, HTTPUpgrade, mKCP, Hysteria, MASQUE |
| Transport security | `streamSettings.security` | none, TLS, REALITY |
| Protocol-native encryption | VLESS `decryption` | off (`"none"`) or VLESS Encryption (`xray vlessenc`) |
| Flow | VLESS user `flow` | none, `xtls-rprx-vision` (+ client-only `-udp443`) |

## Protocol × transport

| Protocol | Transports offered |
|---|---|
| VLESS, VMess, Trojan | RAW, XHTTP, gRPC, WebSocket, HTTPUpgrade, mKCP |
| Shadowsocks | RAW (its own TCP/UDP) |
| Hysteria2 (Xray-native) | Hysteria only |
| MASQUE | MASQUE only |
| SOCKS5, HTTP, Tunnel | RAW (their own TCP/UDP) |

VLESS/VMess/Trojan over the Hysteria transport is valid in Xray but not
offered: the standalone Hysteria2 manager and the Xray Hysteria2 inbound
already cover QUIC.

## Transport × security

| Transport | none | TLS | REALITY |
|---|---|---|---|
| RAW | yes | yes | yes |
| XHTTP | yes | yes (h2/http1.1 or **h3**) | yes |
| gRPC | yes | yes | yes |
| WebSocket | yes | yes | no |
| HTTPUpgrade | yes | yes | no |
| mKCP | yes | yes | no |
| Hysteria | no | **required** | no |
| MASQUE | no | **required** (h3, h2 or both) | no |

Shadowsocks and SOCKS5: none only. HTTP proxy: none or TLS (HTTPS proxy,
ALPN fixed to `http/1.1`).

## Flow control

- The server only knows `xtls-rprx-vision`; `xtls-rprx-vision-udp443` is an
  outbound (client) option. Xray rejects it as a server flow, so the panel
  stores `xtls-rprx-vision` for users and writes `-udp443` only into links
  and client JSON when you pick it.
- Vision is offered only for **VLESS over RAW with TLS or REALITY**, or with
  **VLESS Encryption** on any transport. Xray's config test accepts Vision on
  other transports, but it cannot work there, so the panel refuses it.
- Vision is never switched on automatically.

## Removed transports (never offered)

Legacy HTTP/2 (`h2`/`http`), QUIC and DomainSocket were removed from
Xray-core. XHTTP over HTTP/2 or HTTP/3 replaces them. mKCP's `header` and
`seed` fields were also removed; the panel writes those choices as
FinalMask `mkcp-legacy` instead.

## What the wizard asks

Questions depend on earlier answers; irrelevant ones are skipped. In menus
`0` goes back; at text prompts `<` goes back, Enter keeps the shown default,
and `-` clears an optional value.

| After choosing | It asks |
|---|---|
| VLESS | VLESS Encryption on/off (keys generated with `xray vlessenc`) |
| Security none | nothing about certificates or REALITY (a warning for VLESS/Trojan without Encryption) |
| TLS | certificate (existing one or a new self-signed one), SNI, ALPN (fixed where the transport needs one value), minimum TLS version, client fingerprint |
| REALITY | target `host:port`, server names, private key (generated, or yours), short ID, SpiderX, client fingerprint |
| RAW (no security) | HTTP header camouflage (path, Host) |
| XHTTP | path, Host, client mode (`stream-up`/`stream-one` only with TLS/REALITY) |
| gRPC | service name, client mode (gun/multi) |
| WebSocket | path, Host, heartbeat |
| HTTPUpgrade | path, Host |
| mKCP | MTU, TTI, uplink, downlink, congestion multiplier, obfuscation (seed or legacy header) |
| Hysteria | Salamander obfuscation password |
| MASQUE | address pool, tunnel MTU |
| Shadowsocks | cipher (AEAD or 2022; 2022 server key generated) |
| SOCKS5 | UDP on/off |
| Tunnel | target address, port, TCP/UDP |

The summary offers **Save and Activate**, **Edit settings** (back to the
start with every answer kept) or **Cancel**.

## Safety

- Each inbound has its own settings file (`/etc/vpspanel/xray/inbounds/TAG.json`, mode 600)
  and its own certificate copy (`/etc/vpspanel/xray/tls/TAG/`).
- Every change is tested with `xray run -test`; if the service then fails
  to start, the previous configuration is restored and restarted.
- Disabling an inbound keeps it (with its keys) in its settings file.
- Users are rebuilt into every enabled inbound from `users.db`, in each
  protocol's own shape; expired users are removed by the guard timer.
- REALITY private keys and VLESS Encryption server keys are never put in
  links, client JSON or the "view" screen.
- Self-signed TLS: certificate checks stay on. Client JSON pins the
  certificate (`pinnedPeerCertSha256`); Hysteria2 links use `pinSHA256`.
  Other share links keep verification on, so most apps need the client JSON
  (or a real certificate) for self-signed TLS.
- Inbounds created by v0.3 (legacy `network` field names) are migrated
  automatically and keep working.

## Share links

| Protocol | Link |
|---|---|
| VLESS | `vless://` with encryption, flow, type, path/host/mode/serviceName, security, sni, fp, alpn, pbk, sid, spx |
| VMess | `vmess://` (base64 JSON v2) |
| Trojan | `trojan://` |
| Shadowsocks | `ss://` (SIP002; 2022 ciphers use `serverKey:userKey`) |
| SOCKS5 | `socks://` |
| Hysteria2 (Xray) | `hysteria2://` (official Hysteria2 clients accept it) |
| MASQUE, HTTP proxy, mKCP with obfuscation | client JSON only (no standard link can express them) |
| Tunnel | no client |

## Verified (Ubuntu 22.04 and 24.04, Xray-core v26.11.9)

Each configuration below was created through the panel and carried real
HTTPS traffic through the official Xray-core client built from the panel's
own client JSON:

- VLESS: RAW+REALITY+Vision (also with the `-udp443` client flow),
  RAW+TLS+Vision, RAW none, XHTTP+REALITY, XHTTP+TLS stream-one,
  XHTTP+TLS over HTTP/3, XHTTP none packet-up, gRPC+REALITY, gRPC+TLS multi,
  WebSocket none, HTTPUpgrade+TLS, mKCP none, mKCP with seed, mKCP with
  WeChat header + TLS, VLESS Encryption over WebSocket with Vision and over RAW
- VMess: RAW none, RAW with HTTP header, XHTTP+TLS, gRPC+REALITY
- Trojan: RAW+TLS, XHTTP+REALITY, WebSocket+TLS
- Shadowsocks: chacha20-ietf-poly1305, aes-256-gcm, 2022-blake3-aes-128-gcm, 2022-blake3-aes-256-gcm
- Hysteria2 (Xray-native), with and without Salamander; its share link also
  worked in the **official Hysteria2 client**
- MASQUE over HTTP/3 and HTTP/2
- SOCKS5 (also with curl and the link's credentials), HTTP proxy, HTTPS proxy
- Tunnel to the local SSH port

Also verified: a second user on several inbounds, unknown and expired users
refused, 18 invalid combinations refused with a reason, editing (path change,
REALITY keys kept, invalid edit refused), disable/enable, rollback after a
failed restart, migration of a v0.3 configuration, and the interactive
wizard through a pseudo-terminal (REALITY defaults, Back, Cancel).

## Not verified

- Third-party mobile apps (v2rayNG, NekoBox, Streisand...) importing the links.
  The links follow the common share-link format, but only the official Xray
  and Hysteria2 clients were run.
- MASQUE with non-Xray RFC 9484 clients.
- REALITY against targets other than `www.microsoft.com:443`.
- Behaviour behind real CDNs.
