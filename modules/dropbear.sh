# shellcheck shell=bash
# vpspanel module: Dropbear SSH server.
# Uses the distribution's dropbear-bin package (MIT license) and a panel-owned
# systemd unit, so behaviour is the same on every supported Debian/Ubuntu release.
# Dropbear can listen on several ports (stored space-separated in dropbear.port).

DROPBEAR_UNIT=/etc/systemd/system/vpspanel-dropbear.service
DROPBEAR_PORT_FILE="$VPSP_ETC/dropbear.port"

dropbear_installed() { [[ -x /usr/sbin/dropbear && -f $DROPBEAR_UNIT ]]; }
dropbear_ports()     { tr -s ' \n' '\n' < "$DROPBEAR_PORT_FILE" 2>/dev/null | grep -E '^[0-9]+$'; }
dropbear_port()      { local p; p=$(dropbear_ports | head -n1); echo "${p:--}"; }

# dropbear_install "PORT [PORT...]"
dropbear_install() {
    local ports=$1 p
    has_systemd || { err "Dropbear management requires systemd."; return 1; }
    [[ -n $ports ]] || { err "No port given."; return 1; }
    for p in $ports; do valid_port "$p" || { err "Invalid port: $p"; return 1; }; done
    run_step "apt install dropbear-bin" apt_install dropbear-bin || return 1
    # The distribution's own dropbear service (if any) would fight over ports.
    systemctl disable --now dropbear > /dev/null 2>&1 || true
    mkdir -p /etc/dropbear "$VPSP_ETC"
    echo "$ports" > "$DROPBEAR_PORT_FILE"
    cat > "$DROPBEAR_UNIT" <<UNIT
[Unit]
Description=Dropbear SSH server (vpspanel)
After=network.target

[Service]
ExecStart=$VPSP_HOME/bin/vpspanel-dropbear
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    run_step "systemctl enable --now dropbear" systemctl enable --now vpspanel-dropbear \
        || { err "See: journalctl -u vpspanel-dropbear"; return 1; }
    for p in $ports; do fw_allow "$p"; done
    log_event "dropbear installed on ports $ports"
}

# dropbear_set_ports "PORT [PORT...]"
dropbear_set_ports() {
    local ports=$1 p
    dropbear_installed || { err "Dropbear is not installed."; return 1; }
    [[ -n $ports ]] || { err "No port given."; return 1; }
    for p in $ports; do valid_port "$p" || { err "Invalid port: $p"; return 1; }; done
    echo "$ports" > "$DROPBEAR_PORT_FILE"
    run_step "systemctl restart dropbear" systemctl restart vpspanel-dropbear || return 1
    for p in $ports; do fw_allow "$p"; done
    log_event "dropbear ports $ports"
}
# Kept for the command line and older scripts.
dropbear_set_port() { dropbear_set_ports "$1"; }

dropbear_remove() {
    if has_systemd; then
        systemctl disable --now vpspanel-dropbear > /dev/null 2>&1 || true
    fi
    rm -f "$DROPBEAR_UNIT" "$DROPBEAR_PORT_FILE"
    has_systemd && systemctl daemon-reload
    DEBIAN_FRONTEND=noninteractive apt-get remove -y -q dropbear-bin > /dev/null 2>&1 || true
    log_event "dropbear removed"
    ok "Dropbear removed."
}

# ------------------------------------------------------------------ menu ---
dropbear_info() {
    if dropbear_installed; then
        printf '      %sPORTS:%s %s\n' "$C_GRN" "$C_RST" "$(dropbear_ports | paste -sd' ' -)"
    else
        ui_center "If the install freezes on Debian, press Ctrl+C and retry." "$C_YLW"
    fi
}

m_dropbear_install() {
    local p
    ask_port_list p "Dropbear" "80 90 109 110 143 443" || return
    dropbear_install "$p"
}
m_dropbear_port() {
    local p
    ask_port_list p "Dropbear" "80 90 109 110 143 443" "$(dropbear_ports | paste -sd' ' -)" || return
    dropbear_set_ports "$p"
}
m_dropbear_edit() {
    "${EDITOR:-nano}" "$DROPBEAR_PORT_FILE"
    dropbear_set_ports "$(dropbear_ports | paste -sd' ' -)"
}
m_dropbear_remove()  { confirm "Uninstall Dropbear? Clients connected through it will be disconnected." && dropbear_remove; }

dropbear_menu() {
    local -a items
    while true; do
        if dropbear_installed; then
            items=("REDEFINE PORTS|m_dropbear_port"
                   "MANUAL CONFIGURATION (nano)|m_dropbear_edit"
                   "SSH/DROPBEAR BANNER|>banner_menu"
                   -
                   "SERVICE STATUS|show_service_status vpspanel-dropbear"
                   "RESTART SERVICE|restart_service vpspanel-dropbear"
                   "START/STOP SERVICE $(st_state "$(svc_state vpspanel-dropbear)")|toggle_service vpspanel-dropbear"
                   "@UNINSTALL DROPBEAR|m_dropbear_remove")
        else
            items=("INSTALL DROPBEAR|m_dropbear_install")
        fi
        menu_show "DROPBEAR MANAGER" dropbear_info "${items[@]}" || return 0
    done
}
