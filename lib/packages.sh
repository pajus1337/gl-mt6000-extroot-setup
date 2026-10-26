#!/bin/sh
# Package installation via apk (OpenWrt 25.12+)

# Run apk update (with error handling)
pkg_update() {
    log_step "Updating package lists"
    if ! apk update >> "$LOG_FILE" 2>&1; then
        log_warn "apk update failed - check internet connectivity."
        ask_yn "Continue anyway?" "n" || die "Aborted."
    else
        log_ok "Package lists updated."
    fi
}

# Install a space-separated list of packages, skipping already-installed ones.
pkg_install() {
    local pkgs="$1"
    local label="${2:-packages}"
    local to_install=""

    for pkg in $pkgs; do
        if apk list --installed 2>/dev/null | grep -qE "^${pkg}-[0-9]"; then
            log_info "Already installed: ${pkg}"
        else
            to_install="${to_install} ${pkg}"
        fi
    done

    if [ -z "$(echo "$to_install" | tr -d ' ')" ]; then
        log_ok "All ${label} already installed."
        return 0
    fi

    log_info "Installing:${to_install}"
    if ! apk add $to_install >> "$LOG_FILE" 2>&1; then
        log_error "Failed to install some packages. Check log: ${LOG_FILE}"
        return 1
    fi
    log_ok "${label} installed."
}

# Install base packages required for Phase 1 (extroot / storage setup)
install_base_packages() {
    local _rc=0
    log_step "Installing base packages"
    pkg_update
    pkg_install "$BASE_PACKAGES" "base packages" || _rc=1
    pkg_install "$EXTRA_BASE_PACKAGES" "extra tools" || true
    return $_rc
}

# Install optional service packages (called in Phase 2 after extroot is live)
install_optional_services() {
    log_step "Installing optional services"

    [ "$OPT_SAMBA"        = "1" ] && pkg_install "$PKG_SAMBA"        "Samba"
    [ "$OPT_DOCKER"       = "1" ] && pkg_install "$PKG_DOCKER"       "Docker"
    [ "$OPT_ADGUARD"      = "1" ] && pkg_install "$PKG_ADGUARD"      "AdGuard Home"
    [ "$OPT_TRANSMISSION" = "1" ] && pkg_install "$PKG_TRANSMISSION"  "Transmission"
    [ "$OPT_WIREGUARD"    = "1" ] && pkg_install "$PKG_WIREGUARD"     "WireGuard"
}

# Reinstall the packages a previous installation had added on top of its
# firmware (list written by Phase 3 after an upgrade). Packages the new
# firmware already provides are skipped by pkg_install. If the batch fails
# (e.g. a package was dropped from the feeds), retry one by one so a single
# missing package does not block the rest. Never fatal.
restore_user_packages() {
    local list="/${GL_SETUP_STATE_DIR}/${PACKAGES_FILE_NAME}"
    if [ ! -s "$list" ]; then
        log_info "No package list from a previous installation - skipping."
        return 0
    fi

    local pkgs
    pkgs=$(tr '\n' ' ' < "$list")
    printf "Packages added by the previous installation:\n  %s\n\n" "$pkgs"
    if ! ask_yn "Reinstall them now?" "y"; then
        log_info "Skipped. The list stays at ${list}."
        return 0
    fi

    pkg_update
    if pkg_install "$pkgs" "previous packages"; then
        mv "$list" "${list}.done"
        _refresh_dbus_services
        return 0
    fi

    log_warn "Batch install failed - retrying one package at a time."
    local pkg failed=""
    for pkg in $pkgs; do
        pkg_install "$pkg" "$pkg" || failed="${failed} ${pkg}"
    done
    if [ -z "$failed" ]; then
        mv "$list" "${list}.done"
        log_ok "All previous packages reinstalled."
    else
        log_warn "Could not reinstall:${failed}"
        log_warn "The list stays at ${list}. Check log: ${LOG_FILE}"
    fi
    _refresh_dbus_services
}

# After many packages are installed at once, dbus may have started before a
# newly installed service's policy file existed; avahi-daemon then keeps
# failing with "Failed to contact D-Bus" until dbus is restarted (seen after
# the 25.12.6 upgrade). Restart dbus first, then avahi, if both are present.
_refresh_dbus_services() {
    [ -x /etc/init.d/dbus ] || return 0
    /etc/init.d/dbus restart >> "$LOG_FILE" 2>&1 || return 0
    if [ -x /etc/init.d/avahi-daemon ]; then
        /etc/init.d/avahi-daemon restart >> "$LOG_FILE" 2>&1 || true
    fi
    log_info "dbus restarted so services installed just now can register."
}
