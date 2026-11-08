# shellcheck shell=bash
# vpspanel module: Dropbear SSH server.
# Uses the distribution's dropbear-bin package (MIT license) and a panel-owned
# systemd unit, so behaviour is the same on every supported Debian/Ubuntu release.

DROPBEAR_UNIT=/etc/systemd/system/vpspanel-dropbear.service
DROPBEAR_PORT_FILE="$VPSP_ETC/dropbear.port"

dropbear_installed() { [[ -x /usr/sbin/dropbear && -f $DROPBEAR_UNIT ]]; }
dropbear_port()      { cat "$DROPBEAR_PORT_FILE" 2>/dev/null || echo "-"; }

dropbear_install() {
    local port=$1
    valid_port "$port" || { err "Invalid port: $port"; return 1; }
    has_systemd || { err "Dropbear management requires systemd."; return 1; }
    if port_in_use "$port" && [[ $(dropbear_port) != "$port" ]]; then
        err "Port $port is already in use."; return 1
    fi
    apt_install dropbear-bin || return 1
    # The distribution's own dropbear service (if any) would fight over ports.
    systemctl disable --now dropbear > /dev/null 2>&1 || true
    mkdir -p /etc/dropbear "$VPSP_ETC"
    echo "$port" > "$DROPBEAR_PORT_FILE"
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
    systemctl enable --now vpspanel-dropbear > /dev/null 2>&1 \
        || { err "Dropbear failed to start. See: journalctl -u vpspanel-dropbear"; return 1; }
    fw_allow "$port"
    log_event "dropbear installed on port $port"
    ok "Dropbear is running on port $port."
}

dropbear_set_port() {
    local port=$1
    dropbear_installed || { err "Dropbear is not installed."; return 1; }
    valid_port "$port" || { err "Invalid port: $port"; return 1; }
    [[ $port == "$(dropbear_port)" ]] && { info "Dropbear already uses port $port."; return 0; }
    port_in_use "$port" && { err "Port $port is already in use."; return 1; }
    echo "$port" > "$DROPBEAR_PORT_FILE"
    systemctl restart vpspanel-dropbear || return 1
    fw_allow "$port"
    log_event "dropbear port $port"
    ok "Dropbear now listens on port $port."
}

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
    ui_kv "Status:" "$(fmt_state "$(svc_state vpspanel-dropbear)")"
    ui_kv "Port:" "$(dropbear_port)"
}

m_dropbear_install() { local p; ask_port p "Dropbear port" 143 && dropbear_install "$p"; }
m_dropbear_port()    { local p; ask p "New Dropbear port" && dropbear_set_port "$p"; }
m_dropbear_remove()  { confirm "Uninstall Dropbear? Clients connected through it will be disconnected." && dropbear_remove; }

dropbear_menu() {
    local -a items
    while true; do
        if dropbear_installed; then
            items=("Change port|m_dropbear_port"
                   "Service status|show_service_status vpspanel-dropbear"
                   "Restart service|restart_service vpspanel-dropbear"
                   "Start / stop service|toggle_service vpspanel-dropbear"
                   "SSH/Dropbear banner|>banner_menu"
                   "Uninstall Dropbear|m_dropbear_remove")
        else
            items=("Install Dropbear|m_dropbear_install")
        fi
        menu_show "DROPBEAR MANAGER" dropbear_info "${items[@]}" || return 0
    done
}
