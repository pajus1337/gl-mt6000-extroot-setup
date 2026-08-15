#!/bin/sh
# Phase 3 — Post-upgrade recovery: restore extroot without reformatting.
# Triggered when a previous gl-setup extroot is detected on sda1 but is not
# currently active (typical after OpenWrt sysupgrade).

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
    printf "This wizard restores extroot in 3 steps — no disk formatting needed.\n\n"

    ask_yn "Continue with recovery?" "y" || exit 0

    # ── Step 1: Scan sda1 for previous config ─────────────────────────────────
    header "Step 1/3 — Scanning USB disk"

    local _mp="/tmp/gl-upgrade-recover"
    mkdir -p "$_mp"
    mount -t ext4 -o ro /dev/sda1 "$_mp" \
        || die "Cannot mount /dev/sda1 for scanning. USB drive may be damaged."

    local _services_conf="${_mp}/upper/etc/gl-setup/services.conf"
    if [ -f "$_services_conf" ]; then
        log_ok "Found service configuration from previous setup:"
        . "$_services_conf"
        print_service_summary
    else
        log_warn "No service config found on extroot — Phase 2 will ask about services again."
    fi

    local _sda1_uuid
    _sda1_uuid=$(get_uuid /dev/sda1 2>/dev/null || true)

    local _sda3_uuid=""
    [ -b /dev/sda3 ] && _sda3_uuid=$(get_uuid /dev/sda3 2>/dev/null || true)

    umount "$_mp" 2>/dev/null || true
    rmdir "$_mp" 2>/dev/null || true

    [ -n "$_sda1_uuid" ] || die "Cannot read UUID of /dev/sda1 — filesystem may be damaged."

    log_info "sda1 UUID : ${_sda1_uuid}"
    [ -n "$_sda3_uuid" ] && log_info "sda3 UUID : ${_sda3_uuid}"

    # ── Step 2: Restore preinit hook + fstab ──────────────────────────────────
    header "Step 2/3 — Restoring extroot configuration"

    # Preinit hook — waits for USB device during preinit before mount_root runs.
    local _hook="${SCRIPT_DIR}/lib/79_wait_for_extroot"
    if [ -f "$_hook" ]; then
        mkdir -p /lib/preinit
        cp "$_hook" /lib/preinit/79_wait_for_extroot
        log_ok "Preinit USB wait hook restored to /lib/preinit/."
    else
        log_warn "Hook not found at ${_hook} — USB enumeration may be slow on next boot."
    fi

    # Extroot fstab entry (sda1 → /overlay, by UUID)
    _uci_set_mount "$_sda1_uuid" "/overlay" "ext4" "rw,noatime"
    log_ok "Extroot fstab restored (sda1, UUID: ${_sda1_uuid})."

    # Swap fstab entry (sda2, by device path — BusyBox mkswap has no -U flag)
    if [ -b /dev/sda2 ]; then
        _uci_set_swap_by_dev "/dev/sda2"
        log_ok "Swap fstab restored (/dev/sda2)."
    fi

    # Storage fstab entry (sda3 → /mnt/storage, by UUID)
    if [ -n "$_sda3_uuid" ]; then
        _uci_set_mount "$_sda3_uuid" "$STORAGE_MOUNT_POINT" "ext4" "rw,async,noatime"
        log_ok "Storage fstab restored (sda3, UUID: ${_sda3_uuid})."
    fi

    # ── Step 3: Upgrade resilience ────────────────────────────────────────────
    header "Step 3/3 — Upgrade resilience"
    setup_sysupgrade_conf

    # ── Summary + reboot ──────────────────────────────────────────────────────
    separator
    printf "\n${C_GREEN}${C_BOLD}Recovery complete.${C_RESET}\n\n"
    printf "After reboot:\n"
    printf "  • /dev/sda1 will mount as /overlay (extroot active)\n"
    printf "  • Run ${C_BOLD}./setup.sh${C_RESET} again — Phase 2 will reinstall packages\n"
    printf "  • Files on /mnt/storage (sda3) are untouched\n\n"

    log_info "Phase 3 recovery complete. Reboot required."

    if ask_yn "Reboot now?" "y"; then
        reboot_countdown
    else
        log_warn "Reboot skipped. Run 'reboot' when ready, then re-run this script."
    fi
}
