# shellcheck shell=bash
# vpspanel module: BadVPN UDPGW (ambrop72/badvpn, BSD-3-Clause).
# Built from the pinned upstream source release (checksum verified) because
# Debian/Ubuntu do not package it. One instance per port, on 127.0.0.1 only,
# as in ADMRufu: clients reach it through their SSH tunnel.

BV_VERSION=1.999.130
BV_SHA256=bfd4bbfebd7274bcec792558c9a2fd60e39cd92e04673825ade5d04154766109
BV_BIN=/usr/local/bin/badvpn-udpgw
BV_DIR="$VPSP_ETC/badvpn"
BV_UNIT=/etc/systemd/system/vpspanel-badvpn@.service

bv_installed() { [[ -x $BV_BIN && -f $BV_UNIT ]]; }
bv_ports() { ls "$BV_DIR"/*.port 2>/dev/null | sed 's#.*/##; s#\.port$##' | sort -n; }

bv_build() {
    local tmp
    [[ -x $BV_BIN ]] && return 0
    run_step "apt install cmake build-essential" apt_install cmake build-essential curl || return 1
    tmp=$(mktemp -d) || return 1
    if ! run_step "downloading badvpn $BV_VERSION" curl -fsSL --retry 4 --retry-delay 3 -o "$tmp/src.tgz" \
            "https://github.com/ambrop72/badvpn/archive/refs/tags/$BV_VERSION.tar.gz"; then
        rm -rf "$tmp"; return 1
    fi
    if [[ $(sha256sum "$tmp/src.tgz" | awk '{print $1}') != "$BV_SHA256" ]]; then
        rm -rf "$tmp"; err "Checksum mismatch: the download was not used."; return 1
    fi
    tar -xzf "$tmp/src.tgz" -C "$tmp" || { rm -rf "$tmp"; return 1; }
    mkdir -p "$tmp/build"
    if ! run_step "compiling badvpn-udpgw" bash -c "cd '$tmp/build' && cmake '$tmp/badvpn-$BV_VERSION' -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 -DCMAKE_BUILD_TYPE=Release && make -j\$(nproc)"; then
        rm -rf "$tmp"; return 1
    fi
    install -m 755 "$tmp/build/udpgw/badvpn-udpgw" "$BV_BIN"
    rm -rf "$tmp"
}

bv_write_unit() {
    cat > "$BV_UNIT" <<UNIT
[Unit]
Description=BadVPN UDPGW on 127.0.0.1:%i (vpspanel)
After=network.target
StartLimitIntervalSec=0

[Service]
ExecStart=$BV_BIN --listen-addr 127.0.0.1:%i --max-clients 1000 --max-connections-for-client 10 --loglevel warning
DynamicUser=yes
NoNewPrivileges=yes
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
}

bv_add_port() {
    local port=$1
    valid_port "$port" || { err "Invalid port."; return 1; }
    [[ -f $BV_DIR/$port.port ]] && { err "BadVPN already uses port $port."; return 1; }
    port_in_use "$port" && { err "Port $port is already in use."; return 1; }
    bv_build || return 1
    mkdir -p "$BV_DIR"
    [[ -f $BV_UNIT ]] || bv_write_unit
    : > "$BV_DIR/$port.port"
    run_step "systemctl daemon-reload" systemctl daemon-reload
    if ! run_step "systemctl start badvpn-udpgw.$port" systemctl enable --now "vpspanel-badvpn@$port"; then
        rm -f "$BV_DIR/$port.port"; err "See: journalctl -u vpspanel-badvpn@$port"; return 1
    fi
    log_event "badvpn port $port"
}

bv_remove_port() {
    local port=$1
    [[ -f $BV_DIR/$port.port ]] || { err "BadVPN does not use port $port."; return 1; }
    systemctl disable --now "vpspanel-badvpn@$port" > /dev/null 2>&1 || true
    rm -f "$BV_DIR/$port.port"
    log_event "badvpn port $port removed"
    ok "Port $port removed."
}

bv_uninstall() {
    local p
    for p in $(bv_ports); do bv_remove_port "$p" > /dev/null; done
    rm -f "$BV_UNIT" "$BV_BIN"; rm -rf "$BV_DIR"
    systemctl daemon-reload
    log_event "badvpn removed"
    ok "BadVPN UDPGW removed."
}

# ------------------------------------------------------------------ menu ---
bv_info() {
    if bv_installed && [[ -n $(bv_ports) ]]; then
        printf ' %sPORTS:%s %s (127.0.0.1)\n' "$C_GRN" "$C_RST" "$(bv_ports | paste -sd' ' -)"
    else
        ui_center "UDP GATEWAY FOR SSH CLIENTS (127.0.0.1 ONLY)" "$C_YLW"
    fi
}
m_bv_install() { local p; ask_port p "Port" 7300 && bv_add_port "$p"; }
m_bv_remove()  { local p; ask p "Port to remove" "$(bv_ports | head -n1)" && bv_remove_port "$p"; }
m_bv_restart() { local p; for p in $(bv_ports); do restart_service "vpspanel-badvpn@$p"; done; }
m_bv_status()  { local p; for p in $(bv_ports); do show_service_status "vpspanel-badvpn@$p" | head -n 4; done; }
m_bv_toggle() {
    local p
    if systemctl is-active --quiet "vpspanel-badvpn@$(bv_ports | head -n1)"; then
        for p in $(bv_ports); do run_step "systemctl stop badvpn-udpgw.$p" systemctl stop "vpspanel-badvpn@$p"; done
    else
        for p in $(bv_ports); do run_step "systemctl start badvpn-udpgw.$p" systemctl start "vpspanel-badvpn@$p"; done
    fi
}
m_bv_uninstall() { confirm "Uninstall BadVPN UDPGW?" && bv_uninstall; }

badvpn_menu() {
    local -a items
    while true; do
        if bv_installed && [[ -n $(bv_ports) ]]; then
            items=("ADD BADVPN-UDPGW PORT|m_bv_install" "REMOVE BADVPN-UDPGW PORT|m_bv_remove" -
                   "SERVICE STATUS|m_bv_status" "RESTART SERVICE|m_bv_restart"
                   "START/STOP SERVICE $(st_state "$(systemctl is-active "vpspanel-badvpn@$(bv_ports | head -n1)" 2>/dev/null)")|m_bv_toggle" -
                   "LOG BADVPN-UDPGW|journalctl -u vpspanel-badvpn@* -n 40 --no-pager"
                   "@UNINSTALL|m_bv_uninstall")
        else
            items=("INSTALL BADVPN-UDPGW|m_bv_install")
        fi
        menu_show "BADVPN-UDPGW MANAGER" bv_info "${items[@]}" || return 0
    done
}
