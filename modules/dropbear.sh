# shellcheck shell=bash
# vpspanel module: Dropbear SSH server.
# Uses the distribution's dropbear-bin package (MIT license) and a panel-owned
# systemd unit, so behaviour is the same on every supported Debian/Ubuntu release.

DROPBEAR_UNIT=/etc/systemd/system/vpspanel-dropbear.service
DROPBEAR_PORT_FILE="$VPSP_ETC/dropbear.port"

dropbear_installed() { [[ -x /usr/sbin/dropbear && -f $DROPBEAR_UNIT ]]; }
dropbear_port()      { cat "$DROPBEAR_PORT_FILE" 2>/dev/null || echo "-"; }

port_in_use() { [[ -n $(ss -ltnH "( sport = :$1 )" 2>/dev/null) ]]; }

fw_allow() {
    if command -v ufw > /dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow "$1/tcp" > /dev/null
    fi
}

dropbear_install() {
    local port=$1
    valid_port "$port" || { err "Invalid port: $port"; return 1; }
    has_systemd || { err "Dropbear management requires systemd."; return 1; }
    if port_in_use "$port" && [[ $(dropbear_port) != "$port" ]]; then
        err "Port $port is already in use."; return 1
    fi
    info "Installing dropbear-bin..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q dropbear-bin > /dev/null \
        || { err "apt-get install dropbear-bin failed."; return 1; }
    mkdir -p /etc/dropbear
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

dropbear_menu() {
    local choice port
    while true; do
        clear
        ui_title "Dropbear"
        printf '  Status: %s    Port: %s\n' "$(svc_state vpspanel-dropbear)" "$(dropbear_port)"
        ui_line
        if dropbear_installed; then
            ui_item 1 "Change port"
            ui_item 2 "Restart"
            ui_item 3 "Uninstall"
        else
            ui_item 1 "Install"
        fi
        ui_item 0 "Back"
        ui_line
        ask choice "Option" || return
        case $choice in
            1)  if dropbear_installed; then
                    ask port "New port" && dropbear_set_port "$port"
                else
                    ask port "Port" "143" && dropbear_install "$port"
                fi
                ui_pause ;;
            2)  dropbear_installed && { systemctl restart vpspanel-dropbear && ok "Restarted."; ui_pause; } ;;
            3)  dropbear_installed && { confirm "Uninstall Dropbear?" && dropbear_remove; ui_pause; } ;;
            0)  return ;;
        esac
    done
}
