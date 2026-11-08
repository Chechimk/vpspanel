# shellcheck shell=bash
# vpspanel module: blocking rules (torrent, spam ports, keywords), UFW helpers,
# Fail2ban and speedtest.
#
# Blocking rules live in their own iptables chain, VPSPANEL-BLOCK, reached only
# from traffic of panel accounts (OUTPUT, owner = vpsusers group or the
# vpspanel-svc user that runs Xray/Hysteria2) and from forwarded WireGuard traffic.
# Existing firewall rules are never modified.

FWB_DIR="$VPSP_ETC/firewall"
FWB_CHAIN=VPSPANEL-BLOCK
FWB_UNIT=/etc/systemd/system/vpspanel-firewall.service
FWB_DEFAULT_KEYWORDS=("BitTorrent protocol" "peer_id=" "info_hash" "announce.php?passkey=" "get_peers" "announce_peer" "find_node")
FWB_DEFAULT_PORTS="25,465,587"

fwb_on() { [[ -f $FWB_DIR/$1.on ]]; }

fwb_init() {
    svc_user_ensure
    mkdir -p "$FWB_DIR"
    [[ -f $FWB_DIR/keywords ]] || printf '%s\n' "${FWB_DEFAULT_KEYWORDS[@]}" > "$FWB_DIR/keywords"
    [[ -f $FWB_DIR/ports ]] || echo "$FWB_DEFAULT_PORTS" > "$FWB_DIR/ports"
}

fwb_jumps() {
    printf '%s\n' "OUTPUT -m owner --gid-owner $VPSP_GROUP -j $FWB_CHAIN" \
                  "OUTPUT -m owner --uid-owner $VPSP_SVC_USER -j $FWB_CHAIN" \
                  "FORWARD -j $FWB_CHAIN"
}

# Rebuild the chain from the saved settings (also run at boot).
fwb_apply() {
    has_cmd iptables || return 0
    fwb_init
    local chain rest kw ports
    iptables -N "$FWB_CHAIN" 2>/dev/null || iptables -F "$FWB_CHAIN"
    if fwb_on torrent; then
        while IFS= read -r kw; do
            [[ -n $kw ]] || continue
            iptables -A "$FWB_CHAIN" -m string --string "$kw" --algo bm -j DROP \
                || warn "Could not add keyword rule: $kw"
        done < "$FWB_DIR/keywords"
    fi
    if fwb_on ports; then
        ports=$(tr -d ' \n' < "$FWB_DIR/ports")
        if [[ -n $ports ]]; then
            iptables -A "$FWB_CHAIN" -p tcp -m multiport --dports "$ports" -j DROP
            iptables -A "$FWB_CHAIN" -p udp -m multiport --dports "$ports" -j DROP
        fi
    fi
    if fwb_on torrent || fwb_on ports; then
        while read -r chain rest; do
            # shellcheck disable=SC2086
            iptables -C "$chain" $rest 2>/dev/null || iptables -I "$chain" 1 $rest
        done < <(fwb_jumps)
    else
        fwb_remove
    fi
}

fwb_remove() {
    has_cmd iptables || return 0
    local chain rest
    while read -r chain rest; do
        # shellcheck disable=SC2086
        while iptables -C "$chain" $rest 2>/dev/null; do iptables -D "$chain" $rest; done
    done < <(fwb_jumps)
    iptables -F "$FWB_CHAIN" 2>/dev/null
    iptables -X "$FWB_CHAIN" 2>/dev/null
    return 0
}

fwb_persist() {
    if fwb_on torrent || fwb_on ports; then
        cat > "$FWB_UNIT" <<UNIT
[Unit]
Description=vpspanel blocking rules
After=network-pre.target ufw.service netfilter-persistent.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$VPSP_HOME/bin/vpspanel firewall-apply

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable vpspanel-firewall > /dev/null 2>&1
    elif [[ -f $FWB_UNIT ]]; then
        systemctl disable vpspanel-firewall > /dev/null 2>&1
        rm -f "$FWB_UNIT"
        systemctl daemon-reload
    fi
}

fwb_toggle() {
    has_cmd iptables || apt_install iptables || return 1
    fwb_init
    if fwb_on "$1"; then rm -f "$FWB_DIR/$1.on"; else touch "$FWB_DIR/$1.on"; fi
    fwb_apply && fwb_persist
    log_event "firewall $1 $(fwb_on "$1" && echo on || echo off)"
    ok "$2 blocking is now $(fwb_on "$1" && echo ON || echo OFF)."
}

# ------------------------------------------------------------------ menu ---
fwb_info() {
    ui_kv "Torrent/keywords:" "$(fwb_on torrent && echo "${C_GRN}blocked${C_RST}" || echo "allowed")"
    ui_kv "Spam ports:" "$(fwb_on ports && echo "${C_GRN}blocked${C_RST} ($(cat "$FWB_DIR/ports"))" || echo "allowed")"
    if has_cmd ufw; then ui_kv "UFW:" "$(ufw status 2>/dev/null | head -n1 | sed 's/Status: //')"; fi
}

m_fwb_view() {
    if iptables -S "$FWB_CHAIN" > /dev/null 2>&1; then
        iptables -S "$FWB_CHAIN"
        printf '\n'
        iptables -S OUTPUT | grep -F "$FWB_CHAIN"
        iptables -S FORWARD | grep -F "$FWB_CHAIN"
    else
        info "No blocking rules are active."
    fi
}

m_fwb_keywords() {
    fwb_init
    "${EDITOR:-nano}" "$FWB_DIR/keywords"
    fwb_apply && ok "Keyword list saved."
}

m_fwb_ports() {
    local p
    fwb_init
    ask p "Blocked destination ports, comma-separated" "$(cat "$FWB_DIR/ports")" || return
    [[ $p =~ ^[0-9]{1,5}(,[0-9]{1,5}){0,14}$ ]] || { err "Use up to 15 ports, like 25,465,587."; return 1; }
    echo "$p" > "$FWB_DIR/ports"
    fwb_apply && ok "Port list saved."
}

m_ufw_status() {
    has_cmd ufw || { info "UFW is not installed."; return 0; }
    ufw status verbose
}

m_ufw_allow() {
    local p proto
    has_cmd ufw || { info "UFW is not installed."; return 0; }
    ask p "Port to allow" || return
    valid_port "$p" || { err "Invalid port."; return 1; }
    ask proto "Protocol (tcp/udp)" tcp || return
    [[ $proto == tcp || $proto == udp ]] || { err "Enter tcp or udp."; return 1; }
    ufw allow "$p/$proto" && ok "UFW allows $p/$proto."
}

firewall_menu() {
    while menu_show "BLOCK TORRENT, PORTS & KEYWORDS" fwb_info \
        "Block torrent & keywords (on/off)|fwb_toggle torrent Torrent/keyword" \
        "Block spam ports (on/off)|fwb_toggle ports Spam-port" \
        "Edit blocked keyword list (nano)|m_fwb_keywords" \
        "Edit blocked port list|m_fwb_ports" \
        "View active blocking rules|m_fwb_view" \
        "UFW status|m_ufw_status" \
        "UFW: allow a port|m_ufw_allow"
    do :; done
}

# --------------------------------------------------------------- fail2ban ---
F2B_JAIL=/etc/fail2ban/jail.d/vpspanel.local

f2b_installed() { has_cmd fail2ban-client && [[ -f $F2B_JAIL ]]; }
f2b_get() { awk -F' *= *' -v k="$1" '$1 == k { print $2; exit }' "$F2B_JAIL" 2>/dev/null; }

f2b_write() {
    local bantime=$1 findtime=$2 maxretry=$3 admin
    admin=${SSH_CLIENT%% *}
    mkdir -p "$(dirname "$F2B_JAIL")"
    cat > "$F2B_JAIL" <<JAIL
# Managed by vpspanel
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 ${admin}
bantime = $bantime
findtime = $findtime
maxretry = $maxretry

[sshd]
enabled = true
port = $(ssh_ports)
backend = systemd
JAIL
}

f2b_install() {
    apt_install fail2ban python3-systemd || return 1
    f2b_write 1h 10m 5
    systemctl enable fail2ban > /dev/null 2>&1
    systemctl restart fail2ban || { err "Fail2ban failed to start. See: journalctl -u fail2ban"; return 1; }
    log_event "fail2ban installed"
    ok "Fail2ban protects SSH: 5 failed logins in 10 minutes = 1 hour ban."
    [[ -n ${SSH_CLIENT:-} ]] && info "Your address ${SSH_CLIENT%% *} is never banned."
}

f2b_uninstall() {
    systemctl disable --now fail2ban > /dev/null 2>&1 || true
    rm -f "$F2B_JAIL"
    DEBIAN_FRONTEND=noninteractive apt-get remove -y -q fail2ban > /dev/null 2>&1 || true
    log_event "fail2ban removed"
    ok "Fail2ban removed."
}

f2b_info() {
    ui_kv "Status:" "$(fmt_state "$(svc_state fail2ban)")"
    if f2b_installed; then
        ui_kv "Ban time:" "$(f2b_get bantime)"
        ui_kv "Find period:" "$(f2b_get findtime)"
        ui_kv "Max attempts:" "$(f2b_get maxretry)"
        ui_kv "Banned now:" "$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/ {gsub(/[ \t]/, "", $2); print $2}')"
    fi
}

m_f2b_set() {
    local key=$1 v b f m
    b=$(f2b_get bantime); f=$(f2b_get findtime); m=$(f2b_get maxretry)
    case $key in
        bantime)  ask v "Ban time (e.g. 30m, 1h, 1d)" "$b" || return; [[ $v =~ ^[0-9]+[smhdw]?$ ]] || { err "Invalid time."; return 1; }; b=$v ;;
        findtime) ask v "Find period (e.g. 10m)" "$f" || return; [[ $v =~ ^[0-9]+[smhdw]?$ ]] || { err "Invalid time."; return 1; }; f=$v ;;
        maxretry) ask v "Failed attempts before a ban" "$m" || return; valid_int "$v" 1 100 || { err "Enter 1-100."; return 1; }; m=$v ;;
    esac
    f2b_write "$b" "$f" "$m"
    systemctl restart fail2ban && ok "Saved."
}

m_f2b_edit()   { "${EDITOR:-nano}" "$F2B_JAIL"; systemctl restart fail2ban && ok "Fail2ban restarted."; }
m_f2b_unban()  { local ip; ask ip "IP address to unban" && fail2ban-client set sshd unbanip "$ip"; }
m_f2b_status() { fail2ban-client status sshd; }
m_f2b_uninstall() { confirm "Uninstall Fail2ban?" && f2b_uninstall; }

fail2ban_menu() {
    local -a items
    while true; do
        if f2b_installed; then
            items=("Change ban time|m_f2b_set bantime"
                   "Change find period|m_f2b_set findtime"
                   "Change number of attempts|m_f2b_set maxretry"
                   "Edit settings (nano)|m_f2b_edit"
                   "Banned addresses|m_f2b_status"
                   "Unban an address|m_f2b_unban"
                   "Start / stop service|toggle_service fail2ban"
                   "Fail2ban log|tail -n 40 /var/log/fail2ban.log"
                   "Uninstall Fail2ban|m_f2b_uninstall")
        else
            items=("Install Fail2ban|f2b_install")
        fi
        menu_show "FAIL2BAN MANAGER" f2b_info "${items[@]}" || return 0
    done
}

# --------------------------------------------------------------- speedtest ---
run_speedtest() {
    has_cmd speedtest-cli || apt_install speedtest-cli || return 1
    info "Testing with the nearest server. This takes about 30 seconds..."
    speedtest-cli --simple --secure || err "The speed test failed."
}
