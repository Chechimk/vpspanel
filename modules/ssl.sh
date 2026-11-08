# shellcheck shell=bash
# vpspanel module: SSL certificate manager.
# Let's Encrypt certificates are issued with certbot (Apache-2.0, from the
# distribution) in standalone mode; a self-signed certificate is also offered.
# Services that run unprivileged get a copy of the certificate; the copies are
# refreshed by `vpspanel cert-sync`, which certbot calls after every renewal.

SSL_DIR="$VPSP_ETC/ssl"
SSL_SELF="$SSL_DIR/selfsigned"
LE_LIVE=/etc/letsencrypt/live
CERTBOT_HOOK=/etc/letsencrypt/renewal-hooks/deploy/vpspanel.sh

# Lines of "name|certificate|key" for every certificate the panel can use.
ssl_list() {
    local d
    [[ -s $SSL_SELF/fullchain.pem ]] && echo "self-signed|$SSL_SELF/fullchain.pem|$SSL_SELF/privkey.pem"
    for d in "$LE_LIVE"/*/; do
        [[ -s $d/fullchain.pem ]] || continue
        d=${d%/}
        echo "${d##*/}|$d/fullchain.pem|$d/privkey.pem"
    done
}

ssl_expiry() { openssl x509 -enddate -noout -in "$1" 2>/dev/null | sed 's/^notAfter=//'; }

ssl_selfsigned() {
    local cn=${1:-$(sys_ip)}
    mkdir -p "$SSL_SELF" && chmod 700 "$SSL_SELF"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$cn" \
        -keyout "$SSL_SELF/privkey.pem" -out "$SSL_SELF/fullchain.pem" > /dev/null 2>&1 \
        || { err "openssl failed to create the certificate."; return 1; }
    chmod 600 "$SSL_SELF/privkey.pem"
    log_event "self-signed certificate for $cn"
    ok "Self-signed certificate created for $cn (valid 10 years)."
}

ssl_issue() {
    local domain=$1 email=$2 ip resolved
    valid_domain "$domain" || { err "Invalid domain: $domain"; return 1; }
    ip=$(sys_ip)
    resolved=$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1 {print $1}')
    if [[ -z $resolved ]]; then
        err "$domain does not resolve. Create an A record pointing to this server first."; return 1
    fi
    if [[ $resolved != "$ip" ]]; then
        warn "$domain points to $resolved, but this server's address is $ip."
        warn "That is fine behind NAT; otherwise fix the DNS record first."
        confirm "Try anyway?" || return 0
    fi
    if port_in_use 80 && ! [[ -f $VPSP_ETC/wsproxy/80.env ]]; then
        err "Port 80 is in use by another program. Free it and try again."; return 1
    fi
    apt_install certbot || return 1
    local -a mail=(--register-unsafely-without-email)
    [[ -n $email ]] && mail=(-m "$email")
    systemctl stop vpspanel-wsproxy@80 2>/dev/null || true
    certbot certonly --standalone --non-interactive --agree-tos "${mail[@]}" -d "$domain" \
        --pre-hook "systemctl stop vpspanel-wsproxy@80 2>/dev/null || true" \
        --post-hook "systemctl start vpspanel-wsproxy@80 2>/dev/null || true"
    local rc=$?
    [[ -f $VPSP_ETC/wsproxy/80.env ]] && systemctl start vpspanel-wsproxy@80 2>/dev/null
    (( rc == 0 )) || { err "certbot could not issue the certificate. Check the output above."; return 1; }
    ssl_install_hook
    log_event "certificate issued for $domain"
    ok "Certificate issued for $domain. certbot renews it automatically."
}

ssl_install_hook() {
    mkdir -p "$(dirname "$CERTBOT_HOOK")"
    printf '#!/bin/sh\n# Refresh certificate copies used by vpspanel services.\n%s cert-sync\n' \
        "$VPSP_HOME/bin/vpspanel" > "$CERTBOT_HOOK"
    chmod 755 "$CERTBOT_HOOK"
}

# ssl_pick CERT_VAR KEY_VAR - let the admin choose a certificate.
ssl_pick() {
    local __c=$1 __k=$2 line n=0 choice
    local -a rows=()
    while IFS= read -r line; do rows+=("$line"); done < <(ssl_list)
    if (( ${#rows[@]} == 0 )); then
        info "There is no certificate yet. A self-signed one will be created."
        ssl_selfsigned || return 1
        rows=("$(ssl_list | head -n1)")
    fi
    for line in "${rows[@]}"; do
        n=$((n + 1))
        ui_item "$n" "${line%%|*}  (expires $(ssl_expiry "$(cut -d'|' -f2 <<< "$line")"))"
    done
    ask choice "Certificate" 1 || return 1
    valid_int "$choice" 1 "$n" || { err "Invalid choice."; return 1; }
    line=${rows[choice - 1]}
    printf -v "$__c" '%s' "$(cut -d'|' -f2 <<< "$line")"
    printf -v "$__k" '%s' "$(cut -d'|' -f3 <<< "$line")"
}

# ssl_copy CERT KEY DEST_DIR GROUP - private copy readable by a service group.
ssl_copy() {
    local cert=$1 key=$2 dir=$3 group=$4
    mkdir -p "$dir"
    install -m 644 "$cert" "$dir/cert.pem" && install -m 640 -g "$group" "$key" "$dir/key.pem" || return 1
    printf '%s\n%s\n' "$cert" "$key" > "$dir/source"
}

# Refresh every copy from its source and restart the services using them.
ssl_sync() {
    local src dir cert key
    for src in "$VPSP_ETC"/*/tls/source; do
        [[ -f $src ]] || continue
        dir=$(dirname "$src")
        { read -r cert; read -r key; } < "$src"
        [[ -s $cert && -s $key ]] || continue
        cp -f "$cert" "$dir/cert.pem" && cp -f "$key" "$dir/key.pem"
    done
    systemctl try-restart vpspanel-xray vpspanel-hysteria vpspanel-stunnel 2>/dev/null || true
    log_event "certificates synced"
}

ssl_remove() {
    local name=$1
    if [[ $name == self-signed ]]; then
        rm -rf "$SSL_SELF"
    else
        certbot delete --non-interactive --cert-name "$name" > /dev/null 2>&1 || { err "certbot could not delete $name."; return 1; }
    fi
    log_event "certificate $name removed"
    ok "Certificate $name removed. Services already using a copy keep working until they are reconfigured."
}

# ------------------------------------------------------------------ menu ---
ssl_info() {
    local line any=0
    while IFS= read -r line; do
        any=1
        printf '  %-28s expires %s\n' "${line%%|*}" "$(ssl_expiry "$(cut -d'|' -f2 <<< "$line")")"
    done < <(ssl_list)
    (( any )) || ui_kv "Certificates:" "none"
}

m_ssl_issue() {
    local d e
    info "The domain must point to this server and port 80 must be reachable."
    ask d "Domain (e.g. vpn.example.com)" || return
    ask e "E-mail for expiry notices (optional)" || return
    ssl_issue "$d" "$e"
}

m_ssl_self() { local cn; ask cn "Common name (domain or IP)" "$(sys_ip)" && ssl_selfsigned "$cn"; }

m_ssl_renew() {
    has_cmd certbot || { info "No Let's Encrypt certificates are installed."; return 0; }
    certbot renew --non-interactive && ssl_sync && ok "Renewal check finished."
}

m_ssl_remove() {
    local name
    [[ -n $(ssl_list) ]] || { info "There are no certificates."; return 0; }
    ask name "Certificate name to remove (as listed above)" || return
    ssl_list | cut -d'|' -f1 | grep -qxF -- "$name" || { err "No certificate named $name."; return 1; }
    confirm "Remove the $name certificate?" && ssl_remove "$name"
}

m_ssl_details() {
    local line
    while IFS= read -r line; do
        ui_line
        printf '  %s\n' "${C_BLD}${line%%|*}${C_RST}"
        openssl x509 -noout -subject -issuer -dates -in "$(cut -d'|' -f2 <<< "$line")" 2>/dev/null | sed 's/^/  /'
        printf '  cert: %s\n  key:  %s\n' "$(cut -d'|' -f2 <<< "$line")" "$(cut -d'|' -f3 <<< "$line")"
    done < <(ssl_list)
    [[ -n $(ssl_list) ]] || info "There are no certificates."
}

ssl_menu() {
    while menu_show "SSL CERTIFICATE MANAGER" ssl_info \
        "Issue a Let's Encrypt certificate|m_ssl_issue" \
        "Create a self-signed certificate|m_ssl_self" \
        "Certificate details|m_ssl_details" \
        "Renew certificates now|m_ssl_renew" \
        "Remove a certificate|m_ssl_remove"
    do :; done
}
