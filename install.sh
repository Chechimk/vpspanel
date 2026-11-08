#!/bin/bash
# VPSPanel installer for Ubuntu 20.04+ and Debian 11+.
#
#   git clone https://github.com/Chechimk/vpspanel.git
#   cd vpspanel
#   sudo bash install.sh
#   menu
#
# What it changes:
#   - installs a few packages from the distribution (curl, jq, python3, ...)
#   - copies the panel to /opt/vpspanel, settings in /etc/vpspanel
#   - creates the "vpsusers" group and the `menu` / `vpspanel` commands
#   - enables the vpspanel-guard timer (account expiry and login limits)
#   - lets members of "vpsusers" log in with a password for tunnels only
#     (a Match block appended to sshd_config, validated with `sshd -t`)
# What it never changes: SSH ports, root login, firewall rules, other users.
set -uo pipefail

DEST=/opt/vpspanel
ETC=/etc/vpspanel
REPO_URL_DEFAULT=https://github.com/Chechimk/vpspanel.git
SRC=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
MODE=install
[[ ${1:-} == --update ]] && MODE=update

red=$'\e[1;31m' grn=$'\e[1;32m' ylw=$'\e[1;33m' cyn=$'\e[1;36m' rst=$'\e[0m'
[[ -t 1 ]] || { red='' grn='' ylw='' cyn='' rst=''; }
step() { printf '%s==>%s %s\n' "$cyn" "$rst" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$grn" "$rst" "$*"; }
warn() { printf '%s[!]%s %s\n' "$ylw" "$rst" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$red" "$rst" "$*" >&2; exit 1; }

# ------------------------------------------------------------ checks ---
[[ $(id -u) -eq 0 ]] || die "Run the installer as root: sudo bash install.sh"
[[ -f $SRC/lib/common.sh && -f $SRC/bin/menu ]] || die "Run install.sh from inside the VPSPanel folder."
[[ -r /etc/os-release ]] || die "Cannot detect the operating system (/etc/os-release is missing)."
# shellcheck source=/dev/null
. /etc/os-release
major=${VERSION_ID%%.*}
case ${ID:-} in
    ubuntu) [[ ${major:-0} -ge 20 ]] || die "Ubuntu 20.04 or newer is required (found ${VERSION_ID:-?})." ;;
    debian) [[ ${major:-0} -ge 11 ]] || die "Debian 11 or newer is required (found ${VERSION_ID:-?})." ;;
    *) die "Unsupported system: ${PRETTY_NAME:-unknown}. VPSPanel supports Ubuntu 20.04+ and Debian 11+." ;;
esac
[[ -d /run/systemd/system ]] || die "systemd is required."
command -v apt-get > /dev/null || die "apt-get is required."

printf '\n%s  VPSPanel %s%s on %s\n\n' "$grn" "$MODE" "$rst" "$PRETTY_NAME"

# ------------------------------------------------------ dependencies ---
step "Installing required packages"
pkgs=(curl jq iproute2 procps psmisc openssl ca-certificates python3 unzip passwd iptables nano tzdata)
missing=()
for p in "${pkgs[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' || missing+=("$p")
done
if (( ${#missing[@]} )); then
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=300 update -q > /dev/null || warn "apt-get update reported problems; continuing."
    apt-get -o DPkg::Lock::Timeout=300 install -y -q --no-install-recommends "${missing[@]}" > /dev/null \
        || die "Could not install: ${missing[*]}"
    ok "Installed: ${missing[*]}"
else
    ok "All required packages are present."
fi

# ------------------------------------------------------------- files ---
step "Copying the panel to $DEST"
if [[ $SRC != "$DEST" ]]; then
    tmp="$DEST.new.$$"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    for item in bin lib modules systemd docs install.sh update.sh uninstall.sh README.md; do
        [[ -e $SRC/$item ]] && cp -a "$SRC/$item" "$tmp/"
    done
    chmod 755 "$tmp"/bin/* "$tmp"/*.sh
    chown -R root:root "$tmp"
    rm -rf "$DEST.old"
    [[ -d $DEST ]] && mv "$DEST" "$DEST.old"
    mv "$tmp" "$DEST" || { [[ -d $DEST.old ]] && mv "$DEST.old" "$DEST"; die "Could not install files to $DEST."; }
    rm -rf "$DEST.old"
fi
ok "Files installed."

# 711: services running as the vpspanel-svc user can reach their own
# sub-folders; nobody can list the folder, and every file keeps mode 600/640.
mkdir -p "$ETC" && chmod 711 "$ETC"
getent passwd vpspanel-svc > /dev/null || useradd --system --user-group --no-create-home \
    --home-dir /nonexistent --shell /usr/sbin/nologin vpspanel-svc
[[ -f $ETC/accounts.db ]] || : > "$ETC/accounts.db"
chmod 600 "$ETC/accounts.db"
touch /var/log/vpspanel.log && chmod 600 /var/log/vpspanel.log
url=$(git -C "$SRC" config --get remote.origin.url 2>/dev/null || true)
echo "${url:-$REPO_URL_DEFAULT}" > "$ETC/source"

# --------------------------------------------------- accounts & shell ---
step "Preparing the account group"
getent group vpsusers > /dev/null || groupadd --system vpsusers
# Dropbear refuses users whose shell is not listed in /etc/shells.
grep -qx /bin/false /etc/shells || echo /bin/false >> /etc/shells
ok "Group vpsusers ready."

step "Creating the menu and vpspanel commands"
for c in menu vpspanel; do
    target=/usr/local/bin/$c
    if [[ -e $target && ! -L $target ]]; then
        mv "$target" "$target.before-vpspanel"
        warn "Existing $target moved to $target.before-vpspanel"
    fi
    ln -sfn "$DEST/bin/$c" "$target"
done
if grep -qE '^[[:space:]]*alias[[:space:]]+menu=' /root/.bashrc 2>/dev/null; then
    warn "/root/.bashrc defines an alias named 'menu' (from another panel)."
    warn "It hides the VPSPanel command. Remove that alias line or run /usr/local/bin/menu."
fi
ok "Commands installed: menu, vpspanel"

# ----------------------------------------------------------- services ---
step "Enabling the account guard timer"
install -m 644 "$DEST/systemd/vpspanel-guard.service" /etc/systemd/system/
install -m 644 "$DEST/systemd/vpspanel-guard.timer" /etc/systemd/system/
sed -i "s#/opt/vpspanel#$DEST#g" /etc/systemd/system/vpspanel-guard.service
systemctl daemon-reload
systemctl enable --now vpspanel-guard.timer > /dev/null 2>&1 && ok "vpspanel-guard.timer is active." \
    || warn "Could not start vpspanel-guard.timer. See: systemctl status vpspanel-guard.timer"

step "Allowing panel accounts to open SSH tunnels"
if command -v sshd > /dev/null && [[ -f /etc/ssh/sshd_config ]]; then
    (
        export VPSP_HOME=$DEST
        # shellcheck source=lib/common.sh
        . "$DEST/lib/common.sh"
        # shellcheck source=lib/system.sh
        . "$DEST/lib/system.sh"
        if sshd -t 2> /dev/null; then
            ssh_write_block && ok "sshd: password tunnels enabled for the vpsusers group only."
        else
            warn "Your current sshd configuration does not pass 'sshd -t'; it was left untouched."
            warn "Fix it, then use Protocol configuration > SSH > Re-apply panel account access policy."
        fi
    )
else
    warn "OpenSSH server is not installed; SSH accounts will not work until it is."
fi

# The Dropbear and WebSocket units point at panel files: refresh them on update.
if [[ $MODE == update ]]; then
    systemctl try-restart vpspanel-dropbear 'vpspanel-wsproxy@*' > /dev/null 2>&1 || true
fi

version=$(awk -F'"' '/^VPSP_VERSION=/ {print $2}' "$DEST/lib/common.sh")
printf '\n%s  VPSPanel %s is ready.%s\n\n' "$grn" "$version" "$rst"
printf '  Open the panel:      %smenu%s\n' "$cyn" "$rst"
printf '  Scripting commands:  %svpspanel help%s\n' "$cyn" "$rst"
printf '  SSH ports and firewall rules were not changed.\n\n'
