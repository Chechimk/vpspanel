# shellcheck shell=bash
# vpspanel - SSH/VPN account management.
#
# Accounts are ordinary Linux users in the "$VPSP_GROUP" group, with no home
# directory and a non-login shell, so they can only open tunnels.
# Panel metadata lives in $VPSP_DB, one account per line:
#
#     username:expire_epoch:max_logins:created_epoch:kind
#
# kind is "normal" or "trial". Passwords are never stored by the panel.

# Process names that represent one client session.
VPSP_SESSION_RE='^(sshd|sshd-session|dropbear)$'

# -------------------------------------------------------------- database ---
db_init() {
    mkdir -p "$(dirname "$VPSP_DB")"
    [[ -f $VPSP_DB ]] || : > "$VPSP_DB"
    chmod 600 "$VPSP_DB"
}

db_get() {
    [[ -f $VPSP_DB ]] || return 1
    awk -F: -v u="$1" '$1 == u { print; found = 1 } END { exit !found }' "$VPSP_DB"
}

# db_field USER N  (1=user 2=expire 3=limit 4=created 5=kind)
db_field() { db_get "$1" | cut -d: -f"$2"; }

db_users() {
    [[ -f $VPSP_DB ]] || return 0
    cut -d: -f1 "$VPSP_DB" | grep -v '^$' || true
}

# db_put USER EXPIRE LIMIT CREATED KIND - insert or replace.
db_put() {
    db_init
    local tmp
    tmp=$(mktemp "${VPSP_DB}.XXXXXX") || return 1
    awk -F: -v u="$1" '$1 != u' "$VPSP_DB" > "$tmp"
    printf '%s:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" "$5" >> "$tmp"
    sort -t: -k1,1 -o "$tmp" "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$VPSP_DB"
}

db_del() {
    [[ -f $VPSP_DB ]] || return 0
    local tmp
    tmp=$(mktemp "${VPSP_DB}.XXXXXX") || return 1
    awk -F: -v u="$1" '$1 != u' "$VPSP_DB" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$VPSP_DB"
}

# ---------------------------------------------------------------- status ---
acct_is_panel()   { db_get "$1" > /dev/null; }
acct_os_exists()  { getent passwd "$1" > /dev/null; }

acct_is_locked() {
    local st
    st=$(passwd -S "$1" 2>/dev/null | awk '{print $2}')
    [[ $st == L || $st == LK ]]
}

acct_is_expired() {
    local exp
    exp=$(db_field "$1" 2) || return 1
    (( $(now_epoch) >= exp ))
}

# ACTIVE | EXPIRED | LOCKED
acct_status() {
    if acct_is_locked "$1"; then echo LOCKED
    elif acct_is_expired "$1"; then echo EXPIRED
    else echo ACTIVE
    fi
}

# Number of open sessions (SSH or Dropbear) for a user.
acct_sessions() {
    local n
    n=$(ps -o comm= -u "$1" 2>/dev/null | grep -cE "$VPSP_SESSION_RE")
    echo "${n:-0}"
}

acct_kill_sessions() { pkill -KILL -u "$1" 2>/dev/null || true; }

# Fails with a message unless USER is an existing panel account.
_need_account() {
    acct_is_panel "$1" || { err "Account '$1' is not managed by the panel."; return 1; }
    acct_os_exists "$1" || { err "System user '$1' no longer exists. Use 'Repair accounts'."; return 1; }
}

# ----------------------------------------------------------------- write ---
# acct_create USER PASS EXPIRE_EPOCH LIMIT [KIND]
acct_create() {
    local user=$1 pass=$2 exp=$3 limit=$4 kind=${5:-normal}
    valid_username "$user"   || { err "Invalid username. Use 3-32 lowercase letters, digits, '_' or '-'."; return 1; }
    valid_password "$pass"   || { err "Invalid password. Use 4-64 characters with no spaces or ':'."; return 1; }
    valid_int "$limit" 0 999 || { err "Login limit must be 0-999 (0 = unlimited)."; return 1; }
    if acct_os_exists "$user"; then err "User '$user' already exists on this system."; return 1; fi

    useradd -M -N -g "$VPSP_GROUP" -s "$VPSP_SHELL" -c "vpspanel" \
            -e "$(chage_date "$exp")" "$user" || { err "useradd failed."; return 1; }
    if ! printf '%s:%s\n' "$user" "$pass" | chpasswd; then
        userdel "$user" 2>/dev/null
        err "Setting the password failed."; return 1
    fi
    db_put "$user" "$exp" "$limit" "$(now_epoch)" "$kind"
    log_event "create $user kind=$kind expires=$(fmt_date "$exp") limit=$limit"
}

acct_delete() {
    _need_account "$1" || return 1
    acct_kill_sessions "$1"
    userdel -f "$1" 2>/dev/null || { err "userdel failed for '$1'."; return 1; }
    db_del "$1"
    log_event "delete $1"
}

# acct_renew USER DAYS - extend from today, or from current expiry if still valid.
acct_renew() {
    local user=$1 days=$2 cur base new
    _need_account "$user" || return 1
    valid_int "$days" 1 3650 || { err "Days must be 1-3650."; return 1; }
    cur=$(db_field "$user" 2)
    base=$(now_epoch)
    (( cur > base )) && base=$cur
    new=$(expiry_from_days "$days" "$base")
    chage -E "$(chage_date "$new")" "$user" || return 1
    db_put "$user" "$new" "$(db_field "$user" 3)" "$(db_field "$user" 4)" normal
    log_event "renew $user +${days}d expires=$(fmt_date "$new")"
}

acct_set_password() {
    _need_account "$1" || return 1
    valid_password "$2" || { err "Invalid password. Use 4-64 characters with no spaces or ':'."; return 1; }
    printf '%s:%s\n' "$1" "$2" | chpasswd || return 1
    log_event "password $1"
}

acct_set_limit() {
    _need_account "$1" || return 1
    valid_int "$2" 0 999 || { err "Login limit must be 0-999 (0 = unlimited)."; return 1; }
    db_put "$1" "$(db_field "$1" 2)" "$2" "$(db_field "$1" 4)" "$(db_field "$1" 5)"
    log_event "limit $1 = $2"
}

acct_lock() {
    _need_account "$1" || return 1
    usermod -L "$1" || return 1
    acct_kill_sessions "$1"
    log_event "lock $1"
}

acct_unlock() {
    _need_account "$1" || return 1
    usermod -U "$1" || return 1
    log_event "unlock $1"
}

# Delete every expired account. Prints the names removed.
acct_purge_expired() {
    local u
    for u in $(db_users); do
        if acct_is_expired "$u"; then
            if acct_os_exists "$u"; then acct_kill_sessions "$u"; userdel -f "$u" 2>/dev/null; fi
            db_del "$u"
            log_event "purge-expired $u"
            echo "$u"
        fi
    done
}

# Drop database rows whose system user was removed outside the panel.
acct_repair() {
    local u
    for u in $(db_users); do
        if ! acct_os_exists "$u"; then
            db_del "$u"
            log_event "repair: dropped orphan $u"
            echo "$u"
        fi
    done
}

# ----------------------------------------------------------- enforcement ---
# Called every minute by vpspanel-guard: expire accounts on time,
# enforce login limits, and optionally delete long-expired accounts.
acct_enforce() {
    load_config
    local u exp limit n excess now
    now=$(now_epoch)
    for u in $(db_users); do
        acct_os_exists "$u" || continue
        exp=$(db_field "$u" 2)
        limit=$(db_field "$u" 3)

        if (( now >= exp )); then
            if (( AUTO_DELETE_DAYS > 0 && now >= exp + AUTO_DELETE_DAYS * 86400 )); then
                acct_kill_sessions "$u"; userdel -f "$u" 2>/dev/null; db_del "$u"
                log_event "auto-delete $u (expired ${AUTO_DELETE_DAYS}+ days)"
                continue
            fi
            # Expire at the OS level (shadow field 8 = 0) once, then keep sessions closed.
            if [[ $(getent shadow "$u" | cut -d: -f8) != 0 ]]; then
                chage -E 0 "$u"
                log_event "expired $u"
            fi
            acct_kill_sessions "$u"
            continue
        fi

        (( limit > 0 )) || continue
        n=$(acct_sessions "$u")
        (( n > limit )) || continue
        excess=$(( n - limit ))
        # Close the newest sessions first, keeping the ones already connected.
        ps -o pid=,etimes=,comm= -u "$u" 2>/dev/null \
            | awk -v re="$VPSP_SESSION_RE" '$3 ~ re' \
            | sort -k2,2n | head -n "$excess" | awk '{print $1}' \
            | xargs -r kill -KILL 2>/dev/null || true
        log_event "limit $u: closed $excess session(s) over limit $limit"
    done
}

# ---------------------------------------------------------------- backup ---
# acct_backup FILE - accounts.db plus password hashes, restorable on a new VPS.
acct_backup() {
    local out=$1 tmp u
    tmp=$(mktemp -d) || return 1
    db_init
    cp "$VPSP_DB" "$tmp/accounts.db"
    : > "$tmp/shadow"
    for u in $(db_users); do
        getent shadow "$u" | cut -d: -f1,2 >> "$tmp/shadow"
    done
    printf 'vpspanel-backup 1\n' > "$tmp/VERSION"
    (umask 077; tar -czf "$out" -C "$tmp" VERSION accounts.db shadow) || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    log_event "backup -> $out"
}

# acct_restore FILE - recreate missing accounts from a backup. Existing users are skipped.
acct_restore() {
    local in=$1 tmp line user exp limit created kind hash restored=0 skipped=0
    [[ -f $in ]] || { err "Backup file not found: $in"; return 1; }
    tmp=$(mktemp -d) || return 1
    if ! tar -xzf "$in" -C "$tmp" VERSION accounts.db shadow 2>/dev/null \
       || ! grep -qx 'vpspanel-backup 1' "$tmp/VERSION"; then
        rm -rf "$tmp"; err "Not a valid vpspanel backup."; return 1
    fi
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        IFS=: read -r user exp limit created kind <<< "$line"
        if ! valid_username "$user" || ! [[ $exp =~ ^[0-9]+$ && $limit =~ ^[0-9]+$ && $created =~ ^[0-9]+$ ]]; then
            warn "Skipping malformed entry: $line"; skipped=$((skipped+1)); continue
        fi
        if acct_os_exists "$user"; then
            warn "Skipping '$user': user already exists."; skipped=$((skipped+1)); continue
        fi
        hash=$(awk -F: -v u="$user" '$1 == u { print $2 }' "$tmp/shadow")
        [[ -n $hash ]] || hash='!'
        if ! useradd -M -N -g "$VPSP_GROUP" -s "$VPSP_SHELL" -c "vpspanel" \
                -e "$(chage_date "$exp")" -p "$hash" "$user"; then
            skipped=$((skipped+1)); continue
        fi
        db_put "$user" "$exp" "$limit" "$created" "${kind:-normal}"
        restored=$((restored+1))
    done < "$tmp/accounts.db"
    rm -rf "$tmp"
    log_event "restore <- $in restored=$restored skipped=$skipped"
    ok "Restored $restored account(s), skipped $skipped."
}
