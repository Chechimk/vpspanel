# shellcheck shell=bash
# vpspanel module: Checkuser - account expiry and online count for VPN apps,
# with the same HTTP API as ADMRufu's Checkuser (bin/vpspanel-checkuser).
# The service runs unprivileged and reads a status file refreshed by the
# guard every minute and after account changes (cu_refresh).

CU_DIR="$VPSP_ETC/checkuser"
CU_SETTINGS="$CU_DIR/settings"      # PORT TZ(utc|local) FORMAT(ddmmyyyy|epoch)
CU_DATA_DIR=/run/vpspanel
CU_DATA="$CU_DATA_DIR/checkuser.json"
CU_UNIT=/etc/systemd/system/vpspanel-checkuser.service

cu_installed() { [[ -f $CU_UNIT && -f $CU_SETTINGS ]]; }
cu_get() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print }' "$CU_SETTINGS" 2>/dev/null; }

# cu_refresh - write the public status file (expiry per user, online count).
cu_refresh() {
    cu_installed || return 0
    local u exp online=0 fmt tz tmp first=1
    fmt=$(cu_get FORMAT); tz=$(cu_get TZ)
    mkdir -p "$CU_DATA_DIR"
    tmp=$(mktemp "$CU_DATA_DIR/.checkuser.XXXXXX") || return 1
    {
        printf '{"users": {'
        for u in $(db_users); do
            acct_os_exists "$u" || continue
            exp=$(db_field "$u" 2)
            online=$(( online + $(acct_sessions "$u") ))
            if [[ $fmt == epoch ]]; then exp=$exp
            elif [[ $tz == local ]]; then exp=$(date -d "@$exp" +%d%m%Y)
            else exp=$(TZ=UTC date -d "@$exp" +%d%m%Y); fi
            (( first )) || printf ', '
            first=0
            printf '"%s": "%s"' "$u" "$exp"
        done
        printf '}, "online": %d}\n' "$online"
    } > "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$CU_DATA"
}

cu_install() {
    local port=$1 tz=$2 fmt=$3
    has_systemd || { err "Checkuser requires systemd."; return 1; }
    has_cmd python3 || apt_install python3 || return 1
    mkdir -p "$CU_DIR"
    printf 'PORT=%s\nTZ=%s\nFORMAT=%s\n' "$port" "$tz" "$fmt" > "$CU_SETTINGS"
    chmod 600 "$CU_SETTINGS"
    cat > "$CU_UNIT" <<UNIT
[Unit]
Description=vpspanel Checkuser (account status for VPN apps)
After=network.target
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/bin/python3 $VPSP_HOME/bin/vpspanel-checkuser --port $port --data $CU_DATA
DynamicUser=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
    cu_refresh
    run_step "systemctl daemon-reload" systemctl daemon-reload
    run_step "systemctl start checkuser" systemctl enable --now vpspanel-checkuser \
        || { err "See: journalctl -u vpspanel-checkuser"; return 1; }
    fw_allow "$port"
    log_event "checkuser installed on port $port ($tz, $fmt)"
}

cu_uninstall() {
    systemctl disable --now vpspanel-checkuser > /dev/null 2>&1 || true
    rm -f "$CU_UNIT" "$CU_DATA"; rm -rf "$CU_DIR"
    systemctl daemon-reload
    log_event "checkuser removed"
    ok "Checkuser removed."
}

# ------------------------------------------------------------------ menu ---
cu_info() {
    if cu_installed; then
        printf ' %sURL CHECKUSER:%s http://%s:%s/checkuser\n' "$C_GRN" "$C_RST" "$(sys_ip)" "$(cu_get PORT)"
        printf ' %sURL ONLINES:%s   http://%s:%s\n' "$C_GRN" "$C_RST" "$(sys_ip)" "$(cu_get PORT)"
        printf ' %sDATES:%s %s, %s\n' "$C_GRN" "$C_RST" "$( [[ $(cu_get TZ) == local ]] && echo "server time" || echo UTC)" \
            "$( [[ $(cu_get FORMAT) == epoch ]] && echo "epoch seconds" || echo DDMMYYYY)"
    else
        ui_center "ACCOUNT EXPIRY CHECK FOR VPN APPS" "$C_YLW"
    fi
}
m_cu_install() {
    local port tz=utc fmt=ddmmyyyy a
    ask_port port "PORT" 5000 || return
    ui_item 1 "UTC (international time)"; ui_item 2 "Server time zone"
    ask a "CONFIG" 1 || return; [[ $a == 2 ]] && tz=local
    ui_item 1 "DDMMYYYY"; ui_item 2 "Seconds since epoch (01-01-1970)"
    ask a "FORMAT" 1 || return; [[ $a == 2 ]] && fmt=epoch
    cu_install "$port" "$tz" "$fmt"
}
m_cu_uninstall() { confirm "Uninstall Checkuser?" && cu_uninstall; }

checkuser_menu() {
    local -a items
    while true; do
        if cu_installed; then
            items=("SERVICE STATUS|show_service_status vpspanel-checkuser"
                   "RESTART SERVICE|restart_service vpspanel-checkuser"
                   "START/STOP CHECKUSER $(st_state "$(svc_state vpspanel-checkuser)")|toggle_service vpspanel-checkuser"
                   -
                   "LOG CHECKUSER|journalctl -u vpspanel-checkuser -n 40 --no-pager"
                   "LIVE LOG|follow_log journalctl -u vpspanel-checkuser -n 30 -f"
                   "@UNINSTALL CHECKUSER|m_cu_uninstall")
        else
            items=("INSTALL CHECKUSER|m_cu_install")
        fi
        menu_show "CHECKUSER VERIFICATION" cu_info "${items[@]}" || return 0
    done
}
