# shellcheck shell=bash
# vpspanel - host information and system tools.

SSHD_DROPIN=/etc/ssh/sshd_config.d/vpspanel.conf
BANNER_FILE="$VPSP_ETC/banner.txt"

sys_os()     { . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}"; }
sys_kernel() { uname -r; }
sys_cores()  { nproc 2>/dev/null || echo "?"; }
sys_load()   { cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "?"; }
sys_uptime() { uptime -p 2>/dev/null | sed 's/^up //' || echo "?"; }

# Primary IPv4 address used for outbound traffic (no external lookup).
sys_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
    echo "${ip:-unknown}"
}

# "used/total MB (pct%)"
sys_ram() {
    free -m 2>/dev/null | awk '/^Mem:/ { printf "%d/%d MB (%d%%)\n", $3, $2, ($2 ? $3*100/$2 : 0) }'
}

sys_disk() { df -h / 2>/dev/null | awk 'NR==2 { print $3 "/" $2 " (" $5 ")" }'; }

has_systemd() { [[ -d /run/systemd/system ]]; }

# svc_state UNIT -> active | inactive | not installed
svc_state() {
    if ! has_systemd; then echo "no systemd"; return; fi
    if ! systemctl list-unit-files "$1.service" --no-legend 2>/dev/null | grep -q .; then
        echo "not installed"; return
    fi
    systemctl is-active "$1" 2>/dev/null || true
}

# Services the panel knows about: "unit|label"
VPSP_SERVICES=(
    "ssh|OpenSSH"
    "vpspanel-dropbear|Dropbear"
    "xray|Xray"
    "wg-quick@wg0|WireGuard"
    "openvpn-server@server|OpenVPN"
    "hysteria-server|Hysteria2"
    "vpspanel-guard.timer|Account guard"
)

svc_state_any() {
    # Timers and templated units need the full name.
    if [[ $1 == *.timer ]]; then
        has_systemd || { echo "no systemd"; return; }
        systemctl is-active "$1" 2>/dev/null || true
    else
        svc_state "$1"
    fi
}

# --------------------------------------------------------------------- BBR ---
bbr_enabled() { [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr ]]; }

bbr_enable() {
    modprobe tcp_bbr 2>/dev/null || true
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null \
        || { err "This kernel does not support BBR."; return 1; }
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' \
        > /etc/sysctl.d/99-vpspanel-bbr.conf
    sysctl --system > /dev/null
    log_event "bbr enabled"
}

bbr_disable() {
    rm -f /etc/sysctl.d/99-vpspanel-bbr.conf
    sysctl -w net.ipv4.tcp_congestion_control=cubic > /dev/null
    sysctl --system > /dev/null
    log_event "bbr disabled"
}

# ---------------------------------------------------------------- timezone ---
tz_current() { timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "?"; }

tz_set() {
    [[ -f /usr/share/zoneinfo/$1 && $1 != */../* ]] || { err "Unknown timezone: $1"; return 1; }
    if has_systemd; then
        timedatectl set-timezone "$1"
    else
        ln -sf "/usr/share/zoneinfo/$1" /etc/localtime && echo "$1" > /etc/timezone
    fi
    log_event "timezone $1"
}

# ------------------------------------------------------------- SSH banner ---
# Writes the banner file and points OpenSSH (and Dropbear) at it.
banner_apply() {
    local text=$1 backup=""
    mkdir -p "$VPSP_ETC"
    if [[ -z $text ]]; then
        rm -f "$BANNER_FILE" "$SSHD_DROPIN"
    else
        printf '%b\n' "$text" > "$BANNER_FILE"
        if [[ -d /etc/ssh/sshd_config.d ]]; then
            [[ -f $SSHD_DROPIN ]] && backup=$(cat "$SSHD_DROPIN")
            printf '# Managed by vpspanel\nBanner %s\n' "$BANNER_FILE" > "$SSHD_DROPIN"
            if command -v sshd > /dev/null && ! sshd -t 2>/dev/null; then
                if [[ -n $backup ]]; then printf '%s\n' "$backup" > "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
                err "OpenSSH rejected the new configuration; change reverted."
                return 1
            fi
        fi
    fi
    if has_systemd; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        systemctl is-active --quiet vpspanel-dropbear && systemctl restart vpspanel-dropbear
    fi
    set_config BANNER_TEXT "$text"
    log_event "banner updated"
}
