# shellcheck shell=bash
# vpspanel module: V2Ray/Xray (Xray-core, MPL-2.0, downloaded from the official
# XTLS GitHub releases and verified against the published SHA-256 digest).
#
# Inbounds: VLESS or VMess over WebSocket (with or without TLS) or TCP+TLS.
# Users live in $XRAY_DIR/users.db ("name:uuid:expire_epoch:created_epoch") and
# are added to every inbound. The guard timer removes them when they expire.

XRAY_BIN=/usr/local/bin/xray
XRAY_SHARE=/usr/local/share/xray
XRAY_DIR="$VPSP_ETC/xray"
XRAY_CONF="$XRAY_DIR/config.json"
XRAY_USERS="$XRAY_DIR/users.db"
XRAY_HOSTS="$XRAY_DIR/hosts"          # "tag host" - address put in share links
XRAY_LOGDIR=/var/log/vpspanel-xray
XRAY_UNIT=/etc/systemd/system/vpspanel-xray.service

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
    systemctl enable --now vpspanel-xray > /dev/null 2>&1 || { err "Xray failed to start. See: journalctl -u vpspanel-xray"; return 1; }
    log_event "xray installed"
    ok "Xray is installed. Add an inbound (protocol) next, then create users."
}

xray_uninstall() {
    systemctl disable --now vpspanel-xray > /dev/null 2>&1 || true
    rm -f "$XRAY_UNIT" "$XRAY_BIN"
    rm -rf "$XRAY_SHARE" "$XRAY_DIR" "$XRAY_LOGDIR"
    systemctl daemon-reload
    log_event "xray removed"
    ok "Xray and its users were removed."
}

# Current users as JSON client objects, for a new inbound.
xray_clients_json() {
    local now; now=$(now_epoch)
    awk -F: -v now="$now" '$3 > now { printf "{\"id\":\"%s\",\"email\":\"%s\"}\n", $2, $1 }' "$XRAY_USERS" | jq -s .
}

# xray_add_inbound PROTO NET PORT PATH TLS(0/1) HOST [CERT KEY]
xray_add_inbound() {
    local proto=$1 net=$2 port=$3 path=$4 tls=$5 host=$6 cert=${7:-} key=${8:-}
    local tag="vpsp-$proto-$net-$port" stream new
    jq -e --argjson p "$port" '.inbounds[] | select(.port == $p)' "$XRAY_CONF" > /dev/null 2>&1 \
        && { err "An inbound already uses port $port."; return 1; }
    port_in_use "$port" && { err "Port $port is already in use."; return 1; }
    if (( tls )); then
        ssl_copy "$cert" "$key" "$XRAY_DIR/tls" "$VPSP_SVC_USER" || return 1
    fi
    stream=$(jq -n --arg net "$net" --arg path "$path" --argjson tls "$tls" \
             --arg c "$XRAY_DIR/tls/cert.pem" --arg k "$XRAY_DIR/tls/key.pem" '
        {network: $net, security: (if $tls == 1 then "tls" else "none" end)}
        + (if $net == "ws" then {wsSettings: {path: $path}} else {} end)
        + (if $tls == 1 then {tlsSettings: {certificates: [{certificateFile: $c, keyFile: $k}]}} else {} end)')
    new=$(jq --arg tag "$tag" --arg proto "$proto" --argjson port "$port" \
             --argjson stream "$stream" --argjson clients "$(xray_clients_json)" '
        .inbounds += [{
            tag: $tag, listen: "0.0.0.0", port: $port, protocol: $proto,
            settings: ({clients: $clients} + (if $proto == "vless" then {decryption: "none"} else {} end)),
            streamSettings: $stream,
            sniffing: {enabled: true, destOverride: ["http", "tls"]}
        }]' "$XRAY_CONF") || return 1
    xray_save "$new" || return 1
    sed -i "/^$tag /d" "$XRAY_HOSTS"; echo "$tag $host" >> "$XRAY_HOSTS"
    fw_allow "$port"
    log_event "xray inbound $tag"
    ok "Inbound $tag added."
}

xray_remove_inbound() {
    local tag=$1 new
    jq -e --arg t "$tag" '.inbounds[] | select(.tag == $t)' "$XRAY_CONF" > /dev/null || { err "No inbound $tag."; return 1; }
    new=$(jq --arg t "$tag" '.inbounds |= map(select(.tag != $t))' "$XRAY_CONF") || return 1
    xray_save "$new" && sed -i "/^$tag /d" "$XRAY_HOSTS" && log_event "xray inbound $tag removed" && ok "Inbound $tag removed."
}

xray_inbounds() { jq -r '.inbounds[] | "\(.tag)|\(.protocol)|\(.streamSettings.network)|\(.port)|\(.streamSettings.security)|\(.streamSettings.wsSettings.path // "")"' "$XRAY_CONF" 2>/dev/null; }

xray_user_get() { awk -F: -v u="$1" '$1 == u { print; f = 1 } END { exit !f }' "$XRAY_USERS"; }

# Put a user's client into every inbound (no-op when already there).
xray_config_add_client() {
    jq --arg id "$2" --arg e "$1" '
        .inbounds |= map(if (.protocol == "vless" or .protocol == "vmess")
            and ([.settings.clients[]? | select(.email == $e)] | length) == 0
            then .settings.clients += [{id: $id, email: $e}] else . end)' "$XRAY_CONF"
}

xray_config_del_client() {
    jq --arg e "$1" '.inbounds |= map(if .settings.clients then .settings.clients |= map(select(.email != $e)) else . end)' "$XRAY_CONF"
}

xray_user_add() {
    local name=$1 days=$2 id exp new
    [[ $name =~ ^[A-Za-z0-9_.-]{3,32}$ ]] || { err "Use 3-32 letters, digits, '.', '_' or '-'."; return 1; }
    valid_int "$days" 1 3650 || { err "Days must be 1-3650."; return 1; }
    xray_user_get "$name" > /dev/null && { err "User $name already exists."; return 1; }
    id=$(cat /proc/sys/kernel/random/uuid)
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

xray_user_renew() {
    local name=$1 days=$2 row id exp base new
    row=$(xray_user_get "$name") || { err "No user named $name."; return 1; }
    valid_int "$days" 1 3650 || { err "Days must be 1-3650."; return 1; }
    IFS=: read -r _ id exp _ <<< "$row"
    base=$(now_epoch); (( exp > base )) && base=$exp
    exp=$(expiry_from_days "$days" "$base")
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

xray_links() {
    local name=$1 row id line tag proto net port sec path host q
    row=$(xray_user_get "$name") || { err "No user named $name."; return 1; }
    IFS=: read -r _ id _ _ <<< "$row"
    while IFS='|' read -r tag proto net port sec path; do
        host=$(awk -v t="$tag" '$1 == t { print $2 }' "$XRAY_HOSTS"); host=${host:-$(sys_ip)}
        printf '\n  %s%s%s\n' "$C_BLD" "$tag" "$C_RST"
        if [[ $proto == vless ]]; then
            q="encryption=none&security=$sec&type=$net"
            [[ $net == ws ]] && q+="&path=$(jq -rn --arg p "$path" '$p|@uri')&host=$host"
            [[ $sec == tls ]] && q+="&sni=$host"
            printf '  vless://%s@%s:%s?%s#%s\n' "$id" "$host" "$port" "$q" "$name"
        else
            printf '  vmess://%s\n' "$(jq -cn --arg ps "$name" --arg add "$host" --arg port "$port" --arg id "$id" \
                --arg net "$net" --arg path "$path" --arg tls "$( [[ $sec == tls ]] && echo tls)" \
                '{v:"2", ps:$ps, add:$add, port:$port, id:$id, aid:"0", scy:"auto", net:$net, type:"none", host:$add, path:$path, tls:$tls, sni:(if $tls == "tls" then $add else "" end)}' \
                | tr -d '\n' | base64 -w0)"
        fi
    done < <(xray_inbounds)
}

# ------------------------------------------------------------------ menu ---
xray_info() {
    ui_kv "Status:" "$(fmt_state "$(svc_state vpspanel-xray)")"
    [[ -x $XRAY_BIN ]] && ui_kv "Version:" "$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1 {print $2}')"
    local tag proto net port sec path any=0
    while IFS='|' read -r tag proto net port sec path; do
        any=1
        printf '  %-6s %-4s %-5s port %-6s %s\n' "$proto" "$net" "$sec" "$port" "$path"
    done < <(xray_installed && xray_inbounds)
    xray_installed && (( ! any )) && ui_kv "Inbounds:" "none - add one with option 1"
    return 0
}

m_xray_add() {
    local proto net port path tls=0 host cert="" key="" c
    printf '  1) VLESS (recommended)   2) VMess (deprecated by Xray, for older clients)\n'; ask c "Protocol" 1 || return
    case $c in 1) proto=vless ;; 2) proto=vmess ;; *) err "Invalid choice."; return 1 ;; esac
    printf '  1) WebSocket   2) WebSocket + TLS   3) TCP + TLS\n'; ask c "Transport" 1 || return
    case $c in 1) net=ws ;; 2) net=ws; tls=1 ;; 3) net=tcp; tls=1 ;; *) err "Invalid choice."; return 1 ;; esac
    ask_port port "Port" "$( (( tls )) && echo 443 || echo 8880)" || return
    path=""
    if [[ $net == ws ]]; then
        ask path "WebSocket path" "/$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)" || return
        [[ $path =~ ^/[A-Za-z0-9/_.-]*$ ]] || { err "The path must start with / and use letters, digits, '/', '_', '.', '-'."; return 1; }
    fi
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
    xray_add_inbound "$proto" "$net" "$port" "$path" "$tls" "$host" "$cert" "$key"
}

m_xray_remove() {
    local tag
    [[ -n $(xray_inbounds) ]] || { info "There are no inbounds."; return 0; }
    xray_inbounds | cut -d'|' -f1 | sed 's/^/  /'
    ask tag "Inbound tag to remove" || return
    confirm "Remove inbound $tag?" && xray_remove_inbound "$tag"
}

m_xray_edit() {
    local tmp; tmp=$(mktemp)
    cp "$XRAY_CONF" "$tmp"
    "${EDITOR:-nano}" "$tmp"
    jq . "$tmp" > /dev/null 2>&1 || { rm -f "$tmp"; err "That is not valid JSON; nothing was changed."; return 1; }
    xray_save "$(cat "$tmp")" && ok "Configuration saved."
    rm -f "$tmp"
}

m_xray_uninstall() { confirm "Uninstall Xray and delete all of its users?" && xray_uninstall; }
m_xray_install()   { xray_install; }

xray_menu() {
    local -a items
    while true; do
        if xray_installed; then
            items=("Add an inbound (protocol)|m_xray_add"
                   "Remove an inbound|m_xray_remove"
                   "View JSON configuration|jq . $XRAY_CONF"
                   "Edit JSON configuration (nano)|m_xray_edit"
                   "Access log (live)|follow_log tail -n 30 -f $XRAY_LOGDIR/access.log"
                   "Error log|tail -n 40 $XRAY_LOGDIR/error.log"
                   "Service status|show_service_status vpspanel-xray"
                   "Restart service|restart_service vpspanel-xray"
                   "Start / stop service|toggle_service vpspanel-xray"
                   "Uninstall Xray|m_xray_uninstall")
        else
            items=("Install Xray|m_xray_install")
        fi
        menu_show "V2RAY / XRAY MANAGER" xray_info "${items[@]}" || return 0
    done
}

# ---------------------------------------------------- account manager ---
xray_users_info() {
    local now n=0 e=0
    now=$(now_epoch)
    if [[ -f $XRAY_USERS ]]; then
        n=$(grep -c . "$XRAY_USERS")
        e=$(awk -F: -v now="$now" '$3 <= now' "$XRAY_USERS" | grep -c .)
    fi
    ui_kv "Users:" "$n total, $e expired"
    ui_kv "Inbounds:" "$( { xray_inbounds 2>/dev/null || true; } | grep -c .)"
}

m_xu_list() {
    local name id exp created now
    now=$(now_epoch)
    printf '  %-20s %-17s %5s %s\n' USER EXPIRES DAYS STATUS
    while IFS=: read -r name id exp created; do
        [[ -n $name ]] || continue
        printf '  %-20s %-17s %5s %s\n' "$name" "$(fmt_date "$exp")" "$(days_left "$exp")" \
            "$( (( exp > now )) && echo "${C_GRN}ACTIVE${C_RST}" || echo "${C_RED}EXPIRED${C_RST}")"
    done < "$XRAY_USERS"
    [[ -s $XRAY_USERS ]] || info "There are no users."
}

m_xu_pick() {
    local __v=$1 n
    [[ -s $XRAY_USERS ]] || { info "There are no users."; return 1; }
    printf '  Users: %s\n' "$(cut -d: -f1 "$XRAY_USERS" | paste -sd' ' -)"
    ask n "User name" || return 1
    xray_user_get "$n" > /dev/null || { err "No user named $n."; return 1; }
    printf -v "$__v" '%s' "$n"
}

m_xu_new() {
    local n d
    [[ -n $(xray_inbounds) ]] || { err "Add an inbound in Protocol configuration > V2Ray / Xray first."; return 1; }
    ask n "User name" || return
    ask d "Valid for (days)" "$DEFAULT_DAYS" || return
    xray_user_add "$n" "$d" && xray_links "$n"
}
m_xu_del()   { local n; m_xu_pick n && confirm "Delete $n?" && xray_user_del "$n"; }
m_xu_renew() { local n d; m_xu_pick n && ask d "Add days" "$DEFAULT_DAYS" && xray_user_renew "$n" "$d"; }
m_xu_info()  {
    local n row
    m_xu_pick n || return
    row=$(xray_user_get "$n")
    ui_kv "User:" "$n"
    ui_kv "UUID:" "$(cut -d: -f2 <<< "$row")"
    ui_kv "Expires:" "$(fmt_date "$(cut -d: -f3 <<< "$row")") ($(days_left "$(cut -d: -f3 <<< "$row")") day(s) left)"
    xray_links "$n"
}

xray_users_menu() {
    if ! xray_installed; then
        warn "Xray is not installed."
        info "Install it in Protocol configuration > V2Ray / Xray."
        ui_pause
        return 0
    fi
    while menu_show "V2RAY / XRAY ACCOUNTS" xray_users_info \
        "New user|m_xu_new" \
        "Remove user|m_xu_del" \
        "Renew user|m_xu_renew" \
        "User details and share links|m_xu_info" \
        "List users|m_xu_list"
    do :; done
}
