# VPSPanel roadmap

The panel marks everything below as **Coming Soon**. Selecting one of these
items explains that it isn't available yet and changes nothing. The
comparison with ADMRufu2.0 is in [VPSPANEL-GAP-ANALYSIS.md](VPSPANEL-GAP-ANALYSIS.md).

## Accounts
- **HWID / token account modes.** ADMRufu creates a Linux user named after
  the device ID; how HTTP Custom then authenticates was not observed, so this
  waits for a client test.
- Per-user traffic quotas and usage accounting.
- SSH post-login banner that shows the account's name, expiry and days left
  (ADMRufu does it through PAM).

## Protocols
- **UDP-Custom**: ADMRufu ships a closed-source binary; an open-source server
  that speaks the same client protocol has not been identified.
- **FileBrowser** (open-source web file manager).
- **Xray**: traffic accounting (stats API). REALITY, VLESS Encryption and the other transports are implemented (see XRAY-COMPATIBILITY.md).

## Tools
- Manually pasted (or downloaded .zip) certificates in the SSL manager.
- Scheduled tasks (for example, RAM cleanup on a timer).
- Plugin scripts (named shell scripts available as commands).

## API and bots
- Local API for account management.
- Telegram bot.
- WhatsApp bot.

## Not planned
- Python 2 proxy variants (Python 2 is end-of-life; the Python 3 proxy covers
  both modes).
- Hysteria version 1 (deprecated upstream; Hysteria2 is supported).
- ADMRufu modules that wrap proprietary binaries with no identified
  open-source equivalent: sshGo, HCR Custom, BHTTP Tunnel, ATKEN, and WS-EPRO
  (the VPSPanel proxy covers that use case).
