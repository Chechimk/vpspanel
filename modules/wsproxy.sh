# shellcheck shell=bash
# vpspanel module: SOCKS/WebSocket/HTTP proxy - the equivalent of ADMRufu's
# "SOCKS PYTHON" (Python 3 only; original code in bin/vpspanel-wsproxy).
# One systemd instance per listening port: vpspanel-wsproxy@PORT.service,
# configured by $VPSP_ETC/wsproxy/PORT.env.
#   direct  - HTTP/WebSocket payload -> status line (101/200...) -> one local port
#   connect - HTTP CONNECT proxy limited to this server's own ports

WSP_DIR="$VPSP_ETC/wsproxy"
WSP_UNIT=/etc/systemd/system/vpspanel-wsproxy@.service

wsp_ports() { ls "$WSP_DIR"/*.env 2>/dev/null | sed 's#.*/##; s#\.env$##' | sort -n; }
wsp_installed() { [[ -f $WSP_UNIT ]]; }
# shellcheck source=/dev/null
wsp_env() { ( set +u; . "$WSP_DIR/$1.env" 2>/dev/null; printf '%s' "${!2:-}" ); }

wsp_write_unit() {
    cat > "$WSP_UNIT" <<UNIT
[Unit]
Description=vpspanel SOCKS/WebSocket proxy on port %i
After=network.target
StartLimitIntervalSec=0

[Service]
EnvironmentFile=$WSP_DIR/%i.env
ExecStart=/usr/bin/python3 $VPSP_HOME/bin/vpspanel-wsproxy --port %i --mode \${MODE} --target \${TARGET} --code \${CODE} --status "\${STATUS}" --header-b64 \${HEADER64} --allow \${ALLOW}
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

# wsp_add PORT TARGET [CODE] [STATUS] [HEADER]  - direct mode
# wsp_add PORT connect ALLOWED_PORTS            - CONNECT mode
wsp_add() {
    local port=$1 target=$2 code=${3:-101} status=${4:-} header=${5:-} mode=direct allow='' h64=''
    valid_port "$port" || { err "Invalid port."; return 1; }
    if [[ $target == connect ]]; then
        mode=connect; allow=$3; code=200; status=''
        [[ $allow =~ ^[0-9]+(,[0-9]+)*$ ]] || { err "Allowed ports must be a comma-separated list."; return 1; }
        target=22
    fi
    valid_port "$target" || { err "Invalid target port."; return 1; }
    valid_int "$code" 100 599 || { err "Response code must be 100-599."; return 1; }
    [[ $status =~ ^[[:print:]]{0,120}$ && $status != *'"'* && $status != *'\'* ]] \
        || { err "The banner may contain up to 120 printable characters, without quotes or backslashes."; return 1; }
    [[ -f $WSP_DIR/$port.env ]] && { err "A proxy already uses port $port."; return 1; }
    port_in_use "$port" && { err "Port $port is already in use."; return 1; }
    has_cmd python3 || apt_install python3 || return 1
    # The custom header is typed with \r\n escapes; store the real bytes as base64.
    [[ -n $header ]] && h64=$(printf '%b' "$header" | base64 -w0)
    mkdir -p "$WSP_DIR"
    wsp_write_unit
    printf 'MODE=%s\nTARGET=%s\nCODE=%s\nSTATUS="%s"\nHEADER64=%s\nALLOW=%s\n' \
        "$mode" "$target" "$code" "$status" "$h64" "$allow" > "$WSP_DIR/$port.env"
    run_step "systemctl daemon-reload" systemctl daemon-reload
    if ! run_step "systemctl start proxy.$port" systemctl enable --now "vpspanel-wsproxy@$port"; then
        rm -f "$WSP_DIR/$port.env"
        err "See: journalctl -u vpspanel-wsproxy@$port"
        return 1
    fi
    fw_allow "$port"
    log_event "wsproxy $port mode=$mode target=$target code=$code allow=$allow"
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
    local p any=0 mode
    for p in $(wsp_ports); do
        any=1
        mode=$(wsp_env "$p" MODE)
        if [[ $mode == connect ]]; then
            printf '  %sPort %-6s%s CONNECT -> ports %-14s %s\n' "$C_GRN" "$p" "$C_RST" "$(wsp_env "$p" ALLOW)" \
                "$(st_state "$(systemctl is-active "vpspanel-wsproxy@$p" 2>/dev/null)")"
        else
            printf '  %sPort %-6s%s DIRECT  -> %-6s (%s)       %s\n' "$C_GRN" "$p" "$C_RST" "$(wsp_env "$p" TARGET)" \
                "$(wsp_env "$p" CODE)" "$(st_state "$(systemctl is-active "vpspanel-wsproxy@$p" 2>/dev/null)")"
        fi
    done
    (( any )) || ui_center "NO PROXY PORTS YET" "$C_YLW"
}

wsp_count() { local m=$1 p n=0; for p in $(wsp_ports); do [[ $(wsp_env "$p" MODE) == "$m" || ( -z $(wsp_env "$p" MODE) && $m == direct ) ]] && n=$((n + 1)); done; echo "$n"; }

m_wsp_add() {
    local port target code status header
    clear 2>/dev/null; ui_title "CONFIGURE DIRECT PROXY (WEBSOCKET/HTTP)"
    ask_port port "LISTENING PORT" 80 || return
    ask_target_port target || return
    ui_sep
    ui_center "Enter = 200 (HTTP)      101 = WebSocket" "$C_YLW"
    ask code "RESPONSE STATUS" 200 || return
    valid_int "$code" 100 599 || { err "Enter a code between 100 and 599."; return 1; }
    ui_sep
    info 'Optional bytes sent after the response, with \r\n escapes, e.g.'
    info '\r\nContent-length: 0\r\n\r\nHTTP/1.1 200 Connection Established\r\n\r\n'
    ask header "CUSTOM HEADER (Enter = none)" || return
    ask status "MINI-BANNER (text after the status code, Enter = default)" || return
    wsp_add "$port" "$target" "$code" "$status" "$header"
}

m_wsp_connect() {
    local port allow def
    clear 2>/dev/null; ui_title "CONFIGURE CONNECT PROXY (SIMPLE)"
    info "Clients send 'CONNECT host:PORT'. Only the ports below on this server can"
    info "be reached; other hosts are refused, so this is never an open proxy."
    ask_port port "LISTENING PORT" 8080 || return
    def=$( { ssh_ports; dropbear_ports 2>/dev/null; } | sort -un | paste -sd, -)
    ask allow "ALLOWED LOCAL PORTS (comma-separated)" "$def" || return
    wsp_add "$port" connect "$allow"
}

m_wsp_pick() {
    local __v=$1 __p
    [[ -n $(wsp_ports) ]] || { info "There are no proxy ports."; return 1; }
    ask __p "Port" || return 1
    [[ -f $WSP_DIR/$__p.env ]] || { err "No proxy on port $__p."; return 1; }
    printf -v "$__v" '%s' "$__p"
}

m_wsp_remove()  { local p; m_wsp_pick p && confirm "Remove the proxy on port $p?" && wsp_remove "$p"; }
m_wsp_restart() { local p; for p in $(wsp_ports); do restart_service "vpspanel-wsproxy@$p"; done; [[ -n $(wsp_ports) ]] || info "There are no proxy ports."; }
m_wsp_log()     { local p; m_wsp_pick p && follow_log journalctl -u "vpspanel-wsproxy@$p" -n 30 -f; }
m_wsp_status()  { local p; for p in $(wsp_ports); do show_service_status "vpspanel-wsproxy@$p" | head -n 4; done; [[ -n $(wsp_ports) ]] || info "There are no proxy ports."; }
m_wsp_remove_all() { confirm "Stop and remove every proxy port?" && wsp_remove_all && ok "All proxy ports removed."; }

wsp_menu() {
    local -a items
    while true; do
        items=("DIRECT PROXY (WEBSOCKET/HTTP) $(st_onoff "$( (( $(wsp_count direct) > 0 )) && echo 1 || echo 0)")|m_wsp_add"
               "CONNECT PROXY (SIMPLE) $(st_onoff "$( (( $(wsp_count connect) > 0 )) && echo 1 || echo 0)")|m_wsp_connect")
        if [[ -n $(wsp_ports) ]]; then
            items+=(- "REMOVE A PORT|m_wsp_remove" "RESTART ALL PORTS|m_wsp_restart" -
                    "SERVICE STATUS|m_wsp_status"
                    - "STOP AND REMOVE ALL PORTS|m_wsp_remove_all"
                    "@LOGS|m_wsp_log")
        fi
        menu_show "SOCKS/WEBSOCKET PROXY MANAGER" wsp_info "${items[@]}" || return 0
    done
}
