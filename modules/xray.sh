# shellcheck shell=bash
# vpspanel module: V2Ray/Xray (Xray-core, MPL-2.0, downloaded from the official
# XTLS GitHub releases and verified against the published SHA-256 digest).
#
# Inbounds (as offered by ADMRufu): VLESS, VMess, Trojan or Shadowsocks over
# TCP, WebSocket, gRPC or XHTTP, each with TLS on or off (Shadowsocks: TCP/UDP
# without TLS). Users live in $XRAY_DIR/users.db
# ("name:uuid:expire_epoch:created_epoch"); the UUID is also the Trojan and
# Shadowsocks password. Every user is added to every inbound, and the guard
# timer removes users when they expire.

XRAY_BIN=/usr/local/bin/xray
XRAY_SHARE=/usr/local/share/xray
XRAY_DIR="$VPSP_ETC/xray"
XRAY_CONF="$XRAY_DIR/config.json"
XRAY_USERS="$XRAY_DIR/users.db"
XRAY_HOSTS="$XRAY_DIR/hosts"          # "tag host" - address put in share links
XRAY_LOGDIR=/var/log/vpspanel-xray
XRAY_UNIT=/etc/systemd/system/vpspanel-xray.service
XRAY_SS_METHOD=chacha20-ietf-poly1305

xray_installed() { [[ -x $XRAY_BIN && -f $XRAY_UNIT && -f $XRAY_CONF ]]; }

xray_arch() {
    case $(uname -m) in
        x86_64|amd64)  echo 64 ;;
        aarch64|arm64) echo arm64-v8a ;;
        *) return 1 ;;
    esac
}

xray_download() {
    local arch tag tmp url
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
    local want have
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
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
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

# xray_save JSON - validate a new configuration, then install it and restart.
xray_save() {
    local tmp
    # Xray picks the parser from the file extension, so keep ".json".
    tmp=$(mktemp --suffix=.json "$XRAY_DIR/.config.XXXXXX") || return 1
    printf '%s\n' "$1" > "$tmp"
    chgrp "$VPSP_SVC_USER" "$tmp" && chmod 640 "$tmp"
    if ! XRAY_LOCATION_ASSET=$XRAY_SHARE "$XRAY_BIN" run -test -config "$tmp" > /dev/null 2>&1; then
        rm -f "$tmp"; err "Xray rejected the configuration; nothing was changed."; return 1
    fi
    mv -f "$tmp" "$XRAY_CONF"
    if systemctl is-enabled --quiet vpspanel-xray 2>/dev/null; then
        systemctl restart vpspanel-xray || { err "Xray failed to restart. See: journalctl -u vpspanel-xray"; return 1; }
    fi
}

xray_install() {
    has_systemd || { err "Xray management requires systemd."; return 1; }
    [[ -x $XRAY_BIN ]] || xray_download || return 1
    svc_user_ensure || return 1
    mkdir -p "$XRAY_DIR" "$XRAY_LOGDIR"
    chmod 750 "$XRAY_DIR"; chgrp "$VPSP_SVC_USER" "$XRAY_DIR"
    chown "$VPSP_SVC_USER:$VPSP_SVC_USER" "$XRAY_LOGDIR"
    touch "$XRAY_USERS" "$XRAY_HOSTS"; chmod 600 "$XRAY_USERS"
    [[ -f $XRAY_CONF ]] || { xray_base_config > "$XRAY_CONF"; chgrp "$VPSP_SVC_USER" "$XRAY_CONF"; chmod 640 "$XRAY_CONF"; }
    xray_write_unit
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

# xray_client_obj PROTO NAME UUID - the client entry for one inbound protocol.
xray_client_obj() {
    case $1 in
        trojan)      jq -cn --arg e "$2" --arg p "$3" '{password: $p, email: $e}' ;;
        shadowsocks) jq -cn --arg e "$2" --arg p "$3" --arg m "$XRAY_SS_METHOD" '{password: $p, method: $m, email: $e}' ;;
        *)           jq -cn --arg e "$2" --arg p "$3" '{id: $p, email: $e}' ;;
    esac
}

# Current (unexpired) users as client objects for PROTO.
xray_clients_json() {
    local now name id exp created
    now=$(now_epoch)
    while IFS=: read -r name id exp created; do
        [[ -n $name && $exp -gt $now ]] && xray_client_obj "$1" "$name" "$id"
    done < "$XRAY_USERS" | jq -s .
}

# xray_add_inbound PROTO NET PORT PATH TLS(0/1) HOST [CERT KEY] [NAME]
# NET: tcp, ws, grpc, xhttp. PATH: WebSocket/XHTTP path or gRPC service name.
xray_add_inbound() {
    local proto=$1 net=$2 port=$3 path=$4 tls=$5 host=$6 cert=${7:-} key=${8:-} name=${9:-}
    local tag stream new settings
    tag=${name:-vpsp-$proto-$net-$port}
    [[ $tag =~ ^[A-Za-z0-9_.-]{1,40}$ ]] || { err "The name may use letters, digits, '.', '_' and '-'."; return 1; }
    jq -e --argjson p "$port" '.inbounds[] | select(.port == $p)' "$XRAY_CONF" > /dev/null 2>&1 \
        && { err "An inbound already uses port $port."; return 1; }
    jq -e --arg t "$tag" '.inbounds[] | select(.tag == $t)' "$XRAY_CONF" > /dev/null 2>&1 \
        && { err "An inbound named $tag already exists."; return 1; }
    port_in_use "$port" && { err "Port $port is already in use."; return 1; }
    [[ $proto == shadowsocks ]] && { net=tcp; tls=0; path=''; }
    if (( tls )); then
        ssl_copy "$cert" "$key" "$XRAY_DIR/tls" "$VPSP_SVC_USER" || return 1
    fi
    stream=$(jq -n --arg net "$net" --arg path "$path" --argjson tls "$tls" \
             --arg c "$XRAY_DIR/tls/cert.pem" --arg k "$XRAY_DIR/tls/key.pem" '
        {network: (if $net == "tcp" then "raw" else $net end), security: (if $tls == 1 then "tls" else "none" end)}
        + (if $net == "ws" then {wsSettings: {path: $path}} else {} end)
        + (if $net == "xhttp" then {xhttpSettings: {path: $path}} else {} end)
        + (if $net == "grpc" then {grpcSettings: {serviceName: $path}} else {} end)
        + (if $tls == 1 then {tlsSettings: {certificates: [{certificateFile: $c, keyFile: $k}],
                                            alpn: (if $net == "grpc" or $net == "xhttp" then ["h2", "http/1.1"] else ["http/1.1"] end)}}
           else {} end)')
    case $proto in
        vless)       settings=$(jq -n --argjson c "$(xray_clients_json vless)" '{clients: $c, decryption: "none"}') ;;
        shadowsocks) settings=$(jq -n --argjson c "$(xray_clients_json shadowsocks)" '{clients: $c, network: "tcp,udp"}') ;;
        *)           settings=$(jq -n --argjson c "$(xray_clients_json "$proto")" '{clients: $c}') ;;
    esac
    new=$(jq --arg tag "$tag" --arg proto "$proto" --argjson port "$port" \
             --argjson stream "$stream" --argjson settings "$settings" '
        .inbounds += [{
            tag: $tag, listen: "0.0.0.0", port: $port, protocol: $proto,
            settings: $settings, sniffing: {enabled: true, destOverride: ["http", "tls"]}
        } + (if $proto == "shadowsocks" then {} else {streamSettings: $stream} end)]' "$XRAY_CONF") || return 1
    xray_save "$new" || return 1
    sed -i "/^$tag /d" "$XRAY_HOSTS"; echo "$tag $host" >> "$XRAY_HOSTS"
    fw_allow "$port"
    [[ $proto == shadowsocks ]] && fw_allow "$port" udp
    log_event "xray inbound $tag"
    ok "Inbound $tag added."
}

xray_remove_inbound() {
    local tag=$1 new
    jq -e --arg t "$tag" '.inbounds[] | select(.tag == $t)' "$XRAY_CONF" > /dev/null || { err "No inbound $tag."; return 1; }
    new=$(jq --arg t "$tag" '.inbounds |= map(select(.tag != $t))' "$XRAY_CONF") || return 1
    xray_save "$new" && sed -i "/^$tag /d" "$XRAY_HOSTS" && log_event "xray inbound $tag removed" && ok "Inbound $tag removed."
}

# tag|protocol|network|port|security|path-or-service
xray_inbounds() {
    jq -r '.inbounds[] | select(.protocol != "dokodemo-door") | "\(.tag)|\(.protocol)|\(
        (.streamSettings.network // "tcp") | if . == "raw" then "tcp" else . end)|\(.port)|\(.streamSettings.security // "none")|\(
        .streamSettings.wsSettings.path // .streamSettings.xhttpSettings.path // .streamSettings.grpcSettings.serviceName // "")"' \
        "$XRAY_CONF" 2>/dev/null
}

xray_user_get() { awk -F: -v u="$1" '$1 == u { print; f = 1 } END { exit !f }' "$XRAY_USERS"; }

# Put a user's client into every inbound (no-op when already there).
xray_config_add_client() {
    local new proto
    new=$(cat "$XRAY_CONF")
    for proto in vless vmess trojan shadowsocks; do
        new=$(jq --arg e "$1" --arg p "$proto" --argjson c "$(xray_client_obj "$proto" "$1" "$2")" '
            .inbounds |= map(if .protocol == $p
                and ([.settings.clients[]? | select(.email == $e)] | length) == 0
                then .settings.clients += [$c] else . end)' <<< "$new") || return 1
    done
    printf '%s\n' "$new"
}

xray_config_del_client() {
    jq --arg e "$1" '.inbounds |= map(if .settings.clients then .settings.clients |= map(select(.email != $e)) else . end)' "$XRAY_CONF"
}

xray_user_add() {
    local name=$1 days=$2 id=${3:-} exp new
    [[ $name =~ ^[A-Za-z0-9_.-]{2,32}$ ]] || { err "Use 2-32 letters, digits, '.', '_' or '-'."; return 1; }
    valid_int "$days" 1 3650 || { err "Days must be 1-3650."; return 1; }
    xray_user_get "$name" > /dev/null && { err "User $name already exists."; return 1; }
    [[ -n $id ]] || id=$(cat /proc/sys/kernel/random/uuid)
    [[ $id =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { err "Invalid UUID."; return 1; }
    exp=$(expiry_from_days "$days")
    new=$(xray_config_add_client "$name" "$id") && xray_save "$new" || return 1
    echo "$name:$id:$exp:$(now_epoch)" >> "$XRAY_USERS"
    log_event "xray user $name expires=$(fmt_date "$exp")"
    ok "User $name created, expires $(fmt_date "$exp")."
}

xray_user_del() {
    local new
    xray_user_get "$1" > /dev/null || { err "No user named $1."; return 1; }
    new=$(xray_config_del_client "$1") && xray_save "$new" || return 1
    sed -i "/^$1:/d" "$XRAY_USERS"
    log_event "xray user $1 deleted"
    ok "User $1 deleted."
}

# xray_user_renew NAME DAYS - new expiry = today + DAYS (as in ADMRufu).
xray_user_renew() {
    local name=$1 days=$2 row id exp new
    row=$(xray_user_get "$name") || { err "No user named $name."; return 1; }
    valid_int "$days" 1 3650 || { err "Days must be 1-3650."; return 1; }
    IFS=: read -r _ id exp _ <<< "$row"
    exp=$(expiry_from_days "$days")
    new=$(xray_config_add_client "$name" "$id") && xray_save "$new" || return 1
    awk -F: -v OFS=: -v u="$name" -v e="$exp" '$1 == u { $3 = e } 1' "$XRAY_USERS" > "$XRAY_USERS.tmp" \
        && mv -f "$XRAY_USERS.tmp" "$XRAY_USERS" && chmod 600 "$XRAY_USERS"
    log_event "xray user $name renewed until $(fmt_date "$exp")"
    ok "User $name renewed until $(fmt_date "$exp")."
}

# Remove expired users from the running configuration (called by the guard).
xray_enforce() {
    xray_installed && has_cmd jq || return 0
    local now u new changed=0
    now=$(now_epoch)
    new=$(cat "$XRAY_CONF")
    for u in $(awk -F: -v now="$now" '$3 <= now { print $1 }' "$XRAY_USERS"); do
        if jq -e --arg e "$u" '[.inbounds[].settings.clients[]? | select(.email == $e)] | length > 0' <<< "$new" > /dev/null; then
            new=$(jq --arg e "$u" '.inbounds |= map(if .settings.clients then .settings.clients |= map(select(.email != $e)) else . end)' <<< "$new")
            log_event "xray user $u expired"
            changed=1
        fi
    done
    (( changed )) && xray_save "$new"
    return 0
}

uri() { jq -rn --arg p "$1" '$p|@uri'; }

# xray_link NAME UUID TAG PROTO NET PORT SEC PATH - one share link.
xray_link() {
    local name=$1 id=$2 tag=$3 proto=$4 net=$5 port=$6 sec=$7 path=$8 host q
    host=$(awk -v t="$tag" '$1 == t { print $2 }' "$XRAY_HOSTS"); host=${host:-$(sys_ip)}
    q="security=$sec&type=$net"
    case $net in
        ws|xhttp) q+="&path=$(uri "$path")&host=$host" ;;
        grpc)     q+="&serviceName=$(uri "$path")&mode=gun" ;;
    esac
    [[ $sec == tls ]] && q+="&sni=$host&fp=chrome"
    case $proto in
        vless)  printf 'vless://%s@%s:%s?encryption=none&%s#%s\n' "$id" "$host" "$port" "$q" "$(uri "$name")" ;;
        trojan) printf 'trojan://%s@%s:%s?%s#%s\n' "$(uri "$id")" "$host" "$port" "$q" "$(uri "$name")" ;;
        shadowsocks)
            printf 'ss://%s@%s:%s#%s\n' "$(printf '%s:%s' "$XRAY_SS_METHOD" "$id" | base64 -w0 | tr '+/' '-_' | tr -d '=')" \
                "$host" "$port" "$(uri "$name")" ;;
        vmess)
            printf 'vmess://%s\n' "$(jq -cn --arg ps "$name" --arg add "$host" --arg port "$port" --arg id "$id" \
                --arg net "$net" --arg path "$path" --arg tls "$( [[ $sec == tls ]] && echo tls)" \
                '{v:"2", ps:$ps, add:$add, port:$port, id:$id, aid:"0", scy:"auto", net:$net, type:(if $net == "grpc" then "gun" else "none" end),
                  host:$add, path:$path, tls:$tls, sni:(if $tls == "tls" then $add else "" end)}' | tr -d '\n' | base64 -w0)" ;;
    esac
}

xray_links() {
    local name=$1 row id tag proto net port sec path link
    row=$(xray_user_get "$name") || { err "No user named $name."; return 1; }
    IFS=: read -r _ id _ _ <<< "$row"
    while IFS='|' read -r tag proto net port sec path; do
        link=$(xray_link "$name" "$id" "$tag" "$proto" "$net" "$port" "$sec" "$path")
        printf '\n  %s%s%s (%s %s %s%s)\n  %s\n' "$C_YLW" "$tag" "$C_RST" "$proto" "$net" "$port" \
            "$( [[ $sec == tls ]] && echo " tls")" "$link"
        [[ ${XRAY_QR:-0} == 1 ]] && has_cmd qrencode && qrencode -t ansiutf8 -m 1 "$link"
    done < <(xray_inbounds)
}

# xray_client_json NAME TAG - complete client config (SOCKS 1080 + outbound).
xray_client_json() {
    local name=$1 want=$2 row id tag proto net port sec path host out
    row=$(xray_user_get "$name") || return 1
    IFS=: read -r _ id _ _ <<< "$row"
    while IFS='|' read -r tag proto net port sec path; do
        [[ $tag == "$want" ]] || continue
        host=$(awk -v t="$tag" '$1 == t { print $2 }' "$XRAY_HOSTS"); host=${host:-$(sys_ip)}
        out=$(jq -n --arg proto "$proto" --arg host "$host" --argjson port "$port" --arg id "$id" --arg net "$net" \
                --arg sec "$sec" --arg path "$path" --arg m "$XRAY_SS_METHOD" '
            {inbounds: [{listen: "127.0.0.1", port: 1080, protocol: "socks", settings: {udp: true}}],
             outbounds: [{protocol: $proto,
                settings: (if $proto == "vless" then {vnext: [{address: $host, port: $port, users: [{id: $id, encryption: "none"}]}]}
                           elif $proto == "vmess" then {vnext: [{address: $host, port: $port, users: [{id: $id, security: "auto"}]}]}
                           elif $proto == "trojan" then {servers: [{address: $host, port: $port, password: $id}]}
                           else {servers: [{address: $host, port: $port, method: $m, password: $id}]} end)}
                + (if $proto == "shadowsocks" then {} else {streamSettings: (
                    {network: (if $net == "tcp" then "raw" else $net end), security: $sec}
                    + (if $net == "ws" then {wsSettings: {path: $path, host: $host}} else {} end)
                    + (if $net == "xhttp" then {xhttpSettings: {path: $path, host: $host}} else {} end)
                    + (if $net == "grpc" then {grpcSettings: {serviceName: $path}} else {} end)
                    + (if $sec == "tls" then {tlsSettings: {serverName: $host, fingerprint: "chrome"}} else {} end))} end)]}')
        printf '%s\n' "$out"
        return 0
    done < <(xray_inbounds)
    return 1
}

# ------------------------------------------------------------------ menu ---
xray_info() {
    [[ -x $XRAY_BIN ]] && printf ' %sVERSION:%s %s\n' "$C_GRN" "$C_RST" "$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1 {print $2}')"
    local tag proto net port sec path any=0
    while IFS='|' read -r tag proto net port sec path; do
        any=1
        printf '  %s%-18s%s %-11s %-5s %-5s %s%s\n' "$C_YLW" "${tag:0:18}" "$C_RST" "$proto" "$net" "$port" \
            "$( [[ $sec == tls ]] && echo tls || echo -)" "${path:+  $path}"
    done < <(xray_installed && xray_inbounds)
    xray_installed && (( ! any )) && ui_center "NO PROTOCOL YET - ADD ONE WITH OPTION 1" "$C_YLW"
    xray_installed || ui_center "VMESS, VLESS, TROJAN, SHADOWSOCKS - TCP, WS, GRPC, XHTTP" "$C_YLW"
    return 0
}

m_xray_add() {
    local proto net port path='' tls=0 host cert='' key='' c name rnd
    clear 2>/dev/null; ui_title "NEW V2RAY/XRAY CONFIGURATION"
    rnd=$(tr -dc 'A-Za-z' < /dev/urandom | head -c 4)
    ask name "NAME" "$rnd" || return
    ui_item 1 "VMESS"; ui_item 2 "VLESS"; ui_item 3 "TROJAN"; ui_item 4 "SHADOWSOCKS"; ui_line
    ask c "PROTOCOL" 2 || return
    case $c in 1) proto=vmess ;; 2) proto=vless ;; 3) proto=trojan ;; 4) proto=shadowsocks ;; *) err "Invalid choice."; return 1 ;; esac
    [[ $proto == vmess ]] && warn "Xray marks VMess as deprecated; use it only for older clients."
    if [[ $proto != shadowsocks ]]; then
        ui_item 1 "NETWORK TCP"; ui_item 2 "NETWORK GRPC"; ui_item 3 "NETWORK WEBSOCKET"; ui_item 4 "NETWORK XHTTP"; ui_line
        ask c "NETWORK" 3 || return
        case $c in 1) net=tcp ;; 2) net=grpc ;; 3) net=ws ;; 4) net=xhttp ;; *) err "Invalid choice."; return 1 ;; esac
        case $net in
            ws|xhttp) ask path "PATH" "/$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 10)" || return
                      [[ $path =~ ^/[A-Za-z0-9/_.-]*$ ]] || { err "The path must start with / and use letters, digits, '/', '_', '.', '-'."; return 1; } ;;
            grpc)     ask path "SERVICE NAME" "$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)" || return
                      [[ $path =~ ^[A-Za-z0-9_.-]+$ ]] || { err "Use letters, digits, '_', '.', '-'."; return 1; } ;;
        esac
        ui_item 1 "TLS CLOSED (no TLS)"; ui_item 2 "TLS OPEN"; ui_line
        ask c "TLS" "$( [[ $proto == trojan ]] && echo 2 || echo 1)" || return
        [[ $c == 2 ]] && tls=1
        [[ $proto == trojan && $tls == 0 ]] && warn "Most Trojan clients expect TLS."
    else
        net=tcp
    fi
    ask_port port "PORT" "$( (( tls )) && echo 443 || echo 8880)" || return
    host=$(sys_ip)
    if (( tls )); then
        ssl_pick cert key || return
        if [[ $cert == "$SSL_SELF"/* ]]; then
            warn "Current Xray clients no longer accept self-signed certificates without pinning"
            warn "the certificate hash. Prefer a Let's Encrypt certificate for TLS inbounds."
        fi
        host=$(openssl x509 -noout -subject -in "$cert" 2>/dev/null | sed -n 's/.*CN *= *//p')
        ask host "Address clients connect to (domain on the certificate)" "${host:-$(sys_ip)}" || return
    fi
    xray_add_inbound "$proto" "$net" "$port" "$path" "$tls" "$host" "$cert" "$key" "$name"
}

xray_pick_inbound() {
    local __v=$1 __n=0 __tag proto net port sec path __c
    local -a tags=()
    while IFS='|' read -r __tag proto net port sec path; do
        __n=$((__n + 1)); tags+=("$__tag")
        ui_item "$__n" "$proto $net$( [[ $sec == tls ]] && echo " tls") $port  ($__tag)"
    done < <(xray_inbounds)
    (( __n )) || { info "There are no protocols (inbounds)."; return 1; }
    ui_line
    ask __c "Enter an option" || return 1
    valid_int "$__c" 1 "$__n" || { err "Invalid option."; return 1; }
    printf -v "$__v" '%s' "${tags[__c - 1]}"
}

m_xray_remove() { local tag; xray_pick_inbound tag && confirm "Remove $tag?" && xray_remove_inbound "$tag"; }

m_xray_edit() {
    local tmp; tmp=$(mktemp)
    cp "$XRAY_CONF" "$tmp"
    "${EDITOR:-nano}" "$tmp"
    jq . "$tmp" > /dev/null 2>&1 || { rm -f "$tmp"; err "That is not valid JSON; nothing was changed."; return 1; }
    xray_save "$(cat "$tmp")" && ok "Configuration saved."
    rm -f "$tmp"
}

m_xray_uninstall() { confirm "Uninstall Xray and delete all of its users?" && xray_uninstall; }
m_xray_install()   { xray_install && m_xray_add; }
xray_logsize() { du -ch "$XRAY_LOGDIR"/*.log 2>/dev/null | awk 'END {print $1}'; }

xray_menu() {
    local -a items
    while true; do
        if xray_installed; then
            items=("ADD V2RAY/XRAY PROTOCOL|m_xray_add"
                   "REMOVE V2RAY/XRAY PROTOCOL|m_xray_remove"
                   -
                   "VIEW JSON CONFIGURATION|jq . $XRAY_CONF"
                   "EDIT JSON CONFIGURATION (nano)|m_xray_edit"
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
    [[ -n $(xray_inbounds) ]] || { err "Add a protocol in Protocol configuration > V2Ray/Xray first."; return 1; }
    clear 2>/dev/null; ui_title "NEW V2RAY/XRAY USER"
    xray_user_table; ui_line
    ask n "NAME" || return
    ask id "UUID (Enter = random)" || return
    ask d "EXPIRES IN (days)" "$DEFAULT_DAYS" || return
    xray_user_add "$n" "$d" "$id" || return
    ui_line; xray_links "$n"
    ui_line
    if confirm "Show the client JSON?"; then local t; xray_pick_inbound t && xray_client_json "$n" "$t"; fi
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
    if confirm "Show the client JSON?"; then xray_pick_inbound t && xray_client_json "$n" "$t"; fi
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
