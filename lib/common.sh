# shellcheck shell=bash
# vpspanel - shared helpers: paths, config, UI, logging, validation.
# This file is sourced by the panel commands; it is never executed directly.

VPSP_VERSION="0.2.0"

# All paths can be overridden from the environment (used by the test suite).
VPSP_HOME="${VPSP_HOME:-/opt/vpspanel}"
VPSP_ETC="${VPSP_ETC:-/etc/vpspanel}"
VPSP_DB="${VPSP_DB:-$VPSP_ETC/accounts.db}"
VPSP_CONF="${VPSP_CONF:-$VPSP_ETC/panel.conf}"
VPSP_LOG="${VPSP_LOG:-/var/log/vpspanel.log}"
VPSP_GROUP="${VPSP_GROUP:-vpsusers}"
VPSP_SHELL="${VPSP_SHELL:-/bin/false}"
VPSP_BACKUP_DIR="${VPSP_BACKUP_DIR:-/root/vpspanel-backups}"
VPSP_SVC_USER="${VPSP_SVC_USER:-vpspanel-svc}"   # unprivileged user for Xray/Hysteria2

# ---------------------------------------------------------------- config ---
# Defaults; panel.conf (KEY=value lines) overrides them.
DEFAULT_LIMIT=1          # max simultaneous logins for new accounts (0 = unlimited)
DEFAULT_DAYS=30          # default validity for new accounts
AUTO_DELETE_DAYS=0       # delete accounts N days after expiry (0 = never)
BANNER_TEXT=""           # SSH login banner shown to clients
LIMIT_EXPIRED=1          # guard closes sessions of expired accounts (1/0)
LIMIT_LOGINS=1           # guard enforces simultaneous-login limits (1/0)

readonly VPSP_CONF_KEYS="DEFAULT_LIMIT DEFAULT_DAYS AUTO_DELETE_DAYS BANNER_TEXT LIMIT_EXPIRED LIMIT_LOGINS"

# Parse panel.conf without executing it.
load_config() {
    [[ -r $VPSP_CONF ]] || return 0
    local key value
    while IFS='=' read -r key value; do
        [[ $key =~ ^[A-Z_]+$ ]] || continue
        [[ " $VPSP_CONF_KEYS " == *" $key "* ]] || continue
        value=${value%$'\r'}
        value=${value#\"}; value=${value%\"}
        printf -v "$key" '%s' "$value"
    done < "$VPSP_CONF"
}

# set_config KEY VALUE - update one key in panel.conf atomically.
set_config() {
    local key=$1 value=$2 tmp
    [[ " $VPSP_CONF_KEYS " == *" $key "* ]] || { err "Unknown setting: $key"; return 1; }
    [[ $value != *$'\n'* && $value != *'"'* ]] || { err "Value may not contain newlines or double quotes."; return 1; }
    mkdir -p "$(dirname "$VPSP_CONF")"
    tmp=$(mktemp "${VPSP_CONF}.XXXXXX") || return 1
    if [[ -f $VPSP_CONF ]]; then
        grep -v "^${key}=" "$VPSP_CONF" > "$tmp" || true
    fi
    printf '%s="%s"\n' "$key" "$value" >> "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$VPSP_CONF"
    printf -v "$key" '%s' "$value"
}

# -------------------------------------------------------------------- UI ---
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    C_RED=$'\e[1;31m' C_GRN=$'\e[1;32m' C_YLW=$'\e[1;33m' C_BLU=$'\e[1;34m'
    C_CYN=$'\e[1;36m' C_BLD=$'\e[1m' C_DIM=$'\e[2m' C_RST=$'\e[0m'
else
    C_RED='' C_GRN='' C_YLW='' C_BLU='' C_CYN='' C_BLD='' C_DIM='' C_RST=''
fi

info() { printf '%s\n' "${C_CYN}[i]${C_RST} $*"; }
ok()   { printf '%s\n' "${C_GRN}[+]${C_RST} $*"; }
warn() { printf '%s\n' "${C_YLW}[!]${C_RST} $*" >&2; }
err()  { printf '%s\n' "${C_RED}[x]${C_RST} $*" >&2; }
die()  { err "$*"; exit 1; }

# Screen width follows the terminal, between 40 and 64 columns. Box-drawing
# characters are used only when the locale is UTF-8.
UI_W=60 UI_RULE="" UI_ARROW=">"
ui_refresh_width() {
    local c=${COLUMNS:-} ch='-' i
    [[ -n $c ]] || c=$(tput cols 2>/dev/null) || c=64
    [[ $c =~ ^[0-9]+$ ]] || c=64
    (( c > 64 )) && c=64
    (( c < 40 )) && c=40
    UI_W=$c
    UI_ARROW=">"
    if [[ ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} == *[Uu][Tt][Ff]* ]]; then ch='━'; UI_ARROW='›'; fi
    UI_RULE=""
    for (( i = 0; i < UI_W; i++ )); do UI_RULE+=$ch; done
}
ui_refresh_width

ui_line()   { printf '%s\n' "${C_BLU}${UI_RULE}${C_RST}"; }
# ui_center TEXT [COLOR] - centre plain TEXT in the screen width.
ui_center() {
    local pad=$(( (UI_W - ${#1}) / 2 ))
    (( pad < 0 )) && pad=0
    printf '%*s%s\n' "$pad" '' "${2:-}$1${2:+$C_RST}"
}
ui_title() { ui_line; ui_center "$*" "$C_YLW"; ui_line; }
ui_item()  { printf ' %s%s%s %s\n' "$C_GRN" "[$(printf '%2s' "$1")]" "$C_CYN$UI_ARROW$C_RST" "$2"; }
# ui_kv LABEL VALUE - aligned "label: value" line.
ui_kv()    { printf '  %s%-15s%s %s\n' "$C_CYN" "$1" "$C_RST" "$2"; }
ui_pause() { [[ -t 0 ]] || return 0; printf '\n'; read -r -s -n 1 -p "  Press any key to continue..." _ || true; printf '\n'; }

# ask VAR "Prompt" [default] - read a line into VAR.
ask() {
    local __var=$1 __prompt=$2 __def=${3:-} __ans
    if [[ -n $__def ]]; then
        read -r -p "  $__prompt [$__def]: " __ans || return 1
        __ans=${__ans:-$__def}
    else
        read -r -p "  $__prompt: " __ans || return 1
    fi
    printf -v "$__var" '%s' "$__ans"
}

# ask_secret VAR "Prompt" - read without echo.
ask_secret() {
    local __var=$1 __ans
    read -r -s -p "  $2: " __ans || return 1
    printf '\n'
    printf -v "$__var" '%s' "$__ans"
}

# confirm "Question" - returns 0 on yes.
confirm() {
    local ans
    read -r -p "  $1 [y/N]: " ans || return 1
    [[ $ans =~ ^[Yy]([Ee][Ss])?$ ]]
}

# --------------------------------------------------------------- logging ---
log_event() {
    { printf '%s  %s\n' "$(date '+%F %T')" "$*" >> "$VPSP_LOG"; } 2>/dev/null || true
}

# ------------------------------------------------------------ validation ---
# Usernames: lowercase letter or underscore first, 3-32 chars total.
valid_username() { [[ $1 =~ ^[a-z_][a-z0-9_-]{2,31}$ ]]; }

# Passwords: 4-64 printable characters, no whitespace or colons.
valid_password() {
    local p=$1
    (( ${#p} >= 4 && ${#p} <= 64 )) || return 1
    [[ $p =~ ^[[:graph:]]+$ ]] || return 1
    [[ $p != *:* ]]
}

# valid_int VALUE MIN MAX
valid_int() {
    [[ $1 =~ ^[0-9]+$ ]] || return 1
    (( 10#$1 >= $2 && 10#$1 <= $3 ))
}

valid_port() { valid_int "$1" 1 65535; }

# Hostnames / domains: labels of letters, digits and hyphens.
valid_domain() { [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }

require_root() {
    [[ $(id -u) -eq 0 ]] || die "This command must be run as root."
}

has_cmd() { command -v "$1" > /dev/null 2>&1; }

# gh_latest_tag OWNER/REPO - tag of the latest GitHub release. Follows the
# /releases/latest redirect first (no API rate limit), then tries the API.
gh_latest_tag() {
    local url tag
    url=$(curl -fsSIL --retry 3 --retry-delay 2 -o /dev/null -w '%{url_effective}' \
          "https://github.com/$1/releases/latest" 2>/dev/null)
    tag=${url##*/releases/tag/}
    tag=${tag//%2F//}
    if [[ -z $url || $tag == "$url" || -z $tag ]]; then
        tag=$(curl -fsSL --retry 3 --retry-delay 2 "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
              | jq -r '.tag_name // empty' 2>/dev/null)
    fi
    [[ -n $tag ]] && printf '%s\n' "$tag"
}

# The system user that runs proxy services, and a settings folder it can
# traverse (mode 711: no listing; each file keeps its own permissions).
svc_user_ensure() {
    getent passwd "$VPSP_SVC_USER" > /dev/null \
        || useradd --system --user-group --no-create-home --home-dir /nonexistent \
                   --shell /usr/sbin/nologin "$VPSP_SVC_USER" \
        || { err "Could not create the $VPSP_SVC_USER system user."; return 1; }
    mkdir -p "$VPSP_ETC" && chmod 711 "$VPSP_ETC"
}

# apt_install PKG... - install Debian packages quietly, only those missing.
apt_install() {
    local p missing=()
    for p in "$@"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' || missing+=("$p")
    done
    (( ${#missing[@]} )) || return 0
    info "Installing: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}" > /dev/null 2>&1 && return 0
    # The package lists may be stale on a fresh VPS; refresh once and retry.
    apt-get update -q > /dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}" > /dev/null 2>&1 \
        || { err "apt-get install ${missing[*]} failed."; return 1; }
}

# ------------------------------------------------------------------ time ---
# VPSP_NOW lets tests pin the clock.
now_epoch() { if [[ -n ${VPSP_NOW:-} ]]; then printf '%s\n' "$VPSP_NOW"; else date +%s; fi; }

# Expiry for an account valid N days: the end (23:59:59) of the Nth day from today.
expiry_from_days() {
    local base=${2:-$(now_epoch)}
    date -d "$(date -d "@$base" +%F) + $1 days 23:59:59" +%s
}

expiry_from_hours() { printf '%s\n' $(( $(now_epoch) + $1 * 3600 )); }

fmt_date() { date -d "@$1" '+%Y-%m-%d %H:%M'; }

# Whole days remaining (rounded up), 0 when expired.
days_left() {
    local diff=$(( $1 - $(now_epoch) ))
    (( diff <= 0 )) && { echo 0; return; }
    echo $(( (diff + 86399) / 86400 ))
}

# Date given to `chage -E`: the day after expiry, so the OS never locks an
# account earlier than the panel does. The guard service enforces the exact time.
chage_date() { date -d "@$(( $1 + 86400 ))" +%F; }
