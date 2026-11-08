# shellcheck shell=bash
# vpspanel - shared helpers: paths, config, UI, logging, validation.
# This file is sourced by the panel commands; it is never executed directly.

VPSP_VERSION="0.1.0"

# All paths can be overridden from the environment (used by the test suite).
VPSP_HOME="${VPSP_HOME:-/opt/vpspanel}"
VPSP_ETC="${VPSP_ETC:-/etc/vpspanel}"
VPSP_DB="${VPSP_DB:-$VPSP_ETC/accounts.db}"
VPSP_CONF="${VPSP_CONF:-$VPSP_ETC/panel.conf}"
VPSP_LOG="${VPSP_LOG:-/var/log/vpspanel.log}"
VPSP_GROUP="${VPSP_GROUP:-vpsusers}"
VPSP_SHELL="${VPSP_SHELL:-/bin/false}"

# ---------------------------------------------------------------- config ---
# Defaults; panel.conf (KEY=value lines) overrides them.
DEFAULT_LIMIT=1          # max simultaneous logins for new accounts (0 = unlimited)
DEFAULT_DAYS=30          # default validity for new accounts
AUTO_DELETE_DAYS=0       # delete accounts N days after expiry (0 = never)
BANNER_TEXT=""           # SSH login banner shown to clients

readonly VPSP_CONF_KEYS="DEFAULT_LIMIT DEFAULT_DAYS AUTO_DELETE_DAYS BANNER_TEXT"

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
    C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YLW=$'\e[33m' C_BLU=$'\e[34m'
    C_CYN=$'\e[36m' C_BLD=$'\e[1m' C_DIM=$'\e[2m' C_RST=$'\e[0m'
else
    C_RED='' C_GRN='' C_YLW='' C_BLU='' C_CYN='' C_BLD='' C_DIM='' C_RST=''
fi

info() { printf '%s\n' "${C_CYN}[i]${C_RST} $*"; }
ok()   { printf '%s\n' "${C_GRN}[+]${C_RST} $*"; }
warn() { printf '%s\n' "${C_YLW}[!]${C_RST} $*" >&2; }
err()  { printf '%s\n' "${C_RED}[x]${C_RST} $*" >&2; }
die()  { err "$*"; exit 1; }

ui_line()  { printf '%s\n' "${C_BLU}$(printf '%*s' 56 '' | tr ' ' '-')${C_RST}"; }
ui_title() { ui_line; printf '  %s\n' "${C_BLD}$*${C_RST}"; ui_line; }
ui_item()  { printf '  %s %s\n' "${C_GRN}[$1]${C_RST}" "$2"; }
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

require_root() {
    [[ $(id -u) -eq 0 ]] || die "This command must be run as root."
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
