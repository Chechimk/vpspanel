#!/bin/bash
# Uninstall VPSPanel.
#
# Always removed: the panel files, its commands, the guard timer and every
# service the panel created (Dropbear unit, proxies, Stunnel, Xray, Hysteria2,
# SlowDNS, BadVPN, Checkuser, OpenVPN, DDoS rules,
# WireGuard server created by the panel, blocking rules, Squid configuration,
# Fail2ban jail).
# Kept unless you choose otherwise: panel accounts and /etc/vpspanel.
# Never touched: SSH ports and root-login settings, so you cannot be locked out.
set -uo pipefail

[[ $(id -u) -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
export VPSP_HOME=$HERE
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/accounts.sh
. "$HERE/lib/accounts.sh"
# shellcheck source=lib/system.sh
. "$HERE/lib/system.sh"
for m in "$HERE"/modules/*.sh; do
    # shellcheck source=/dev/null
    . "$m"
done

assume_yes=0
[[ ${1:-} == -y ]] && assume_yes=1
yes_no() { (( assume_yes )) && return 1; confirm "$1"; }

if (( ! assume_yes )); then
    warn "This removes VPSPanel and every service it set up."
    confirm "Continue?" || { info "Cancelled."; exit 1; }
fi
delete_accounts=0
yes_no "Also delete all panel accounts and /etc/vpspanel? (default: keep them)" && delete_accounts=1

info "Stopping panel services..."
systemctl disable --now vpspanel-guard.timer > /dev/null 2>&1
rm -f /etc/systemd/system/vpspanel-guard.service /etc/systemd/system/vpspanel-guard.timer
dropbear_installed && dropbear_remove
[[ -n $(wsp_ports) || -f $WSP_UNIT ]] && wsp_remove_all
stn_installed && stn_uninstall
[[ -f $XRAY_UNIT ]] && xray_uninstall
[[ -f $HY_UNIT ]] && hy_uninstall
wg_installed && wg_uninstall
sdns_installed && sdns_uninstall
bv_installed && bv_uninstall
cu_installed && cu_uninstall
ovpn_installed && ovpn_uninstall
ddos_installed && ddos_uninstall
[[ -f $AUTHD_UNIT ]] && { systemctl disable --now vpspanel-authd > /dev/null 2>&1; rm -f "$AUTHD_UNIT"; }
fwb_remove; rm -rf "$FWB_DIR"; [[ -f $FWB_UNIT ]] && { systemctl disable vpspanel-firewall > /dev/null 2>&1; rm -f "$FWB_UNIT"; }
squid_installed && squid_uninstall
if [[ -f $F2B_JAIL ]]; then rm -f "$F2B_JAIL"; systemctl try-restart fail2ban > /dev/null 2>&1; fi
rm -f "$CERTBOT_HOOK"
rm -f /etc/sysctl.d/99-vpspanel-bbr.conf
# The banner drop-in only shows a message; removing it is safe.
rm -f "$SSHD_DROPIN" "$BANNER_FILE"

if (( delete_accounts )); then
    acct_delete_all > /dev/null
    ssh_remove_block
    getent group "$VPSP_GROUP" > /dev/null && groupdel "$VPSP_GROUP" 2>/dev/null
    rm -rf "$VPSP_ETC"
    info "Accounts and settings deleted. Backups in $VPSP_BACKUP_DIR were kept."
else
    ssh_apply || true
    info "Accounts were kept. Reinstall VPSPanel to manage them again."
fi

getent passwd "$VPSP_SVC_USER" > /dev/null && userdel "$VPSP_SVC_USER" 2>/dev/null
sed -i '/vpspanel-autostart/d' /root/.bashrc 2>/dev/null
for c in menu vpspanel; do
    [[ -L /usr/local/bin/$c ]] && rm -f "/usr/local/bin/$c"
    [[ -e /usr/local/bin/$c.before-vpspanel ]] && mv "/usr/local/bin/$c.before-vpspanel" "/usr/local/bin/$c"
done
systemctl daemon-reload
systemctl reset-failed "vpspanel-*" > /dev/null 2>&1 || true
log_event "panel uninstalled"
[[ $HERE == /opt/vpspanel ]] && rm -rf /opt/vpspanel
ok "VPSPanel was uninstalled. SSH ports and root-login settings were not changed."
