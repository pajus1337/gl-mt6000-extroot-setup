#!/bin/sh
# Phase 2 — Post-reboot: verify extroot, configure swap/storage, install services

run_phase2() {
    printf "\n${C_BOLD}${C_CYAN}"
    printf "╔══════════════════════════════════════════════════════════╗\n"
    printf "║         GL-MT6000 Setup Tool — Phase 2 / 2              ║\n"
    printf "║         Services & Storage Setup (post-reboot)          ║\n"
    printf "╚══════════════════════════════════════════════════════════╝\n"
    printf "${C_RESET}\n"
    printf "Log file: ${C_DIM}%s${C_RESET}\n\n" "$LOG_FILE"

    # ── 1. Verify extroot ──────────────────────────────────────────────────────
    header "Step 1/6 - Extroot Verification"

    if is_extroot_active; then
        local overlay_dev
        overlay_dev=$(awk '$2 == "/overlay" {print $1}' /proc/mounts)
        log_ok "Extroot is active (${overlay_dev} → /overlay)."
    else
        log_error "Extroot is NOT active."
        printf "\nTroubleshooting:\n"
        printf "  1. Ensure the USB drive is connected.\n"
        printf "  2. Run: block info\n"
        printf "  3. Run: uci show fstab | grep overlay\n"
        printf "  4. Check log: %s\n\n" "$LOG_FILE"
        die "Cannot continue Phase 2 without active extroot."
    fi

    # Available space sanity check
    local overlay_free
    overlay_free=$(df -m /overlay 2>/dev/null | awk 'NR==2{print $4}')
    log_info "Free space on /overlay: ${overlay_free:-?} MB"

    # ── 2. Load service config ─────────────────────────────────────────────────
    header "Step 2/6 - Loading Configuration"
    detect_firmware
    load_service_config

    # Determine USB device from /proc/mounts (overlay source)
    local overlay_dev
    overlay_dev=$(awk '$2 == "/overlay" {print $1}' /proc/mounts)
    USB_DEV="/dev/$(echo "$overlay_dev" | sed 's|/dev/||; s|[0-9]*$||')"
    resolve_partitions "$USB_DEV"
    log_info "USB device: ${USB_DEV} (${PART1}, ${PART2}, ${PART3})"

    # ── 3. Swap ────────────────────────────────────────────────────────────────
    header "Step 3/6 - Swap"
    setup_swap "$PART2"

    # ── 4. Storage mount ───────────────────────────────────────────────────────
    header "Step 4/6 - Storage"
    setup_storage "$PART3"

    # ── 5. Packages from a previous installation (after an upgrade) ───────────
    header "Step 5/6 - Packages From Previous Installation"
    restore_user_packages

    # ── 6. Optional services ───────────────────────────────────────────────────
    header "Step 6/6 - Optional Services"

    local any_service=0
    for flag in OPT_SAMBA OPT_DOCKER OPT_ADGUARD OPT_TRANSMISSION OPT_WIREGUARD; do
        eval "val=\$$flag"
        [ "$val" = "1" ] && any_service=1 && break
    done

    if [ "$any_service" = "0" ]; then
        log_info "No optional services selected — skipping."
    else
        pkg_update
        install_optional_services

        [ "$OPT_SAMBA"        = "1" ] && configure_samba
        [ "$OPT_DOCKER"       = "1" ] && configure_docker
        [ "$OPT_DOCKER"       = "1" ] && [ "$OPT_PORTAINER" = "1" ] && configure_portainer
        [ "$OPT_TRANSMISSION" = "1" ] && configure_transmission
        [ "$OPT_WIREGUARD"    = "1" ] && /etc/init.d/wireguard enable 2>/dev/null || true
        [ "$OPT_ADGUARD"      = "1" ] && /etc/init.d/adguardhome enable 2>/dev/null \
            && /etc/init.d/adguardhome start 2>/dev/null || true
    fi

    # ── Final report ───────────────────────────────────────────────────────────
    separator
    printf "\n${C_GREEN}${C_BOLD}Setup complete!${C_RESET}\n\n"
    printf "${C_BOLD}System status:${C_RESET}\n"

    # Overlay
    local ol_info
    ol_info=$(df -h /overlay 2>/dev/null | awk 'NR==2{printf "%s used of %s (%s free)", $3, $2, $4}')
    printf "  %-20s %s\n" "/overlay (extroot)" "${ol_info:-active}"

    # Swap
    local sw_info
    sw_info=$(grep "$PART2" /proc/swaps 2>/dev/null | awk '{printf "%s kB total", $3}')
    printf "  %-20s %s\n" "swap" "${sw_info:-see /proc/swaps}"

    # Storage
    local st_info
    st_info=$(df -h "$STORAGE_MOUNT_POINT" 2>/dev/null | awk 'NR==2{printf "%s used of %s (%s free)", $3, $2, $4}')
    printf "  %-20s %s\n" "${STORAGE_MOUNT_POINT}" "${st_info:-mounted}"

    printf "\n${C_DIM}Full log: %s${C_RESET}\n\n" "$LOG_FILE"

    # Ensure upgrade resilience (hook + fstab preserved across sysupgrade)
    setup_sysupgrade_conf

    # Mark setup as complete so re-runs warn the user
    local _state_file="/${GL_SETUP_STATE_DIR}/${STATE_FILE_NAME}"
    printf "PHASE=COMPLETE\n" > "$_state_file" 2>/dev/null || true

    log_info "Phase 2 complete. Setup finished."
}
