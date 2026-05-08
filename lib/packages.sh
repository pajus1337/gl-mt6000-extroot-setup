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
        if apk info "$pkg" > /dev/null 2>&1; then
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
    log_step "Installing base packages"
    pkg_update
    pkg_install "$BASE_PACKAGES" "base packages"
    pkg_install "$EXTRA_BASE_PACKAGES" "extra tools" || true
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
