# shellcheck shell=bash
# vpspanel module: SlowDNS (dnstt by David Fifield, public domain / CC0).
# dnstt-server is built from a pinned upstream tag (commit verified) with the
# official Go toolchain from go.dev (SHA-256 verified); the toolchain is
# deleted after the build. As in ADMRufu: the server listens on UDP 5300,
# incoming UDP 53 is redirected to it, and tunnelled traffic goes to one
# local port (SSH or Dropbear).

SDNS_TAG=v1.20260501.0
SDNS_COMMIT=0c5c52a57d899c05428c116898941761a2ed83c2
SDNS_REPO=https://www.bamsoftware.com/git/dnstt.git
SDNS_BIN=/usr/local/bin/dnstt-server
SDNS_DIR="$VPSP_ETC/slowdns"
SDNS_SETTINGS="$SDNS_DIR/settings"     # NS TARGET
SDNS_UNIT=/etc/systemd/system/vpspanel-slowdns.service
SDNS_PORT=5300

sdns_installed() { [[ -x $SDNS_BIN && -f $SDNS_UNIT && -f $SDNS_SETTINGS ]]; }
sdns_get() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print }' "$SDNS_SETTINGS" 2>/dev/null; }
sdns_set() {
    local tmp; tmp=$(mktemp)
    grep -v "^$1=" "$SDNS_SETTINGS" 2>/dev/null > "$tmp"
    printf '%s=%s\n' "$1" "$2" >> "$tmp"
    install -m 600 "$tmp" "$SDNS_SETTINGS"; rm -f "$tmp"
}

sdns_build() {
    local arch tmp file sum have
    [[ -x $SDNS_BIN ]] && return 0
    case $(uname -m) in
        x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;;
        *) err "Unsupported CPU architecture: $(uname -m)"; return 1 ;;
    esac
    run_step "apt install git curl jq" apt_install git curl jq ca-certificates || return 1
    tmp=$(mktemp -d) || return 1
    read -r file sum < <(curl -fsSL --retry 4 'https://go.dev/dl/?mode=json' 2>/dev/null | jq -r --arg a "$arch" \
        '[.[] | select(.stable)][0].files[] | select(.os == "linux" and .arch == $a and .kind == "archive") | "\(.filename) \(.sha256)"')
    [[ $file =~ ^go[0-9.]+\.linux-$arch\.tar\.gz$ && $sum =~ ^[0-9a-f]{64}$ ]] \
        || { rm -rf "$tmp"; err "Could not find the Go toolchain on go.dev."; return 1; }
    run_step "downloading ${file%.linux*}" curl -fsSL --retry 4 --retry-delay 3 -o "$tmp/go.tgz" "https://go.dev/dl/$file" \
        || { rm -rf "$tmp"; return 1; }
    have=$(sha256sum "$tmp/go.tgz" | awk '{print $1}')
    [[ $have == "$sum" ]] || { rm -rf "$tmp"; err "Go checksum mismatch: not used."; return 1; }
    tar -xzf "$tmp/go.tgz" -C "$tmp" || { rm -rf "$tmp"; return 1; }
    run_step "downloading dnstt $SDNS_TAG" git clone -q --branch "$SDNS_TAG" "$SDNS_REPO" "$tmp/dnstt" \
        || { rm -rf "$tmp"; return 1; }
    [[ $(git -C "$tmp/dnstt" rev-parse HEAD) == "$SDNS_COMMIT" ]] \
        || { rm -rf "$tmp"; err "dnstt commit mismatch: not built."; return 1; }
    if ! run_step "compiling dnstt-server" env -C "$tmp/dnstt/dnstt-server" HOME="$tmp" GOPATH="$tmp/gopath" GOCACHE="$tmp/cache" \
            CGO_ENABLED=0 GOFLAGS=-mod=readonly GOTOOLCHAIN=local "$tmp/go/bin/go" build -trimpath -o "$tmp/dnstt-server" .; then
        rm -rf "$tmp"; return 1
    fi
    install -m 755 "$tmp/dnstt-server" "$SDNS_BIN"
    # The test suite also builds the client, to make a real tunnel through it.
    if [[ -n ${SDNS_CLIENT_OUT:-} ]]; then
        env -C "$tmp/dnstt/dnstt-client" HOME="$tmp" GOPATH="$tmp/gopath" GOCACHE="$tmp/cache" CGO_ENABLED=0 \
            GOFLAGS=-mod=readonly GOTOOLCHAIN=local "$tmp/go/bin/go" build -trimpath -o "$SDNS_CLIENT_OUT" . > /dev/null 2>&1
    fi
    rm -rf "$tmp"
}

sdns_genkeys() {
    rm -f "$SDNS_DIR/server.key" "$SDNS_DIR/server.pub"
    "$SDNS_BIN" -gen-key -privkey-file "$SDNS_DIR/server.key" -pubkey-file "$SDNS_DIR/server.pub" > /dev/null 2>&1 || return 1
    chgrp "$VPSP_SVC_USER" "$SDNS_DIR/server.key" && chmod 640 "$SDNS_DIR/server.key"
}

sdns_write_unit() {
    cat > "$SDNS_UNIT" <<UNIT
[Unit]
Description=SlowDNS / dnstt server (vpspanel)
After=network.target
StartLimitIntervalSec=0

[Service]
User=$VPSP_SVC_USER
Group=$VPSP_SVC_USER
ExecStartPre=-+/usr/sbin/iptables -t nat -D PREROUTING -p udp --dport 53 -m comment --comment vpspanel-slowdns -j REDIRECT --to-ports $SDNS_PORT
ExecStartPost=-+/usr/sbin/iptables -I INPUT -p udp --dport $SDNS_PORT -m comment --comment vpspanel-slowdns -j ACCEPT
ExecStartPost=-+/usr/sbin/iptables -t nat -I PREROUTING -p udp --dport 53 -m comment --comment vpspanel-slowdns -j REDIRECT --to-ports $SDNS_PORT
ExecStopPost=-+/usr/sbin/iptables -D INPUT -p udp --dport $SDNS_PORT -m comment --comment vpspanel-slowdns -j ACCEPT
ExecStopPost=-+/usr/sbin/iptables -t nat -D PREROUTING -p udp --dport 53 -m comment --comment vpspanel-slowdns -j REDIRECT --to-ports $SDNS_PORT
ExecStart=$SDNS_BIN -udp :$SDNS_PORT -privkey-file $SDNS_DIR/server.key $(sdns_get NS) 127.0.0.1:$(sdns_get TARGET)
NoNewPrivileges=yes
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
}

sdns_install() {
    local ns=$1 target=$2
    has_systemd || { err "SlowDNS requires systemd."; return 1; }
    valid_domain "$ns" || { err "Invalid NS domain: $ns"; return 1; }
    valid_port "$target" || { err "Invalid target port."; return 1; }
    udp_port_in_use "$SDNS_PORT" && { err "UDP port $SDNS_PORT is already in use."; return 1; }
    run_step "apt install iptables" apt_install iptables || return 1
    sdns_build || return 1
    svc_user_ensure || return 1
    mkdir -p "$SDNS_DIR" && chmod 750 "$SDNS_DIR" && chgrp "$VPSP_SVC_USER" "$SDNS_DIR"
    : > "$SDNS_SETTINGS"
    sdns_set NS "$ns"; sdns_set TARGET "$target"
    run_step "generating key pair" sdns_genkeys || return 1
    sdns_write_unit
    run_step "systemctl start slowdns" systemctl enable --now vpspanel-slowdns \
        || { err "See: journalctl -u vpspanel-slowdns"; return 1; }
    fw_allow 53 udp
    log_event "slowdns installed ns=$ns target=$target"
}

sdns_uninstall() {
    systemctl disable --now vpspanel-slowdns > /dev/null 2>&1 || true
    rm -f "$SDNS_UNIT" "$SDNS_BIN"; rm -rf "$SDNS_DIR"
    systemctl daemon-reload
    log_event "slowdns removed"
    ok "SlowDNS removed."
}

sdns_apply() { sdns_write_unit; restart_service vpspanel-slowdns; }

# ------------------------------------------------------------------ menu ---
sdns_info() {
    if sdns_installed; then
        printf ' %sPORT:%s %s   %sREDIRECT:%s 53 > %s   %sTRAFFIC PORT:%s %s\n' "$C_GRN" "$C_RST" "$SDNS_PORT" \
            "$C_GRN" "$C_RST" "$SDNS_PORT" "$C_GRN" "$C_RST" "$(sdns_get TARGET)"
        printf ' %sNS DOMAIN:%s %s\n' "$C_GRN" "$C_RST" "$(sdns_get NS)"
        printf ' %sPUBLIC KEY:%s %s\n' "$C_GRN" "$C_RST" "$(cat "$SDNS_DIR/server.pub" 2>/dev/null)"
    else
        ui_center "DNS TUNNEL (DNSTT): NEEDS AN NS RECORD POINTING HERE" "$C_YLW"
    fi
}
m_sdns_install() {
    local ns target
    clear 2>/dev/null; ui_title "SLOWDNS (DNSTT) INSTALLER"
    info "Create a DNS record first: NS ns.example.com -> a.example.com, A a.example.com -> $(sys_ip)"
    ask ns "Your NS domain" || return
    valid_domain "$ns" || { err "Invalid domain."; return 1; }
    ask_target_port target || return
    sdns_install "$ns" "$target"
}
m_sdns_keys()   { printf '  %sPRIVATE:%s %s\n  %sPUBLIC:%s  %s\n' "$C_GRN" "$C_RST" "$(cat "$SDNS_DIR/server.key")" "$C_GRN" "$C_RST" "$(cat "$SDNS_DIR/server.pub")"; }
m_sdns_newkeys() { confirm "Generate a new key pair? Clients need the new public key." && run_step "generating key pair" sdns_genkeys && sdns_apply; }
m_sdns_ownkeys() {
    local priv pub
    ask priv "Private key (64 hex characters)" || return
    ask pub "Public key (64 hex characters)" || return
    [[ $priv =~ ^[0-9a-f]{64}$ && $pub =~ ^[0-9a-f]{64}$ ]] || { err "Keys must be 64 lowercase hex characters."; return 1; }
    printf '%s\n' "$priv" > "$SDNS_DIR/server.key"; printf '%s\n' "$pub" > "$SDNS_DIR/server.pub"
    chgrp "$VPSP_SVC_USER" "$SDNS_DIR/server.key" && chmod 640 "$SDNS_DIR/server.key"
    sdns_apply
}
m_sdns_target() { local t; ask_target_port t && sdns_set TARGET "$t" && sdns_apply; }
m_sdns_ns()     { local n; ask n "New NS domain" "$(sdns_get NS)" && valid_domain "$n" && sdns_set NS "$n" && sdns_apply; }
m_sdns_uninstall() { confirm "Uninstall SlowDNS?" && sdns_uninstall; }
m_sdns_reinstall() { local ns t; ns=$(sdns_get NS); t=$(sdns_get TARGET); confirm "Reinstall SlowDNS (new keys)?" && sdns_uninstall > /dev/null && sdns_install "$ns" "$t"; }

slowdns_menu() {
    local -a items
    while true; do
        if sdns_installed; then
            items=("MY SLOWDNS KEYS|m_sdns_keys" "GENERATE A NEW KEY PAIR|m_sdns_newkeys" "USE MY OWN KEY PAIR|m_sdns_ownkeys" -
                   "CHANGE TRAFFIC PORT|m_sdns_target" "CHANGE NS DOMAIN|m_sdns_ns" -
                   "SERVICE STATUS|show_service_status vpspanel-slowdns" "RESTART SERVICE|restart_service vpspanel-slowdns"
                   "START/STOP SERVICE $(st_state "$(svc_state vpspanel-slowdns)")|toggle_service vpspanel-slowdns" -
                   "LOG SLOWDNS|journalctl -u vpspanel-slowdns -n 40 --no-pager"
                   "LIVE LOG|follow_log journalctl -u vpspanel-slowdns -n 30 -f"
                   "@REINSTALL|m_sdns_reinstall" "@UNINSTALL|m_sdns_uninstall")
        else
            items=("INSTALL SLOWDNS|m_sdns_install")
        fi
        menu_show "DNSTT (SLOWDNS) MANAGER" sdns_info "${items[@]}" || return 0
    done
}
