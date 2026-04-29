#!/bin/sh
# Phase 1 — Pre-reboot: system detection, partitions, extroot configuration

run_phase1() {
    printf "\n${C_BOLD}${C_CYAN}"
    printf "╔══════════════════════════════════════════════════════════╗\n"
    printf "║         GL-MT6000 Setup Tool — Phase 1 / 2              ║\n"
    printf "║         System & Disk Setup (pre-reboot)                ║\n"
    printf "╚══════════════════════════════════════════════════════════╝\n"
    printf "${C_RESET}\n"
    printf "Log file: ${C_DIM}%s${C_RESET}\n\n" "$LOG_FILE"

    # ── 1. Firmware detection ──────────────────────────────────────────────────
    header "Step 1/6 — Firmware Detection"
    detect_firmware

    # ── 2. USB device selection ────────────────────────────────────────────────
    header "Step 2/6 — USB Device"

    if [ -n "$CLI_USB_DEV" ]; then
        # Explicit device passed via command-line argument
        USB_DEV="$CLI_USB_DEV"
        USB_BASE=$(basename "$USB_DEV")
        USB_TOTAL_MB=$(( $(cat "/sys/block/${USB_BASE}/size" 2>/dev/null || echo 0) / 2048 ))
        log_info "Using specified device: ${USB_DEV} (${USB_TOTAL_MB} MB)"
        [ -b "$USB_DEV" ] || die "Device '${USB_DEV}' does not exist."
    else
        if detect_usb_device; then
            USB_DEV="/dev/${DETECTED_USB_DEV}"
            USB_BASE="$DETECTED_USB_DEV"
            log_info "Auto-detected: ${USB_DEV}"
            ask_yn "Use ${USB_DEV} (${USB_TOTAL_MB} MB)?" "y" || ask_usb_device
        else
            ask_usb_device
        fi
    fi

    # ── 3. Partition validation / formatting ───────────────────────────────────
    header "Step 3/6 — Partitions"
    ensure_partitions

    # ── 4. Base package installation ───────────────────────────────────────────
    header "Step 4/6 — Base Packages"
    install_base_packages

    # ── 5. Optional service selection ─────────────────────────────────────────
    header "Step 5/6 — Optional Services"
    ask_optional_services
    print_service_summary

    if ! ask_yn "Proceed with these selections?" "y"; then
        log_info "Re-running service selection..."
        ask_optional_services
        print_service_summary
    fi

    # ── 6. Extroot setup ───────────────────────────────────────────────────────
    header "Step 6/6 — Extroot Configuration"
    setup_extroot "$PART1"

    # ── Summary ────────────────────────────────────────────────────────────────
    separator
    printf "\n${C_GREEN}${C_BOLD}Phase 1 complete.${C_RESET}\n"
    printf "  • Extroot configured on %s\n" "$PART1"
    printf "  • Service selections saved to extroot\n"
    printf "  • After reboot, run this script again — it will\n"
    printf "    automatically continue with Phase 2.\n\n"
    log_info "Phase 1 complete."

    # ── Reboot prompt ──────────────────────────────────────────────────────────
    if ask_yn "Reboot now to activate extroot?" "y"; then
        reboot_countdown
    else
        log_warn "Reboot skipped. Run 'reboot' when ready, then re-run this script."
    fi
}
