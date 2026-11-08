# shellcheck shell=bash
# vpspanel - menu framework shared by every screen of the interactive panel.
#
# A screen is drawn with:
#
#     menu_show "TITLE" INFO_FN "Label|action" "Label|action" ...
#
# INFO_FN is a function printing status lines under the title, or "-".
# Each item's action is one of:
#     fn args...    run a command, then wait for a key press
#     >fn args...   open a submenu (it handles its own loop)
#     soon          feature not implemented yet: shown as "Coming soon"
# Arguments are split on whitespace; they are never passed through eval.
#
# menu_show returns 1 when the user picks 0 (Back), so a submenu is simply:
#
#     while menu_show "TITLE" - "A|do_a" "B|>sub_b"; do :; done
#
# Typing x (or q) on any screen leaves the panel.

MENU_ZERO_LABEL="Back"   # the main menu sets this to "Exit"
MENU_TOPBAR=ui_topbar    # function drawn at the top of every screen

ui_topbar() {
    ui_line
    printf ' %sVPS PANEL%s %s%-8s%s %s%s%s\n' "$C_BLD" "$C_RST" "$C_DIM" "v$VPSP_VERSION" "$C_RST" \
        "$C_CYN" "$(sys_ip)  $(date '+%F %H:%M')" "$C_RST"
}

coming_soon() {
    ui_line
    warn "$1 is coming soon."
    info "It is not implemented in this version of VPSPanel, so nothing was changed."
    info "Planned features are listed in docs/ROADMAP.md."
}

menu_run() {
    local -a cmd
    read -r -a cmd <<< "$1"
    (( ${#cmd[@]} )) || return 0
    if ! declare -F "${cmd[0]}" > /dev/null && ! command -v "${cmd[0]}" > /dev/null; then
        err "Internal error: '${cmd[0]}' is not available."
        return 1
    fi
    "${cmd[@]}"
}

menu_show() {
    local title=$1 info_fn=$2; shift 2
    local -a items=("$@")
    local n=${#items[@]} i label action choice

    ui_refresh_width
    clear 2>/dev/null || printf '\n'
    "$MENU_TOPBAR"
    ui_title "$title"
    if [[ $info_fn != - ]]; then
        "$info_fn"
        ui_line
    fi
    for (( i = 0; i < n; i++ )); do
        label=${items[i]%%|*}
        action=${items[i]#*|}
        if [[ $action == soon ]]; then
            ui_item $((i + 1)) "${C_DIM}${label} (coming soon)${C_RST}"
        else
            ui_item $((i + 1)) "$label"
        fi
    done
    ui_line
    printf ' %s %s%s     %s %s\n' "${C_RED}[ 0]$C_RST$C_CYN$UI_ARROW$C_RST" "$C_BLD" "$MENU_ZERO_LABEL$C_RST" \
        "${C_RED}[ x]$C_RST$C_CYN$UI_ARROW$C_RST" "Exit panel"
    ui_line

    if ! ask choice "Enter an option"; then
        printf '\n'; exit 0          # end of input (e.g. the SSH session closed)
    fi
    choice=${choice//[[:space:]]/}
    case $choice in
        0|00) return 1 ;;
        x|X|q|Q|exit) clear 2>/dev/null; exit 0 ;;
        '') return 0 ;;
    esac
    if ! valid_int "$choice" 1 "$n"; then
        err "Invalid option: $choice"
        sleep 1
        return 0
    fi

    label=${items[choice - 1]%%|*}
    action=${items[choice - 1]#*|}
    case $action in
        soon) coming_soon "$label"; ui_pause ;;
        '>'*) menu_run "${action#>}" ;;
        *)    ui_line; menu_run "$action"; ui_pause ;;
    esac
    return 0
}

# Status helpers for "INFO_FN" lines.
fmt_state() {
    case $1 in
        active)          printf '%s' "${C_GRN}running${C_RST}" ;;
        inactive|failed) printf '%s' "${C_RED}stopped${C_RST}" ;;
        "not installed") printf '%s' "${C_DIM}not installed${C_RST}" ;;
        *)               printf '%s' "$1" ;;
    esac
}

# toggle_service UNIT - start it if stopped, stop it if running.
toggle_service() {
    if systemctl is-active --quiet "$1"; then
        confirm "Stop $1?" && systemctl stop "$1" && ok "Stopped $1."
    else
        systemctl start "$1" && ok "Started $1." || err "$1 failed to start. See: journalctl -u $1"
    fi
}

restart_service() {
    systemctl restart "$1" && ok "Restarted $1." || err "$1 failed to restart. See: journalctl -u $1"
}

show_service_status() { systemctl status "$1" --no-pager -n 15 2>&1 | head -n 25; }

# follow_log CMD... - live log view, stopped with Ctrl+C without leaving the panel.
follow_log() {
    info "Showing live log. Press Ctrl+C to return."
    trap ':' INT
    "$@" || true
    trap - INT
}
