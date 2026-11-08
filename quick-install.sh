#!/bin/bash
# VPSPanel one-command installer for Ubuntu 20.04+ and Debian 11+.
#
#   sudo apt-get update -y && sudo apt-get install -y curl && curl -fsSLo vpspanel-install.sh https://raw.githubusercontent.com/Chechimk/vpspanel/main/quick-install.sh && sudo bash vpspanel-install.sh
#
# It installs git, downloads the latest VPSPanel from the main branch into a
# temporary folder, and runs install.sh from there. No activation key.
#
# An existing installation is never replaced silently: you are asked first
# (accounts and settings in /etc/vpspanel are always kept). Without a terminal
# to ask on, it stops unless --update is given.
#
# Options:
#   --update   update an existing installation without asking
#   -h, --help show this help
# Testing a fork or branch: VPSPANEL_REPO=<git URL> VPSPANEL_BRANCH=<name>
set -uo pipefail

REPO=${VPSPANEL_REPO:-https://github.com/Chechimk/vpspanel.git}
BRANCH=${VPSPANEL_BRANCH:-main}
DEST=/opt/vpspanel
ETC=/etc/vpspanel
LOCK=/run/vpspanel-install.lock

red=$'\e[1;31m' grn=$'\e[1;32m' ylw=$'\e[1;33m' cyn=$'\e[1;36m' rst=$'\e[0m'
[[ -t 1 ]] || { red='' grn='' ylw='' cyn='' rst=''; }
step() { printf '%s==>%s %s\n' "$cyn" "$rst" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$grn" "$rst" "$*"; }
warn() { printf '%s[!]%s %s\n' "$ylw" "$rst" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$red" "$rst" "$*" >&2; exit 1; }

assume_update=0
for arg in "$@"; do
    case $arg in
        --update) assume_update=1 ;;
        -h|--help) sed -n '2,/^set -uo/{/^set -uo/d; s/^# \{0,1\}//; p}' "$0"; exit 0 ;;
        *) die "Unknown option: $arg (see --help)" ;;
    esac
done

# ------------------------------------------------------------ checks ---
[[ $(id -u) -eq 0 ]] || die "Run this script as root: sudo bash $0"
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
[[ $REPO =~ ^(https://[A-Za-z0-9./_-]+|/[A-Za-z0-9./_-]+)$ ]] || die "Unexpected repository URL: $REPO"
[[ $BRANCH =~ ^[A-Za-z0-9._/-]+$ ]] || die "Unexpected branch name: $BRANCH"

# Only one installer at a time.
exec 9> "$LOCK" || die "Cannot create $LOCK."
flock -n 9 || die "Another VPSPanel installation is already running."

# ------------------------------------------- existing installation ---
mode=install
if [[ -e $DEST ]]; then
    [[ -f $DEST/lib/common.sh && -f $DEST/bin/menu ]] \
        || die "$DEST exists but is not a VPSPanel installation. Move it away first; nothing was changed."
    have=$(awk -F'"' '/^VPSP_VERSION=/ {print $2}' "$DEST/lib/common.sh")
    warn "VPSPanel ${have:-?} is already installed in $DEST."
    if (( ! assume_update )); then
        ans=
        if { : < /dev/tty; } 2> /dev/null; then
            printf 'Update it to the latest version? Accounts and settings are kept. [y/N] ' > /dev/tty
            read -r ans < /dev/tty || ans=
        else
            die "No terminal to confirm on. Re-run with --update to update it; nothing was changed."
        fi
        [[ $ans =~ ^[Yy]([Ee][Ss])?$ ]] || { echo "Nothing was changed."; exit 0; }
    fi
    mode=update
elif [[ -s $ETC/accounts.db ]]; then
    ok "Existing accounts in $ETC will be reused."
fi

printf '\n%s  VPSPanel quick %s%s on %s\n\n' "$grn" "$mode" "$rst" "$PRETTY_NAME"

# ------------------------------------------------------ dependencies ---
step "Installing git and certificates"
missing=()
for p in git ca-certificates curl; do
    dpkg-query -W -f='${Status}' "$p" 2> /dev/null | grep -q 'ok installed' || missing+=("$p")
done
if (( ${#missing[@]} )); then
    export DEBIAN_FRONTEND=noninteractive
    # Wait (up to 5 minutes) instead of failing if unattended-upgrades holds the lock.
    apt_opts=(-q -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 -o Acquire::http::Timeout=30)
    apt-get "${apt_opts[@]}" update > /dev/null || warn "apt-get update reported problems; continuing."
    apt-get "${apt_opts[@]}" install -y --no-install-recommends "${missing[@]}" > /dev/null \
        || die "Could not install: ${missing[*]}. Nothing else was changed."
    ok "Installed: ${missing[*]}"
else
    ok "git, ca-certificates and curl are present."
fi

# ---------------------------------------------------------- download ---
step "Downloading VPSPanel ($BRANCH) from $REPO"
work=$(mktemp -d /tmp/vpspanel-quick.XXXXXX) || die "Cannot create a temporary folder."
trap 'rm -rf "$work"' EXIT
export GIT_TERMINAL_PROMPT=0
cloned=0
for attempt in 1 2 3; do
    if git clone -q --depth 1 --branch "$BRANCH" "$REPO" "$work/vpspanel"; then
        cloned=1; break
    fi
    rm -rf "$work/vpspanel"
    (( attempt < 3 )) && { warn "Download failed (attempt $attempt of 3); retrying..."; sleep 5; }
done
(( cloned )) || die "Could not download VPSPanel. Check the network and try again; nothing was changed."
for f in install.sh lib/common.sh bin/menu bin/vpspanel; do
    [[ -f $work/vpspanel/$f ]] || die "The download is incomplete ($f is missing); nothing was changed."
done
bash -n "$work/vpspanel/install.sh" || die "The downloaded installer is damaged; nothing was changed."
rev=$(git -C "$work/vpspanel" rev-parse --short HEAD 2> /dev/null)
new=$(awk -F'"' '/^VPSP_VERSION=/ {print $2}' "$work/vpspanel/lib/common.sh")
ok "Downloaded VPSPanel ${new:-?} (commit ${rev:-?})."

# ----------------------------------------------------------- install ---
step "Running install.sh"
args=()
[[ $mode == update ]] && args=(--update)
( cd "$work/vpspanel" && bash ./install.sh "${args[@]}" )
rc=$?
if (( rc != 0 )); then
    die "install.sh stopped with an error (exit $rc); see the messages above. Fix the problem and run the same command again."
fi
[[ -x /usr/local/bin/menu && -f $DEST/lib/common.sh ]] \
    || die "install.sh finished, but the menu command is missing. Run the command again or open an issue."
ok "Done. Type ${cyn}menu${rst} to open the panel."
