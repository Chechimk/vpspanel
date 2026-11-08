# shellcheck shell=bash
# vpspanel - host information, SSH server settings and system tools.

SSHD_CONFIG=${SSHD_CONFIG:-/etc/ssh/sshd_config}
SSHD_DIR=${SSHD_DIR:-/etc/ssh/sshd_config.d}
SSHD_DROPIN=$SSHD_DIR/vpspanel.conf              # banner
SSHD_PORTS_DROPIN=$SSHD_DIR/vpspanel-ports.conf  # ports chosen in the panel
SSHD_ROOT_DROPIN=$SSHD_DIR/00-vpspanel-root.conf # PermitRootLogin
BANNER_FILE="$VPSP_ETC/banner.txt"

# ------------------------------------------------------------ host facts ---
sys_os()     { ( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}" ); }
sys_kernel() { uname -r; }
sys_cores()  { nproc 2>/dev/null || echo "?"; }
sys_load()   { cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "?"; }
sys_uptime() { uptime -p 2>/dev/null | sed 's/^up //' || echo "?"; }
sys_hostname() { hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "?"; }

# Primary IPv4 address used for outbound traffic (no external lookup).
sys_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
    echo "${ip:-unknown}"
}

# Default network interface (used for NAT rules).
sys_iface() { ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'; }

# meminfo KEY -> value in MB
meminfo_mb() { awk -v k="$1:" '$1 == k { printf "%d\n", $2 / 1024 }' /proc/meminfo 2>/dev/null; }

# "used/total MB (pct%)"
sys_ram() {
    free -m 2>/dev/null | awk '/^Mem:/ { printf "%d/%d MB (%d%%)\n", $3, $2, ($2 ? $3*100/$2 : 0) }'
}

sys_swap() {
    free -m 2>/dev/null | awk '/^Swap:/ { if ($2 == 0) print "none"; else printf "%d/%d MB (%d%%)\n", $3, $2, $3*100/$2 }'
}

sys_disk() { df -h / 2>/dev/null | awk 'NR==2 { print $3 "/" $2 " (" $5 ")" }'; }

# CPU usage in percent, sampled over a short interval.
sys_cpu_pct() {
    local a b
    read -r -a a < <(head -n1 /proc/stat 2>/dev/null) || { echo "?"; return; }
    sleep 0.3
    read -r -a b < <(head -n1 /proc/stat 2>/dev/null) || { echo "?"; return; }
    local idle=$(( (b[4] + b[5]) - (a[4] + a[5]) ))
    local total=0 i
    for i in 1 2 3 4 5 6 7 8; do total=$(( total + b[i] - a[i] )); done
    (( total > 0 )) || { echo 0; return; }
    echo $(( (100 * (total - idle)) / total ))
}

has_systemd() { [[ -d /run/systemd/system ]]; }

# svc_state UNIT -> active | inactive | failed | not installed | no systemd
svc_state() {
    if ! has_systemd; then echo "no systemd"; return; fi
    local unit=$1
    [[ $unit == *.* ]] || unit+=.service
    if [[ $unit != *@* ]] && ! systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q .; then
        echo "not installed"; return
    fi
    systemctl is-active "$unit" 2>/dev/null || true
}

# Listening TCP/UDP ports of processes whose name matches REGEX, comma-separated.
listen_ports() {
    local re=$1 proto=${2:-t}
    ss -"${proto}"lnpH 2>/dev/null | awk -v re="$re" '
        $0 ~ "\"(" re ")\"" { n = split($4, a, ":"); print a[n] }' | sort -un | paste -sd, -
}

port_in_use() { [[ -n $(ss -ltnH "( sport = :$1 )" 2>/dev/null) ]]; }
udp_port_in_use() { [[ -n $(ss -lunH "( sport = :$1 )" 2>/dev/null) ]]; }

# Open a port in UFW when UFW is active. Never enables UFW by itself.
fw_allow() {
    local port=$1 proto=${2:-tcp}
    if has_cmd ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow "$port/$proto" > /dev/null && info "UFW: allowed $port/$proto."
    fi
}

# ask_port VAR "Prompt" DEFAULT [udp] - ask until a free, valid port is given.
ask_port() {
    local __v=$1 __p
    while true; do
        ask __p "$2" "${3:-}" || return 1
        valid_port "$__p" || { err "Enter a port between 1 and 65535."; continue; }
        if [[ ${4:-} == udp ]]; then
            udp_port_in_use "$__p" && { err "UDP port $__p is already in use."; continue; }
        else
            port_in_use "$__p" && { err "Port $__p is already in use."; continue; }
        fi
        printf -v "$__v" '%s' "$__p"
        return 0
    done
}

# ask_target_port VAR - local port that a proxy forwards traffic to.
ask_target_port() {
    local __v=$1 __p __def
    __def=$(ssh_ports | cut -d, -f1)
    printf '  Local services: SSH %s' "${__def:-22}"
    declare -F dropbear_installed > /dev/null && dropbear_installed && printf ', Dropbear %s' "$(dropbear_port)"
    printf '\n'
    ask __p "Forward traffic to local port" "${__def:-22}" || return 1
    valid_port "$__p" || { err "Invalid port."; return 1; }
    printf -v "$__v" '%s' "$__p"
}

# ------------------------------------------------------------- OpenSSH ---
ssh_unit() {
    if systemctl list-unit-files ssh.service --no-legend 2>/dev/null | grep -q .; then echo ssh; else echo sshd; fi
}

ssh_ports() {
    local p
    p=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -un | paste -sd, -)
    echo "${p:-22}"
}

# Port of the SSH connection this panel runs in (empty when local).
ssh_session_port() { [[ -n ${SSH_CONNECTION:-} ]] && echo "${SSH_CONNECTION##* }"; }

ssh_include_ok() { grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_CONFIG"; }

ssh_backup_config() {
    local dir=$VPSP_ETC/backup
    mkdir -p "$dir" && chmod 700 "$dir"
    cp -p "$SSHD_CONFIG" "$dir/sshd_config.$(date +%Y%m%d-%H%M%S)"
}

# Apply new sshd settings without dropping open sessions.
ssh_apply() {
    if ! sshd -t 2>/dev/null; then return 1; fi
    has_systemd || return 0
    local unit; unit=$(ssh_unit)
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        systemctl daemon-reload
        systemctl restart ssh.socket
    fi
    systemctl reload-or-restart "$unit" 2>/dev/null || systemctl restart "$unit"
}

# ssh_set_ports PORT... - replace the OpenSSH listening ports.
ssh_set_ports() {
    local -a ports=() seen=()
    local p cur sock_dropin=/etc/systemd/system/ssh.socket.d/vpspanel-ports.conf
    for p in "$@"; do
        valid_port "$p" || { err "Invalid port: $p"; return 1; }
        [[ " ${seen[*]} " == *" $p "* ]] && continue
        seen+=("$p"); ports+=("$p")
    done
    (( ${#ports[@]} >= 1 && ${#ports[@]} <= 5 )) || { err "Give between 1 and 5 ports."; return 1; }
    cur=$(ssh_session_port)
    if [[ -n $cur && " ${ports[*]} " != *" $cur "* ]]; then
        err "You are connected through port $cur. Keep it in the list so this session stays reachable."
        return 1
    fi
    for p in "${ports[@]}"; do
        if port_in_use "$p" && [[ ",$(ssh_ports)," != *",$p,"* ]]; then
            err "Port $p is used by another program."; return 1
        fi
    done
    ssh_include_ok || { err "$SSHD_CONFIG does not include $SSHD_DIR/*.conf; edit the ports there manually."; return 1; }

    ssh_backup_config
    local backup_main; backup_main=$(mktemp)
    cp -p "$SSHD_CONFIG" "$backup_main"
    sed -i -E 's/^([[:space:]]*Port[[:space:]])/#vpspanel# \1/I' "$SSHD_CONFIG"
    mkdir -p "$SSHD_DIR"
    { echo "# Managed by vpspanel"; for p in "${ports[@]}"; do echo "Port $p"; done; } > "$SSHD_PORTS_DROPIN"

    # Ubuntu 22.10/23.x socket activation without the sshd-socket-generator.
    if systemctl is-active --quiet ssh.socket 2>/dev/null \
       && [[ ! -x /usr/lib/systemd/system-generators/sshd-socket-generator ]]; then
        mkdir -p "$(dirname "$sock_dropin")"
        { echo "[Socket]"; echo "ListenStream="; for p in "${ports[@]}"; do echo "ListenStream=$p"; done; } > "$sock_dropin"
    fi

    for p in "${ports[@]}"; do fw_allow "$p"; done
    if ! ssh_apply; then
        cp -p "$backup_main" "$SSHD_CONFIG"; rm -f "$SSHD_PORTS_DROPIN" "$sock_dropin" "$backup_main"
        has_systemd && systemctl daemon-reload
        err "OpenSSH rejected the configuration; nothing was changed."
        return 1
    fi
    rm -f "$backup_main"
    sleep 1
    log_event "ssh ports ${ports[*]}"
    ok "OpenSSH ports: $(ssh_ports)"
}

# The managed block at the end of sshd_config. Match blocks must come last,
# so they live here rather than in a drop-in file.
SSH_BLOCK_BEGIN="# >>> vpspanel managed block (do not edit) >>>"
SSH_BLOCK_END="# <<< vpspanel managed block <<<"

ssh_write_block() {
    local root_pw=0 tmp
    [[ -f $VPSP_ETC/ssh-root-password ]] && root_pw=1
    tmp=$(mktemp) || return 1
    cp -p "$SSHD_CONFIG" "$tmp"
    sed -i "/^$SSH_BLOCK_BEGIN\$/,/^$SSH_BLOCK_END\$/d" "$SSHD_CONFIG"
    {
        echo "$SSH_BLOCK_BEGIN"
        echo "# Panel accounts: password login for tunnels only, no shell access."
        echo "Match Group $VPSP_GROUP"
        echo "    PasswordAuthentication yes"
        echo "    AllowTcpForwarding yes"
        echo "    X11Forwarding no"
        echo "    AllowAgentForwarding no"
        echo "    PermitTunnel no"
        if (( root_pw )); then
            echo "Match User root"
            echo "    PasswordAuthentication yes"
        fi
        echo "Match all"
        echo "$SSH_BLOCK_END"
    } >> "$SSHD_CONFIG"
    if ! ssh_apply; then
        cp -p "$tmp" "$SSHD_CONFIG"; rm -f "$tmp"
        err "OpenSSH rejected the panel account settings; change reverted."
        return 1
    fi
    rm -f "$tmp"
}

ssh_remove_block() {
    sed -i "/^$SSH_BLOCK_BEGIN\$/,/^$SSH_BLOCK_END\$/d" "$SSHD_CONFIG"
    ssh_apply || true
}

# Effective value of an sshd setting for a given user.
ssh_effective() {
    sshd -T -C "user=$1,host=localhost,addr=127.0.0.1" 2>/dev/null | awk -v k="$2" '$1 == k { print $2 }'
}

root_login_status() {
    printf '%s (password login: %s)' "$(ssh_effective root permitrootlogin)" "$(ssh_effective root passwordauthentication)"
}

root_set_password() {
    info "Type the new root password twice. It is passed straight to passwd."
    passwd root && log_event "root password changed"
}

root_allow_password() {
    warn "Anyone who knows the root password will be able to log in over SSH."
    confirm "Allow root login with a password?" || return 0
    printf '# Managed by vpspanel\nPermitRootLogin yes\n' > "$SSHD_ROOT_DROPIN"
    touch "$VPSP_ETC/ssh-root-password"
    if ssh_write_block; then
        log_event "root password login enabled"; ok "Root can now log in with a password."
    else
        rm -f "$SSHD_ROOT_DROPIN" "$VPSP_ETC/ssh-root-password"; ssh_apply || true
    fi
}

root_keys_only() {
    if [[ ! -s /root/.ssh/authorized_keys ]]; then
        err "/root/.ssh/authorized_keys is empty. Add an SSH key first or you could lose root access."
        return 1
    fi
    confirm "Allow root login with SSH keys only?" || return 0
    printf '# Managed by vpspanel\nPermitRootLogin prohibit-password\n' > "$SSHD_ROOT_DROPIN"
    rm -f "$VPSP_ETC/ssh-root-password"
    if ssh_write_block; then
        log_event "root login keys only"; ok "Root login now requires an SSH key. Open sessions stay connected."
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
    sysctl --system > /dev/null 2>&1
    log_event "bbr enabled"
}

bbr_disable() {
    rm -f /etc/sysctl.d/99-vpspanel-bbr.conf
    sysctl -w net.ipv4.tcp_congestion_control=cubic > /dev/null
    sysctl --system > /dev/null 2>&1
    log_event "bbr disabled"
}

# ---------------------------------------------------------------- timezone ---
tz_current() { timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "?"; }

tz_set() {
    [[ $1 =~ ^[A-Za-z0-9_+/-]+$ && $1 != *..* && -f /usr/share/zoneinfo/$1 ]] || { err "Unknown timezone: $1"; return 1; }
    if has_systemd && timedatectl set-timezone "$1" 2>/dev/null; then :; else
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
        if [[ -d $SSHD_DIR ]]; then
            [[ -f $SSHD_DROPIN ]] && backup=$(cat "$SSHD_DROPIN")
            printf '# Managed by vpspanel\nBanner %s\n' "$BANNER_FILE" > "$SSHD_DROPIN"
            if has_cmd sshd && ! sshd -t 2>/dev/null; then
                if [[ -n $backup ]]; then printf '%s\n' "$backup" > "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
                err "OpenSSH rejected the new configuration; change reverted."
                return 1
            fi
        fi
    fi
    if has_systemd; then
        systemctl reload "$(ssh_unit)" 2>/dev/null || true
        systemctl is-active --quiet vpspanel-dropbear && systemctl restart vpspanel-dropbear
    fi
    set_config BANNER_TEXT "$text"
    log_event "banner updated"
}

# ------------------------------------------------------- maintenance ---
clean_ram() {
    sync
    if echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; then
        ok "Page cache released. Free RAM: $(meminfo_mb MemAvailable) MB available."
    else
        err "The kernel refused to drop caches (this is normal inside containers)."
    fi
}

clean_disk() {
    local before after
    before=$(df -m / | awk 'NR==2 {print $4}')
    apt-get clean -q 2>/dev/null
    apt-get autoremove -y -q > /dev/null 2>&1 || true
    has_cmd journalctl && journalctl --vacuum-time=7d > /dev/null 2>&1
    find /tmp /var/tmp -xdev -type f -atime +7 -delete 2>/dev/null || true
    after=$(df -m / | awk 'NR==2 {print $4}')
    ok "Disk cleaned: $(( after - before )) MB freed, $(df -h / | awk 'NR==2 {print $4}') available."
    log_event "disk cleanup"
}

SWAPFILE=/swapfile-vpspanel

swap_create() {
    local mb
    swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE" && { err "The panel swap file already exists."; return 1; }
    ask mb "Swap size in MB" "1024" || return
    valid_int "$mb" 128 16384 || { err "Enter 128-16384."; return 1; }
    (( $(df -m / | awk 'NR==2 {print $4}') > mb + 512 )) || { err "Not enough free disk space."; return 1; }
    fallocate -l "${mb}M" "$SWAPFILE" 2>/dev/null || dd if=/dev/zero of="$SWAPFILE" bs=1M count="$mb" status=none
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" > /dev/null && swapon "$SWAPFILE" || { rm -f "$SWAPFILE"; err "Could not enable swap here."; return 1; }
    grep -q "^$SWAPFILE " /etc/fstab || echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
    log_event "swap ${mb}MB created"
    ok "Swap enabled: $(sys_swap)"
}

swap_remove() {
    [[ -f $SWAPFILE ]] || { err "There is no panel swap file."; return 1; }
    confirm "Remove the ${SWAPFILE} swap file?" || return 0
    swapoff "$SWAPFILE" 2>/dev/null
    sed -i "\#^$SWAPFILE #d" /etc/fstab
    rm -f "$SWAPFILE"
    log_event "swap removed"
    ok "Swap file removed."
}

# ------------------------------------------------------------ auto-start ---
AUTOSTART_LINE='[[ -n ${SSH_TTY:-} && ${SHLVL:-1} -eq 1 && -x /usr/local/bin/menu ]] && /usr/local/bin/menu # vpspanel-autostart'

autostart_enabled() { grep -q 'vpspanel-autostart' /root/.bashrc 2>/dev/null; }

autostart_toggle() {
    if autostart_enabled; then
        sed -i '/vpspanel-autostart/d' /root/.bashrc
        ok "The panel no longer opens at login."
    else
        printf '%s\n' "$AUTOSTART_LINE" >> /root/.bashrc
        ok "The panel will open automatically when root logs in over SSH."
    fi
}
