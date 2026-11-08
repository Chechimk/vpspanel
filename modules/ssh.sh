# shellcheck shell=bash
# vpspanel module: OpenSSH server, login banner and root access.

ssh_info() {
    local unit; unit=$(ssh_unit)
    ui_kv "Status:" "$(fmt_state "$(svc_state "$unit")")"
    ui_kv "Ports:" "$(ssh_ports)"
    [[ -n $(ssh_session_port) ]] && ui_kv "This session:" "port $(ssh_session_port)"
    ui_kv "Panel accounts:" "$(grep -qF "$SSH_BLOCK_BEGIN" "$SSHD_CONFIG" 2>/dev/null && echo "password tunnels allowed" || echo "${C_YLW}policy missing (use option 4)${C_RST}")"
}

m_ssh_ports() {
    local input
    warn "Changing SSH ports can lock you out if a provider firewall blocks the new port."
    info "Your current connection is protected: its port must stay in the list."
    info "Open the new port in your provider's firewall before you close this session."
    ask input "SSH ports, separated by spaces" "$(ssh_ports | tr ',' ' ')" || return
    # shellcheck disable=SC2086
    ssh_set_ports $input
}

m_ssh_policy() {
    info "This lets panel accounts log in with a password to open tunnels."
    info "They get no shell, no agent or X11 forwarding. Other users are not affected."
    ssh_write_block && ok "Panel account access policy applied."
}

ssh_menu() {
    local unit; unit=$(ssh_unit)
    while menu_show "OPENSSH MANAGER" ssh_info \
        "Change SSH ports|m_ssh_ports" \
        "Service status|show_service_status $unit" \
        "Restart SSH (open sessions stay connected)|restart_service $unit" \
        "Re-apply panel account access policy|m_ssh_policy" \
        "SSH/Dropbear banner|>banner_menu" \
        "Root password & access|>root_menu"
    do :; done
}

# ---------------------------------------------------------------- banner ---
banner_info() {
    if [[ -s $BANNER_FILE ]]; then
        ui_kv "Banner:" "set ($(wc -l < "$BANNER_FILE") line(s))"
    else
        ui_kv "Banner:" "none"
    fi
}

m_banner_text() {
    local v
    info "Type the banner on one line. Use \\n for a new line. Leave empty to cancel."
    ask v "Banner text" || return
    [[ -n $v ]] || return 0
    banner_apply "$v" && ok "Banner updated."
}

m_banner_edit() {
    mkdir -p "$VPSP_ETC"
    [[ -f $BANNER_FILE ]] || : > "$BANNER_FILE"
    "${EDITOR:-nano}" "$BANNER_FILE"
    if [[ -s $BANNER_FILE ]]; then
        # Keep panel.conf in sync and point OpenSSH/Dropbear at the file.
        banner_apply "$(sed ':a;N;$!ba;s/\n/\\n/g' "$BANNER_FILE")" && ok "Banner updated."
    else
        banner_apply "" && ok "Banner removed."
    fi
}

m_banner_show()   { if [[ -s $BANNER_FILE ]]; then cat "$BANNER_FILE"; else info "No banner is set."; fi; }
m_banner_remove() { confirm "Remove the login banner?" && banner_apply "" && ok "Banner removed."; }

m_banner_help() {
    cat <<'HELP'
  The banner is shown by OpenSSH and Dropbear before the password prompt.
  Most tunnelling apps display it to the customer when they connect.
  Plain text works everywhere. Some apps also render simple HTML such as
  <font color="red">text</font> or <br>.
HELP
}

banner_menu() {
    while menu_show "SSH/DROPBEAR BANNER" banner_info \
        "Set banner (one line)|m_banner_text" \
        "Create / edit banner (nano)|m_banner_edit" \
        "Show current banner|m_banner_show" \
        "Remove banner|m_banner_remove" \
        "Help|m_banner_help"
    do :; done
}

# ------------------------------------------------------------ root access ---
root_info() { ui_kv "Root login:" "$(root_login_status)"; }

root_menu() {
    while menu_show "ROOT PASSWORD & ACCESS" root_info \
        "Set root password|root_set_password" \
        "Allow root login with password|root_allow_password" \
        "Root login with SSH keys only|root_keys_only"
    do :; done
}
