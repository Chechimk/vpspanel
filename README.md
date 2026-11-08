# VPSPanel

An independent, Bash-based administration panel for managing SSH/VPN tunnel
accounts on Debian/Ubuntu VPS servers.

> **Status: early development (v0.1.0).** It isn't ready for production use yet:
> the installer, systemd units and tests haven't been written.

## Layout

| Path | Purpose |
|------|---------|
| `bin/vpspanel` | Command-line interface (scriptable) |
| `bin/menu` | Interactive menu for administrators |
| `bin/vpspanel-dropbear` | Launcher used by the Dropbear systemd unit |
| `lib/common.sh` | Paths, config parsing, UI helpers, logging, validation, time helpers |
| `lib/accounts.sh` | Account database, create/renew/lock/delete, enforcement, backup/restore |
| `lib/system.sh` | Host info, service status, BBR, timezone, SSH banner |
| `modules/dropbear.sh` | Dropbear install / port change / removal |
| `docs/`, `systemd/`, `tests/` | Reserved, still empty |

## Implemented

- **Accounts:** create, trial (hours-based), delete, renew, change password,
  login limit, lock/unlock, info, list, online monitor, purge expired, repair
  orphaned records.
- **Enforcement:** the `vpspanel enforce` command expires accounts on time,
  enforces simultaneous-login limits, and can optionally auto-delete accounts
  that have been expired for a while.
- **Backup/restore:** accounts and password hashes in a `tar.gz` archive.
- **System tools:** a dashboard with OS, IP, RAM, disk and load, plus a BBR
  toggle, timezone setting, panel log viewer, package update and reboot.
- **Settings:** default validity, default login limit, auto-delete, and the
  SSH login banner (applied to OpenSSH and Dropbear).
- **Dropbear module:** install, change port, restart, uninstall.

The panel never stores account passwords. Accounts are regular Linux users
in the `vpsusers` group, with no home directory and the `/bin/false` shell.

## Unfinished / planned

- [ ] `install.sh`, `update.sh`, `uninstall.sh` (the menu references these, but
      they don't exist yet)
- [ ] systemd units: `vpspanel-guard.service` and `vpspanel-guard.timer`, to run
      `vpspanel enforce` every minute
- [ ] `docs/ROADMAP.md`
- [ ] Test suite under `tests/` (paths can already be overridden through
      `VPSP_*` environment variables, and `VPSP_NOW` pins the clock)
- [ ] Protocol modules: Xray, WireGuard, OpenVPN, Hysteria2, SlowDNS
- [ ] Testing on supported Debian/Ubuntu releases

## Usage (development)

```bash
sudo VPSP_HOME=/path/to/vpspanel /path/to/vpspanel/bin/vpspanel help
sudo VPSP_HOME=/path/to/vpspanel /path/to/vpspanel/bin/menu
```

Runtime files default to `/etc/vpspanel/` (`accounts.db`, `panel.conf`) and
`/var/log/vpspanel.log`.
