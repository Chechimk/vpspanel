# shellcheck shell=bash
# vpspanel module: WireGuard server and clients (wireguard-tools from the
# distribution, GPL-2.0). The panel only manages a wg0.conf that it created.

WG_CONF=/etc/wireguard/wg0.conf
WG_DIR="$VPSP_ETC/wireguard"
WG_CLIENTS="$WG_DIR/clients"
WG_NET=10.66.66
WG_MARK="# Managed by vpspanel"

wg_installed() { [[ -f $WG_CONF ]] && grep -qF "$WG_MARK" "$WG_CONF"; }
wg_port()      { awk -F' *= *' '$1 == "ListenPort" { print $2 }' "$WG_CONF" 2>/dev/null; }
wg_endpoint()  { cat "$WG_DIR/endpoint" 2>/dev/null || sys_ip; }
wg_clients()   { ls "$WG_CLIENTS"/*.conf 2>/dev/null | sed 's#.*/##; s#\.conf$##'; }

wg_nat_rules() {
    local iface=$1
    echo "PostUp = iptables -t nat -A POSTROUTING -s $WG_NET.0/24 -o $iface -j MASQUERADE; iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT"
    echo "PostDown = iptables -t nat -D POSTROUTING -s $WG_NET.0/24 -o $iface -j MASQUERADE; iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT"
}

wg_apply() {
    systemctl is-active --quiet wg-quick@wg0 || return 0
    wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || systemctl restart wg-quick@wg0
}

wg_install() {
    local port=$1 endpoint=$2 iface key
    has_systemd || { err "WireGuard management requires systemd."; return 1; }
    if [[ -f $WG_CONF ]] && ! wg_installed; then
        err "$WG_CONF already exists and was not created by the panel. It was left untouched."; return 1
    fi
    iface=$(sys_iface)
    [[ -n $iface ]] || { err "Could not detect the default network interface."; return 1; }
    apt_install wireguard-tools iptables qrencode || return 1
    mkdir -p /etc/wireguard "$WG_CLIENTS" && chmod 700 /etc/wireguard "$WG_DIR"
    key=$(wg genkey)
    echo "$endpoint" > "$WG_DIR/endpoint"
    {
        echo "$WG_MARK"
        echo "[Interface]"
        echo "Address = $WG_NET.1/24"
        echo "ListenPort = $port"
        echo "PrivateKey = $key"
        wg_nat_rules "$iface"
    } > "$WG_CONF"
    chmod 600 "$WG_CONF"
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-vpspanel-wireguard.conf
    sysctl --system > /dev/null 2>&1
    if ! systemctl enable --now wg-quick@wg0 > /dev/null 2>&1; then
        err "WireGuard failed to start. See: journalctl -u wg-quick@wg0"; return 1
    fi
    fw_allow "$port" udp
    log_event "wireguard installed port $port"
    ok "WireGuard is running on UDP port $port. Create clients in Manage accounts (WireGuard)."
}

wg_set_port() {
    valid_port "$1" || { err "Invalid port."; return 1; }
    udp_port_in_use "$1" && [[ $1 != "$(wg_port)" ]] && { err "UDP port $1 is in use."; return 1; }
    sed -i "s/^ListenPort = .*/ListenPort = $1/" "$WG_CONF"
    local c
    for c in $(wg_clients); do sed -i "s/^\(Endpoint = .*\):[0-9]*$/\1:$1/" "$WG_CLIENTS/$c.conf"; done
    systemctl restart wg-quick@wg0 && fw_allow "$1" udp && ok "WireGuard now listens on UDP $1. Re-send client configs."
}

wg_fix_nat() {
    local iface tmp
    iface=$(sys_iface)
    [[ -n $iface ]] || { err "Could not detect the default network interface."; return 1; }
    tmp=$(mktemp)
    { grep -vE '^(PostUp|PostDown) = ' "$WG_CONF" | awk -v rules="$(wg_nat_rules "$iface")" '
        { print } /^ListenPort = / { print rules }'; } > "$tmp"
    install -m 600 "$tmp" "$WG_CONF"; rm -f "$tmp"
    systemctl restart wg-quick@wg0 && ok "NAT rules now use interface $iface."
}

wg_uninstall() {
    systemctl disable --now wg-quick@wg0 > /dev/null 2>&1 || true
    rm -f "$WG_CONF" /etc/sysctl.d/99-vpspanel-wireguard.conf
    rm -rf "$WG_DIR"
    log_event "wireguard removed"
    ok "WireGuard and its clients were removed."
}

wg_next_ip() {
    local i
    for (( i = 2; i < 255; i++ )); do
        grep -q "^AllowedIPs = $WG_NET.$i/32" "$WG_CONF" || { echo "$WG_NET.$i"; return 0; }
    done
    return 1
}

wg_client_add() {
    local name=$1 key pub psk ip spub
    [[ $name =~ ^[A-Za-z0-9_-]{2,32}$ ]] || { err "Use 2-32 letters, digits, '_' or '-'."; return 1; }
    [[ -f $WG_CLIENTS/$name.conf ]] && { err "Client $name already exists."; return 1; }
    ip=$(wg_next_ip) || { err "The client address range is full."; return 1; }
    key=$(wg genkey); pub=$(wg pubkey <<< "$key"); psk=$(wg genpsk)
    spub=$(awk -F' *= *' '$1 == "PrivateKey" { print $2 }' "$WG_CONF" | wg pubkey)
    printf '\n### client %s\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' \
        "$name" "$pub" "$psk" "$ip" >> "$WG_CONF"
    : > "$WG_CLIENTS/$name.conf" && chmod 600 "$WG_CLIENTS/$name.conf"
    cat > "$WG_CLIENTS/$name.conf" <<CONF
[Interface]
PrivateKey = $key
Address = $ip/32
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $spub
PresharedKey = $psk
Endpoint = $(wg_endpoint):$(wg_port)
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CONF
    wg_apply
    log_event "wireguard client $name ($ip)"
    ok "Client $name created ($ip)."
}

wg_client_del() {
    local name=$1 tmp
    [[ -f $WG_CLIENTS/$name.conf ]] || { err "No client named $name."; return 1; }
    tmp=$(mktemp)
    awk -v n="### client $name" '
        $0 == n { skip = 1; next }
        /^### client / { skip = 0 }
        !skip { print }' "$WG_CONF" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$tmp"
    install -m 600 "$tmp" "$WG_CONF"; rm -f "$tmp"
    rm -f "$WG_CLIENTS/$name.conf"
    wg_apply
    log_event "wireguard client $name removed"
    ok "Client $name removed."
}

wg_client_show() {
    [[ -f $WG_CLIENTS/$1.conf ]] || { err "No client named $1."; return 1; }
    cat "$WG_CLIENTS/$1.conf"
    if has_cmd qrencode; then
        printf '\n'
        qrencode -t ansiutf8 < "$WG_CLIENTS/$1.conf"
    fi
}

# ------------------------------------------------------------------ menu ---
wg_info() {
    ui_kv "Status:" "$(fmt_state "$(svc_state wg-quick@wg0)")"
    if wg_installed; then
        ui_kv "UDP port:" "$(wg_port)"
        ui_kv "Endpoint:" "$(wg_endpoint)"
        ui_kv "Clients:" "$(wg_clients | grep -c .)"
    fi
}

m_wg_install() {
    local p e
    ask_port p "WireGuard UDP port" 51820 udp || return
    ask e "Public address clients connect to" "$(sys_ip)" || return
    wg_install "$p" "$e"
}
m_wg_port()      { local p; ask p "New UDP port" "$(wg_port)" && wg_set_port "$p"; }
m_wg_edit()      { "${EDITOR:-nano}" "$WG_CONF"; restart_service wg-quick@wg0; }
m_wg_uninstall() { confirm "Uninstall WireGuard and delete all clients?" && wg_uninstall; }

wireguard_menu() {
    local -a items
    while true; do
        if wg_installed; then
            items=("Change port|m_wg_port"
                   "Edit configuration (nano)|m_wg_edit"
                   "Fix NAT (re-detect network interface)|wg_fix_nat"
                   "Service status|show_service_status wg-quick@wg0"
                   "Restart service|restart_service wg-quick@wg0"
                   "Start / stop service|toggle_service wg-quick@wg0"
                   "Uninstall WireGuard|m_wg_uninstall")
        else
            items=("Install WireGuard|m_wg_install")
        fi
        menu_show "WIREGUARD MANAGER" wg_info "${items[@]}" || return 0
    done
}

m_wgc_pick() {
    local __v=$1 n
    [[ -n $(wg_clients) ]] || { info "There are no clients."; return 1; }
    printf '  Clients: %s\n' "$(wg_clients | paste -sd' ' -)"
    ask n "Client name" || return 1
    [[ -f $WG_CLIENTS/$n.conf ]] || { err "No client named $n."; return 1; }
    printf -v "$__v" '%s' "$n"
}

m_wgc_new()  { local n; ask n "Client name" && wg_client_add "$n" && wg_client_show "$n"; }
m_wgc_del()  { local n; m_wgc_pick n && confirm "Remove client $n?" && wg_client_del "$n"; }
m_wgc_show() { local n; m_wgc_pick n && wg_client_show "$n"; }
m_wgc_list() {
    local n ip hs
    printf '  %-20s %-14s %s\n' CLIENT ADDRESS "LAST HANDSHAKE"
    for n in $(wg_clients); do
        ip=$(awk -F' *= *' '$1 == "Address" { print $2 }' "$WG_CLIENTS/$n.conf")
        hs=$(wg show wg0 latest-handshakes 2>/dev/null | awk -v k="$(awk -F' *= *' '$1 == "PrivateKey" { print $2 }' "$WG_CLIENTS/$n.conf" | wg pubkey)" \
             '$1 == k { print $2 }')
        if [[ ${hs:-0} -gt 0 ]]; then hs=$(fmt_date "$hs"); else hs=never; fi
        printf '  %-20s %-14s %s\n' "$n" "${ip%/32}" "$hs"
    done
    [[ -n $(wg_clients) ]] || info "There are no clients."
}

wireguard_clients_menu() {
    if ! wg_installed; then
        warn "WireGuard is not installed."
        info "Install it in Protocol configuration > WireGuard."
        ui_pause
        return 0
    fi
    while menu_show "WIREGUARD ACCOUNTS" wg_info \
        "New client|m_wgc_new" \
        "Remove client|m_wgc_del" \
        "List clients|m_wgc_list" \
        "Show client config / QR code|m_wgc_show"
    do :; done
}
