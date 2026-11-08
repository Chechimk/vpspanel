# VPSPanel roadmap

The panel marks everything below as **Coming Soon**. Selecting one of these
items explains that it isn't available yet and changes nothing.

## Protocols
- **SlowDNS (DNSTT)**: build `dnstt-server` (public domain) from source, manage
  the NS domain, key pair and forward port.
- **UDP Custom**: the ADMRufu module ships a closed-source binary. It needs an
  open-source replacement first.
- **BadVPN UDPGW**: build `badvpn-udpgw` (BSD) from source, with one service per
  port.
- **OpenVPN**: server with easy-rsa, client `.ovpn` export, and
  reconfiguration.
- **Checkuser**: an HTTP endpoint apps can query for account expiry.
- **Xray XHTTP / REALITY inbounds**: Xray now marks WebSocket and VMess as
  deprecated.
- **Hysteria2 per-user authentication**: today every client shares one
  password.

## Accounts
- HWID / token account modes.
- Per-user traffic quotas and usage accounting.
- Automatic daily user backups.

## Tools
- DDoS protection (connection-rate limits per port).
- Scheduled tasks (for example, RAM cleanup on a timer).
- Plugin scripts.

## API and bots
- REST API for account management.
- Telegram bot.
- WhatsApp bot.

## Not planned
These ADMRufu modules wrap proprietary binaries with no identified open-source
equivalent: sshGo, HCRCustom, BHTTPtunnel, aToken, and the WS-Epro binary (the
VPSPanel WebSocket proxy covers that use case). File Browser is also not
planned.
