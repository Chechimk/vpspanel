#!/bin/bash
# VPSPanel test suite. Run as root on a DISPOSABLE Ubuntu/Debian machine or
# container, after `bash install.sh`. It creates and deletes accounts.
#
#   sudo bash tests/run.sh            # all tests
#   sudo bash tests/run.sh static     # syntax checks only (safe anywhere)
set -uo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
PASS=0 FAIL=0
t_ok()   { PASS=$((PASS + 1)); printf '  \e[32mPASS\e[0m %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf '  \e[31mFAIL\e[0m %s\n' "$*"; }
check()  { local name=$1; shift; if "$@" > /tmp/vpsp-test.out 2>&1; then t_ok "$name"; else t_fail "$name"; sed 's/^/       /' /tmp/vpsp-test.out | tail -n 15; fi; }
section() { printf '\n\e[1m%s\e[0m\n' "$*"; }

# ---------------------------------------------------------------- static ---
static_tests() {
    section "Static checks"
    local f
    for f in "$ROOT"/bin/menu "$ROOT"/bin/vpspanel "$ROOT"/bin/vpspanel-dropbear "$ROOT"/lib/*.sh "$ROOT"/modules/*.sh \
             "$ROOT"/install.sh "$ROOT"/update.sh "$ROOT"/uninstall.sh "$ROOT"/tests/run.sh; do
        check "bash -n ${f#"$ROOT"/}" bash -n "$f"
    done
    check "python3 compiles bin/vpspanel-wsproxy" python3 -m py_compile "$ROOT/bin/vpspanel-wsproxy"
    if command -v shellcheck > /dev/null; then
        check "shellcheck (errors only)" shellcheck -S error -x "$ROOT"/bin/menu "$ROOT"/bin/vpspanel "$ROOT"/lib/*.sh \
            "$ROOT"/modules/*.sh "$ROOT"/install.sh "$ROOT"/update.sh "$ROOT"/uninstall.sh
    fi
    check "no files referenced by the menu are missing" missing_files
}

missing_files() {
    local rc=0 f
    for f in update.sh uninstall.sh bin/vpspanel bin/vpspanel-dropbear bin/vpspanel-wsproxy \
             systemd/vpspanel-guard.service systemd/vpspanel-guard.timer docs/ROADMAP.md; do
        [[ -e $ROOT/$f ]] || { echo "missing: $f"; rc=1; }
    done
    return $rc
}

# ------------------------------------------------------------ menu crawl ---
# Loads bin/menu as a library, replaces menu_show with a crawler that visits
# every submenu and checks that each action resolves to a function/command.
menu_crawl() {
    VPSP_MENU_LIB=1 NO_COLOR=1 bash -c '
        set -uo pipefail
        . "$1/bin/menu"
        declare -A SEEN=()
        bad=0 menus=0 n_items=0 soon=0
        ui_pause() { :; }
        menu_show() {
            local title=$1 info=$2 it label action
            local -a cmd
            shift 2
            [[ -n ${SEEN[$title]:-} ]] && return 1
            SEEN[$title]=1; menus=$((menus + 1))
            echo "MENU $title"
            if [[ $info != - ]]; then
                declare -F "$info" > /dev/null || { echo "  BAD info function $info"; bad=$((bad + 1)); }
                "$info" > /dev/null 2> /tmp/vpsp-info.err
                if grep -qE "command not found|unbound variable|syntax error" /tmp/vpsp-info.err; then
                    echo "  BAD info output: $(head -n1 /tmp/vpsp-info.err)"; bad=$((bad + 1))
                fi
            fi
            for it in "$@"; do
                n_items=$((n_items + 1))
                label=${it%%|*}; action=${it#*|}
                case $action in
                    soon) soon=$((soon + 1)); echo "  [soon] $label" ;;
                    ">"*) read -r -a cmd <<< "${action#>}"
                          echo "  [menu] ${label:0:40}"
                          "${cmd[@]}" ;;
                    *)    read -r -a cmd <<< "$action"
                          if declare -F "${cmd[0]}" > /dev/null || command -v "${cmd[0]}" > /dev/null; then
                              echo "  [run ] ${label:0:40} -> ${cmd[0]}"
                          else
                              echo "  BAD action ${cmd[0]} for \"$label\""; bad=$((bad + 1))
                          fi ;;
                esac
            done
            return 1
        }
        trap '"'"'echo "SUMMARY menus=$menus items=$n_items soon=$soon bad=$bad"; [[ $bad == 0 ]]'"'"' EXIT
        main_menu
    ' _ "$ROOT"
}

# Drive the real menu through a pseudo-terminal, typing like a person:
#   drive 4 2 0 0 0      each word is typed followed by Enter
#   drive 7 2 1 k 0      "k" is a single key press (for "Press any key")
# Output goes to /tmp/vpsp-drive.out; returns the menu's exit status.
drive() {
    local k
    { sleep 1.5
      for k in "$@"; do
          if [[ $k == k ]]; then printf 'k'; else printf '%s\n' "$k"; fi
          sleep 0.7
      done
      sleep 1; } | TERM=xterm COLUMNS=64 timeout 90 script -qec "/usr/local/bin/menu" /dev/null > /tmp/vpsp-drive.out 2>&1
}
no_errors() { ! grep -qE "command not found|unbound variable|syntax error|Internal error" /tmp/vpsp-drive.out; }

navigation_tests() {
    section "Menu crawl (every screen, every option)"
    if menu_crawl > /tmp/vpsp-crawl.out 2>&1; then
        t_ok "$(tail -n1 /tmp/vpsp-crawl.out)"
    else
        t_fail "menu crawl"; grep -E "BAD|SUMMARY" /tmp/vpsp-crawl.out | sed 's/^/       /'
    fi

    section "Interactive navigation through a pseudo-terminal"
    check "menu opens and 0 exits"            bash -c 'drive 0 && grep -q "MAIN MENU" /tmp/vpsp-drive.out'
    # Xray/WireGuard account screens explain they are not installed and wait for a key.
    check "Back from every main section"      bash -c 'drive 1 0 2 k 3 k 4 0 5 0 6 0 7 0 0 && [[ $(grep -c "MAIN MENU" /tmp/vpsp-drive.out) -eq 8 ]] && no_errors'
    check "nested Back (Protocols > Dropbear)" bash -c 'drive 4 2 0 0 0 && grep -q "DROPBEAR MANAGER" /tmp/vpsp-drive.out && [[ $(grep -c "PROTOCOL CONFIGURATION" /tmp/vpsp-drive.out) -eq 2 ]]'
    check "x exits from a deep submenu"       bash -c 'drive 5 1 x && grep -q "SSL CERTIFICATE MANAGER" /tmp/vpsp-drive.out'
    check "invalid option is rejected"        bash -c 'drive 99 abc 0 && grep -q "Invalid option: 99" /tmp/vpsp-drive.out && grep -q "Invalid option: abc" /tmp/vpsp-drive.out'
    check "Coming Soon items explain themselves" bash -c 'drive 6 2 k 0 0 && grep -q "Telegram bot is coming soon" /tmp/vpsp-drive.out && no_errors'
    check "end of input closes the menu"      bash -c 'drive 1; [[ $? -eq 0 ]]'
    check "System information screens"        bash -c 'drive 7 2 1 k 2 k 3 k 4 k 5 k 0 0 0 && grep -q "Load average" /tmp/vpsp-drive.out && grep -q "SSH sessions" /tmp/vpsp-drive.out && no_errors'
    check "Account defaults and limiter screens" bash -c 'drive 7 3 0 0 1 10 1 k 1 k 0 0 0 && grep -q "ACCOUNT LIMITER" /tmp/vpsp-drive.out && grep -qE "expired-account limiter is now .*OFF" /tmp/vpsp-drive.out && grep -qE "expired-account limiter is now .*ON" /tmp/vpsp-drive.out && no_errors'
    check "create an account from the menu"   bash -c 'drive 1 1 t_menu Menu1234 7 1 k 0 0 && grep -q "Save these details now" /tmp/vpsp-drive.out && id t_menu && vpspanel delete t_menu'
    check "every Extra tools screen opens"    bash -c 'drive 5 1 0 2 0 3 0 4 0 5 0 6 0 7 0 9 0 0 0 && no_errors && grep -q "FAIL2BAN MANAGER" /tmp/vpsp-drive.out && grep -q "TIME ZONE" /tmp/vpsp-drive.out'
}
export -f drive no_errors

# ------------------------------------------------------- account lifecycle ---
account_tests() {
    section "Accounts (CLI used by the menu)"
    local v=vpspanel
    $v delete t_alice > /dev/null 2>&1; $v delete t_bob > /dev/null 2>&1
    check "create account"              $v create t_alice Secret123 30 1
    check "account is in vpsusers group" bash -c 'id -gn t_alice | grep -qx vpsusers'
    check "account has no shell"        bash -c 'getent passwd t_alice | grep -q ":/bin/false$"'
    check "duplicate is rejected"       bash -c '! vpspanel create t_alice x1234 1'
    check "bad username is rejected"    bash -c '! vpspanel create "Bad Name" pass1234 1'
    check "list shows ACTIVE"           bash -c 'NO_COLOR=1 vpspanel list | grep -E "^t_alice +ACTIVE"'
    check "renew adds days"             $v renew t_alice 5
    check "limit change"                bash -c 'vpspanel limit t_alice 2 && vpspanel info t_alice | grep -q "Login limit: 2"'
    check "lock"                        bash -c 'vpspanel lock t_alice && vpspanel info t_alice | grep -q LOCKED'
    check "unlock"                      bash -c 'vpspanel unlock t_alice && vpspanel info t_alice | grep -q ACTIVE'
    check "trial account"               $v trial t_bob Trial123 2
    check "expiry enforced by guard"    bash -c 'VPSP_NOW=$(( $(date +%s) + 3 * 86400 )) vpspanel enforce && [[ $(getent shadow t_bob | cut -d: -f8) == 0 ]]'
    check "purge-expired removes trial" bash -c 'VPSP_NOW=$(( $(date +%s) + 3 * 86400 )) vpspanel purge-expired | grep -q t_bob && ! id t_bob 2>/dev/null'
    check "backup"                      bash -c 'vpspanel backup /root/vpsp-test-backup.tar.gz'
    check "delete-all"                  bash -c 'vpspanel delete-all | grep -q t_alice && ! id t_alice 2>/dev/null'
    check "restore recreates account"   bash -c 'vpspanel restore /root/vpsp-test-backup.tar.gz && id t_alice'
    check "guard timer is active"       systemctl is-active --quiet vpspanel-guard.timer
}

# ------------------------------------------------------------- SSH tunnels ---
ssh_probe() { # ssh_probe PORT USER PASS -> forwards stdio to local SSH and expects its banner
    timeout 20 sshpass -p "$3" ssh -p "$1" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -W 127.0.0.1:22 "$2@127.0.0.1" < /dev/null 2>/dev/null | head -c 7 | grep -q 'SSH-2.0'
}
export -f ssh_probe

tunnel_tests() {
    section "SSH tunnelling with a panel account"
    command -v sshpass > /dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -q sshpass > /dev/null
    vpspanel delete t_tun > /dev/null 2>&1
    vpspanel create t_tun Tunnel123 3 1 > /dev/null
    check "sshd config valid after install"     sshd -t
    check "panel user: password + forwarding"   bash -c 'sshd -T -C user=t_tun,host=x,addr=10.0.0.1 | grep -qx "passwordauthentication yes"'
    check "tunnel through OpenSSH"              ssh_probe 22 t_tun Tunnel123
    check "wrong password is refused"           bash -c '! ssh_probe 22 t_tun wrongpass'
    check "panel user has no shell"             bash -c '! timeout 15 sshpass -p Tunnel123 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null t_tun@127.0.0.1 "echo SHELL-OK" 2>/dev/null | grep -q SHELL-OK'

    section "Login limit enforcement"
    timeout 60 sshpass -p Tunnel123 ssh -N -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null t_tun@127.0.0.1 & local p1=$!
    timeout 60 sshpass -p Tunnel123 ssh -N -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null t_tun@127.0.0.1 & local p2=$!
    sleep 4
    check "two sessions open"                   bash -c '[[ $(ps -o comm= -u t_tun | grep -cE "^(sshd|sshd-session)$") -ge 2 ]]'
    vpspanel enforce; sleep 1
    check "limit 1 closes the extra session"    bash -c '[[ $(ps -o comm= -u t_tun | grep -cE "^(sshd|sshd-session)$") -eq 1 ]]'
    vpspanel lock t_tun > /dev/null; sleep 1
    check "lock closes remaining sessions"      bash -c '[[ $(ps -o comm= -u t_tun | grep -cE "^(sshd|sshd-session)$") -eq 0 ]]'
    vpspanel unlock t_tun > /dev/null
    kill "$p1" "$p2" 2> /dev/null; wait 2> /dev/null
}

# ------------------------------------------------------------ protocols ---
protocol_tests() {
    section "Protocol modules (installed through the module functions)"
    local lib="export VPSP_HOME=/opt/vpspanel; . /opt/vpspanel/lib/common.sh; . /opt/vpspanel/lib/accounts.sh; . /opt/vpspanel/lib/system.sh; . /opt/vpspanel/lib/ui.sh; for m in /opt/vpspanel/modules/*.sh; do . \$m; done"
    check "Dropbear install on 2143"    bash -c "$lib; dropbear_install 2143"
    check "tunnel through Dropbear"     ssh_probe 2143 t_tun Tunnel123
    check "Dropbear port change"        bash -c "$lib; dropbear_set_port 2144 && sleep 1 && ss -ltn | grep -q ':2144 '"
    check "WebSocket proxy on 8081"     bash -c "$lib; wsp_add 8081 22 'Switching Protocols'"
    sleep 1
    check "WebSocket proxy answers 101 then relays SSH" python3 - <<'PY'
import socket
s = socket.create_connection(("127.0.0.1", 8081), timeout=10)
s.sendall(b"GET / HTTP/1.1\r\nHost: example.com\r\nUpgrade: websocket\r\n\r\n")
data = b""
while b"SSH-2.0" not in data:
    chunk = s.recv(4096)
    if not chunk:
        break
    data += chunk
assert data.startswith(b"HTTP/1.1 101 Switching Protocols\r\n\r\n"), data[:80]
assert b"SSH-2.0" in data, data[:200]
PY
    check "WebSocket proxy, split payload"  python3 - <<'PY'
import socket, time
s = socket.create_connection(("127.0.0.1", 8081), timeout=10)
s.sendall(b"CONNECT a:443 HTTP/1.1\r\nHost: a\r\n\r\n")
time.sleep(0.1)
s.sendall(b"GET / HTTP/1.1\r\nHost: b\r\nUpgrade: websocket\r\n\r\n")
data = b""
while b"SSH-2.0" not in data:
    chunk = s.recv(4096)
    if not chunk:
        break
    data += chunk
assert data.count(b"HTTP/1.1 101") == 1 and b"SSH-2.0" in data, data[:200]
PY
    check "self-signed certificate"     bash -c "$lib; ssl_selfsigned 127.0.0.1"
    check "Stunnel on 4443 -> 22"       bash -c "$lib; stn_install 4443 22 \$SSL_SELF/fullchain.pem \$SSL_SELF/privkey.pem"
    sleep 1
    check "TLS handshake then SSH banner" bash -c 'timeout 10 openssl s_client -connect 127.0.0.1:4443 -quiet < <(sleep 3) 2>/dev/null | head -c 7 | grep -q SSH-2.0'
    check "Stunnel add/remove port"     bash -c "$lib; stn_add_port 4444 22 && stn_remove_port 4444"
    check "Squid on 8888"               bash -c "$lib; squid_install 8888"
    check "Squid CONNECT to local SSH"  python3 - <<'PY'
import socket
s = socket.create_connection(("127.0.0.1", 8888), timeout=10)
s.sendall(b"CONNECT 127.0.0.1:22 HTTP/1.1\r\nHost: 127.0.0.1:22\r\n\r\n")
data = b""
while b"SSH-2.0" not in data:
    chunk = s.recv(4096)
    if not chunk:
        break
    data += chunk
assert b" 200 " in data.split(b"\r\n")[0] and b"SSH-2.0" in data, data[:200]
PY
    check "Squid refuses other hosts"   bash -c '! timeout 10 curl -s -f -x http://127.0.0.1:8888 http://example.com -o /dev/null'
    check "blocking rules on/off"       bash -c "$lib; fwb_toggle torrent Torrent && iptables -S VPSPANEL-BLOCK | grep -q peer_id && fwb_toggle torrent Torrent && ! iptables -S VPSPANEL-BLOCK 2>/dev/null"
    check "BBR toggle"                  bash -c "$lib; if bbr_enable; then bbr_disable; else echo 'kernel without BBR (container) - skipped'; fi"
    check "time zone set and restore"   bash -c "$lib; old=\$(tz_current); tz_set Europe/London && tz_set \"\$old\""
    check "banner apply/remove"         bash -c "$lib; banner_apply 'Welcome\\nto test' && grep -q Welcome \$BANNER_FILE && sshd -t && banner_apply ''"
    check "SSH port change keeps 22"    bash -c "$lib; ssh_set_ports 22 2222 && sleep 1 && ss -ltn | grep -q ':2222 ' && ssh_set_ports 22"
    if [[ ${VPSP_TEST_NETWORK:-1} == 1 ]]; then
        check "Xray install (download + checksum)" bash -c "$lib; xray_install"
        check "Xray VLESS+WS inbound"       bash -c "$lib; xray_add_inbound vless ws 8880 /vt 0 127.0.0.1 && sleep 1 && systemctl is-active --quiet vpspanel-xray && ss -ltn | grep -q ':8880 '"
        check "Xray VMess+WS+TLS inbound"   bash -c "$lib; xray_add_inbound vmess ws 8443 /vm 1 127.0.0.1 \$SSL_SELF/fullchain.pem \$SSL_SELF/privkey.pem && sleep 1 && systemctl is-active --quiet vpspanel-xray"
        check "Xray user + share links"     bash -c "$lib; xray_user_add t_ray 1 && xray_links t_ray | grep -q 'vless://' && xray_links t_ray | grep -q 'vmess://' && [[ \$(jq '[.inbounds[].settings.clients[] | select(.email==\"t_ray\")] | length' \$XRAY_CONF) == 2 ]]"
        check "Xray menus open"             bash -c 'drive 2 5 k 0 0 && no_errors && grep -q t_ray /tmp/vpsp-drive.out && grep -q "V2RAY / XRAY ACCOUNTS" /tmp/vpsp-drive.out'
        check "Xray expired user removed"   bash -c "$lib; VPSP_NOW=\$(( \$(date +%s) + 3 * 86400 )) xray_enforce; ! jq -e '.inbounds[].settings.clients[] | select(.email==\"t_ray\")' \$XRAY_CONF"
        check "Xray uninstall"              bash -c "$lib; xray_uninstall"
        check "Hysteria2 install"           bash -c "$lib; hy_install 36712 \$SSL_SELF/fullchain.pem \$SSL_SELF/privkey.pem 127.0.0.1 1 && sleep 1 && systemctl is-active --quiet vpspanel-hysteria"
        check "Hysteria2 obfs + restart"    bash -c "$lib; hy_set OBFS testobfs123 && hy_restart && sleep 1 && systemctl is-active --quiet vpspanel-hysteria"
        check "Hysteria2 uninstall"         bash -c "$lib; hy_uninstall"
    fi
    check "WireGuard install (wg0)"     bash -c "$lib; wg_install 51820 203.0.113.1 || { echo 'kernel/container may lack WireGuard'; false; }"
    if systemctl is-active --quiet wg-quick@wg0; then
        check "WireGuard client add"    bash -c "$lib; wg_client_add t_phone && grep -q 'Endpoint = 203.0.113.1:51820' \$WG_CLIENTS/t_phone.conf && wg show wg0 peers | grep -q ."
        check "WireGuard client remove" bash -c "$lib; wg_client_del t_phone && [[ -z \$(wg show wg0 peers) ]]"
        check "WireGuard uninstall"     bash -c "$lib; wg_uninstall"
    fi
    check "installed-service menus open without errors" bash -c 'drive 4 2 0 3 0 4 0 9 0 0 0 && no_errors && grep -q "Uninstall Dropbear" /tmp/vpsp-drive.out && grep -q "Remove a TLS port" /tmp/vpsp-drive.out && grep -q "Port 8081" /tmp/vpsp-drive.out && grep -q "Uninstall Squid" /tmp/vpsp-drive.out'
    check "remove test services"        bash -c "$lib; dropbear_remove && wsp_remove_all && stn_uninstall && squid_uninstall"
}

# ------------------------------------------------------------------ main ---
static_tests
if [[ ${1:-} != static ]]; then
    [[ $(id -u) -eq 0 ]] || { echo "Run the full suite as root on a disposable machine." >&2; exit 1; }
    [[ -x /usr/local/bin/menu ]] || { echo "Install VPSPanel first: bash install.sh" >&2; exit 1; }
    navigation_tests
    account_tests
    tunnel_tests
    protocol_tests
    vpspanel delete-all > /dev/null 2>&1
    rm -f /root/vpsp-test-backup.tar.gz
fi
printf '\n\e[1m%d passed, %d failed\e[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
