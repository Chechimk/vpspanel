# shellcheck shell=bash
# vpspanel module: DDoS protection (connection-rate limiting per source IP).
# Same settings as ADMRufu's DDoS manager - ports to watch, maximum attempts,
# block time in minutes, IP whitelist - implemented with iptables:
# a source opening more than MAX new TCP connections per minute to a watched
# port is dropped for BLOCK minutes. Rules live in their own chain and are
# applied by vpspanel-ddos.service at boot.

DDOS_CONF="$VPSP_ETC/ddos.conf"      # PORTS MAX BLOCK WHITELIST
DDOS_CHAIN=VPSPANEL-DDOS
DDOS_UNIT=/etc/systemd/system/vpspanel-ddos.service

ddos_installed() { [[ -f $DDOS_CONF && -f $DDOS_UNIT ]]; }
ddos_get() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print }' "$DDOS_CONF" 2>/dev/null; }

ddos_remove_rules() {
    while iptables -D INPUT -p tcp -j "$DDOS_CHAIN" 2>/dev/null; do :; done
    iptables -F "$DDOS_CHAIN" 2>/dev/null
    iptables -X "$DDOS_CHAIN" 2>/dev/null
    return 0
}

# ddos_apply - (re)build the chain from ddos.conf.
ddos_apply() {
    local ports max block ip p
    ports=$(ddos_get PORTS); max=$(ddos_get MAX); block=$(ddos_get BLOCK)
    ddos_remove_rules
    [[ -n $ports ]] || return 0
    iptables -N "$DDOS_CHAIN" || return 1
    for ip in $(ddos_get WHITELIST | tr "," " "); do
        iptables -A "$DDOS_CHAIN" -s "$ip" -j RETURN
    done
    iptables -A "$DDOS_CHAIN" -m recent --name vpsp_ddos_ban --rcheck --seconds $(( block * 60 )) -j DROP
    for p in $ports; do
        iptables -A "$DDOS_CHAIN" -p tcp --dport "$p" --syn \
            -m hashlimit --hashlimit-name "vpsp_ddos_$p" --hashlimit-mode srcip \
            --hashlimit-above "$max/minute" --hashlimit-burst "$max" \
            -m recent --name vpsp_ddos_ban --set -j DROP
    done
    iptables -I INPUT -p tcp -j "$DDOS_CHAIN"
}

ddos_install() {
    local ports=$1 max=$2 block=$3 white=$4 p ip
    for p in $ports; do valid_port "$p" || { err "Invalid port: $p"; return 1; }; done
    valid_int "$max" 2 10000 || { err "Maximum attempts must be 2-10000."; return 1; }
    valid_int "$block" 1 10080 || { err "Block time must be 1-10080 minutes."; return 1; }
    for ip in ${white//,/ }; do
        [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] || { err "Invalid whitelist entry: $ip"; return 1; }
    done
    run_step "apt install iptables" apt_install iptables || return 1
    printf 'PORTS=%s\nMAX=%s\nBLOCK=%s\nWHITELIST=%s\n' "$ports" "$max" "$block" "$white" > "$DDOS_CONF"
    chmod 600 "$DDOS_CONF"
    cat > "$DDOS_UNIT" <<UNIT
[Unit]
Description=vpspanel DDoS protection rules
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$VPSP_HOME/bin/vpspanel ddos-apply
ExecStop=$VPSP_HOME/bin/vpspanel ddos-remove

[Install]
WantedBy=multi-user.target
UNIT
    run_step "systemctl daemon-reload" systemctl daemon-reload
    run_step "systemctl start ddos" systemctl enable --now vpspanel-ddos || return 1
    systemctl restart vpspanel-ddos > /dev/null 2>&1
    log_event "ddos protection ports=$ports max=$max block=$block"
}

ddos_uninstall() {
    systemctl disable --now vpspanel-ddos > /dev/null 2>&1 || true
    ddos_remove_rules
    rm -f "$DDOS_UNIT" "$DDOS_CONF"
    systemctl daemon-reload
    log_event "ddos protection removed"
    ok "DDoS protection removed."
}

# ------------------------------------------------------------------ menu ---
ddos_info() {
    if ddos_installed; then
        printf ' %sMONITORED PORTS:%s %s\n' "$C_GRN" "$C_RST" "$(ddos_get PORTS)"
        printf ' %sMAX ATTEMPTS:%s %s/min   %sBLOCK:%s %s min\n' "$C_GRN" "$C_RST" "$(ddos_get MAX)" "$C_GRN" "$C_RST" "$(ddos_get BLOCK)"
        printf ' %sWHITELIST:%s %s\n' "$C_GRN" "$C_RST" "$(ddos_get WHITELIST)"
    else
        ui_center "LIMITS NEW CONNECTIONS PER IP ON CHOSEN PORTS" "$C_YLW"
    fi
}
m_ddos_install() {
    local ports max block white def
    clear 2>/dev/null; ui_title "DDOS PROTECTION INSTALLER"
    def=$( { ssh_ports; dropbear_ports 2>/dev/null; wsp_ports 2>/dev/null; } | sort -un | paste -sd' ' -)
    ask ports "PORTS TO MONITOR" "$def" || return
    ask max "MAXIMUM ATTEMPTS (new connections per minute per IP)" 20 || return
    ask block "BLOCK TIME, IN MINUTES" 10 || return
    white="127.0.0.1,$(sys_ip)"
    [[ -n ${SSH_CONNECTION:-} ]] && white+=",${SSH_CONNECTION%% *}"
    ask white "IP WHITELIST (comma-separated)" "$white" || return
    ddos_install "$ports" "$max" "$block" "$white"
}
m_ddos_banned() {
    if [[ -r /proc/net/xt_recent/vpsp_ddos_ban ]]; then
        awk '{print "  " $1}' /proc/net/xt_recent/vpsp_ddos_ban | sed 's/src=//' | grep . || info "No address is blocked right now."
    else
        info "No address is blocked right now."
    fi
}
m_ddos_unban() { [[ -w /proc/net/xt_recent/vpsp_ddos_ban ]] && echo / > /proc/net/xt_recent/vpsp_ddos_ban; ok "All blocks cleared."; }
m_ddos_toggle() {
    if systemctl is-active --quiet vpspanel-ddos; then run_step "systemctl stop ddos" systemctl stop vpspanel-ddos
    else run_step "systemctl start ddos" systemctl start vpspanel-ddos; fi
}
m_ddos_rules() { iptables -S "$DDOS_CHAIN" 2>/dev/null || info "The rules are not active."; }
m_ddos_uninstall() { confirm "Remove DDoS protection?" && ddos_uninstall; }
m_ddos_reinstall() { ddos_uninstall > /dev/null && m_ddos_install; }

ddos_menu() {
    local -a items
    while true; do
        if ddos_installed; then
            items=("SERVICE STATUS|show_service_status vpspanel-ddos"
                   "RESTART (RE-APPLY RULES)|restart_service vpspanel-ddos"
                   "START/STOP $(st_state "$(svc_state vpspanel-ddos)")|m_ddos_toggle"
                   -
                   "BLOCKED ADDRESSES|m_ddos_banned"
                   "CLEAR ALL BLOCKS|m_ddos_unban"
                   "VIEW RULES|m_ddos_rules"
                   "@RECONFIGURE|m_ddos_reinstall"
                   "@UNINSTALL|m_ddos_uninstall")
        else
            items=("INSTALL DDOS PROTECTION|m_ddos_install")
        fi
        menu_show "DDOS PROTECTION" ddos_info "${items[@]}" || return 0
    done
}
