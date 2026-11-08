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
             "$ROOT"/install.sh "$ROOT"/quick-install.sh "$ROOT"/update.sh "$ROOT"/uninstall.sh "$ROOT"/tests/run.sh; do
        check "bash -n ${f#"$ROOT"/}" bash -n "$f"
    done
    for f in vpspanel-wsproxy vpspanel-authd vpspanel-checkuser; do
        check "python3 compiles bin/$f" python3 -m py_compile "$ROOT/bin/$f"
    done
    if command -v shellcheck > /dev/null; then
        check "shellcheck (errors only)" shellcheck -S error -x "$ROOT"/bin/menu "$ROOT"/bin/vpspanel "$ROOT"/lib/*.sh \
            "$ROOT"/modules/*.sh "$ROOT"/install.sh "$ROOT"/quick-install.sh "$ROOT"/update.sh "$ROOT"/uninstall.sh
    fi
    check "no files referenced by the menu are missing" missing_files
}

missing_files() {
    local rc=0 f
    for f in update.sh uninstall.sh bin/vpspanel bin/vpspanel-dropbear bin/vpspanel-wsproxy bin/vpspanel-authd bin/vpspanel-checkuser \
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
        logout_vps() { exit 0; }
        menu_show() {
            local title=$1 info=$2 it label action
            local -a cmd
            shift 2
            title=${title:-MAIN MENU}
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
                [[ $it == - ]] && continue
                it=${it#@}
                n_items=$((n_items + 1))
                label=${it%%|*}; action=${it#*|}
                case $action in
                    soon) soon=$((soon + 1)); echo "  [soon] $label" ;;
                    ">"*) read -r -a cmd <<< "${action#>}"
                          echo "  [menu] ${label:0:40}"
                          "${cmd[@]}" ;;
                    *)    action=${action#!}; read -r -a cmd <<< "$action"
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
#   drive 2 2 0 0 x      each word is typed followed by Enter
#   drive 1 7 k 0 x      "k" (or "") presses Enter alone, e.g. at "Press Enter"
# Output goes to /tmp/vpsp-drive.out; returns the menu's exit status.
drive() {
    local k
    { sleep 1.5
      for k in "$@"; do
          if [[ $k == k ]]; then printf '\n'; else printf '%s\n' "$k"; fi
          sleep 0.7
      done
      sleep 1; } | TERM=xterm COLUMNS=60 timeout 120 script -qec "/usr/local/bin/menu" /dev/null > /tmp/vpsp-drive.raw 2>&1
    local rc=$?
    # Strip colour codes so the checks match the text as it reads on screen.
    sed 's/\x1b\[[0-9;]*m//g' /tmp/vpsp-drive.raw | tr -d '\r' > /tmp/vpsp-drive.out
    return $rc
}
no_errors() { ! grep -qE "command not found|unbound variable|syntax error|Internal error|bad array subscript" /tmp/vpsp-drive.out; }
MAIN_RE='MANAGE ACCOUNTS \(SSH/DROPBEAR\)'

navigation_tests() {
    section "Menu crawl (every screen, every option)"
    if menu_crawl > /tmp/vpsp-crawl.out 2>&1; then
        t_ok "$(tail -n1 /tmp/vpsp-crawl.out)"
    else
        t_fail "menu crawl"; grep -E "BAD|SUMMARY" /tmp/vpsp-crawl.out | sed 's/^/       /'
    fi

    section "Interactive navigation through a pseudo-terminal"
    rm -f /etc/vpspanel/panel.conf      # start from the default settings
    check "menu opens with the dashboard, x exits" bash -c 'drive x && grep -qE "$MAIN_RE" /tmp/vpsp-drive.out && grep -q "ACTIVE:" /tmp/vpsp-drive.out && grep -q "╔" /tmp/vpsp-drive.out'
    check "Back from every main section"      bash -c 'drive 1 0 2 0 3 0 4 0 5 0 x && [[ $(grep -cE "$MAIN_RE" /tmp/vpsp-drive.out) -eq 6 ]] && no_errors'
    check "nested Back (Protocols > Dropbear)" bash -c 'drive 2 2 0 0 x && grep -q "DROPBEAR MANAGER" /tmp/vpsp-drive.out && [[ $(grep -c "PROTOCOL ADMINISTRATION" /tmp/vpsp-drive.out) -eq 2 ]]'
    check "protocol list has two columns"     bash -c 'drive 2 0 x && grep -qE "\[1\]> SSH SETTINGS +\[ON\] +\[8\]> BADVPN-UDPGW" /tmp/vpsp-drive.out'
    check "x exits from a deep submenu"       bash -c 'drive 3 1 x && grep -q "SSL CERTIFICATE MANAGER" /tmp/vpsp-drive.out'
    check "invalid option is rejected"        bash -c 'drive 99 abc x && grep -q "Invalid option: 99" /tmp/vpsp-drive.out && grep -q "Invalid option: abc" /tmp/vpsp-drive.out'
    check "Coming Soon items explain themselves" bash -c 'drive 4 2 k 0 x && grep -qi "Telegram bot installer is coming soon" /tmp/vpsp-drive.out && no_errors'
    check "end of input closes the menu"      bash -c 'drive 1; [[ $? -eq 0 ]]'
    check "0 on the main menu ends the session" bash -c 'drive 0; [[ $? -ne 124 ]] && grep -qE "$MAIN_RE" /tmp/vpsp-drive.out'
    check "Script settings and system details" bash -c 'drive 5 8 k 9 k 11 k 0 x && grep -q "Load average" /tmp/vpsp-drive.out && grep -q "Installed in" /tmp/vpsp-drive.out && no_errors'
    check "dashboard blocks can be switched"  bash -c 'drive 5 5 0 x && tail -n 30 /tmp/vpsp-drive.out | grep -q "═Swap═" && drive 5 5 0 x && ! tail -n 30 /tmp/vpsp-drive.out | grep -q "═Swap═"'
    check "limiter toggles"                   bash -c 'drive 1 9 1 k 1 k 0 0 x && grep -q "ACCOUNT LIMITER" /tmp/vpsp-drive.out && grep -qE "limiter is now .*OFF" /tmp/vpsp-drive.out && grep -qE "limiter is now .*ON" /tmp/vpsp-drive.out && no_errors'
    check "create an account from the menu"   bash -c 'drive 1 1 t_menu Menu1234 7 1 k k 0 x && grep -q "USER CREATED SUCCESSFULLY" /tmp/vpsp-drive.out && id t_menu'
    check "Retry and Back on the save prompt" bash -c 'drive 1 1 t_rt Retry123 5 1 1 t_rt2 Retry123 5 1 0 0 x && ! id t_rt 2>/dev/null && ! id t_rt2 2>/dev/null && no_errors'
    check "edit user (password + limit)"      bash -c 'drive 1 4 t_menu NewPass77 3 k 0 x && vpspanel info t_menu | grep -q "Login limit: 3"'
    check "general password skips the prompt" bash -c 'drive 1 6 2 GenPass99 k 1 k 0 1 t_gen 5 1 k k 0 x && grep -q "general password" /tmp/vpsp-drive.out && id t_gen'
    vpspanel delete t_gen > /dev/null 2>&1
    check "temporary-user option appears when enabled" bash -c 'drive 1 13 7 k 0 0 x && grep -q "CREATE TEMPORARY USER" /tmp/vpsp-drive.out && drive 1 14 7 k 0 0 x'
    check "user table lists accounts"         bash -c 'drive 1 7 k k 0 x && grep -qE "1\) .*t_menu" /tmp/vpsp-drive.out'
    check "every Extra tools screen opens"    bash -c 'drive 3 1 0 2 0 3 0 4 0 5 0 6 0 7 0 8 0 9 0 0 x && no_errors && grep -q "FAIL2BAN MANAGER" /tmp/vpsp-drive.out && grep -q "DDOS PROTECTION" /tmp/vpsp-drive.out && grep -q "TIME ZONE" /tmp/vpsp-drive.out'
    check "every protocol screen opens"       bash -c 'drive 2 1 0 2 0 3 0 4 0 5 0 7 0 8 0 9 0 10 0 11 0 13 0 14 0 0 x && no_errors && grep -q "OPENVPN MANAGER" /tmp/vpsp-drive.out && grep -q "DNSTT (SLOWDNS) MANAGER" /tmp/vpsp-drive.out && grep -q "CHECKUSER VERIFICATION" /tmp/vpsp-drive.out'
    vpspanel delete t_menu > /dev/null 2>&1
    /opt/vpspanel/bin/vpspanel version > /dev/null
}
export -f drive no_errors
export MAIN_RE

# ------------------------------------------------------- account lifecycle ---
account_tests() {
    section "Accounts (CLI used by the menu)"
    local v=vpspanel exp5
    $v delete t_alice > /dev/null 2>&1; $v delete t_bob > /dev/null 2>&1
    check "create account"              $v create t_alice Secret123 30 1
    check "two-letter name (as ADMRufu)" bash -c 'vpspanel create ab Secret123 3 1 && vpspanel delete ab'
    check "account is in vpsusers group" bash -c 'id -gn t_alice | grep -qx vpsusers'
    check "account has no shell"        bash -c 'getent passwd t_alice | grep -q ":/bin/false$"'
    check "password is not in /etc/passwd" bash -c '! grep -q Secret123 /etc/passwd'
    check "duplicate is rejected"       bash -c '! vpspanel create t_alice x1234 1'
    check "bad username is rejected"    bash -c '! vpspanel create "Bad Name" pass1234 1'
    check "list shows ACTIVE"           bash -c 'NO_COLOR=1 vpspanel list | grep -E "^t_alice +ACTIVE"'
    exp5=$(date -d "+5 days" +%F)
    check "renew = today + days"        bash -c "vpspanel renew t_alice 5 && vpspanel info t_alice | grep -q 'Expires:     $exp5'"
    check "renew --extend adds days"    bash -c "vpspanel renew t_alice 5 --extend && vpspanel info t_alice | grep -q 'Expires:     $(date -d '+10 days' +%F)'"
    check "edit (password + limit)"     bash -c 'vpspanel edit t_alice Secret456 2 && vpspanel info t_alice | grep -q "Login limit: 2"'
    check "lock"                        bash -c 'vpspanel lock t_alice && vpspanel info t_alice | grep -q LOCKED'
    check "unlock"                      bash -c 'vpspanel unlock t_alice && vpspanel info t_alice | grep -q ACTIVE'
    check "temporary user (minutes)"    $v trial t_bob Trial123 2
    check "temporary user deleted when its minutes run out" bash -c 'VPSP_NOW=$(( $(date +%s) + 180 )) vpspanel enforce && ! id t_bob 2>/dev/null && ! vpspanel info t_bob 2>/dev/null'
    $v create t_old Old12345 1 1 > /dev/null
    check "expiry enforced by guard"    bash -c 'VPSP_NOW=$(( $(date +%s) + 3 * 86400 )) vpspanel enforce && [[ $(getent shadow t_old | cut -d: -f8) == 0 ]]'
    check "purge-expired"               bash -c 'VPSP_NOW=$(( $(date +%s) + 3 * 86400 )) vpspanel purge-expired | grep -q t_old && ! id t_old 2>/dev/null'
    check "backup"                      bash -c 'vpspanel backup /root/vpsp-test-backup.tar.gz'
    check "delete-all"                  bash -c 'vpspanel delete-all | grep -q t_alice && ! id t_alice 2>/dev/null'
    check "restore recreates account"   bash -c 'vpspanel restore /root/vpsp-test-backup.tar.gz && id t_alice'
    check "backup picked and deleted from the menu" bash -c 'vpspanel backup > /dev/null && n=$(ls /root/vpspanel-backups/*.tar.gz | wc -l) && drive 1 12 4 1 y k 0 0 x && [[ $(ls /root/vpspanel-backups/*.tar.gz | wc -l) -eq $((n - 1)) ]]'
    check "automatic daily backup"      bash -c '. /opt/vpspanel/lib/common.sh; set_config AUTO_BACKUP 1 && vpspanel enforce && ls /root/vpspanel-backups/vpspanel-backup-auto-*.tar.gz && set_config AUTO_BACKUP 0'
    cat > /root/vpsp-admrufu.json <<JSON
{ "ssh": { "imp1": { "conecciones": 2, "expira": "$exp5", "pass": "abc" },
           "t_alice": { "conecciones": 1, "expira": "$exp5", "pass": "x123" },
           "0": { "conecciones": 1, "expira": "$exp5", "pass": "y123" } } }
JSON
    check "import an ADMRufu2.0 backup" bash -c 'vpspanel import-admrufu /root/vpsp-admrufu.json | grep -q "Imported 1 account(s), skipped 2" && vpspanel info imp1 | grep -q "Login limit: 2" && vpspanel info imp1 | grep -q "Expires:     '"$exp5"'"'
    check "imported password works"     bash -c 'h=$(getent shadow imp1 | cut -d: -f2); printf "%s\nabc\n" "$h" | perl -e "my \$h=<STDIN>; my \$p=<STDIN>; chomp(\$h,\$p); exit(crypt(\$p,\$h) eq \$h ? 0 : 1)"'
    $v delete imp1 > /dev/null 2>&1; rm -f /root/vpsp-admrufu.json
    check "guard timer is active"       systemctl is-active --quiet vpspanel-guard.timer
}

# ------------------------------------------------------------- SSH tunnels ---
ssh_probe() { # ssh_probe PORT USER PASS [HOST] -> forwards stdio to local SSH and expects its banner
    timeout 25 sshpass -p "$3" ssh -p "$1" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -W 127.0.0.1:22 "$2@${4:-127.0.0.1}" < /dev/null 2>/dev/null | head -c 7 | grep -q 'SSH-2.0'
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
LIB="export VPSP_HOME=/opt/vpspanel; . /opt/vpspanel/lib/common.sh; . /opt/vpspanel/lib/accounts.sh; . /opt/vpspanel/lib/system.sh; . /opt/vpspanel/lib/ui.sh; for m in /opt/vpspanel/modules/*.sh; do . \$m; done; load_config"
export LIB

# http_probe PORT REQUEST EXPECT... - send REQUEST, assert every EXPECT is in the reply.
http_probe() {
    python3 - "$@" <<'PY'
import socket, sys, time
port, req, expect = int(sys.argv[1]), sys.argv[2].encode().decode("unicode_escape").encode("latin-1"), sys.argv[3:]
s = socket.create_connection(("127.0.0.1", port), timeout=10)
for part in req.split(b"<PAUSE>"):
    s.sendall(part); time.sleep(0.15)
data, end = b"", time.time() + 8
while time.time() < end and not all(e.encode() in data for e in expect):
    try:
        chunk = s.recv(4096)
    except socket.timeout:
        break
    if not chunk:
        break
    data += chunk
missing = [e for e in expect if e.encode() not in data]
assert not missing, (missing, data[:300])
PY
}
export -f http_probe

# socks_get PORT - fetch a page through a local SOCKS5 proxy.
socks_get() { curl -s -m 20 --socks5-hostname "127.0.0.1:$1" -o /dev/null -w '%{http_code}' http://example.com | grep -q 200; }
export -f socks_get
# killp PATTERN - stop background test processes, never this shell or its parents.
killp() { local p; for p in $(pgrep -f "$1"); do [[ $p == "$$" || $p == "$BASHPID" || $p == "$PPID" ]] || kill "$p" 2> /dev/null; done; }
export -f killp

ssh_like_protocols() {
    section "Dropbear, WebSocket/HTTP proxy, Stunnel, Squid"
    check "Dropbear on two ports (2143 2145)" bash -c "$LIB; dropbear_install '2143 2145'"
    check "tunnel through Dropbear port 1"    ssh_probe 2143 t_tun Tunnel123
    check "tunnel through Dropbear port 2"    ssh_probe 2145 t_tun Tunnel123
    check "Dropbear ports redefined"          bash -c "$LIB; dropbear_set_ports 2144 && sleep 1 && ss -ltn | grep -q ':2144 ' && ! ss -ltn | grep -q ':2143 '"
    check "direct proxy 101 (WebSocket)"      bash -c "$LIB; wsp_add 8081 22 101 && sleep 1"
    check "101 response, then SSH"            http_probe 8081 'GET / HTTP/1.1\r\nHost: a\r\nUpgrade: websocket\r\n\r\n' 'HTTP/1.1 101 Switching Protocols' 'SSH-2.0'
    check "split payload answered once"       http_probe 8081 'CONNECT a:443 HTTP/1.1\r\nHost: a\r\n\r\n<PAUSE>GET / HTTP/1.1\r\nHost: b\r\nUpgrade: websocket\r\n\r\n' 'HTTP/1.1 101' 'SSH-2.0'
    check "direct proxy 200 + custom header + banner" bash -c "$LIB; wsp_add 8082 2144 200 'Hello-Banner' '\\r\\nX-Test: yes\\r\\n\\r\\n' && sleep 1"
    check "200 response, header, banner, Dropbear" http_probe 8082 'GET / HTTP/1.1\r\nHost: a\r\n\r\n' 'HTTP/1.1 200 Hello-Banner' 'X-Test: yes' 'SSH-2.0-dropbear'
    check "CONNECT proxy limited to local ports" bash -c "$LIB; wsp_add 8083 connect 22,2144 && sleep 1"
    check "CONNECT to an allowed port"        http_probe 8083 'CONNECT 127.0.0.1:22 HTTP/1.1\r\n\r\n' '200 Connection established' 'SSH-2.0'
    check "CONNECT to another port refused"   http_probe 8083 'CONNECT example.com:443 HTTP/1.1\r\n\r\n' '403 Forbidden'
    check "real SSH tunnel through the CONNECT proxy" bash -c 'timeout 25 sshpass -p Tunnel123 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o "ProxyCommand=nc -X connect -x 127.0.0.1:8083 %h %p" -W 127.0.0.1:22 t_tun@127.0.0.1 < /dev/null 2>/dev/null | head -c 7 | grep -q SSH-2.0'
    check "self-signed certificate"           bash -c "$LIB; ssl_selfsigned 127.0.0.1"
    check "Stunnel on 4443 -> 22"             bash -c "$LIB; stn_install 4443 22 \$SSL_SELF/fullchain.pem \$SSL_SELF/privkey.pem"
    sleep 1
    check "TLS handshake then SSH banner"     bash -c 'timeout 10 openssl s_client -connect 127.0.0.1:4443 -quiet < <(sleep 3) 2>/dev/null | head -c 7 | grep -q SSH-2.0'
    check "Squid on 8888"                     bash -c "$LIB; squid_install 8888"
    check "Squid CONNECT to local SSH"        http_probe 8888 'CONNECT 127.0.0.1:22 HTTP/1.1\r\nHost: 127.0.0.1:22\r\n\r\n' ' 200 ' 'SSH-2.0'
    check "Squid refuses other hosts"         bash -c '! timeout 10 curl -s -f -x http://127.0.0.1:8888 http://example.com -o /dev/null'
    check "installed-service screens open"    bash -c 'drive 2 2 0 3 0 4 0 9 0 0 x && no_errors && grep -q "UNINSTALL DROPBEAR" /tmp/vpsp-drive.out && grep -q "Port 8083" /tmp/vpsp-drive.out && grep -q "DROPBEAR: 2144" /tmp/vpsp-drive.out'
    check "remove a proxy port from the menu" bash -c 'drive 2 3 3 8083 y k 0 0 x && [[ ! -f /etc/vpspanel/wsproxy/8083.env ]] && no_errors'
    check "Dropbear ports set from the menu"  bash -c 'drive 2 2 1 "2190 2144" 2 k 0 0 x && sleep 1 && ss -ltn | grep -q ":2190 " && grep -q "Port 2190.*AVAILABLE" /tmp/vpsp-drive.out'
    check "remove these services"             bash -c "$LIB; dropbear_remove && wsp_remove_all && stn_uninstall && squid_uninstall"
}

udp_and_vpn_protocols() {
    section "Checkuser"
    check "Checkuser on 5000 (UTC, DDMMYYYY)" bash -c "$LIB; cu_install 5000 utc ddmmyyyy && sleep 2"
    check "GET / returns the online count"    bash -c 'curl -s -m 5 http://127.0.0.1:5000/ | grep -qE "^[0-9]+$"'
    check "POST /checkuser returns the expiry" bash -c 'exp=$(awk -F: "\$1==\"t_tun\" {print \$2}" /etc/vpspanel/accounts.db); [[ $(curl -s -m 5 -X POST -H "Content-Type: application/json" -d "{\"user\":\"t_tun\"}" http://127.0.0.1:5000/checkuser) == $(TZ=UTC date -d "@$exp" +%d%m%Y) ]]'
    check "unknown user gets 404"             bash -c '[[ $(curl -s -o /dev/null -w "%{http_code}" -X POST -d "{\"user\":\"nobody1\"}" http://127.0.0.1:5000/checkuser) == 404 ]]'
    check "new account visible immediately"   bash -c 'vpspanel create t_cu Check123 4 1 > /dev/null && [[ -n $(curl -s -X POST -d "{\"user\":\"t_cu\"}" http://127.0.0.1:5000/checkuser) ]] && vpspanel delete t_cu > /dev/null'
    check "Checkuser uninstall"               bash -c "$LIB; cu_uninstall"

    section "DDoS protection"
    (python3 -m http.server 9999 --bind 0.0.0.0 > /dev/null 2>&1 &) ; sleep 1
    check "DDoS rules (port 9999, 5/min, 1 min)" bash -c "$LIB; ddos_install 9999 5 1 127.0.0.2 && iptables -S VPSPANEL-DDOS | grep -q hashlimit"
    check "excess connections from one IP are dropped" bash -c 'ok=0; for i in $(seq 1 12); do curl -s -m 2 -o /dev/null http://127.0.0.1:9999/ && ok=$((ok+1)); done; echo "accepted $ok of 12"; (( ok >= 4 && ok <= 7 ))'
    check "blocked address is listed, then cleared" bash -c "$LIB; m_ddos_banned | grep -q 127.0.0.1 && m_ddos_unban > /dev/null && curl -s -m 3 -o /dev/null http://127.0.0.1:9999/"
    check "DDoS uninstall"                    bash -c "$LIB; ddos_uninstall && ! iptables -S VPSPANEL-DDOS 2>/dev/null"
    pkill -f "http.server 9999" 2>/dev/null

    section "OpenVPN (login with a panel account)"
    check "OpenVPN install (TCP 1194)"        bash -c "$LIB; ovpn_install tcp 1194 AES-256-GCM 1.1.1.1 1.0.0.1 127.0.0.1 && sleep 2 && systemctl is-active --quiet openvpn-server@vpspanel"
    check "client file has no private key"    bash -c '! grep -q "PRIVATE KEY" /root/vpspanel-openvpn.ovpn && grep -q "<tls-crypt>" /root/vpspanel-openvpn.ovpn'
    printf 't_tun\nTunnel123\n' > /root/ovpn-ok.txt; printf 't_tun\nwrong\n' > /root/ovpn-bad.txt
    check "real client connects with the account" bash -c 'timeout 30 openvpn --config /root/vpspanel-openvpn.ovpn --auth-user-pass /root/ovpn-ok.txt --route-nopull --dev tun9 > /tmp/ovpn.log 2>&1 & sleep 20; grep -q "Initialization Sequence Completed" /tmp/ovpn.log; r=$?; killp "dev tun9"; exit $r'
    check "wrong password is refused"         bash -c 'timeout 25 openvpn --config /root/vpspanel-openvpn.ovpn --auth-user-pass /root/ovpn-bad.txt --route-nopull --dev tun9 > /tmp/ovpn.log 2>&1 & sleep 15; grep -q "AUTH_FAILED" /tmp/ovpn.log; r=$?; killp "dev tun9"; exit $r'
    rm -f /root/ovpn-ok.txt /root/ovpn-bad.txt
    check "OpenVPN screens open"              bash -c 'drive 2 10 1 k 0 0 x && no_errors && grep -q "RENEW CERTIFICATES" /tmp/vpsp-drive.out'
    check "OpenVPN uninstall"                 bash -c "$LIB; ovpn_uninstall"

    section "BadVPN UDPGW (built from source)"
    check "BadVPN build + port 7300"          bash -c "$LIB; bv_add_port 7300 && sleep 1 && ss -ltn | grep -q '127.0.0.1:7300 '"
    check "second port 7400, then removed"    bash -c "$LIB; bv_add_port 7400 && sleep 1 && ss -ltn | grep -q ':7400 ' && bv_remove_port 7400"
    check "BadVPN uninstall"                  bash -c "$LIB; bv_uninstall"

    if [[ ${VPSP_TEST_NETWORK:-1} == 1 ]]; then
        section "SlowDNS (dnstt built from source, real tunnel)"
        check "SlowDNS install (NS t.example.com -> 22)" bash -c "$LIB; SDNS_CLIENT_OUT=/root/dnstt-client sdns_install t.example.com 22 && sleep 2 && systemctl is-active --quiet vpspanel-slowdns"
        check "53 -> 5300 redirect rule present"  bash -c 'iptables -t nat -S PREROUTING | grep -q "dport 53 .*vpspanel-slowdns"'
        check "real SSH tunnel through dnstt"     bash -c '[[ -x /root/dnstt-client ]] || { echo "client not built"; exit 1; }; (/root/dnstt-client -udp 127.0.0.1:5300 -pubkey-file /etc/vpspanel/slowdns/server.pub t.example.com 127.0.0.1:7022 > /tmp/dnstt.log 2>&1 &); sleep 3; ssh_probe 7022 t_tun Tunnel123; r=$?; killp dnstt-client; exit $r'
        check "SlowDNS uninstall"                 bash -c "$LIB; sdns_uninstall && ! iptables -t nat -S PREROUTING | grep -q vpspanel-slowdns"
        rm -f /root/dnstt-client

        section "Hysteria2 (official binary, login with a panel account)"
        check "self-signed certificate"           bash -c "$LIB; ssl_selfsigned 127.0.0.1"
        check "Hysteria2 install (accounts, obfs, hop 20000:20100)" bash -c "$LIB; hy_install 36712 \$SSL_SELF/fullchain.pem \$SSL_SELF/privkey.pem 127.0.0.1 1 accounts obfs123x 20000:20100 && sleep 2 && systemctl is-active --quiet vpspanel-hysteria && systemctl is-active --quiet vpspanel-authd"
        check "port-hopping redirect rule present" bash -c 'iptables -t nat -S PREROUTING | grep -q "20000:20100 .*vpspanel-hysteria"'
        check "authd accepts the account"         bash -c 'curl -s -X POST -d "{\"addr\":\"1.2.3.4:5\",\"auth\":\"t_tun:Tunnel123\"}" http://127.0.0.1:18990/auth | grep -q "\"ok\": true"'
        check "authd refuses a wrong password"    bash -c 'curl -s -X POST -d "{\"addr\":\"1.2.3.5:5\",\"auth\":\"t_tun:nope\"}" http://127.0.0.1:18990/auth | grep -q "\"ok\": false"'
        hy_client() { cat > /root/hyc.yaml <<YAML
server: 127.0.0.1:36712
auth: $1
tls: {sni: 127.0.0.1, insecure: true}
obfs: {type: salamander, salamander: {password: obfs123x}}
socks5: {listen: 127.0.0.1:1088}
YAML
            (/usr/local/bin/hysteria client -c /root/hyc.yaml > /tmp/hyc.log 2>&1 &); sleep 4
            socks_get 1088; local r=$?; killp "hysteria client"; return $r; }
        export -f hy_client
        check "real Hysteria2 client traffic with the account" bash -c 'hy_client t_tun:Tunnel123'
        check "Hysteria2 refuses a wrong password" bash -c '! hy_client t_tun:wrongpass'
        check "expired account refused by Hysteria2" bash -c 'vpspanel create t_hyx Hyx12345 1 1 > /dev/null; f=/etc/vpspanel/accounts.db; cp $f /root/db.bak; awk -F: -v OFS=: "\$1==\"t_hyx\" {\$2=1} 1" /root/db.bak > $f; ! hy_client t_hyx:Hyx12345; r=$?; vpspanel delete t_hyx > /dev/null; exit $r'
        check "Hysteria2 screens open"            bash -c 'drive 2 7 1 k 0 0 x && no_errors && grep -q "hysteria2://USER:PASSWORD@127.0.0.1:36712,20000-20100/" /tmp/vpsp-drive.out'
        check "Hysteria2 uninstall"               bash -c "$LIB; hy_uninstall && ! systemctl is-active --quiet vpspanel-authd && ! iptables -t nat -S PREROUTING | grep -q vpspanel-hysteria"
        rm -f /root/hyc.yaml

        section "Xray (official binary, real traffic for every protocol)"
        check "Xray install (download + checksum)" bash -c "$LIB; xray_install"
        check "inbounds: VLESS WS, VLESS XHTTP, VMess WS, VLESS gRPC+TLS, Trojan TCP+TLS, Shadowsocks" bash -c "$LIB; \
            xray_add_inbound vless ws 8880 /vw 0 127.0.0.1 '' '' t-vless-ws && \
            xray_add_inbound vless xhttp 8881 /vx 0 127.0.0.1 '' '' t-vless-xhttp && \
            xray_add_inbound vmess ws 8882 /vm 0 127.0.0.1 '' '' t-vmess-ws && \
            xray_add_inbound vless grpc 8443 svc 1 127.0.0.1 \$SSL_SELF/fullchain.pem \$SSL_SELF/privkey.pem t-vless-grpc && \
            xray_add_inbound trojan tcp 8444 '' 1 127.0.0.1 \$SSL_SELF/fullchain.pem \$SSL_SELF/privkey.pem t-trojan && \
            xray_add_inbound shadowsocks tcp 8445 '' 0 127.0.0.1 '' '' t-ss && sleep 1 && systemctl is-active --quiet vpspanel-xray"
        check "user added to every inbound"       bash -c "$LIB; xray_user_add t_ray 2 && [[ \$(jq '[.inbounds[].settings.clients[] | select(.email==\"t_ray\")] | length' \$XRAY_CONF) == 6 ]]"
        check "share links for every protocol"    bash -c "$LIB; out=\$(xray_links t_ray); for s in vless:// vmess:// trojan:// ss:// 'type=grpc' 'type=xhttp'; do grep -q \"\$s\" <<< \"\$out\" || { echo missing \$s; exit 1; }; done"
        xray_traffic() { # xray_traffic TAG - run a client from the panel's client JSON, fetch a page
            . /dev/stdin <<< "$LIB"
            local pin; pin=$(openssl x509 -in "$SSL_SELF/fullchain.pem" -outform der | sha256sum | cut -d" " -f1)
            xray_client_json t_ray "$1" | jq --arg pin "$pin" '.inbounds[0].port = 1089
                | if .outbounds[0].streamSettings.tlsSettings then .outbounds[0].streamSettings.tlsSettings += {pinnedPeerCertSha256: $pin} else . end' > /root/xc.json
            (XRAY_LOCATION_ASSET=/usr/local/share/xray /usr/local/bin/xray run -c /root/xc.json > /tmp/xc.log 2>&1 &); sleep 3
            socks_get 1089; local r=$?; killp "xray run -c /root/xc.json"; sleep 1; return $r
        }
        export -f xray_traffic
        for t in t-vless-ws t-vless-xhttp t-vmess-ws t-vless-grpc t-trojan t-ss; do
            check "real traffic: $t" bash -c "xray_traffic $t || { tail -n 5 /tmp/xc.log; false; }"
        done
        check "unknown user refused"              bash -c ". /dev/stdin <<< \"\$LIB\"; xray_client_json t_ray t-vless-ws | jq '.inbounds[0].port = 1089 | .outbounds[0].settings.vnext[0].users[0].id = \"00000000-0000-4000-8000-000000000000\"' > /root/xc.json; (/usr/local/bin/xray run -c /root/xc.json > /dev/null 2>&1 &); sleep 3; ! socks_get 1089; r=\$?; killp 'xray run -c /root/xc.json'; exit \$r"
        check "renew = today + days"              bash -c "$LIB; xray_user_renew t_ray 5 && [[ \$(date -d @\$(awk -F: '\$1==\"t_ray\" {print \$3}' \$XRAY_USERS) +%F) == \$(date -d '+5 days' +%F) ]]"
        check "Xray screens open"                 bash -c 'drive 1 0 2 4 1 n n k 0 x && no_errors && grep -q "V2RAY AND XRAY USER ADMINISTRATION" /tmp/vpsp-drive.out && grep -q "t_ray" /tmp/vpsp-drive.out'
        check "expired user removed by the guard" bash -c "$LIB; VPSP_NOW=\$(( \$(date +%s) + 9 * 86400 )) xray_enforce; ! jq -e '.inbounds[].settings.clients[] | select(.email==\"t_ray\")' \$XRAY_CONF"
        check "Xray uninstall"                    bash -c "$LIB; xray_uninstall"
        rm -f /root/xc.json
    fi

    section "WireGuard"
    check "WireGuard install (wg0)"     bash -c "$LIB; wg_install 51820 203.0.113.1 || { echo 'kernel/container may lack WireGuard'; false; }"
    if systemctl is-active --quiet wg-quick@wg0; then
        check "WireGuard client add"    bash -c "$LIB; wg_client_add t_phone && grep -q 'Endpoint = 203.0.113.1:51820' \$WG_CLIENTS/t_phone.conf && wg show wg0 peers | grep -q ."
        check "WireGuard accounts appear in the main menu" bash -c 'drive x && grep -q "MANAGE ACCOUNTS (WIREGUARD)" /tmp/vpsp-drive.out'
        check "WireGuard client remove" bash -c "$LIB; wg_client_del t_phone && [[ -z \$(wg show wg0 peers) ]]"
        check "WireGuard uninstall"     bash -c "$LIB; wg_uninstall"
    fi

    section "System tools"
    check "blocking rules on/off"       bash -c "$LIB; fwb_toggle torrent Torrent && iptables -S VPSPANEL-BLOCK | grep -q peer_id && fwb_toggle torrent Torrent && ! iptables -S VPSPANEL-BLOCK 2>/dev/null"
    check "BBR toggle"                  bash -c "$LIB; if bbr_enable; then bbr_disable; else echo 'kernel without BBR (container) - skipped'; fi"
    check "time zone set and restore"   bash -c "$LIB; old=\$(tz_current); tz_set Europe/London && tz_set \"\$old\""
    check "banner apply/remove"         bash -c "$LIB; banner_apply 'Welcome\\nto test' && grep -q Welcome \$BANNER_FILE && sshd -t && banner_apply ''"
    check "SSH port change keeps 22"    bash -c "$LIB; ssh_set_ports 22 2222 && sleep 1 && ss -ltn | grep -q ':2222 ' && ssh_set_ports 22"
}

# ------------------------------------------------------------------ main ---
static_tests
if [[ ${1:-} != static ]]; then
    [[ $(id -u) -eq 0 ]] || { echo "Run the full suite as root on a disposable machine." >&2; exit 1; }
    [[ -x /usr/local/bin/menu ]] || { echo "Install VPSPanel first: bash install.sh" >&2; exit 1; }
    for dep in sshpass openvpn netcat-openbsd; do dpkg -s "$dep" > /dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$dep" > /dev/null 2>&1; done
    case ${1:-all} in
        nav)       navigation_tests ;;
        accounts)  account_tests ;;
        protocols) tunnel_tests; ssh_like_protocols; udp_and_vpn_protocols ;;
        *)         navigation_tests; account_tests; tunnel_tests; ssh_like_protocols; udp_and_vpn_protocols ;;
    esac
    vpspanel delete-all > /dev/null 2>&1
    rm -f /root/vpsp-test-backup.tar.gz
fi
printf '\n\e[1m%d passed, %d failed\e[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
