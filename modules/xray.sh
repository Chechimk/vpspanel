# shellcheck shell=bash
# vpspanel module: V2Ray/Xray manager (Xray-core, MPL-2.0, downloaded from the
# official XTLS GitHub releases and verified against the published SHA-256).
#
# Layout
#   $XRAY_CONF          the running configuration (enabled inbounds only)
#   $XRAY_META/TAG.json one settings file per inbound: everything the panel
#                       asked for, the client-side values (address, SNI,
#                       REALITY public key, flow...) and, while the inbound is
#                       disabled, the server inbound object itself
#   $XRAY_USERS         "name:uuid:expire_epoch:created_epoch"
# Every unexpired user is a client of every enabled inbound; the client
# entries are always rebuilt from users.db (xray_rebuild), so each protocol
# gets the right credential shape. The UUID is the password for protocols
# that use passwords.
#
# What can be combined comes from the compatibility table below, built from
# the official documentation (xtls.github.io/en/config/transport.html) and
# checked against Xray-core v26.11 with `xray run -test`. Only that table
# decides what the wizard offers.

XRAY_BIN=/usr/local/bin/xray
XRAY_SHARE=/usr/local/share/xray
XRAY_DIR="$VPSP_ETC/xray"
XRAY_CONF="$XRAY_DIR/config.json"
XRAY_USERS="$XRAY_DIR/users.db"
XRAY_META="$XRAY_DIR/inbounds"
XRAY_HOSTS="$XRAY_DIR/hosts"          # v0.3.0 and earlier: "tag host" (migrated)
XRAY_LOGDIR=/var/log/vpspanel-xray
XRAY_UNIT=/etc/systemd/system/vpspanel-xray.service

# ======================================================= compatibility ===
# Proxy-server protocols, auxiliary inbounds, transports (streamSettings
# "method") and transport security are separate dimensions.
XR_PROTOCOLS="vless vmess trojan shadowsocks hysteria masque socks http tunnel"
declare -A XR_PROTO_LABEL=(
    [vless]="VLESS" [vmess]="VMESS" [trojan]="TROJAN" [shadowsocks]="SHADOWSOCKS"
    [hysteria]="HYSTERIA2 (XRAY-NATIVE, UDP)" [masque]="MASQUE (CONNECT-IP)"
    [socks]="SOCKS5 PROXY (AUXILIARY)" [http]="HTTP PROXY (AUXILIARY)"
    [tunnel]="TUNNEL / DOKODEMO-DOOR (PORT FORWARD)")
declare -A XR_PROTO_METHODS=(
    [vless]="raw xhttp grpc websocket httpupgrade mkcp"
    [vmess]="raw xhttp grpc websocket httpupgrade mkcp"
    [trojan]="raw xhttp grpc websocket httpupgrade mkcp"
    [shadowsocks]="raw" [hysteria]="hysteria" [masque]="masque"
    [socks]="raw" [http]="raw" [tunnel]="raw")
declare -A XR_PROTO_SECURITY=(
    [vless]="none tls reality" [vmess]="none tls reality" [trojan]="none tls reality"
    [shadowsocks]="none" [hysteria]="tls" [masque]="tls" [socks]="none" [http]="none tls" [tunnel]="none")
declare -A XR_METHOD_LABEL=(
    [raw]="RAW / TCP" [xhttp]="XHTTP" [grpc]="GRPC" [websocket]="WEBSOCKET (deprecated by Xray)"
    [httpupgrade]="HTTPUPGRADE" [mkcp]="MKCP (UDP)" [hysteria]="HYSTERIA (QUIC)" [masque]="MASQUE (HTTP/3 or HTTP/2)")
declare -A XR_METHOD_SECURITY=(
    [raw]="none tls reality" [xhttp]="none tls reality" [grpc]="none tls reality"
    [websocket]="none tls" [httpupgrade]="none tls" [mkcp]="none tls"
    [hysteria]="tls" [masque]="tls")
# Share-link "type" for each transport.
declare -A XR_METHOD_TYPE=(
    [raw]=tcp [xhttp]=xhttp [grpc]=grpc [websocket]=ws [httpupgrade]=httpupgrade
    [mkcp]=kcp [hysteria]=hysteria [masque]=masque)
# Removed upstream; never offered: legacy HTTP/2 ("h2"/"http"), QUIC,
# DomainSocket. (XHTTP over HTTP/2 or HTTP/3 is offered instead.)
XR_REMOVED_METHODS="h2 http quic domainsocket"
XR_SS_METHODS="chacha20-ietf-poly1305 aes-128-gcm aes-256-gcm xchacha20-ietf-poly1305 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm"
XR_FINGERPRINTS="chrome firefox safari edge ios android random randomized"

xr_in() { [[ " $2 " == *" $1 "* ]]; }      # xr_in WORD "LIST"
xr_security_options() { local s out=''; for s in ${XR_PROTO_SECURITY[$1]}; do xr_in "$s" "${XR_METHOD_SECURITY[$2]}" && out+="$s "; done; printf '%s' "${out% }"; }
# Vision (xtls-rprx-vision) needs VLESS over RAW with TLS or REALITY, or
# VLESS Encryption on any transport (official VLESS inbound documentation).
xr_flow_allowed() { [[ $1 == vless ]] && { [[ $4 == 1 ]] || { [[ $2 == raw ]] && xr_in "$3" "tls reality"; }; }; }
xr_udp_method() { xr_in "$1" "mkcp hysteria"; }

# xr_check - central validation of the wizard state (W_* variables).
# Prints the reason and fails when the combination is not valid.
xr_check() {
    local p=$W_proto m=$W_method s=$W_security
    xr_in "$p" "$XR_PROTOCOLS" || { echo "Unknown protocol '$p'."; return 1; }
    xr_in "$m" "${XR_PROTO_METHODS[$p]}" || { echo "${XR_PROTO_LABEL[$p]} cannot use transport '$m'."; return 1; }
    xr_in "$m" "$XR_REMOVED_METHODS" && { echo "Transport '$m' was removed from Xray-core."; return 1; }
    xr_in "$s" "$(xr_security_options "$p" "$m")" || { echo "Security '$s' is not available for ${XR_PROTO_LABEL[$p]} over ${XR_METHOD_LABEL[$m]}."; return 1; }
    [[ $W_tag =~ ^[A-Za-z0-9_.-]{1,40}$ ]] || { echo "The name may use 1-40 letters, digits, '.', '_' or '-'."; return 1; }
    valid_port "$W_port" || { echo "Invalid port."; return 1; }
    if [[ -n $W_flow ]]; then
        [[ $W_flow == xtls-rprx-vision ]] || { echo "The only server-side flow is xtls-rprx-vision."; return 1; }
        xr_flow_allowed "$p" "$m" "$s" "$W_enc" || { echo "Vision needs VLESS over RAW with TLS/REALITY, or VLESS Encryption."; return 1; }
        xr_in "${W_cflow:-$W_flow}" "xtls-rprx-vision xtls-rprx-vision-udp443" || { echo "Invalid client flow."; return 1; }
    fi
    [[ $W_enc == 1 && $p != vless ]] && { echo "VLESS Encryption is only for VLESS."; return 1; }
    [[ $W_enc == 1 && -z $W_dec ]] && { echo "VLESS Encryption keys are missing."; return 1; }
    case $m in
        xhttp|websocket|httpupgrade) [[ $W_path == /* ]] || { echo "The path must start with '/'."; return 1; } ;;
        grpc) [[ $W_path =~ ^[A-Za-z0-9_./-]+$ ]] || { echo "Invalid gRPC service name."; return 1; } ;;
    esac
    if [[ $m == xhttp && $s == none ]] && xr_in "$W_mode" "stream-up stream-one"; then
        echo "XHTTP $W_mode needs HTTP/2 or HTTP/3, i.e. TLS or REALITY."; return 1
    fi
    if [[ $s == tls ]]; then
        [[ -s $W_cert && -s $W_key ]] || { echo "TLS needs a certificate and key."; return 1; }
    fi
    if [[ $s == reality ]]; then
        [[ $W_target =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || { echo "REALITY target must be host:port."; return 1; }
        [[ -n $W_snis && $W_rpriv =~ ^[A-Za-z0-9_-]{43}$ && $W_rpub =~ ^[A-Za-z0-9_-]{43}$ ]] || { echo "REALITY needs server names and a key pair."; return 1; }
        [[ $W_sid =~ ^([0-9a-f]{2}){0,8}$ ]] || { echo "Short ID: 0-16 hex characters, even length."; return 1; }
    fi
    if [[ $p == shadowsocks ]]; then xr_in "$W_ssm" "$XR_SS_METHODS" || { echo "Unknown Shadowsocks cipher."; return 1; }; fi
    if [[ $p == tunnel ]]; then
        [[ -n $W_ttarget ]] && valid_port "$W_tport" || { echo "Tunnel needs a target address and port."; return 1; }
    fi
    if [[ $p == masque ]]; then [[ $W_pool =~ ^[0-9.]+/[0-9]+$ ]] || { echo "MASQUE needs an IPv4 address pool, e.g. 10.77.0.1/24."; return 1; }; fi
    return 0
}

# ============================================================== install ===
xray_installed() { [[ -x $XRAY_BIN && -f $XRAY_UNIT && -f $XRAY_CONF ]]; }

xray_arch() {
    case $(uname -m) in
        x86_64|amd64)  echo 64 ;;
        aarch64|arm64) echo arm64-v8a ;;
        *) return 1 ;;
    esac
}

xray_download() {
    local arch tag tmp url want have
    arch=$(xray_arch) || { err "Unsupported CPU architecture: $(uname -m)"; return 1; }
    apt_install curl unzip jq || return 1
    tag=$(gh_latest_tag XTLS/Xray-core)
    [[ $tag =~ ^v[0-9.]+$ ]] || { err "Could not find the latest Xray release on GitHub."; return 1; }
    url="https://github.com/XTLS/Xray-core/releases/download/$tag/Xray-linux-$arch.zip"
    tmp=$(mktemp -d) || return 1
    info "Downloading Xray $tag..."
    if ! curl -fsSL --retry 4 --retry-delay 3 -o "$tmp/xray.zip" "$url" || ! curl -fsSL --retry 4 --retry-delay 3 -o "$tmp/xray.dgst" "$url.dgst"; then
        rm -rf "$tmp"; err "Download failed."; return 1
    fi
    want=$(awk -F'= ' '/^SHA2-256=/ {print $2}' "$tmp/xray.dgst")
    have=$(sha256sum "$tmp/xray.zip" | awk '{print $1}')
    if [[ -z $want || $want != "$have" ]]; then
        rm -rf "$tmp"; err "Checksum mismatch: the download was not installed."; return 1
    fi
    unzip -q -o "$tmp/xray.zip" -d "$tmp/x" || { rm -rf "$tmp"; return 1; }
    install -m 755 "$tmp/x/xray" "$XRAY_BIN"
    mkdir -p "$XRAY_SHARE"
    install -m 644 "$tmp/x/geoip.dat" "$tmp/x/geosite.dat" "$XRAY_SHARE/" 2>/dev/null || true
    rm -rf "$tmp"
    ok "Xray $tag installed (checksum verified)."
}

xray_write_unit() {
    cat > "$XRAY_UNIT" <<UNIT
[Unit]
Description=Xray proxy (vpspanel)
After=network.target
StartLimitIntervalSec=0

[Service]
User=$VPSP_SVC_USER
Group=$VPSP_SVC_USER
Environment=XRAY_LOCATION_ASSET=$XRAY_SHARE
ExecStart=$XRAY_BIN run -config $XRAY_CONF
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
NoNewPrivileges=yes
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
}

xray_base_config() {
    jq -n --arg a "$XRAY_LOGDIR/access.log" --arg e "$XRAY_LOGDIR/error.log" '{
        log: {access: $a, error: $e, loglevel: "warning"},
        inbounds: [],
        outbounds: [{protocol: "freedom", tag: "direct"}, {protocol: "blackhole", tag: "block"}],
        routing: {rules: [{type: "field", ip: ["geoip:private"], outboundTag: "block"}]}
    }'
}

xray_install() {
    has_systemd || { err "Xray management requires systemd."; return 1; }
    [[ -x $XRAY_BIN ]] || xray_download || return 1
    svc_user_ensure || return 1
    mkdir -p "$XRAY_DIR" "$XRAY_LOGDIR" "$XRAY_META"
    chmod 750 "$XRAY_DIR"; chgrp "$VPSP_SVC_USER" "$XRAY_DIR"; chmod 700 "$XRAY_META"
    chown "$VPSP_SVC_USER:$VPSP_SVC_USER" "$XRAY_LOGDIR"
    touch "$XRAY_USERS"; chmod 600 "$XRAY_USERS"
    [[ -f $XRAY_CONF ]] || { xray_base_config > "$XRAY_CONF"; chgrp "$VPSP_SVC_USER" "$XRAY_CONF"; chmod 640 "$XRAY_CONF"; }
    # The unit is rewritten on every install so new capabilities apply.
    xray_write_unit
    xray_migrate
    run_step "systemctl enable --now xray" systemctl enable --now vpspanel-xray \
        || { err "See: journalctl -u vpspanel-xray"; return 1; }
    log_event "xray installed"
}

xray_uninstall() {
    systemctl disable --now vpspanel-xray > /dev/null 2>&1 || true
    rm -f "$XRAY_UNIT" "$XRAY_BIN"
    rm -rf "$XRAY_SHARE" "$XRAY_DIR" "$XRAY_LOGDIR"
    systemctl daemon-reload
    log_event "xray removed"
    ok "Xray and its users were removed."
}

# ======================================================= save + rollback ===
# xray_save JSON - test the new configuration with `xray run -test`; if it
# passes, install it and restart. If Xray does not come back up, the previous
# configuration is restored and restarted.
xray_save() {
    local tmp bak i
    # Xray picks the parser from the file extension, so keep ".json".
    local probe
    tmp=$(mktemp --suffix=.json "$XRAY_DIR/.config.XXXXXX") || return 1
    printf '%s\n' "$1" > "$tmp"
    chgrp "$VPSP_SVC_USER" "$tmp" && chmod 640 "$tmp"
    # The test runs as root: test a copy without log files, so it cannot
    # create log files the unprivileged service would not be allowed to open.
    probe=$(mktemp --suffix=.json "$XRAY_DIR/.probe.XXXXXX") || { rm -f "$tmp"; return 1; }
    jq 'del(.log.access, .log.error)' "$tmp" > "$probe" 2>/dev/null || cp "$tmp" "$probe"
    if ! XRAY_LOCATION_ASSET=$XRAY_SHARE "$XRAY_BIN" run -test -config "$probe" > "$XRAY_DIR/.last-test" 2>&1; then
        rm -f "$tmp" "$probe"
        err "Xray rejected the configuration; nothing was changed:"
        grep -vE '^Xray|^A unified' "$XRAY_DIR/.last-test" | tail -n 3 >&2
        return 1
    fi
    rm -f "$probe"
    bak="$XRAY_DIR/.config.previous.json"
    [[ -f $XRAY_CONF ]] && cp -p "$XRAY_CONF" "$bak"
    mv -f "$tmp" "$XRAY_CONF"
    mkdir -p "$XRAY_LOGDIR" && chown -R "$VPSP_SVC_USER:$VPSP_SVC_USER" "$XRAY_LOGDIR" 2>/dev/null
    systemctl is-enabled --quiet vpspanel-xray 2>/dev/null || return 0
    systemctl restart vpspanel-xray > /dev/null 2>&1
    for i in 1 2 3 4; do
        sleep 1
        systemctl is-active --quiet vpspanel-xray || break
    done
    if systemctl is-active --quiet vpspanel-xray; then return 0; fi
    err "Xray did not start with the new configuration; the previous one was restored."
    journalctl -u vpspanel-xray -n 3 --no-pager -o cat 2>/dev/null | sed 's/^/    /' >&2
    if [[ -f $bak ]]; then
        cp -p "$bak" "$XRAY_CONF"
        systemctl reset-failed vpspanel-xray > /dev/null 2>&1
        systemctl restart vpspanel-xray > /dev/null 2>&1
        for i in 1 2 3 4 5; do sleep 1; systemctl is-active --quiet vpspanel-xray && break; done
    fi
    log_event "xray change rolled back"
    return 1
}

# ============================================================= metadata ===
xr_meta_file() { printf '%s/%s.json' "$XRAY_META" "$1"; }
xr_meta() { jq -r --arg k "$2" 'if has($k) and .[$k] != null then .[$k] | (if type == "array" then join(",") else tostring end) else empty end' "$(xr_meta_file "$1")" 2>/dev/null; }
xr_tags() { local f; for f in "$XRAY_META"/*.json; do [[ -f $f ]] && basename "$f" .json; done; }
xr_enabled() { [[ $(xr_meta "$1" enabled) != false ]]; }

# Older panel versions stored inbounds without settings files: create them
# from the running configuration so links and editing keep working.
xray_migrate() {
    local tag certsrc='' keysrc='' pin=''
    [[ -f $XRAY_CONF ]] || return 0
    mkdir -p "$XRAY_META"; chmod 700 "$XRAY_META"
    # v0.3 kept one shared certificate copy; remember where it came from.
    if [[ -f $XRAY_DIR/tls/source ]]; then
        { read -r certsrc; read -r keysrc; } < "$XRAY_DIR/tls/source"
        [[ $certsrc == "$SSL_SELF"/* && -s $certsrc ]] && pin=$(openssl x509 -in "$certsrc" -outform der 2>/dev/null | sha256sum | awk '{print $1}')
    fi
    while IFS= read -r tag; do
        [[ -n $tag && $tag != api && ! -f $(xr_meta_file "$tag") ]] || continue
        jq --arg t "$tag" --arg host "$(awk -v t="$tag" '$1 == t {print $2}' "$XRAY_HOSTS" 2>/dev/null)" --arg ip "$(sys_ip)" \
           --arg certsrc "$certsrc" --arg keysrc "$keysrc" --arg pin "$pin" '
            .inbounds[] | select(.tag == $t) | . as $i | ($i.streamSettings // {}) as $s |
            (($s.method // $s.network // "raw") | {tcp: "raw", ws: "websocket", kcp: "mkcp", splithttp: "xhttp"}[.] // .) as $m |
            {tag: $t, protocol: $i.protocol, method: $m, security: ($s.security // "none"), port: $i.port,
             address: (if $host != "" then $host else $ip end), sni: (if $host != "" then $host else $ip end),
             path: ($s.wsSettings.path // $s.xhttpSettings.path // $s.httpupgradeSettings.path // $s.grpcSettings.serviceName // ""),
             host: "", mode: "auto", fp: "chrome", flow: "", cflow: "", enc: 0, encc: "none",
             alpn: (($s.tlsSettings.alpn // []) | join(",")), ssm: ($i.settings.clients[0].method // $i.settings.method // "chacha20-ietf-poly1305"),
             sskey: ($i.settings.password // ""), certsrc: (if ($s.security // "none") == "tls" then $certsrc else "" end),
             keysrc: (if ($s.security // "none") == "tls" then $keysrc else "" end), pin: (if ($s.security // "none") == "tls" then $pin else "" end),
             header: "none", hpath: "/", gmode: "gun", enabled: true, migrated: true}' \
            "$XRAY_CONF" > "$(xr_meta_file "$tag")" 2>/dev/null || rm -f "$(xr_meta_file "$tag")"
        chmod 600 "$(xr_meta_file "$tag")" 2>/dev/null
    done < <(jq -r '.inbounds[] | .tag // empty' "$XRAY_CONF" 2>/dev/null)
}

# ===================================================== users -> clients ===
xray_user_get() { awk -F: -v u="$1" '$1 == u { print; f = 1 } END { exit !f }' "$XRAY_USERS" 2>/dev/null; }

# Shadowsocks 2022: base64 key of the right length for the cipher.
xr_ss_keylen() { case $1 in 2022-blake3-aes-128-gcm) echo 16 ;; *) echo 32 ;; esac; }
xr_ss_userkey() { printf 'vpspanel-ss-%s' "$2" | openssl dgst -sha256 -binary | head -c "$(xr_ss_keylen "$1")" | base64 -w0; }
# Credential a user gives for a password-based protocol.
xr_password() {   # xr_password TAG UUID
    local m; m=$(xr_meta "$1" ssm)
    if [[ $(xr_meta "$1" protocol) == shadowsocks && $m == 2022-* ]]; then printf '%s:%s' "$(xr_meta "$1" sskey)" "$(xr_ss_userkey "$m" "$2")"
    else printf '%s' "$2"; fi
}

# Client entries for one inbound, as a JSON array (or object for socks/http).
xr_clients_for() {   # xr_clients_for TAG
    local tag=$1 proto flow ssm now name id exp created
    proto=$(xr_meta "$tag" protocol); flow=$(xr_meta "$tag" flow); ssm=$(xr_meta "$tag" ssm); now=$(now_epoch)
    while IFS=: read -r name id exp created; do
        [[ -n $name && $exp -gt $now ]] || continue
        case $proto in
            vless)       jq -cn --arg e "$name" --arg id "$id" --arg f "$flow" '{id: $id, email: $e} + (if $f != "" then {flow: $f} else {} end)' ;;
            vmess)       jq -cn --arg e "$name" --arg id "$id" '{id: $id, email: $e}' ;;
            trojan)      jq -cn --arg e "$name" --arg id "$id" '{password: $id, email: $e}' ;;
            shadowsocks) if [[ $ssm == 2022-* ]]; then jq -cn --arg e "$name" --arg p "$(xr_ss_userkey "$ssm" "$id")" '{password: $p, email: $e}'
                         else jq -cn --arg e "$name" --arg p "$id" --arg m "$ssm" '{password: $p, method: $m, email: $e}'; fi ;;
            hysteria)    jq -cn --arg e "$name" --arg id "$id" '{auth: $id, email: $e}' ;;
            masque)      jq -cn --arg e "$name" --arg id "$id" '{email: $e, pass: $id}' ;;
            socks|http)  jq -cn --arg e "$name" --arg id "$id" '{user: $e, pass: $id}' ;;
        esac
    done < "$XRAY_USERS" | jq -s .
}

# xray_rebuild [JSON] - put the current users into every enabled inbound
# that has a settings file; prints the new configuration.
xray_rebuild() {
    local cfg=${1:-$(cat "$XRAY_CONF")} tag proto field c
    for tag in $(xr_tags); do
        xr_enabled "$tag" || continue
        proto=$(xr_meta "$tag" protocol)
        case $proto in
            tunnel) continue ;;
            hysteria|masque) field=users ;;
            socks|http) field=accounts ;;
            *) field=clients ;;
        esac
        c=$(xr_clients_for "$tag")
        cfg=$(jq --arg t "$tag" --arg f "$field" --argjson c "$c" \
            '.inbounds |= map(if .tag == $t then .settings[$f] = $c else . end)' <<< "$cfg") || return 1
    done
    # Tunnels usually forward to a local service, which the "block private
    # addresses" rule would stop: route tunnel inbounds straight to direct.
    cfg=$(jq '([.inbounds[] | select(.protocol == "tunnel" or .protocol == "dokodemo-door") | .tag // empty]) as $tt |
        .routing.rules = ((if ($tt | length) > 0 then [{type: "field", ruleTag: "vpsp-tunnels", inboundTag: $tt, outboundTag: "direct"}] else [] end)
                          + [(.routing.rules // [])[] | select(.ruleTag != "vpsp-tunnels")])' <<< "$cfg") || return 1
    printf '%s\n' "$cfg"
}

xray_apply_users() { local new; new=$(xray_rebuild) && xray_save "$new"; }

# =========================================================== inbounds ===
# xr_build_inbound - server inbound object from the W_* wizard variables.
xr_build_inbound() {
    local tlsdir="$XRAY_DIR/tls/$W_tag"
    jq -n --arg tag "$W_tag" --arg p "$W_proto" --arg m "$W_method" --arg s "$W_security" --argjson port "$W_port" \
        --arg flow "$W_flow" --arg dec "${W_dec:-none}" --arg path "$W_path" --arg host "$W_host" --arg mode "${W_mode:-auto}" \
        --arg header "${W_header:-none}" --arg hpath "${W_hpath:-/}" --arg hb "${W_hb:-}" --arg mtu "${W_mtu:-}" --arg tti "${W_tti:-}" \
        --arg up "${W_up:-}" --arg down "${W_down:-}" --arg cwnd "${W_cwnd:-}" --arg kmask "${W_kmask:-}" --arg kval "${W_kval:-}" \
        --arg alpn "${W_alpn:-}" --arg minv "${W_minv:-}" --arg cert "$tlsdir/cert.pem" --arg key "$tlsdir/key.pem" \
        --arg target "${W_target:-}" --arg snis "${W_snis:-}" --arg rpriv "${W_rpriv:-}" --arg sid "${W_sid:-}" \
        --arg ssm "${W_ssm:-}" --arg sskey "${W_sskey:-}" --arg obfs "${W_obfs:-}" --arg pool "${W_pool:-}" --arg qmtu "${W_qmtu:-}" \
        --arg udp "${W_udp:-1}" --arg tt "${W_ttarget:-}" --arg tp "${W_tport:-0}" --arg tn "${W_tnet:-tcp}" '
    def num($v): if $v == "" then empty else ($v | tonumber) end;
    def list($v): $v | split(",") | map(select(. != ""));
    ({
        vless: {clients: [], decryption: $dec},
        vmess: {clients: []}, trojan: {clients: []},
        shadowsocks: (if ($ssm | startswith("2022-")) then {method: $ssm, password: $sskey, clients: [], network: "tcp,udp"}
                      else {clients: [], network: "tcp,udp"} end),
        hysteria: {version: 2, users: []},
        masque: ({users: [], address: [$pool]} + (if $qmtu != "" then {mtu: ($qmtu | tonumber)} else {} end)),
        socks: {auth: "password", accounts: [], udp: ($udp == "1")},
        http: {accounts: []},
        tunnel: {rewriteAddress: $tt, rewritePort: ($tp | tonumber), allowedNetwork: $tn}
    }[$p]) as $settings |
    ({method: $m, security: $s}
     + (if $m == "raw" and $header == "http" then {rawSettings: {header: {type: "http", request: ({path: [$hpath]}
                                + (if $host != "" then {headers: {Host: [$host]}} else {} end))}}} else {} end)
     + (if $m == "xhttp" then {xhttpSettings: ({path: $path, mode: "auto"} + (if $host != "" then {host: $host} else {} end))} else {} end)
     + (if $m == "grpc" then {grpcSettings: {serviceName: $path}} else {} end)
     + (if $m == "websocket" then {wsSettings: ({path: $path} + (if $host != "" then {host: $host} else {} end)
                                                + (if $hb != "" then {heartbeatPeriod: ($hb | tonumber)} else {} end))} else {} end)
     + (if $m == "httpupgrade" then {httpupgradeSettings: ({path: $path} + (if $host != "" then {host: $host} else {} end))} else {} end)
     + (if $m == "mkcp" then {kcpSettings: ({} + (if $mtu != "" then {mtu: num($mtu)} else {} end) + (if $tti != "" then {tti: num($tti)} else {} end)
                                + (if $up != "" then {uplinkCapacity: num($up)} else {} end) + (if $down != "" then {downlinkCapacity: num($down)} else {} end)
                                + (if $cwnd != "" then {cwndMultiplier: num($cwnd)} else {} end))}
                         + (if $kmask != "" then {finalmask: {udp: [{type: "mkcp-legacy", settings: {header: (if $kmask == "seed" then "" else $kmask end), value: $kval}}]}} else {} end)
        else {} end)
     + (if $m == "hysteria" then {hysteriaSettings: {version: 2}}
                                 + (if $obfs != "" then {finalmask: {udp: [{type: "salamander", settings: {password: $obfs}}]}} else {} end) else {} end)
     + (if $m == "masque" then {masqueSettings: {}} else {} end)
     + (if $s == "tls" then {tlsSettings: ({certificates: [{certificateFile: $cert, keyFile: $key}]}
                                           + (if $alpn != "" then {alpn: list($alpn)} else {} end)
                                           + (if $minv != "" then {minVersion: $minv} else {} end))} else {} end)
     + (if $s == "reality" then {realitySettings: {target: $target, serverNames: list($snis), privateKey: $rpriv, shortIds: [$sid]}} else {} end)
    ) as $stream |
    {tag: $tag, listen: "0.0.0.0", port: $port, protocol: $p, settings: $settings,
     sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]}}
    + (if $p == "tunnel" or $p == "socks" or $p == "http" or $p == "shadowsocks" then (if $s == "tls" then {streamSettings: $stream} else {} end)
       else {streamSettings: $stream} end)'
}

# xr_save_meta - write the settings file from the W_* variables.
xr_save_meta() {
    local f; f=$(xr_meta_file "$W_tag")
    mkdir -p "$XRAY_META"; chmod 700 "$XRAY_META"
    jq -n --arg tag "$W_tag" --arg p "$W_proto" --arg m "$W_method" --arg s "$W_security" --argjson port "$W_port" \
        --arg address "$W_addr" --arg sni "${W_sni:-}" --arg alpn "${W_alpn:-}" --arg fp "${W_fp:-chrome}" --arg minv "${W_minv:-}" \
        --arg flow "${W_flow:-}" --arg cflow "${W_cflow:-}" --argjson enc "${W_enc:-0}" --arg encc "${W_encc:-none}" --arg dec "${W_dec:-}" \
        --arg path "${W_path:-}" --arg host "${W_host:-}" --arg mode "${W_mode:-auto}" --arg header "${W_header:-none}" --arg hpath "${W_hpath:-/}" \
        --arg hb "${W_hb:-}" --arg gmode "${W_gmode:-gun}" --arg mtu "${W_mtu:-}" --arg tti "${W_tti:-}" --arg up "${W_up:-}" --arg down "${W_down:-}" \
        --arg cwnd "${W_cwnd:-}" --arg kmask "${W_kmask:-}" --arg kval "${W_kval:-}" --arg pin "${W_pin:-}" --arg certsrc "${W_cert:-}" --arg keysrc "${W_key:-}" \
        --arg target "${W_target:-}" --arg snis "${W_snis:-}" --arg rpriv "${W_rpriv:-}" --arg rpub "${W_rpub:-}" --arg sid "${W_sid:-}" --arg spx "${W_spx:-}" \
        --arg ssm "${W_ssm:-}" --arg sskey "${W_sskey:-}" --arg obfs "${W_obfs:-}" --arg pool "${W_pool:-}" --arg qmtu "${W_qmtu:-}" --arg udp "${W_udp:-1}" \
        --arg tt "${W_ttarget:-}" --arg tp "${W_tport:-}" --arg tn "${W_tnet:-tcp}" \
        '{tag: $tag, protocol: $p, method: $m, security: $s, port: $port, address: $address, sni: $sni, alpn: $alpn, fp: $fp, minv: $minv,
          flow: $flow, cflow: $cflow, enc: $enc, encc: $encc, dec: $dec, path: $path, host: $host, mode: $mode, header: $header, hpath: $hpath,
          hb: $hb, gmode: $gmode, mtu: $mtu, tti: $tti, up: $up, down: $down, cwnd: $cwnd, kmask: $kmask, kval: $kval, pin: $pin,
          certsrc: $certsrc, keysrc: $keysrc, target: $target, snis: $snis, rpriv: $rpriv, rpub: $rpub, sid: $sid, spx: $spx,
          ssm: $ssm, sskey: $sskey, obfs: $obfs, pool: $pool, qmtu: $qmtu, udp: $udp, ttarget: $tt, tport: $tp, tnet: $tn, enabled: true}' > "$f.tmp" \
        && chmod 600 "$f.tmp" && mv -f "$f.tmp" "$f"
}

# xr_load_meta TAG - load a settings file into the W_* variables (editing).
xr_load_meta() {
    local k v
    while IFS=$'\t' read -r k v; do printf -v "W_$k" '%s' "$v"; done < <(jq -r 'to_entries[] | select(.key != "inbound") |
        [.key, (.value | if type == "array" then join(",") else tostring end)] | @tsv' "$(xr_meta_file "$1")")
    W_proto=$W_protocol W_security=$W_security W_addr=$W_address W_cert=${W_certsrc:-} W_key=${W_keysrc:-}
    W_ssm=${W_ssm:-chacha20-ietf-poly1305}
}

xr_ports_used() {   # ports used by other panel inbounds (enabled or not)
    local t
    for t in $(xr_tags); do [[ $t == "${1:-}" ]] || xr_meta "$t" port; done
}

# xr_commit [REPLACE_TAG] - validate W_*, write certificates, settings file
# and the running configuration (with users), with rollback on failure.
_xr_commit() {
    local replace=${1:-} msg inbound new tlsdir metaf backup=''
    msg=$(xr_check) || { err "$msg"; return 1; }
    if xr_ports_used "$replace" | grep -qx "$W_port"; then err "Another Xray inbound already uses port $W_port."; return 1; fi
    if [[ -z $replace || $(xr_meta "$replace" port) != "$W_port" ]]; then
        if xr_udp_method "$W_method" || [[ $W_alpn == h3 ]]; then
            udp_port_in_use "$W_port" && { err "UDP port $W_port is already in use."; return 1; }
        fi
        if ! xr_udp_method "$W_method" && [[ $W_alpn != h3 ]]; then
            port_in_use "$W_port" && { err "Port $W_port is already in use."; return 1; }
        fi
    fi
    if [[ -z $replace && -f $(xr_meta_file "$W_tag") ]]; then err "An inbound named $W_tag already exists."; return 1; fi
    tlsdir="$XRAY_DIR/tls/$W_tag"
    if [[ $W_security == tls ]]; then
        ssl_copy "$W_cert" "$W_key" "$tlsdir" "$VPSP_SVC_USER" || { err "Could not copy the certificate."; return 1; }
        chmod 750 "$tlsdir"; chgrp "$VPSP_SVC_USER" "$tlsdir"
    fi
    metaf=$(xr_meta_file "$W_tag")
    [[ -f $metaf ]] && backup=$(cat "$metaf")
    xr_save_meta || return 1
    inbound=$(xr_build_inbound) || { err "Internal error while building the inbound."; return 1; }
    new=$(jq --arg r "${replace:-$W_tag}" --argjson ib "$inbound" '.inbounds = ([.inbounds[] | select(.tag != $r)] + [$ib])' "$XRAY_CONF") \
        && new=$(xray_rebuild "$new") && xray_save "$new" && return 0
    # Undo the settings file when the configuration was not accepted.
    if [[ -n $backup ]]; then printf '%s\n' "$backup" > "$metaf"; else rm -f "$metaf"; fi
    return 1
}

xr_fw_open() {
    if xr_udp_method "$W_method" || [[ $W_alpn == h3 ]]; then fw_allow "$W_port" udp; else fw_allow "$W_port"; fi
    [[ $W_method == masque && $W_alpn == *h2* ]] && fw_allow "$W_port"
    return 0
}

_xray_remove_inbound() {
    local tag=$1 new
    [[ -f $(xr_meta_file "$tag") ]] || jq -e --arg t "$tag" '.inbounds[] | select(.tag == $t)' "$XRAY_CONF" > /dev/null 2>&1 \
        || { err "No inbound $tag."; return 1; }
    new=$(jq --arg t "$tag" '.inbounds |= map(select(.tag != $t))' "$XRAY_CONF") || return 1
    xray_save "$new" || return 1
    rm -f "$(xr_meta_file "$tag")"
    sed -i "/^$tag /d" "$XRAY_HOSTS" 2>/dev/null
    log_event "xray inbound $tag removed"
    ok "Inbound $tag removed."
}

# Disable keeps the inbound (with its keys) in its settings file.
_xray_disable_inbound() {
    local tag=$1 ib new f
    f=$(xr_meta_file "$tag")
    ib=$(jq -c --arg t "$tag" '.inbounds[] | select(.tag == $t)' "$XRAY_CONF") && [[ -n $ib ]] || { err "$tag is not enabled."; return 1; }
    new=$(jq --arg t "$tag" '.inbounds |= map(select(.tag != $t))' "$XRAY_CONF") || return 1
    xray_save "$new" || return 1
    jq --argjson ib "$ib" '.enabled = false | .inbound = $ib' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f" && chmod 600 "$f"
    log_event "xray inbound $tag disabled"; ok "Inbound $tag disabled."
}
_xray_enable_inbound() {
    local tag=$1 ib new f port
    f=$(xr_meta_file "$tag")
    ib=$(jq -c '.inbound // empty' "$f") && [[ -n $ib ]] || { err "$tag is not disabled."; return 1; }
    port=$(jq -r '.port' <<< "$ib")
    jq -e --argjson p "$port" '.inbounds[] | select(.port == $p)' "$XRAY_CONF" > /dev/null 2>&1 && { err "Port $port is now used by another inbound."; return 1; }
    jq '.enabled = true | del(.inbound)' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f" && chmod 600 "$f"
    new=$(jq --argjson ib "$ib" '.inbounds += [$ib]' "$XRAY_CONF") && new=$(xray_rebuild "$new") && xray_save "$new" && { log_event "xray inbound $tag enabled"; ok "Inbound $tag enabled."; return 0; }
    jq --argjson ib "$ib" '.enabled = false | .inbound = $ib' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
    return 1
}

# tag|protocol|type|port|security|path   (type as used in share links)
xray_inbounds() {
    local t
    for t in $(xr_tags); do
        xr_enabled "$t" || continue
        printf '%s|%s|%s|%s|%s|%s\n' "$t" "$(xr_meta "$t" protocol)" "${XR_METHOD_TYPE[$(xr_meta "$t" method)]:-tcp}" \
            "$(xr_meta "$t" port)" "$(xr_meta "$t" security)" "$(xr_meta "$t" path)"
    done
}

# ================================================================ users ===
_xray_user_add() {
    local name=$1 days=$2 id=${3:-} exp
    [[ $name =~ ^[A-Za-z0-9_.-]{2,32}$ ]] || { err "Use 2-32 letters, digits, '.', '_' or '-'."; return 1; }
    valid_int "$days" 1 3650 || { err "Days must be 1-3650."; return 1; }
    xray_user_get "$name" > /dev/null && { err "User $name already exists."; return 1; }
    [[ -n $id ]] || id=$(cat /proc/sys/kernel/random/uuid)
    [[ $id =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { err "Invalid UUID."; return 1; }
    exp=$(expiry_from_days "$days")
    echo "$name:$id:$exp:$(now_epoch)" >> "$XRAY_USERS"
    if ! xray_apply_users; then sed -i "/^$name:/d" "$XRAY_USERS"; return 1; fi
    log_event "xray user $name expires=$(fmt_date "$exp")"
    ok "User $name created, expires $(fmt_date "$exp")."
}

_xray_user_del() {
    local row
    row=$(xray_user_get "$1") || { err "No user named $1."; return 1; }
    sed -i "/^$1:/d" "$XRAY_USERS"
    if ! xray_apply_users; then echo "$row" >> "$XRAY_USERS"; return 1; fi
    log_event "xray user $1 deleted"
    ok "User $1 deleted."
}

# xray_user_renew NAME DAYS - new expiry = today + DAYS (as in ADMRufu).
_xray_user_renew() {
    local name=$1 days=$2 exp
    xray_user_get "$name" > /dev/null || { err "No user named $name."; return 1; }
    valid_int "$days" 1 3650 || { err "Days must be 1-3650."; return 1; }
    exp=$(expiry_from_days "$days")
    cp -p "$XRAY_USERS" "$XRAY_USERS.bak"
    awk -F: -v OFS=: -v u="$name" -v e="$exp" '$1 == u { $3 = e } 1' "$XRAY_USERS.bak" > "$XRAY_USERS" && chmod 600 "$XRAY_USERS"
    if ! xray_apply_users; then mv -f "$XRAY_USERS.bak" "$XRAY_USERS"; return 1; fi
    rm -f "$XRAY_USERS.bak"
    log_event "xray user $name renewed until $(fmt_date "$exp")"
    ok "User $name renewed until $(fmt_date "$exp")."
}

# Remove expired users from the running configuration (called by the guard).
_xray_enforce() {
    xray_installed && has_cmd jq || return 0
    local new
    xray_migrate
    new=$(xray_rebuild) || return 0
    if [[ $(jq -S . <<< "$new") != $(jq -S . "$XRAY_CONF") ]]; then
        xray_save "$new" && log_event "xray: expired users removed"
    fi
    return 0
}

# ======================================================= client output ===
xr_uri() { jq -rn --arg v "$1" '$v|@uri'; }
xr_b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }

# Why a standard share link cannot carry this inbound (empty = it can).
xr_link_blocker() {
    local t=$1
    case $(xr_meta "$t" protocol) in
        masque) echo "MASQUE has no standard share link; use the client JSON." ;;
        http)   echo "HTTP proxies have no standard share link; use the client JSON." ;;
        tunnel) echo "A tunnel is a port forward and has no client." ;;
    esac
    [[ $(xr_meta "$t" method) == mkcp && -n $(xr_meta "$t" kmask) ]] && echo "mKCP masks (FinalMask) cannot be written in a share link; use the client JSON."
    return 0
}

# xray_link NAME TAG - the share link of one user for one inbound.
xray_link() {
    local name=$1 tag=$2 id proto m s addr port sni q type pw b
    id=$(xray_user_get "$name" | cut -d: -f2) || return 1
    b=$(xr_link_blocker "$tag"); [[ -z $b ]] || { echo "($b)"; return 0; }
    proto=$(xr_meta "$tag" protocol); m=$(xr_meta "$tag" method); s=$(xr_meta "$tag" security)
    addr=$(xr_meta "$tag" address); port=$(xr_meta "$tag" port); sni=$(xr_meta "$tag" sni)
    [[ $addr == *:* ]] && addr="[$addr]"
    type=${XR_METHOD_TYPE[$m]}
    q="security=$s&type=$type"
    case $m in
        raw)        [[ $(xr_meta "$tag" header) == http ]] && q+="&headerType=http&path=$(xr_uri "$(xr_meta "$tag" hpath)")$( [[ -n $(xr_meta "$tag" host) ]] && echo "&host=$(xr_uri "$(xr_meta "$tag" host)")")" ;;
        websocket|httpupgrade) q+="&path=$(xr_uri "$(xr_meta "$tag" path)")$( [[ -n $(xr_meta "$tag" host) ]] && echo "&host=$(xr_uri "$(xr_meta "$tag" host)")")" ;;
        xhttp)      q+="&path=$(xr_uri "$(xr_meta "$tag" path)")&mode=$(xr_meta "$tag" mode)$( [[ -n $(xr_meta "$tag" host) ]] && echo "&host=$(xr_uri "$(xr_meta "$tag" host)")")" ;;
        grpc)       q+="&serviceName=$(xr_uri "$(xr_meta "$tag" path)")&mode=$(xr_meta "$tag" gmode)" ;;
        mkcp)       q+="&headerType=none" ;;
    esac
    case $s in
        tls)     q+="&sni=$(xr_uri "$sni")&fp=$(xr_meta "$tag" fp)"
                 [[ -n $(xr_meta "$tag" alpn) ]] && q+="&alpn=$(xr_uri "$(xr_meta "$tag" alpn)")" ;;
        reality) q+="&sni=$(xr_uri "$sni")&fp=$(xr_meta "$tag" fp)&pbk=$(xr_meta "$tag" rpub)&sid=$(xr_meta "$tag" sid)"
                 [[ -n $(xr_meta "$tag" spx) ]] && q+="&spx=$(xr_uri "$(xr_meta "$tag" spx)")" ;;
    esac
    case $proto in
        vless)
            [[ -n $(xr_meta "$tag" flow) ]] && q+="&flow=$(xr_meta "$tag" cflow)"
            printf 'vless://%s@%s:%s?encryption=%s&%s#%s\n' "$id" "$addr" "$port" "$(xr_uri "$(xr_meta "$tag" encc)")" "$q" "$(xr_uri "$name")" ;;
        trojan) printf 'trojan://%s@%s:%s?%s#%s\n' "$(xr_uri "$id")" "$addr" "$port" "$q" "$(xr_uri "$name")" ;;
        vmess)
            printf 'vmess://%s\n' "$(jq -cn --arg ps "$name" --arg add "${addr//[\[\]]/}" --arg port "$port" --arg id "$id" --arg net "$type" \
                --arg path "$(xr_meta "$tag" path)" --arg host "$(xr_meta "$tag" host)" --arg s "$s" --arg sni "$sni" \
                --arg fp "$(xr_meta "$tag" fp)" --arg alpn "$(xr_meta "$tag" alpn)" --arg mode "$(xr_meta "$tag" mode)" \
                --arg h "$(xr_meta "$tag" header)" --arg pbk "$(xr_meta "$tag" rpub)" --arg sid "$(xr_meta "$tag" sid)" '
                {v: "2", ps: $ps, add: $add, port: $port, id: $id, aid: "0", scy: "auto", net: $net,
                 type: (if $net == "grpc" then "gun" elif $h == "http" then "http" else "none" end),
                 host: $host, path: $path, tls: (if $s == "none" then "" else $s end), sni: $sni, fp: $fp, alpn: $alpn}
                + (if $net == "xhttp" then {mode: $mode} else {} end)
                + (if $s == "reality" then {pbk: $pbk, sid: $sid} else {} end)' | tr -d '\n' | base64 -w0)" ;;
        shadowsocks)
            pw=$(xr_password "$tag" "$id")
            printf 'ss://%s@%s:%s#%s\n' "$(printf '%s:%s' "$(xr_meta "$tag" ssm)" "$pw" | xr_b64url)" "$addr" "$port" "$(xr_uri "$name")" ;;
        socks)  printf 'socks://%s@%s:%s#%s\n' "$(printf '%s:%s' "$name" "$id" | base64 -w0)" "$addr" "$port" "$(xr_uri "$name")" ;;
        hysteria)
            q="sni=$(xr_uri "$sni")"
            # Self-signed: name checks are skipped but the certificate pin is enforced.
            [[ -n $(xr_meta "$tag" pin) ]] && q+="&insecure=1&pinSHA256=$(xr_meta "$tag" pin)"
            [[ -n $(xr_meta "$tag" obfs) ]] && q+="&obfs=salamander&obfs-password=$(xr_uri "$(xr_meta "$tag" obfs)")"
            printf 'hysteria2://%s@%s:%s/?%s#%s\n' "$(xr_uri "$id")" "$addr" "$port" "$q" "$(xr_uri "$name")" ;;
    esac
}

# xray_client_json NAME TAG - complete client configuration (local SOCKS 1080).
xray_client_json() {
    local name=$1 tag=$2 id pw
    id=$(xray_user_get "$name" | cut -d: -f2) || return 1
    [[ -f $(xr_meta_file "$tag") ]] || return 1
    [[ $(xr_meta "$tag" protocol) == tunnel ]] && { echo '{}'; return 0; }
    pw=$(xr_password "$tag" "$id")
    jq --arg name "$name" --arg id "$id" --arg pw "$pw" '
    def list($v): $v | split(",") | map(select(. != ""));
    . as $c |
    ({raw: "tcp", websocket: "ws", mkcp: "kcp"}[$c.method] // $c.method) as $net |
    ($c.port | tonumber? // $c.port) as $port |
    ({
        vless: {vnext: [{address: $c.address, port: $port, users: [{id: $id, encryption: $c.encc}
                                                                     + (if $c.flow != "" then {flow: $c.cflow} else {} end)]}]},
        vmess: {vnext: [{address: $c.address, port: $port, users: [{id: $id, security: "auto"}]}]},
        trojan: {servers: [{address: $c.address, port: $port, password: $id}]},
        shadowsocks: {servers: [{address: $c.address, port: $port, method: $c.ssm, password: $pw}]},
        socks: {servers: [{address: $c.address, port: $port, users: [{user: $name, pass: $id}]}]},
        http: {servers: [{address: $c.address, port: $port, users: [{user: $name, pass: $id}]}]},
        hysteria: {version: 2, address: $c.address, port: $port},
        masque: {address: $c.address, port: $port, remoteDNS: ["8.8.8.8", "1.1.1.1"]}
    }[$c.protocol]) as $settings |
    (if ($c.protocol | IN("shadowsocks", "socks", "http")) and $c.security == "none" then null else
     ({security: $c.security}
      + (if ($c.method | IN("hysteria", "masque")) then {method: $c.method} else {network: $net} end)
      + (if $c.method == "raw" and $c.header == "http" then {tcpSettings: {header: {type: "http", request: ({path: [$c.hpath]}
                                                                     + (if $c.host != "" then {headers: {Host: [$c.host]}} else {} end))}}} else {} end)
      + (if $c.method == "xhttp" then {xhttpSettings: ({path: $c.path, mode: $c.mode} + (if $c.host != "" then {host: $c.host} else {} end))} else {} end)
      + (if $c.method == "grpc" then {grpcSettings: {serviceName: $c.path, multiMode: ($c.gmode == "multi")}} else {} end)
      + (if $c.method == "websocket" then {wsSettings: ({path: $c.path} + (if $c.host != "" then {host: $c.host} else {} end))} else {} end)
      + (if $c.method == "httpupgrade" then {httpupgradeSettings: ({path: $c.path} + (if $c.host != "" then {host: $c.host} else {} end))} else {} end)
      + (if $c.method == "mkcp" then {kcpSettings: ({} + (if $c.mtu != "" then {mtu: ($c.mtu | tonumber)} else {} end)
                                       + (if $c.tti != "" then {tti: ($c.tti | tonumber)} else {} end)
                                       + (if $c.up != "" then {uplinkCapacity: ($c.up | tonumber)} else {} end)
                                       + (if $c.down != "" then {downlinkCapacity: ($c.down | tonumber)} else {} end))}
                                    + (if $c.kmask != "" then {finalmask: {udp: [{type: "mkcp-legacy", settings: {header: (if $c.kmask == "seed" then "" else $c.kmask end), value: $c.kval}}]}} else {} end)
         else {} end)
      + (if $c.method == "hysteria" then {hysteriaSettings: {version: 2, auth: $id}}
                                        + (if $c.obfs != "" then {finalmask: {udp: [{type: "salamander", settings: {password: $c.obfs}}]}} else {} end) else {} end)
      + (if $c.method == "masque" then {masqueSettings: {user: $name, pass: $id}} else {} end)
      + (if $c.security == "tls" then {tlsSettings: ({serverName: $c.sni, fingerprint: $c.fp}
                                                    + (if $c.alpn != "" then {alpn: list($c.alpn)} else {} end)
                                                    + (if $c.pin != "" then {pinnedPeerCertSha256: $c.pin} else {} end))} else {} end)
      + (if $c.security == "reality" then {realitySettings: ({serverName: $c.sni, fingerprint: $c.fp, publicKey: $c.rpub, shortId: $c.sid}
                                                            + (if $c.spx != "" then {spiderX: $c.spx} else {} end))} else {} end))
     end) as $stream |
    {log: {loglevel: "warning"},
     inbounds: [{listen: "127.0.0.1", port: 1080, protocol: "socks", settings: {udp: true}, tag: "socks-in"}],
     outbounds: [({protocol: $c.protocol, settings: $settings, tag: "proxy"} + (if $stream then {streamSettings: $stream} else {} end)),
                 {protocol: "freedom", tag: "direct"}]}' "$(xr_meta_file "$tag")"
}

xray_links() {
    local name=$1 tag proto net port sec path link
    xray_user_get "$name" > /dev/null || { err "No user named $name."; return 1; }
    while IFS='|' read -r tag proto net port sec path; do
        [[ $proto == tunnel ]] && continue
        link=$(xray_link "$name" "$tag")
        printf '\n  %s%s%s (%s %s %s %s)\n  %s\n' "$C_YLW" "$tag" "$C_RST" "$proto" "$net" "$sec" "$port" "$link"
        [[ $link == '('* ]] && continue
        [[ $sec == tls && -n $(xr_meta "$tag" pin) && $proto != hysteria ]] && \
            warn "Self-signed certificate: the link keeps certificate checks on, so most apps need the client JSON (it pins the certificate)."
        [[ ${XRAY_QR:-0} == 1 ]] && has_cmd qrencode && qrencode -t ansiutf8 -m 1 "$link"
    done < <(xray_inbounds)
}

# =============================================================== wizard ===
# Every step returns 0 = next, 10 = back, 20 = cancel, 3 = not relevant
# (skipped in whichever direction the wizard is moving).
XR_BACK=10 XR_CANCEL=20 XR_SKIP=3

# xr_choose VAR "TITLE" DEFAULT "value|label"... - numbered menu, 0 = back.
xr_choose() {
    local __v=$1 title=$2 def=$3 n=0 i a dn=1
    shift 3
    local -a vals=()
    ui_title "$title"
    for i in "$@"; do
        n=$((n + 1)); vals+=("${i%%|*}")
        [[ ${i%%|*} == "$def" ]] && dn=$n
        ui_item "$n" "${i#*|}"
    done
    ui_line
    printf '  %s[0]%s Back\n' "$C_GRN" "$C_RST"
    while true; do
        read -r -p " ${C_WHT}Select [$dn]:${C_RST} " a || return $XR_CANCEL
        a=${a:-$dn}
        [[ $a == 0 ]] && return $XR_BACK
        if valid_int "$a" 1 "$n"; then printf -v "$__v" '%s' "${vals[a - 1]}"; return 0; fi
        err "Choose 1-$n, or 0 to go back."
    done
}

# xr_ask VAR "Prompt" DEFAULT MODE CHECK - text input.
# MODE: req (an answer is needed) | opt (Enter keeps DEFAULT, "-" clears it)
# CHECK: function validating the value (prints why it is wrong). "<" = back.
xr_ask() {
    local __v=$1 p=$2 d=$3 mode=$4 chk=${5:-} a shown
    while true; do
        shown=$d; [[ $mode == opt && -z $d ]] && shown="none"
        if [[ -n $shown ]]; then read -r -p "  $p [$shown]: " a || return $XR_CANCEL
        else read -r -p "  $p: " a || return $XR_CANCEL; fi
        [[ $a == "<" ]] && return $XR_BACK
        [[ -z $a ]] && a=$d
        [[ $mode == opt && $a == - ]] && a=''
        if [[ $mode == req && -z $a ]]; then err "This value is required (type < to go back)."; continue; fi
        if [[ -n $a && -n $chk ]] && ! "$chk" "$a"; then continue; fi
        printf -v "$__v" '%s' "$a"; return 0
    done
}
xr_v_path()  { [[ $1 =~ ^/[A-Za-z0-9/_.~-]*$ ]] || { err "Start with '/' and use letters, digits, '/', '_', '.', '~', '-'."; return 1; }; }
xr_v_name()  { [[ $1 =~ ^[A-Za-z0-9_.-]{1,40}$ ]] || { err "Use 1-40 letters, digits, '.', '_' or '-'."; return 1; }; }
xr_v_host()  { valid_domain "$1" || [[ $1 =~ ^[0-9.]+$ || $1 =~ ^[0-9a-fA-F:]+$ ]] || { err "Enter a domain name or IP address."; return 1; }; }
xr_v_hosts() { local h; for h in ${1//,/ }; do xr_v_host "$h" || return 1; done; }
xr_v_target() { [[ $1 =~ ^([A-Za-z0-9.-]+):([0-9]{1,5})$ ]] && valid_port "${BASH_REMATCH[2]}" || { err "Use host:port, e.g. www.microsoft.com:443."; return 1; }; }
xr_v_svc()   { [[ $1 =~ ^[A-Za-z0-9_.-]+$ ]] || { err "Use letters, digits, '_', '.', '-'."; return 1; }; }
xr_v_key()   { [[ $1 =~ ^[A-Za-z0-9_-]{43}$ ]] || { err "A key is 43 base64url characters (from 'xray x25519')."; return 1; }; }
xr_v_sid()   { [[ $1 =~ ^([0-9a-f]{2}){1,8}$ ]] || { err "2-16 lowercase hex characters, even length."; return 1; }; }
xr_v_secret() { [[ $1 =~ ^[A-Za-z0-9_.~-]{6,64}$ ]] || { err "Use 6-64 letters, digits, '_', '.', '-' or '~'."; return 1; }; }
xr_v_pool()  { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]] && (( BASH_REMATCH[2] >= 8 && BASH_REMATCH[2] <= 30 )) || { err "Use an IPv4 prefix /8-/30, e.g. 10.77.0.1/24."; return 1; }; }
xr_v_int()   { valid_int "$1" "$XR_MIN" "$XR_MAX" || { err "Enter a number from $XR_MIN to $XR_MAX."; return 1; }; }
xr_v_port()  { valid_port "$1" || { err "Enter a port from 1 to 65535."; return 1; }; }
xr_rand() { tr -dc "${2:-a-z0-9}" < /dev/urandom | head -c "$1"; }

# ---- steps ----
xs_name() {
    ui_title "NEW XRAY CONFIGURATION"
    info "Type < at a text prompt or 0 in a menu to go back."
    while true; do
        xr_ask W_tag "Configuration name" "${W_tag:-$(xr_rand 4 A-Za-z)}" req xr_v_name || return
        [[ -n ${XR_EDITING:-} || ! -f $(xr_meta_file "$W_tag") ]] && return 0
        err "$W_tag already exists; choose another name."; W_tag=''
    done
}
xs_proto() {
    local p; local -a opts=()
    for p in $XR_PROTOCOLS; do opts+=("$p|${XR_PROTO_LABEL[$p]}"); done
    xr_choose W_proto "PROTOCOL" "${W_proto:-vless}" "${opts[@]}"
}
xs_method() {
    local m; local -a opts=()
    local -a ms=(${XR_PROTO_METHODS[$W_proto]})
    if (( ${#ms[@]} == 1 )); then W_method=${ms[0]}; return $XR_SKIP; fi
    for m in "${ms[@]}"; do opts+=("$m|${XR_METHOD_LABEL[$m]}"); done
    xr_choose W_method "NETWORK / TRANSPORT" "${W_method:-raw}" "${opts[@]}" || return
    [[ $W_method == websocket ]] && warn "Xray marks WebSocket as deprecated; XHTTP or HTTPUpgrade are its successors."
    return 0
}
xs_enc() {
    [[ $W_proto == vless ]] || { W_enc=0; return $XR_SKIP; }
    local c=off out
    [[ $W_enc == 1 ]] && c=on
    xr_choose c "VLESS ENCRYPTION (PROTOCOL-NATIVE)" "$c" \
        "off|Off - decryption \"none\" (use TLS or REALITY for security)" \
        "on|On - ML-KEM-768 + X25519 handshake (works even without TLS)" || return
    if [[ $c == off ]]; then W_enc=0 W_dec='' W_encc=none; return 0; fi
    if [[ $W_enc != 1 || -z $W_dec ]]; then
        out=$("$XRAY_BIN" vlessenc 2>/dev/null | awk '/Authentication: X25519/ {f = 1} f && /"decryption"/ {print; f2 = 1} f2 && /"encryption"/ {print; exit}')
        W_dec=$(sed -n 's/.*"decryption": *"\([^"]*\)".*/\1/p' <<< "$out")
        W_encc=$(sed -n 's/.*"encryption": *"\([^"]*\)".*/\1/p' <<< "$out")
        [[ -n $W_dec && -n $W_encc ]] || { err "xray vlessenc did not produce keys."; return $XR_BACK; }
    fi
    W_enc=1
}
xs_security() {
    local s; local -a opts=()
    local -a ss=($(xr_security_options "$W_proto" "$W_method"))
    if (( ${#ss[@]} == 1 )); then W_security=${ss[0]}; return $XR_SKIP; fi
    for s in "${ss[@]}"; do
        case $s in
            none) opts+=("none|NONE") ;; tls) opts+=("tls|TLS") ;; reality) opts+=("reality|REALITY") ;;
        esac
    done
    xr_choose W_security "TRANSPORT LAYER SECURITY" "${W_security:-$( xr_in reality "${ss[*]}" && echo reality || echo tls)}" "${opts[@]}" || return
    if [[ $W_security == none ]]; then
        case $W_proto in
            vless) [[ $W_enc == 1 ]] || warn "Without TLS, REALITY or VLESS Encryption, Xray clients only connect to private addresses or through a TLS front (CDN / reverse proxy)." ;;
            trojan) warn "Trojan without TLS only works on private networks or behind a TLS front." ;;
            vmess) warn "VMess encrypts the payload, but without TLS it is easy to detect." ;;
            socks|http) warn "This proxy is unencrypted; credentials and traffic can be read on the way." ;;
        esac
    fi
    return 0
}
xs_flow() {
    xr_flow_allowed "$W_proto" "$W_method" "$W_security" "$W_enc" || { W_flow='' W_cflow=''; return $XR_SKIP; }
    local f=${W_cflow:-none}
    xr_choose f "SELECT FLOW CONTROL" "$f" \
        "none|None / Empty" \
        "xtls-rprx-vision|xtls-rprx-vision" \
        "xtls-rprx-vision-udp443|xtls-rprx-vision-udp443 (client side; lets QUIC through)" || return
    if [[ $f == none ]]; then W_flow='' W_cflow=''; else W_flow=xtls-rprx-vision W_cflow=$f; fi
    [[ $f == xtls-rprx-vision-udp443 ]] && info "The server uses xtls-rprx-vision; the -udp443 variant only exists on the client."
    return 0
}
xs_port() {
    local d=8880
    xr_in "$W_security" "tls reality" && d=443
    xr_ask W_port "Port" "${W_port:-$d}" req xr_v_port
}
xs_address() {
    xr_ask W_addr "Server address in client links (IP or domain)" "${W_addr:-$(sys_ip)}" req xr_v_host
}
xs_transport() {
    case $W_method in
        raw)
            [[ $W_proto =~ ^(vless|vmess|trojan)$ ]] || { W_header=none; return $XR_SKIP; }
            local h=${W_header:-none}
            if [[ $W_security == none ]]; then
                xr_choose h "RAW HEADER" "$h" "none|None" "http|HTTP camouflage (plain HTTP request/response headers)" || return
            else h=none; fi
            W_header=$h
            if [[ $h == http ]]; then
                xr_ask W_hpath "HTTP request path" "${W_hpath:-/}" req xr_v_path || return
                xr_ask W_host "HTTP Host header" "${W_host:-}" opt xr_v_host || return
            fi ;;
        xhttp)
            xr_ask W_path "XHTTP path" "${W_path:-/$(xr_rand 10 A-Za-z0-9)}" req xr_v_path || return
            xr_ask W_host "Host (Enter = any)" "${W_host:-}" opt xr_v_host || return
            if [[ $W_security == none ]]; then
                xr_choose W_mode "XHTTP MODE (CLIENT)" "${W_mode:-auto}" "auto|auto" "packet-up|packet-up (works through any HTTP/1.1 proxy or CDN)" || return
            else
                xr_choose W_mode "XHTTP MODE (CLIENT)" "${W_mode:-auto}" "auto|auto (recommended)" "packet-up|packet-up" \
                    "stream-up|stream-up (needs HTTP/2 or HTTP/3 end to end)" "stream-one|stream-one (needs HTTP/2 or HTTP/3 end to end)" || return
            fi ;;
        grpc)
            xr_ask W_path "gRPC service name" "${W_path:-$(xr_rand 8)}" req xr_v_svc || return
            xr_choose W_gmode "GRPC MODE (CLIENT)" "${W_gmode:-gun}" "gun|gun" "multi|multi (multiMode)" || return ;;
        websocket)
            xr_ask W_path "WebSocket path" "${W_path:-/$(xr_rand 8)}" req xr_v_path || return
            xr_ask W_host "Host (Enter = any)" "${W_host:-}" opt xr_v_host || return
            XR_MIN=0 XR_MAX=600; xr_ask W_hb "Heartbeat period in seconds (Enter = off)" "${W_hb:-}" opt xr_v_int || return ;;
        httpupgrade)
            xr_ask W_path "HTTPUpgrade path" "${W_path:-/$(xr_rand 8)}" req xr_v_path || return
            xr_ask W_host "Host (Enter = any)" "${W_host:-}" opt xr_v_host || return ;;
        mkcp)
            info "mKCP sends over UDP. Press Enter to keep each default."
            XR_MIN=576 XR_MAX=1460; xr_ask W_mtu "MTU" "${W_mtu:-}" opt xr_v_int || return
            XR_MIN=10 XR_MAX=100;   xr_ask W_tti "TTI in ms" "${W_tti:-}" opt xr_v_int || return
            XR_MIN=0 XR_MAX=1000;   xr_ask W_up "Uplink capacity MB/s" "${W_up:-}" opt xr_v_int || return
            XR_MIN=0 XR_MAX=1000;   xr_ask W_down "Downlink capacity MB/s" "${W_down:-}" opt xr_v_int || return
            XR_MIN=1 XR_MAX=10;     xr_ask W_cwnd "Congestion window multiplier" "${W_cwnd:-}" opt xr_v_int || return
            local km=${W_kmask:-none}
            xr_choose km "MKCP OBFUSCATION (FINALMASK)" "$km" "none|None" "seed|Seed / password (AES-128-GCM)" \
                "dns|Header: DNS" "dtls|Header: DTLS 1.2" "srtp|Header: SRTP" "utp|Header: uTP" "wechat|Header: WeChat video" "wireguard|Header: WireGuard" || return
            [[ $km == none ]] && km=''
            W_kmask=$km W_kval=''
            if [[ $km == seed ]]; then xr_ask W_kval "Seed" "$(xr_rand 12 A-Za-z0-9)" req xr_v_secret || return
            elif [[ $km == dns ]]; then xr_ask W_kval "Domain for the DNS header" "www.example.com" req xr_v_host || return; fi ;;
        hysteria)
            xr_ask W_obfs "Salamander obfuscation password (Enter = random, - = off)" "${W_obfs:-$(xr_rand 24 A-Za-z0-9)}" opt xr_v_secret || return ;;
        masque)
            xr_ask W_pool "Tunnel address pool (server address/prefix)" "${W_pool:-10.77.0.1/24}" req xr_v_pool || return
            XR_MIN=1280 XR_MAX=65535; xr_ask W_qmtu "Tunnel MTU" "${W_qmtu:-}" opt xr_v_int || return ;;
        *) return $XR_SKIP ;;
    esac
    return 0
}
xs_proto_settings() {
    case $W_proto in
        shadowsocks)
            local m; local -a opts=()
            for m in $XR_SS_METHODS; do opts+=("$m|$m"); done
            xr_choose W_ssm "SHADOWSOCKS CIPHER" "${W_ssm:-chacha20-ietf-poly1305}" "${opts[@]}" || return
            if [[ $W_ssm == 2022-* && ( -z $W_sskey || $(printf '%s' "$W_sskey" | base64 -d 2>/dev/null | wc -c) -ne $(xr_ss_keylen "$W_ssm") ) ]]; then
                W_sskey=$(openssl rand -base64 "$(xr_ss_keylen "$W_ssm")")
            fi ;;
        socks)
            local u=${W_udp:-1}
            xr_choose u "SOCKS UDP" "$u" "1|Allow UDP (UDP ASSOCIATE)" "0|TCP only" || return
            W_udp=$u ;;
        tunnel)
            warn "A tunnel forwards everything arriving on its port to one target; anyone who can reach the port can use it."
            xr_ask W_ttarget "Target address" "${W_ttarget:-127.0.0.1}" req xr_v_host || return
            xr_ask W_tport "Target port" "${W_tport:-22}" req xr_v_port || return
            xr_choose W_tnet "NETWORK" "${W_tnet:-tcp}" "tcp|TCP" "udp|UDP" "tcp,udp|TCP and UDP" || return ;;
        *) return $XR_SKIP ;;
    esac
    return 0
}
xs_tls() {
    [[ $W_security == tls ]] || return $XR_SKIP
    local cn a
    if [[ -n $W_cert && -s $W_cert ]] && ! confirm "Keep the certificate $(basename "$(dirname "$W_cert")")/$(basename "$W_cert")?"; then W_cert=''; fi
    if [[ -z $W_cert || ! -s $W_cert ]]; then ssl_pick W_cert W_key || return $XR_BACK; fi
    W_pin=''
    [[ $W_cert == "$SSL_SELF"/* ]] && W_pin=$(openssl x509 -in "$W_cert" -outform der 2>/dev/null | sha256sum | awk '{print $1}')
    cn=$(openssl x509 -noout -subject -in "$W_cert" 2>/dev/null | sed -n 's/.*CN *= *//p')
    xr_ask W_sni "SNI / server name clients ask for" "${W_sni:-${cn:-$W_addr}}" req xr_v_host || return
    # An HTTP proxy over TLS speaks HTTP/1.1 CONNECT; offering h2 breaks it.
    case $( [[ $W_proto == http ]] && echo httpproxy || echo "$W_method") in
        httpproxy) W_alpn=http/1.1 ;;
        grpc) W_alpn=h2 ;;
        websocket|httpupgrade) W_alpn=http/1.1 ;;
        hysteria) W_alpn=h3 ;;
        mkcp) W_alpn='' ;;
        xhttp) a=${W_alpn:-h2,http/1.1}
               xr_choose a "ALPN" "$a" "h2,http/1.1|h2, http/1.1 (TCP)" "h3|h3 (XHTTP over HTTP/3, UDP)" || return
               W_alpn=$a ;;
        masque) a=${W_alpn:-h3,h2}
               xr_choose a "ALPN (MASQUE HTTP VERSION)" "$a" "h3,h2|h3 and h2 (UDP and TCP on the same port)" "h3|h3 only (UDP)" "h2|h2 only (TCP)" || return
               W_alpn=$a ;;
        *) a=${W_alpn:-h2,http/1.1}
           xr_choose a "ALPN" "$a" "h2,http/1.1|h2, http/1.1" "http/1.1|http/1.1" "h2|h2" || return
           W_alpn=$a ;;
    esac
    xr_choose W_minv "MINIMUM TLS VERSION" "${W_minv:-}" "|Default (Xray: 1.2)" "1.2|1.2" "1.3|1.3" || return
    if [[ $W_method != hysteria ]]; then
        local f; local -a fo=(); for f in $XR_FINGERPRINTS; do fo+=("$f|$f"); done
        xr_choose W_fp "CLIENT TLS FINGERPRINT (uTLS)" "${W_fp:-chrome}" "${fo[@]}" || return
    fi
    [[ -n $W_pin ]] && info "Self-signed certificate: clients verify it by its SHA-256 pin (written into the client JSON)."
    return 0
}
xs_reality() {
    [[ $W_security == reality ]] || return $XR_SKIP
    local k out
    info "REALITY borrows the TLS handshake of a real website (the target)."
    xr_ask W_target "Target (dest) host:port" "${W_target:-www.microsoft.com:443}" req xr_v_target || return
    xr_ask W_snis "Server names (comma-separated)" "${W_snis:-${W_target%%:*}}" req xr_v_hosts || return
    W_sni=${W_snis%%,*}
    xr_ask k "Private key (Enter = keep/generate)" "" opt xr_v_key || return
    if [[ -n $k ]]; then W_rpriv=$k
    elif [[ -z $W_rpriv ]]; then W_rpriv=$("$XRAY_BIN" x25519 | awk '/PrivateKey/ {print $2}'); fi
    out=$("$XRAY_BIN" x25519 -i "$W_rpriv" 2>/dev/null)
    W_rpub=$(awk -F': ' '/PublicKey/ {print $2}' <<< "$out")
    [[ -n $W_rpub ]] || { err "Could not derive the public key from that private key."; W_rpriv=''; return $XR_SKIP; }
    xr_ask W_sid "Short ID (hex)" "${W_sid:-$(openssl rand -hex 8)}" req xr_v_sid || return
    xr_ask W_spx "SpiderX (client path)" "${W_spx:-/}" opt || return
    local f; local -a fo=(); for f in $XR_FINGERPRINTS; do fo+=("$f|$f"); done
    xr_choose W_fp "CLIENT TLS FINGERPRINT (uTLS)" "${W_fp:-chrome}" "${fo[@]}" || return
    info "Public key (for clients): $W_rpub"
}

xr_summary() {
    ui_title "CONFIGURATION SUMMARY"
    ui_kv "Name:" "$W_tag"
    ui_kv "Protocol:" "${XR_PROTO_LABEL[$W_proto]}"
    ui_kv "Network:" "${XR_METHOD_LABEL[$W_method]}"
    ui_kv "Security:" "$(tr a-z A-Z <<< "$W_security")"
    [[ $W_proto == vless ]] && ui_kv "VLESS Encryption:" "$( [[ $W_enc == 1 ]] && echo on || echo off)"
    [[ $W_proto == vless ]] && ui_kv "Flow:" "${W_cflow:-none}"
    ui_kv "Port:" "$W_port"
    ui_kv "Address:" "$W_addr"
    case $W_method in
        xhttp) ui_kv "Path / mode:" "$W_path / $W_mode" ;;
        websocket|httpupgrade) ui_kv "Path:" "$W_path" ;;
        grpc) ui_kv "Service:" "$W_path ($W_gmode)" ;;
        mkcp) ui_kv "mKCP mask:" "${W_kmask:-none}" ;;
        hysteria) ui_kv "Obfuscation:" "${W_obfs:+salamander}${W_obfs:-none}" ;;
        masque) ui_kv "Address pool:" "$W_pool" ;;
    esac
    [[ $W_security == tls ]] && ui_kv "SNI / ALPN:" "$W_sni / ${W_alpn:-default}"
    [[ $W_security == reality ]] && { ui_kv "Target:" "$W_target"; ui_kv "Server names:" "$W_snis"; ui_kv "Short ID:" "$W_sid"; }
    [[ $W_proto == shadowsocks ]] && ui_kv "Cipher:" "$W_ssm"
    [[ $W_proto == tunnel ]] && ui_kv "Forward to:" "$W_ttarget:$W_tport ($W_tnet)"
    ui_line
}

XR_STEPS=(xs_name xs_proto xs_method xs_enc xs_security xs_flow xs_port xs_address xs_transport xs_proto_settings xs_tls xs_reality)

# xr_wizard [TAG] - new configuration, or edit TAG. Returns 0 when saved.
xr_wizard() {
    local edit=${1:-} i=0 dir=1 rc a msg
    xr_wizard_reset
    if [[ -n $edit ]]; then xr_load_meta "$edit"; XR_EDITING=$edit; i=1; else XR_EDITING=''; fi
    while true; do
        if (( i < 0 )); then return 1; fi
        if (( i >= ${#XR_STEPS[@]} )); then
            clear 2>/dev/null
            if ! msg=$(xr_check); then err "$msg"; i=$(( ${#XR_STEPS[@]} - 1 )); dir=-1; ui_pause; continue; fi
            xr_summary
            printf '  %s[1]%s Save and Activate   %s[2]%s Edit settings   %s[0]%s Cancel\n' "$C_GRN" "$C_RST" "$C_GRN" "$C_RST" "$C_GRN" "$C_RST"
            ui_line
            read -r -p " ${C_WHT}Enter an option:${C_RST} " a || return 1
            case $a in
                1) if xr_commit "$edit"; then xr_fw_open; log_event "xray inbound $W_tag ${edit:+edited}${edit:-added}"
                       ok "Configuration $W_tag is active."; return 0
                   fi
                   ui_pause; i=$(( ${#XR_STEPS[@]} - 1 )); dir=-1; continue ;;
                2) i=$( [[ -n $edit ]] && echo 1 || echo 0 ); dir=1; continue ;;
                *) info "Cancelled; nothing was changed."; return 1 ;;
            esac
        fi
        [[ $edit && ${XR_STEPS[i]} == xs_name ]] && { i=$((i + dir)); continue; }
        clear 2>/dev/null
        "${XR_STEPS[i]}"; rc=$?
        case $rc in
            0) dir=1; i=$((i + 1)) ;;
            "$XR_SKIP") i=$((i + dir)) ;;
            "$XR_BACK") dir=-1; i=$((i - 1)); [[ $edit ]] && (( i < 1 )) && return 1 ;;
            *) info "Cancelled; nothing was changed."; return 1 ;;
        esac
    done
}

xr_wizard_reset() {
    local v
    for v in tag proto method security port addr sni alpn fp minv flow cflow enc encc dec path host mode header hpath hb gmode \
             mtu tti up down cwnd kmask kval pin cert key target snis rpriv rpub sid spx ssm sskey obfs pool qmtu udp ttarget tport tnet; do
        printf -v "W_$v" "%s" ""     # defined but empty: the panel runs with set -u
    done
    W_enc=0 W_encc=none
}

# xray_add_kv key=value... - non-interactive add (tests and scripts).
# Keys are the W_* names: tag proto method security port addr sni alpn fp
# flow cflow enc path host mode header hpath gmode mtu tti up down cwnd kmask
# kval cert key target snis sid spx ssm obfs pool qmtu udp ttarget tport tnet.
xray_add_kv() {
    local kv k out
    xr_wizard_reset
    for kv in "$@"; do k=${kv%%=*}; printf -v "W_$k" '%s' "${kv#*=}"; done
    : "${W_addr:=$(sys_ip)}" "${W_mode:=auto}" "${W_gmode:=gun}" "${W_fp:=chrome}" "${W_header:=none}" "${W_hpath:=/}"
    # Like the wizard: a single possible transport or security is implied.
    if [[ -z ${W_method:-} && -n ${W_proto:-} && ${XR_PROTO_METHODS[$W_proto]:-} != *" "* ]]; then W_method=${XR_PROTO_METHODS[$W_proto]:-}; fi
    if [[ -z ${W_security:-} && -n ${W_method:-} && -n ${W_proto:-} ]] && xr_in "$W_proto" "$XR_PROTOCOLS"; then
        k=$(xr_security_options "${W_proto:-}" "$W_method" 2>/dev/null); [[ $k != *" "* ]] && W_security=$k
    fi
    [[ ${W_proto:-} == http && ${W_security:-} == tls ]] && W_alpn=http/1.1
    [[ -n $W_flow && -z ${W_cflow:-} ]] && W_cflow=$W_flow
    if [[ $W_enc == 1 && -z ${W_dec:-} ]]; then
        out=$("$XRAY_BIN" vlessenc 2>/dev/null | awk '/Authentication: X25519/ {f = 1} f && /"decryption"/ {print; f2 = 1} f2 && /"encryption"/ {print; exit}')
        W_dec=$(sed -n 's/.*"decryption": *"\([^"]*\)".*/\1/p' <<< "$out"); W_encc=$(sed -n 's/.*"encryption": *"\([^"]*\)".*/\1/p' <<< "$out")
    fi
    if [[ $W_security == reality ]]; then
        [[ -n ${W_rpriv:-} ]] || W_rpriv=$("$XRAY_BIN" x25519 | awk '/PrivateKey/ {print $2}')
        W_rpub=$("$XRAY_BIN" x25519 -i "$W_rpriv" | awk -F': ' '/PublicKey/ {print $2}')
        : "${W_sid:=$(openssl rand -hex 8)}" "${W_snis:=${W_target%%:*}}"
        W_sni=${W_sni:-${W_snis%%,*}}
    fi
    if [[ $W_security == tls ]]; then
        [[ $W_cert == "$SSL_SELF"/* || ${W_selfsigned:-0} == 1 ]] && W_pin=$(openssl x509 -in "$W_cert" -outform der | sha256sum | awk '{print $1}')
        : "${W_sni:=$(openssl x509 -noout -subject -in "$W_cert" 2>/dev/null | sed -n 's/.*CN *= *//p')}"
        case $W_method in grpc) : "${W_alpn:=h2}" ;; websocket|httpupgrade) : "${W_alpn:=http/1.1}" ;; hysteria) W_alpn=h3 ;; masque) : "${W_alpn:=h3,h2}" ;; esac
    fi
    if [[ $W_proto == shadowsocks ]]; then
        : "${W_ssm:=chacha20-ietf-poly1305}"
        [[ $W_ssm == 2022-* ]] && W_sskey=$(openssl rand -base64 "$(xr_ss_keylen "$W_ssm")")
    fi
    xr_commit || return 1
    xr_fw_open
    log_event "xray inbound $W_tag added"
}

# Backward-compatible API of v0.3: PROTO NET PORT PATH TLS HOST [CERT KEY] [NAME]
xray_add_inbound() {
    local m=$2 s=none
    case $m in ws) m=websocket ;; tcp) m=raw ;; kcp) m=mkcp ;; esac
    (( $5 )) && s=tls
    xray_add_kv "tag=${9:-vpsp-$1-$2-$3}" "proto=$1" "method=$m" "security=$s" "port=$3" "path=$4" \
        "addr=$6" "sni=$6" "cert=${7:-}" "key=${8:-}" $( [[ ${7:-} == "$SSL_SELF"/* ]] && echo selfsigned=1 )
}

# ================================================================ menus ===
xray_info() {
    [[ -x $XRAY_BIN ]] && printf ' %sVERSION:%s %s\n' "$C_GRN" "$C_RST" "$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1 {print $2}')"
    local t any=0
    if xray_installed; then
        for t in $(xr_tags); do
            any=1
            printf '  %s%-16s%s %-11s %-11s %-7s %-5s %s\n' "$C_YLW" "${t:0:16}" "$C_RST" "$(xr_meta "$t" protocol)" \
                "$(xr_meta "$t" method)" "$(xr_meta "$t" security)" "$(xr_meta "$t" port)" \
                "$(xr_enabled "$t" && echo "${C_GRN}ON${C_RST}" || echo "${C_RED}OFF${C_RST}")"
        done
        (( any )) || ui_center "NO CONFIGURATION YET - ADD ONE WITH OPTION 1" "$C_YLW"
    else
        ui_center "VLESS VMESS TROJAN SS HYSTERIA2 MASQUE - REALITY / TLS" "$C_YLW"
    fi
    return 0
}

# xr_pick_tag VAR [enabled|disabled|all]
xr_pick_tag() {
    local __v=$1 want=${2:-all} __t __n=0 __c
    local -a tags=()
    for __t in $(xr_tags); do
        case $want in enabled) xr_enabled "$__t" || continue ;; disabled) xr_enabled "$__t" && continue ;; esac
        __n=$((__n + 1)); tags+=("$__t")
        ui_item "$__n" "$__t  ($(xr_meta "$__t" protocol) $(xr_meta "$__t" method) $(xr_meta "$__t" security) $(xr_meta "$__t" port))"
    done
    (( __n )) || { info "There is no matching configuration."; return 1; }
    ui_line
    ask __c "Enter an option" || return 1
    valid_int "$__c" 1 "$__n" || { err "Invalid option."; return 1; }
    printf -v "$__v" '%s' "${tags[__c - 1]}"
}
# Backward-compatible name used by older code.
xray_pick_inbound() { xr_pick_tag "$1" enabled; }

m_xray_add()    { xr_wizard; }
m_xray_edit_ib() { local t; xr_pick_tag t all && xr_wizard "$t"; }
m_xray_view()   {
    local t; xr_pick_tag t all || return
    ui_line; jq 'del(.rpriv, .dec, .sskey, .inbound.streamSettings.realitySettings.privateKey, .inbound.settings.decryption)' "$(xr_meta_file "$t")"
    xr_enabled "$t" && { ui_sep; jq --arg t "$t" '.inbounds[] | select(.tag == $t) | del(.settings.clients, .settings.users, .settings.accounts)
        | if .streamSettings.realitySettings.privateKey then .streamSettings.realitySettings.privateKey = "(hidden)" else . end
        | if (.settings.decryption // "none") != "none" then .settings.decryption = "(hidden)" else . end' "$XRAY_CONF"; }
}
m_xray_toggle() {
    local t; xr_pick_tag t all || return
    if xr_enabled "$t"; then confirm "Disable $t? Its settings are kept." && xray_disable_inbound "$t"; else xray_enable_inbound "$t"; fi
}
m_xray_remove() { local t; xr_pick_tag t all && confirm "Remove $t permanently?" && xray_remove_inbound "$t"; }
m_xray_edit() {
    local tmp; tmp=$(mktemp --suffix=.json)
    cp "$XRAY_CONF" "$tmp"
    "${EDITOR:-nano}" "$tmp"
    jq . "$tmp" > /dev/null 2>&1 || { rm -f "$tmp"; err "That is not valid JSON; nothing was changed."; return 1; }
    xray_save "$(cat "$tmp")" && ok "Configuration saved."
    rm -f "$tmp"
}
m_xray_uninstall() { confirm "Uninstall Xray and delete all of its users?" && xray_uninstall; }
m_xray_install()   { xray_install && m_xray_add; }
xray_logsize() { du -ch "$XRAY_LOGDIR"/*.log 2>/dev/null | awk 'END {print $1}'; }
m_xray_matrix() {
    local p
    printf '  %s%-34s %-38s %s%s\n' "$C_YLW" "PROTOCOL" "TRANSPORTS" "SECURITY" "$C_RST"
    for p in $XR_PROTOCOLS; do printf '  %-34s %-38s %s\n' "${XR_PROTO_LABEL[$p]:0:34}" "${XR_PROTO_METHODS[$p]}" "${XR_PROTO_SECURITY[$p]}"; done
    ui_sep
    info "REALITY: RAW, XHTTP, gRPC only. Hysteria and MASQUE require TLS."
    info "Vision flow: VLESS over RAW with TLS/REALITY, or with VLESS Encryption."
    info "Removed from Xray and never offered: $XR_REMOVED_METHODS."
}

xray_menu() {
    local -a items
    while true; do
        if xray_installed; then
            xray_migrate
            items=("ADD XRAY CONFIGURATION|m_xray_add"
                   "EDIT A CONFIGURATION|m_xray_edit_ib"
                   "VIEW A CONFIGURATION|m_xray_view"
                   "ENABLE / DISABLE A CONFIGURATION|m_xray_toggle"
                   "REMOVE A CONFIGURATION|m_xray_remove"
                   -
                   "COMPATIBILITY TABLE|m_xray_matrix"
                   "VIEW FULL JSON CONFIGURATION|jq . $XRAY_CONF"
                   "EDIT FULL JSON CONFIGURATION (nano)|m_xray_edit"
                   -
                   "TRAFFIC CONTROL|soon"
                   -
                   "LOG ACCESS/ERROR $(xray_logsize)|tail -n 40 $XRAY_LOGDIR/error.log $XRAY_LOGDIR/access.log"
                   "LIVE LOG|follow_log tail -n 30 -f $XRAY_LOGDIR/access.log $XRAY_LOGDIR/error.log"
                   -
                   "SERVICE STATUS|show_service_status vpspanel-xray"
                   "RESTART SERVICE|restart_service vpspanel-xray"
                   "START/STOP SERVICE $(st_state "$(svc_state vpspanel-xray)")|toggle_service vpspanel-xray"
                   "@UNINSTALL|m_xray_uninstall")
        else
            items=("INSTALL V2RAY/XRAY|m_xray_install")
        fi
        menu_show "V2RAY AND XRAY MANAGER" xray_info "${items[@]}" || return 0
    done
}

# ---------------------------------------------------- account manager ---
xray_user_table() {
    local name id exp created now n=0
    now=$(now_epoch)
    [[ -s $XRAY_USERS ]] || { ui_center "THERE ARE NO USERS YET" "$C_YLW"; return 1; }
    while IFS=: read -r name id exp created; do
        [[ -n $name ]] || continue
        n=$((n + 1))
        printf ' %3s- %sNAME:%s %-20s %sEXP:%s %-11s %sREMAIN:%s %s\n' "$n" "$C_GRN" "$C_WHT" "$name" "$C_GRN" "$C_WHT" \
            "$(date -d "@$exp" +%b%d/%y)" "$C_GRN" "$C_WHT" "$(days_left "$exp")"
        printf '      %sUUID:%s %s %s\n' "$C_GRN" "$C_RST" "$id" "$( (( exp > now )) && echo "${C_GRN}ACTIVE${C_RST}" || echo "${C_RED}EXPIRED${C_RST}")"
    done < "$XRAY_USERS"
}

m_xu_pick() {
    local __v=$1 __n
    xray_user_table || return 1
    ui_line
    ask __n "Number or name" || return 1
    [[ -n $__n ]] || return 1
    if [[ $__n =~ ^[0-9]+$ ]]; then __n=$(sed -n "${__n}p" "$XRAY_USERS" | cut -d: -f1); fi
    xray_user_get "$__n" > /dev/null || { err "No such user."; return 1; }
    printf -v "$__v" '%s' "$__n"
}

m_xu_new() {
    local n d id
    [[ -n $(xray_inbounds) ]] || { err "Add a configuration in Protocol configuration > V2Ray/Xray first."; return 1; }
    clear 2>/dev/null; ui_title "NEW V2RAY/XRAY USER"
    xray_user_table; ui_line
    ask n "NAME" || return
    ask id "UUID (Enter = random)" || return
    ask d "EXPIRES IN (days)" "$DEFAULT_DAYS" || return
    xray_user_add "$n" "$d" "$id" || return
    ui_line; xray_links "$n"
    ui_line
    if confirm "Show a client JSON?"; then local t; xr_pick_tag t enabled && xray_client_json "$n" "$t"; fi
}
m_xu_del()   { local n; clear 2>/dev/null; ui_title "REMOVE V2RAY/XRAY USER"; m_xu_pick n && confirm "Delete $n?" && xray_user_del "$n"; }
m_xu_renew() { local n d; clear 2>/dev/null; ui_title "RENEW V2RAY/XRAY USER"; m_xu_pick n && ask d "EXPIRES IN (days from today)" "$DEFAULT_DAYS" && xray_user_renew "$n" "$d"; }
m_xu_info()  {
    local n row t
    clear 2>/dev/null; ui_title "V2RAY/XRAY USER INFORMATION"
    m_xu_pick n || return
    row=$(xray_user_get "$n")
    ui_line
    ui_kv "User:" "$n"
    ui_kv "UUID/password:" "$(cut -d: -f2 <<< "$row")"
    ui_kv "Expires:" "$(fmt_date "$(cut -d: -f3 <<< "$row")") ($(days_left "$(cut -d: -f3 <<< "$row")") day(s) left)"
    XRAY_QR=0 xray_links "$n"
    ui_line
    if confirm "Show QR codes?"; then apt_install qrencode > /dev/null && XRAY_QR=1 xray_links "$n"; fi
    if confirm "Show a client JSON?"; then xr_pick_tag t enabled && xray_client_json "$n" "$t"; fi
}

xray_users_menu() {
    if ! xray_installed; then
        warn "Xray is not installed."
        info "Install it in Protocol configuration > V2Ray/Xray."
        ui_pause
        return 0
    fi
    while menu_show "V2RAY AND XRAY USER ADMINISTRATION" - \
        "NEW USER|m_xu_new" \
        "REMOVE USER|m_xu_del" \
        "RENEW USER|m_xu_renew" \
        "USER INFORMATION (LINKS, QR, JSON)|m_xu_info" \
        "RESET TRAFFIC STATS|soon"
    do :; done
}

# ============================================================== locking ===
# Every change reads the configuration, edits it and writes it back. The
# guard timer (xray_enforce, every minute) and the panel can run at the same
# time, so each change holds one lock; otherwise one could undo the other.
xr_locked() {
    local fd r
    mkdir -p "$XRAY_DIR" 2>/dev/null
    exec {fd}>>"$XRAY_DIR/.lock" || { "$@"; return; }
    if ! flock -w 120 "$fd"; then exec {fd}>&-; err "Another Xray change is still running; try again."; return 1; fi
    "$@"; r=$?
    exec {fd}>&-
    return $r
}
xr_commit()            { xr_locked _xr_commit "$@"; }
xray_remove_inbound()  { xr_locked _xray_remove_inbound "$@"; }
xray_disable_inbound() { xr_locked _xray_disable_inbound "$@"; }
xray_enable_inbound()  { xr_locked _xray_enable_inbound "$@"; }
xray_user_add()        { xr_locked _xray_user_add "$@"; }
xray_user_del()        { xr_locked _xray_user_del "$@"; }
xray_user_renew()      { xr_locked _xray_user_renew "$@"; }
xray_enforce()         { xray_installed || return 0; xr_locked _xray_enforce "$@"; }
