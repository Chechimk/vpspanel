# shellcheck shell=bash
# vpspanel module: WebSocket / HTTP proxy (HTTP payload -> "101" -> SSH).
# One systemd instance per listening port: vpspanel-wsproxy@PORT.service,
# configured by $VPSP_ETC/wsproxy/PORT.env.

WSP_DIR="$VPSP_ETC/wsproxy"
WSP_UNIT=/etc/systemd/system/vpspanel-wsproxy@.service

wsp_ports() { ls "$WSP_DIR"/*.env 2>/dev/null | sed 's#.*/##; s#\.env$##' | sort -n; }
wsp_installed() { [[ -f $WSP_UNIT ]]; }

wsp_write_unit() {
    cat > "$WSP_UNIT" <<UNIT
[Unit]
Description=vpspanel WebSocket/HTTP proxy on port %i
After=network.target

[Service]
EnvironmentFile=$WSP_DIR/%i.env
ExecStart=/usr/bin/python3 $VPSP_HOME/bin/vpspanel-wsproxy --port %i --target \${TARGET} --status \${STATUS}
DynamicUser=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
}

# wsp_add PORT TARGET [STATUS]
wsp_add() {
    local port=$1 target=$2 status=${3:-Switching Protocols}
    valid_port "$port" && valid_port "$target" || { err "Invalid port."; return 1; }
    [[ $status =~ ^[A-Za-z0-9\ ._-]{1,60}$ ]] || { err "Status text may contain letters, digits, spaces, '.', '_' and '-' only."; return 1; }
    [[ -f $WSP_DIR/$port.env ]] && { err "A proxy already uses port $port."; return 1; }
    port_in_use "$port" && { err "Port $port is already in use."; return 1; }
    has_cmd python3 || apt_install python3 || return 1
    mkdir -p "$WSP_DIR"
    wsp_installed || wsp_write_unit
    # systemd needs the value quoted because it may contain spaces.
    printf 'TARGET=%s\nSTATUS="%s"\n' "$target" "$status" > "$WSP_DIR/$port.env"
    if ! systemctl enable --now "vpspanel-wsproxy@$port" > /dev/null 2>&1; then
        rm -f "$WSP_DIR/$port.env"
        err "The proxy failed to start. See: journalctl -u vpspanel-wsproxy@$port"
        return 1
    fi
    fw_allow "$port"
    log_event "wsproxy $port -> $target"
    ok "Proxy listening on port $port, forwarding to local port $target."
}

wsp_remove() {
    local port=$1
    [[ -f $WSP_DIR/$port.env ]] || { err "No proxy on port $port."; return 1; }
    systemctl disable --now "vpspanel-wsproxy@$port" > /dev/null 2>&1 || true
    rm -f "$WSP_DIR/$port.env"
    log_event "wsproxy $port removed"
    ok "Proxy on port $port removed."
}

wsp_remove_all() {
    local p
    for p in $(wsp_ports); do wsp_remove "$p"; done
    rm -f "$WSP_UNIT"
    has_systemd && systemctl daemon-reload
}

# ------------------------------------------------------------------ menu ---
wsp_info() {
    local p any=0
    for p in $(wsp_ports); do
        any=1
        printf '  Port %-6s -> %-6s %s\n' "$p" "$(. "$WSP_DIR/$p.env"; echo "$TARGET")" \
            "$(fmt_state "$(systemctl is-active "vpspanel-wsproxy@$p" 2>/dev/null)")"
    done
    (( any )) || ui_kv "Ports:" "none"
}

m_wsp_add() {
    local port target status
    ask_port port "Listening port (80 and 8080 are common)" 80 || return
    ask_target_port target || return
    ask status "Text sent after '101' in the response" "Switching Protocols" || return
    wsp_add "$port" "$target" "$status"
}

m_wsp_pick() {
    local __v=$1 p
    [[ -n $(wsp_ports) ]] || { info "There are no proxy ports."; return 1; }
    ask p "Port" || return 1
    [[ -f $WSP_DIR/$p.env ]] || { err "No proxy on port $p."; return 1; }
    printf -v "$__v" '%s' "$p"
}

m_wsp_remove()  { local p; m_wsp_pick p && confirm "Remove the proxy on port $p?" && wsp_remove "$p"; }
m_wsp_restart() { local p; for p in $(wsp_ports); do restart_service "vpspanel-wsproxy@$p"; done; [[ -n $(wsp_ports) ]] || info "There are no proxy ports."; }
m_wsp_log()     { local p; m_wsp_pick p && follow_log journalctl -u "vpspanel-wsproxy@$p" -n 30 -f; }
m_wsp_status()  { local p; m_wsp_pick p && show_service_status "vpspanel-wsproxy@$p"; }
m_wsp_remove_all() { confirm "Remove every WebSocket proxy port?" && wsp_remove_all && ok "All proxy ports removed."; }

wsp_menu() {
    while menu_show "WEBSOCKET / HTTP PROXY" wsp_info \
        "Add a proxy port|m_wsp_add" \
        "Remove a proxy port|m_wsp_remove" \
        "Port status|m_wsp_status" \
        "Restart all proxy ports|m_wsp_restart" \
        "Live log of a port|m_wsp_log" \
        "Remove all proxy ports|m_wsp_remove_all"
    do :; done
}
