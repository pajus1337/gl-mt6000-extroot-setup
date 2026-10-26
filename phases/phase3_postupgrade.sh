#!/bin/sh
# Phase 3 - Post-upgrade recovery: re-pivot extroot onto a fresh overlay.
# Triggered when a previous gl-setup extroot is detected on sda1 but is not
# currently active (typical after OpenWrt sysupgrade).
#
# The old overlay is not reused: after a firmware upgrade its apk database
# shadows the new ROM's, /etc/apk/world pins the old kernel, and its kmods are
# built for the old kernel. Instead it is archived on sda1 (for rollback), the
# freshly booted internal overlay is copied to sda1, and Phase 2 reinstalls
# the packages the old installation had added.

run_phase3() {
    printf "\n${C_BOLD}${C_CYAN}"
    printf "╔══════════════════════════════════════════════════════════╗\n"
    printf "║         GL-MT6000 Setup Tool — Post-Upgrade Recovery    ║\n"
    printf "║         Restoring extroot after firmware upgrade        ║\n"
    printf "╚══════════════════════════════════════════════════════════╝\n"
    printf "${C_RESET}\n"
    printf "Log file: ${C_DIM}%s${C_RESET}\n\n" "$LOG_FILE"

    header "Post-Upgrade Recovery Detected"
    printf "A previous gl-setup installation was found on /dev/sda1.\n"
    printf "${C_GREEN}Your data on sda1 (extroot) and sda3 (storage/Samba) is intact.${C_RESET}\n\n"
    printf "The old overlay was built for the previous firmware and is not reused.\n"
    printf "It is archived on sda1 (nothing is deleted), and extroot is rebuilt from\n"
    printf "the current system. No disk formatting is done.\n\n"

    ask_yn "Continue with recovery?" "y" || exit 0

    detect_firmware

    # ── Step 1: Scan sda1 for previous config ─────────────────────────────────
    header "Step 1/4 - Scanning USB disk"

    local _mp="/tmp/gl-upgrade-recover"
    local _pkg_list="/tmp/gl-setup-${PACKAGES_FILE_NAME}"
    local _have_services=0
    mkdir -p "$_mp"
    mount -t ext4 -o ro /dev/sda1 "$_mp" \
        || die "Cannot mount /dev/sda1 for scanning. USB drive may be damaged."

    local _services_conf="${_mp}/upper/${GL_SETUP_STATE_DIR}/${CONFIG_FILE_NAME}"
    if [ -f "$_services_conf" ]; then
        log_ok "Found service configuration from previous setup:"
        . "$_services_conf"
        _have_services=1
        print_service_summary
    else
        log_warn "No service config found on extroot - Phase 2 will skip service configuration."
    fi

    rm -f "$_pkg_list"
    if save_user_packages "${_mp}/upper/etc/apk/world" "$_pkg_list"; then
        local _pkg_count
        _pkg_count=$(grep -c . "$_pkg_list" 2>/dev/null || true)
        log_ok "Previous installation added ${_pkg_count:-0} package(s) on top of its firmware."
        log_info "Phase 2 will offer to reinstall those the new firmware does not provide."
    else
        log_warn "No package list found in the old overlay - nothing to reinstall automatically."
    fi

    local _old_kver
    _old_kver=$(ls "${_mp}/upper/lib/modules" 2>/dev/null | head -1)
    log_info "Old overlay kernel : ${_old_kver:-unknown}"
    log_info "Running kernel     : $(uname -r)"

    local _sda1_uuid
    _sda1_uuid=$(get_uuid /dev/sda1 2>/dev/null || true)

    local _sda3_uuid=""
    [ -b /dev/sda3 ] && _sda3_uuid=$(get_uuid /dev/sda3 2>/dev/null || true)

    umount "$_mp" 2>/dev/null || true

    [ -n "$_sda1_uuid" ] || die "Cannot read UUID of /dev/sda1 — filesystem may be damaged."

    log_info "sda1 UUID : ${_sda1_uuid}"
    [ -n "$_sda3_uuid" ] && log_info "sda3 UUID : ${_sda3_uuid}"

    # ── Step 2: Extroot prerequisites on the internal overlay ────────────────
    # mount_root loads kmods from the internal overlay before extroot exists,
    # so block-mount and the USB/ext4 kmods must be installed here, not only
    # on sda1.
    header "Step 2/4 - Base packages"
    install_base_packages || die "Base packages are required for extroot. Check internet access."

    local _hook="${SCRIPT_DIR}/lib/79_wait_for_extroot"
    if [ -f "$_hook" ]; then
        mkdir -p /lib/preinit
        cp "$_hook" /lib/preinit/79_wait_for_extroot
        log_ok "Preinit USB wait hook installed to /lib/preinit/."
    else
        log_warn "Hook not found at ${_hook} — USB enumeration may be slow on next boot."
    fi

    # ── Step 3: Re-pivot extroot onto a fresh overlay ─────────────────────────
    header "Step 3/4 - Rebuilding extroot"

    # Swap and storage entries first, so the copy below carries them too.
    if [ -b /dev/sda2 ]; then
        _uci_set_swap_by_dev "/dev/sda2"
        log_ok "Swap fstab entry set (/dev/sda2)."
    fi
    if [ -n "$_sda3_uuid" ]; then
        _uci_set_mount "$_sda3_uuid" "$STORAGE_MOUNT_POINT" "ext4" "rw,async,noatime"
        log_ok "Storage fstab entry set (sda3, UUID: ${_sda3_uuid})."
    fi

    run_cmd mount -t ext4 /dev/sda1 "$_mp" \
        || die "Cannot mount /dev/sda1 read-write."

    local _suffix
    _suffix=$(archive_old_overlay "$_mp") \
        || { umount "$_mp" 2>/dev/null; die "Could not archive the old overlay on sda1."; }
    log_ok "Old overlay archived as upper.${_suffix} (kept for rollback)."

    populate_extroot "$_mp"

    local _state_dir="${_mp}/upper/${GL_SETUP_STATE_DIR}"
    mkdir -p "$_state_dir"
    [ "$_have_services" = "1" ] && save_service_config "${_state_dir}/${CONFIG_FILE_NAME}"
    [ -s "$_pkg_list" ] && cp "$_pkg_list" "${_state_dir}/${PACKAGES_FILE_NAME}"
    printf "PHASE=2\n" > "${_state_dir}/${STATE_FILE_NAME}"

    umount "$_mp" 2>/dev/null || true
    rmdir "$_mp" 2>/dev/null || true

    _uci_set_mount "$_sda1_uuid" "/overlay" "ext4" "rw,noatime"
    log_ok "Extroot fstab entry set (sda1, UUID: ${_sda1_uuid})."

    # ── Step 4: Upgrade resilience ────────────────────────────────────────────
    header "Step 4/4 - Upgrade resilience"
    setup_sysupgrade_conf

    # ── Summary + reboot ──────────────────────────────────────────────────────
    separator
    printf "\n${C_GREEN}${C_BOLD}Recovery complete.${C_RESET}\n\n"
    printf "After reboot:\n"
    printf "  • /dev/sda1 will mount as /overlay (fresh extroot active)\n"
    printf "  • Run ${C_BOLD}./setup.sh${C_RESET} again - Phase 2 reinstalls packages and services\n"
    printf "  • Files on /mnt/storage (sda3) are untouched\n"
    printf "  • The previous overlay stays on sda1 as upper.%s\n" "$_suffix"
    printf "    (delete it once everything works, it is only needed for rollback)\n\n"

    log_info "Phase 3 recovery complete. Reboot required."

    if ask_yn "Reboot now?" "y"; then
        reboot_countdown
    else
        log_warn "Reboot skipped. Run 'reboot' when ready, then re-run this script."
    fi
}
