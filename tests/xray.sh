# shellcheck shell=bash
# Xray manager tests, sourced by tests/run.sh (uses check/t_ok/t_fail/section,
# LIB, drive, socks_get). Every positive case sends real traffic through the
# official Xray-core client built from the panel's own client JSON.

xt_traffic() {   # xt_traffic TAG [USER] - client JSON -> SOCKS 1089 -> fetch
    [[ $(type -t xray_client_json) == function ]] || . /dev/stdin <<< "$LIB"
    local tag=$1 u=${2:-t_ray} pid
    xray_client_json "$u" "$tag" | jq '.inbounds[0].port = 1089' > /root/xc.json
    XRAY_LOCATION_ASSET=/usr/local/share/xray /usr/local/bin/xray run -c /root/xc.json > /tmp/xc.log 2>&1 & pid=$!
    sleep 3
    # One retry: the test network sometimes drops a single outbound request.
    socks_get 1089 || { sleep 2; socks_get 1089; }; local r=$?
    kill "$pid" 2> /dev/null; wait "$pid" 2> /dev/null
    return $r
}
xt_add() {   # xt_add TAG kv... - add through the non-interactive API
    . /dev/stdin <<< "$LIB"
    xray_add_kv "tag=$1" addr=127.0.0.1 "${@:2}"
}
xt_refuse() ( . /dev/stdin <<< "$LIB"; ! xray_add_kv addr=127.0.0.1 "$@" )
xt_hylink() {   # official Hysteria2 client given a share link
    printf 'server: "%s"
socks5:
  listen: 127.0.0.1:1090
' "$1" > /root/hyx.yaml
    /usr/local/bin/hysteria client -c /root/hyx.yaml > /tmp/hyx.log 2>&1 & local pid=$!
    sleep 4; socks_get 1090; local r=$?; kill "$pid" 2> /dev/null; wait "$pid" 2> /dev/null; return $r
}
export -f xt_traffic xt_add xt_refuse xt_hylink

xray_tests() {
    local SELF=/etc/vpspanel/ssl/selfsigned/fullchain.pem SKEY=/etc/vpspanel/ssl/selfsigned/privkey.pem t
    section "Xray: install, users"
    check "self-signed certificate (with SAN)"  bash -c "$LIB; ssl_selfsigned 127.0.0.1 && openssl x509 -in \$SSL_SELF/fullchain.pem -noout -ext subjectAltName | grep -q 'IP Address:127.0.0.1'"
    check "Xray install (download + checksum)"  bash -c "$LIB; xray_install"
    check "users t_ray and t_ray2"              bash -c "$LIB; xray_user_add t_ray 10 && xray_user_add t_ray2 10"

    section "Xray: every protocol x transport x security, real traffic"
    local -a cases=(
        "x-vless-raw-reality-vision|proto=vless method=raw security=reality port=8501 target=www.microsoft.com:443 flow=xtls-rprx-vision"
        "x-vless-raw-reality-udp443|proto=vless method=raw security=reality port=8502 target=www.microsoft.com:443 flow=xtls-rprx-vision cflow=xtls-rprx-vision-udp443"
        "x-vless-raw-tls-vision|proto=vless method=raw security=tls port=8503 cert=$SELF key=$SKEY flow=xtls-rprx-vision"
        "x-vless-raw-none|proto=vless method=raw security=none port=8504"
        "x-vless-xhttp-reality|proto=vless method=xhttp security=reality port=8505 target=www.microsoft.com:443 path=/xr"
        "x-vless-xhttp-tls-streamone|proto=vless method=xhttp security=tls port=8506 cert=$SELF key=$SKEY path=/xt mode=stream-one alpn=h2,http/1.1"
        "x-vless-xhttp-tls-h3|proto=vless method=xhttp security=tls port=8507 cert=$SELF key=$SKEY path=/x3 alpn=h3"
        "x-vless-xhttp-none-packetup|proto=vless method=xhttp security=none port=8508 path=/xn mode=packet-up"
        "x-vless-grpc-reality|proto=vless method=grpc security=reality port=8509 target=www.microsoft.com:443 path=gsvc"
        "x-vless-grpc-tls-multi|proto=vless method=grpc security=tls port=8510 cert=$SELF key=$SKEY path=gsvc2 gmode=multi"
        "x-vless-ws-none|proto=vless method=websocket security=none port=8511 path=/w"
        "x-vless-httpupgrade-tls|proto=vless method=httpupgrade security=tls port=8512 cert=$SELF key=$SKEY path=/hu"
        "x-vless-mkcp-none|proto=vless method=mkcp security=none port=8513"
        "x-vless-mkcp-seed|proto=vless method=mkcp security=none port=8514 kmask=seed kval=seedpass1 mtu=1350 tti=20 up=10 down=50"
        "x-vless-mkcp-wechat-tls|proto=vless method=mkcp security=tls port=8515 cert=$SELF key=$SKEY kmask=wechat"
        "x-vless-enc-ws-vision|proto=vless method=websocket security=none port=8516 path=/e enc=1 flow=xtls-rprx-vision"
        "x-vless-enc-raw|proto=vless method=raw security=none port=8517 enc=1"
        "x-vmess-raw-none|proto=vmess method=raw security=none port=8518"
        "x-vmess-raw-httpheader|proto=vmess method=raw security=none port=8519 header=http hpath=/index.html host=www.example.com"
        "x-vmess-xhttp-tls|proto=vmess method=xhttp security=tls port=8520 cert=$SELF key=$SKEY path=/mx"
        "x-vmess-grpc-reality|proto=vmess method=grpc security=reality port=8521 target=www.microsoft.com:443 path=mg"
        "x-trojan-raw-tls|proto=trojan method=raw security=tls port=8522 cert=$SELF key=$SKEY"
        "x-trojan-xhttp-reality|proto=trojan method=xhttp security=reality port=8523 target=www.microsoft.com:443 path=/tx"
        "x-trojan-ws-tls|proto=trojan method=websocket security=tls port=8524 cert=$SELF key=$SKEY path=/tw"
        "x-ss-chacha20|proto=shadowsocks port=8525"
        "x-ss-aes256|proto=shadowsocks port=8526 ssm=aes-256-gcm"
        "x-ss-2022-aes128|proto=shadowsocks port=8527 ssm=2022-blake3-aes-128-gcm"
        "x-ss-2022-aes256|proto=shadowsocks port=8528 ssm=2022-blake3-aes-256-gcm"
        "x-hysteria-obfs|proto=hysteria port=8529 cert=$SELF key=$SKEY obfs=obfspass123"
        "x-hysteria|proto=hysteria port=8530 cert=$SELF key=$SKEY"
        "x-masque-h3|proto=masque port=8531 cert=$SELF key=$SKEY pool=10.77.0.1/24 alpn=h3"
        "x-masque-h2|proto=masque port=8532 cert=$SELF key=$SKEY pool=10.78.0.1/24 alpn=h2"
        "x-socks|proto=socks port=8533"
        "x-http|proto=http security=none port=8534"
        "x-https|proto=http security=tls port=8535 cert=$SELF key=$SKEY"
    )
    local c tag kv
    for c in "${cases[@]}"; do
        tag=${c%%|*}; kv=${c#*|}
        # shellcheck disable=SC2086
        check "$tag" bash -c "xt_add $tag $kv > /tmp/xadd.log 2>&1 || { cat /tmp/xadd.log; exit 1; }; xt_traffic $tag || { grep -iE 'error|fail' /tmp/xc.log | tail -n 2; false; }"
    done
    check "second user works too (REALITY, SS2022, Hysteria2)" bash -c 'xt_traffic x-vless-raw-reality-vision t_ray2 && xt_traffic x-ss-2022-aes256 t_ray2 && xt_traffic x-hysteria-obfs t_ray2'
    check "tunnel (dokodemo-door) forwards to local SSH" bash -c "xt_add x-tunnel proto=tunnel port=8536 ttarget=127.0.0.1 tport=22 tnet=tcp > /dev/null && sleep 2 && timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/8536; head -c 7 <&3' | grep -q SSH-2.0"
    check "unknown user refused"                bash -c ". /dev/stdin <<< \"\$LIB\"; xray_client_json t_ray x-vless-ws-none | jq '.inbounds[0].port = 1089 | .outbounds[0].settings.vnext[0].users[0].id = \"00000000-0000-4000-8000-000000000000\"' > /root/xc.json; /usr/local/bin/xray run -c /root/xc.json > /dev/null 2>&1 & p=\$!; sleep 3; ! socks_get 1089; r=\$?; kill \$p; wait \$p 2> /dev/null; exit \$r"

    section "Xray: invalid combinations are refused"
    check "WebSocket + REALITY"            xt_refuse tag=n1 proto=vless method=websocket security=reality port=9101 target=www.microsoft.com:443
    check "mKCP + REALITY"                 xt_refuse tag=n2 proto=vless method=mkcp security=reality port=9102 target=www.microsoft.com:443
    check "Vision on WebSocket + TLS"      xt_refuse tag=n3 proto=vless method=websocket security=tls port=9103 cert=$SELF key=$SKEY path=/n flow=xtls-rprx-vision
    check "Vision on RAW without security" xt_refuse tag=n4 proto=vless method=raw security=none port=9104 flow=xtls-rprx-vision
    check "udp443 flow as a server flow"   xt_refuse tag=n5 proto=vless method=raw security=tls port=9105 cert=$SELF key=$SKEY flow=xtls-rprx-vision-udp443
    check "Vision on VMess"                xt_refuse tag=n6 proto=vmess method=raw security=tls port=9106 cert=$SELF key=$SKEY flow=xtls-rprx-vision
    check "Shadowsocks over TLS"           xt_refuse tag=n7 proto=shadowsocks method=raw security=tls port=9107 cert=$SELF key=$SKEY
    check "Hysteria without TLS"           xt_refuse tag=n8 proto=hysteria method=hysteria security=none port=9108
    check "MASQUE with REALITY"            xt_refuse tag=n9 proto=masque method=masque security=reality port=9109 target=www.microsoft.com:443
    check "VMess over Hysteria transport"  xt_refuse tag=n10 proto=vmess method=hysteria security=tls port=9110 cert=$SELF key=$SKEY
    check "removed transport (h2)"         xt_refuse tag=n11 proto=vless method=h2 security=tls port=9111 cert=$SELF key=$SKEY
    check "REALITY without target"         xt_refuse tag=n12 proto=vless method=raw security=reality port=9112
    check "TLS without certificate"        xt_refuse tag=n13 proto=vless method=raw security=tls port=9113
    check "XHTTP stream-one without TLS"   xt_refuse tag=n14 proto=vless method=xhttp security=none port=9114 path=/s mode=stream-one
    check "path without leading slash"     xt_refuse tag=n15 proto=vless method=websocket security=none port=9115 path=abc
    check "duplicate name"                 xt_refuse tag=x-vless-ws-none proto=vless method=websocket security=none port=9116 path=/d
    check "port of another inbound"        xt_refuse tag=n17 proto=vless method=websocket security=none port=8511 path=/d
    check "VLESS Encryption on Trojan"     xt_refuse tag=n18 proto=trojan method=raw security=none port=9118 enc=1

    section "Xray: links, client JSON, QR"
    check "REALITY link: pbk sid sni fp flow encryption" bash -c "$LIB; l=\$(xray_link t_ray x-vless-raw-reality-vision); for k in pbk= sid= sni=www.microsoft.com fp=chrome flow=xtls-rprx-vision security=reality type=tcp encryption=none; do grep -q \"\$k\" <<< \"\$l\" || { echo missing \$k in \$l; exit 1; }; done"
    check "udp443 variant only in the client" bash -c "$LIB; xray_link t_ray x-vless-raw-reality-udp443 | grep -q flow=xtls-rprx-vision-udp443 && ! jq -e '[.inbounds[].settings.clients[]?.flow] | index(\"xtls-rprx-vision-udp443\")' \$XRAY_CONF"
    check "VLESS Encryption link carries the client key" bash -c "$LIB; xray_link t_ray x-vless-enc-raw | grep -q 'encryption=mlkem768x25519plus'"
    check "private keys never leave the server" bash -c "$LIB; for t in x-vless-raw-reality-vision x-vless-enc-raw; do for k in \$(xr_meta \$t rpriv) \$(xr_meta \$t dec); do xray_link t_ray \$t | grep -qF \"\$k\" && exit 1; xray_client_json t_ray \$t | grep -qF \"\$k\" && exit 1; done; done; true"
    check "every protocol has a link or a JSON-only note" bash -c "$LIB; out=\$(xray_links t_ray); for s in vless:// vmess:// trojan:// ss:// hysteria2:// socks:// 'type=grpc' 'type=xhttp' 'type=httpupgrade' 'type=kcp' 'client JSON'; do grep -q \"\$s\" <<< \"\$out\" || { echo missing \$s; exit 1; }; done"
    check "QR codes render"                     bash -c "$LIB; apt_install qrencode > /dev/null; XRAY_QR=1 xray_links t_ray | grep -q '█'"
    if [[ ! -x /usr/local/bin/hysteria ]]; then bash -c "$LIB; hy_download > /dev/null 2>&1"; fi
    check "Xray-native Hysteria2 link works in the official Hysteria2 client" bash -c "$LIB; xt_hylink \"\$(xray_link t_ray x-hysteria-obfs)\""
    check "socks:// credentials work with curl"   bash -c "$LIB; id=\$(xray_user_get t_ray | cut -d: -f2); [[ \$(curl -s -m 15 -x socks5h://t_ray:\$id@127.0.0.1:8533 -o /dev/null -w '%{http_code}' https://www.google.com/generate_204) == 204 ]]"

    section "Xray: edit, enable/disable, expiry, rollback, migration"
    check "edit: new path, link and traffic follow" bash -c "$LIB; xr_wizard_reset; xr_load_meta x-vless-ws-none; W_path=/wnew; xr_commit x-vless-ws-none > /dev/null && xray_link t_ray x-vless-ws-none | grep -q 'path=%2Fwnew' && xt_traffic x-vless-ws-none"
    check "edit keeps REALITY keys" bash -c "$LIB; k=\$(xr_meta x-vless-grpc-reality rpriv); xr_wizard_reset; xr_load_meta x-vless-grpc-reality; W_sid=abcd1234; xr_commit x-vless-grpc-reality > /dev/null && [[ \$(xr_meta x-vless-grpc-reality rpriv) == \$k ]] && xt_traffic x-vless-grpc-reality"
    check "invalid edit refused, inbound unchanged" bash -c "$LIB; xr_wizard_reset; xr_load_meta x-vless-raw-reality-vision; W_method=websocket; ! xr_commit x-vless-raw-reality-vision > /dev/null 2>&1 && [[ \$(xr_meta x-vless-raw-reality-vision method) == raw ]] && xt_traffic x-vless-raw-reality-vision"
    check "disable: inbound leaves the config, settings kept" bash -c "$LIB; xray_disable_inbound x-socks > /dev/null && ! jq -e '.inbounds[] | select(.tag==\"x-socks\")' \$XRAY_CONF > /dev/null && [[ \$(xr_meta x-socks enabled) == false ]]"
    check "users added while disabled work after enable" bash -c "$LIB; xray_user_add t_ray3 3 > /dev/null && xray_enable_inbound x-socks > /dev/null && xt_traffic x-socks t_ray3"
    check "expired user removed from every inbound type" bash -c "$LIB; VPSP_NOW=\$(( \$(date +%s) + 4 * 86400 )) xray_enforce;
        cut -d: -f1,3 \$XRAY_USERS; jq -c '[.inbounds[] | {tag, u: ((.settings.clients // .settings.users // .settings.accounts // []) | map(.email // .user))}]' \$XRAY_CONF;
        ! grep -q t_ray3 \$XRAY_CONF && grep -q t_ray2 \$XRAY_CONF"
    check "expired user cannot connect"         bash -c '! xt_traffic x-vless-ws-none t_ray3'
    bash -c "$LIB; xray_user_del t_ray3" > /dev/null 2>&1
    check "parallel changes do not undo each other (lock)" bash -c "$LIB; xray_user_add t_p1 5 > /dev/null & xray_user_add t_p2 5 > /dev/null & xray_enforce & xray_user_add t_p3 5 > /dev/null & wait
        for u in t_p1 t_p2 t_p3; do
            n=\$(jq --arg u \"\$u\" '[.inbounds[] | (.settings.clients // .settings.users // .settings.accounts // [])[] | select((.email // .user) == \$u)] | length' \$XRAY_CONF)
            [[ \$n -gt 30 ]] || { echo \"\$u missing (\$n)\"; exit 1; }
        done
        xray_user_del t_p1 > /dev/null; xray_user_del t_p2 > /dev/null; xray_user_del t_p3 > /dev/null"
    python3 -m http.server 8599 --bind 0.0.0.0 > /dev/null 2>&1 & local hp=$!; sleep 1
    check "failed restart: previous config restored" bash -c "$LIB; b=\$(md5sum < \$XRAY_CONF); new=\$(jq '.inbounds += [{tag:\"clash\",port:8599,listen:\"0.0.0.0\",protocol:\"socks\",settings:{auth:\"noauth\"}}]' \$XRAY_CONF); ! xray_save \"\$new\" > /dev/null 2>&1 && [[ \$(md5sum < \$XRAY_CONF) == \$b ]] && systemctl is-active --quiet vpspanel-xray && xt_traffic x-vless-ws-none"
    kill "$hp" 2> /dev/null; wait "$hp" 2> /dev/null
    check "config rejected by xray -test is not installed" bash -c "$LIB; b=\$(md5sum < \$XRAY_CONF); ! xray_save '{\"inbounds\":[{\"protocol\":\"nope\"}]}' > /dev/null 2>&1 && [[ \$(md5sum < \$XRAY_CONF) == \$b ]]"

    section "Xray: interactive wizard"
    check "REALITY + Vision with defaults, through the menus" bash -c 'drive 3 13 1 w-rea k k k k 2 8590 127.0.0.1 k k k k k k 1 k 0 0 x && grep -q "CONFIGURATION SUMMARY" /tmp/vpsp-drive.out && . /dev/stdin <<< "$LIB" && [[ $(xr_meta w-rea security) == reality && $(xr_meta w-rea flow) == xtls-rprx-vision ]] && xt_traffic w-rea'
    check "Back steps return to earlier questions" bash -c 'drive 3 13 1 w-back k k k 0 0 0 0 "<" k 0 0 x && [[ $(grep -c "NEW XRAY CONFIGURATION" /tmp/vpsp-drive.out) -ge 2 ]] && . /dev/stdin <<< "$LIB" && [[ ! -f $(xr_meta_file w-back) ]]'
    check "Cancel at the summary saves nothing" bash -c 'drive 3 13 1 w-cancel 9 8591 k k k k 0 k 0 0 x && grep -q "CONFIGURATION SUMMARY" /tmp/vpsp-drive.out && grep -q "nothing was changed" /tmp/vpsp-drive.out && . /dev/stdin <<< "$LIB" && [[ ! -f $(xr_meta_file w-cancel) ]]'
    check "Xray screens open (view hides private keys)" bash -c 'drive 3 13 6 k 3 1 k 0 0 2 4 1 n n k 0 x && no_errors && grep -q "REALITY: RAW, XHTTP, gRPC only" /tmp/vpsp-drive.out && grep -q "V2RAY AND XRAY USER ADMINISTRATION" /tmp/vpsp-drive.out && grep -q "(hidden)" /tmp/vpsp-drive.out'

    check "migration of a v0.3 config (legacy field names)" bash -c "$LIB; for t in \$(xr_tags); do xray_remove_inbound \$t > /dev/null; done;
        id=\$(xray_user_get t_ray | cut -d: -f2)
        new=\$(jq --arg id \"\$id\" '.inbounds = [{tag:\"vpsp-vless-ws-8880\",listen:\"0.0.0.0\",port:8880,protocol:\"vless\",settings:{clients:[{id:\$id,email:\"t_ray\"}],decryption:\"none\"},streamSettings:{network:\"ws\",security:\"none\",wsSettings:{path:\"/old\"}}},
            {tag:\"vpsp-shadowsocks-tcp-8881\",listen:\"0.0.0.0\",port:8881,protocol:\"shadowsocks\",settings:{clients:[{password:\$id,method:\"aes-128-gcm\",email:\"t_ray\"}],network:\"tcp,udp\"}}]' \$XRAY_CONF)
        xray_save \"\$new\" > /dev/null && printf 'vpsp-vless-ws-8880 127.0.0.1\nvpsp-shadowsocks-tcp-8881 127.0.0.1\n' > \$XRAY_HOSTS &&
        xray_migrate && [[ \$(xr_meta vpsp-vless-ws-8880 method) == websocket && \$(xr_meta vpsp-shadowsocks-tcp-8881 ssm) == aes-128-gcm ]] &&
        xray_link t_ray vpsp-vless-ws-8880 | grep -q 'type=ws&path=%2Fold' && xt_traffic vpsp-vless-ws-8880 && xt_traffic vpsp-shadowsocks-tcp-8881 && xray_enforce && xt_traffic vpsp-vless-ws-8880"
    check "Xray uninstall"                      bash -c "$LIB; xray_uninstall"
    rm -f /root/xc.json
}
