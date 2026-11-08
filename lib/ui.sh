# shellcheck shell=bash
# vpspanel - menu framework shared by every screen of the interactive panel.
#
# A screen is drawn with:
#
#     menu_show "TITLE" INFO_FN ITEM...
#
# INFO_FN is a function printing status lines under the title, or "-".
# Each ITEM is one of:
#     "Label|action"    a numbered option
#     "@Label|action"   a numbered option shown in the footer, next to [0]
#     "-"               a dashed separator between groups of options
# and each action is one of:
#     fn args...    run a command, then wait for Enter
#     >fn args...   open a submenu (it handles its own loop)
#     (!)fn args... with a leading "!": run, then redraw at once (on/off switches)
#     soon          not implemented yet: shown as "(coming soon)"
# Arguments are split on whitespace; they are never passed through eval.
#
# menu_show returns 1 when the user picks 0 (Back), so a submenu is simply:
#
#     while menu_show "TITLE" - "A|do_a" "B|>sub_b"; do :; done
#
# Typing x (or q) on any screen leaves the panel.
#
# Optional globals: MENU_ZERO_LABEL (default "Back"), MENU_TOPBAR (function
# drawn above the title, e.g. the dashboard), MENU_COLS=2 (two columns).

MENU_ZERO_LABEL="Back"
MENU_TOPBAR=""
MENU_COLS=1

# Visible length of a string that may contain colour codes.
vlen() { local s; s=$(printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'); printf '%s' "${#s}"; }

# st_onoff 0|1 / st_state UNIT-STATE - "[ON]" in green or "[OFF]" in red.
st_onoff() { if [[ $1 == 1 ]]; then printf '%s' "${C_GRN}[ON]${C_RST}"; else printf '%s' "${C_RED}[OFF]${C_RST}"; fi; }
st_state() { if [[ $1 == active ]]; then st_onoff 1; else st_onoff 0; fi; }

coming_soon() {
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

# upper TEXT - upper-case TEXT, leaving colour codes intact.
upper() {
    local s=$1 out='' re=$'^([^\e]*)(\e\\[[0-9;]*m)(.*)$'
    while [[ $s =~ $re ]]; do
        out+=${BASH_REMATCH[1]^^}${BASH_REMATCH[2]}
        s=${BASH_REMATCH[3]}
    done
    printf '%s' "$out${s^^}"
}

# _menu_cell N LABEL ACTION - one "[n]> LABEL" cell, without a newline.
_menu_cell() {
    local num=$1 label pad='  ' action=$3
    # Upper-case the label like ADMRufu, but keep values after ": " as typed.
    if [[ $2 == *": "* ]]; then label="$(upper "${2%%: *}"): ${2#*: }"; else label=$(upper "$2"); fi
    (( ${#num} > 1 )) && pad=' '
    if [[ $action == soon ]]; then
        if (( MENU_COLS == 2 )); then label=$(printf "%s%-17s %s%s" "$C_DIM" "$label" "[SOON]" "$C_RST")
        else label="${C_DIM}${label} (coming soon)${C_RST}"; fi
    fi
    printf '%s%s%s%s>%s %s%s%s' "$pad" "$C_GRN" "[$num]" "$C_RED" "$C_RST" "$C_WHT" "$label" "$C_RST"
}

menu_show() {
    local title=$1 info_fn=$2; shift 2
    local -a labels=() actions=() body=() foot=()
    local it n=0 k=0 i choice label action cell line w half rows

    # Number the options: the list first, then the footer options.
    for it in "$@"; do
        [[ $it == - || $it == @* ]] && continue
        n=$((n + 1)); labels[n]=${it%%|*}; actions[n]=${it#*|}; body+=("$n")
    done
    for it in "$@"; do
        [[ $it == @* ]] || continue
        it=${it#@}; n=$((n + 1)); labels[n]=${it%%|*}; actions[n]=${it#*|}; foot+=("$n")
    done

    ui_refresh_width
    clear 2>/dev/null || printf '\n'
    [[ -n $MENU_TOPBAR ]] && "$MENU_TOPBAR"
    [[ -n $title ]] && ui_title "$title"
    if [[ $info_fn != - ]]; then
        "$info_fn"
        ui_line
    fi

    if (( MENU_COLS == 2 )); then
        half=$(( UI_W / 2 ))
        rows=$(( (${#body[@]} + 1) / 2 ))
        for (( i = 0; i < rows; i++ )); do
            cell=$(_menu_cell "${body[i]}" "${labels[body[i]]}" "${actions[body[i]]}")
            line=$cell
            if (( i + rows < ${#body[@]} )); then
                w=$(vlen "$cell")
                (( w < half )) && line+=$(printf '%*s' $(( half - w )) '')
                line+=$(_menu_cell "${body[i + rows]}" "${labels[body[i + rows]]}" "${actions[body[i + rows]]}")
            fi
            printf '%s\n' "$line"
        done
    else
        for it in "$@"; do
            [[ $it == @* ]] && continue
            if [[ $it == - ]]; then ui_sep; continue; fi
            k=$((k + 1))
            _menu_cell "$k" "${labels[k]}" "${actions[k]}"; printf '\n'
        done
    fi

    ui_line
    line="  ${C_GRN}[0]${C_RST} ${MENU_ZERO_LABEL}${C_RST}"
    for i in "${foot[@]}"; do
        w=$(vlen "$line")
        if (( w < 27 )); then line+=$(printf '%*s' $(( 27 - w )) ''); else line+='  '; fi
        line+="${C_GRN}[$i]${C_RST} $(upper "${labels[i]}")${C_RST}"
    done
    printf '%s\n' "$line"
    ui_line

    if ! read -r -p " ${C_WHT}Enter an option:${C_RST} " choice; then
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

    label=${labels[choice]}; action=${actions[choice]}
    case $action in
        soon) ui_line; coming_soon "$(printf '%s' "$label" | sed 's/\x1b\[[0-9;]*m//g')"; ui_pause ;;
        '>'*) menu_run "${action#>}" ;;
        '!'*) menu_run "${action#!}" ;;     # on/off switches: redraw at once
        *)    ui_line; menu_run "$action"; ui_pause ;;
    esac
    return 0
}

# Status helpers for INFO_FN lines.
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
        confirm "Stop $1?" && run_step "systemctl stop $1" systemctl stop "$1"
    else
        run_step "systemctl start $1" systemctl start "$1" || err "See: journalctl -u $1"
    fi
}

restart_service() {
    run_step "systemctl restart $1" systemctl restart "$1" || err "See: journalctl -u $1"
}

show_service_status() { systemctl status "$1" --no-pager -n 15 2>&1 | head -n 25; }

# follow_log CMD... - live log view, stopped with Ctrl+C without leaving the panel.
follow_log() {
    info "Showing live log. Press Ctrl+C to return."
    trap ':' INT
    "$@" || true
    trap - INT
}

# show_log FILE [LINES] - last lines of a log file.
show_log() {
    if [[ -s $1 ]]; then tail -n "${2:-40}" "$1"; else info "The log is empty."; fi
}
