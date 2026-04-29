#!/bin/sh
# User interaction: prompts, menus, confirmations, countdown
# Requires: lib/common.sh (colors), lib/detect.sh (FIRMWARE)
# Ash (BusyBox v1.33.2) compatible — no bash-isms

# Ask a yes/no question. Returns 0 for yes, 1 for no.
# Usage: ask_yn "Question" [default: y|n]
ask_yn() {
    local question="$1"
    local default="${2:-y}"
    local prompt

    if [ "$default" = "y" ]; then
        prompt="[Y/n]"
    else
        prompt="[y/N]"
    fi

    while true; do
        printf "${C_BOLD}%s${C_RESET} %s: " "$question" "$prompt"
        read -r answer
        answer="${answer:-$default}"
        case "$answer" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) printf "  Please answer y or n.\n" ;;
        esac
    done
}

# Ask for a string value with a default. Prints result to stdout.
# Usage: var=$(ask_value "Prompt" default)
ask_value() {
    local question="$1"
    local default="$2"
    printf "${C_BOLD}%s${C_RESET} [${C_CYAN}%s${C_RESET}]: " "$question" "$default" >/dev/tty
    read -r value </dev/tty
    printf '%s' "${value:-$default}"
}

# Ask user to select a block device when auto-detection failed.
# Sets globals: USB_DEV, USB_BASE, USB_TOTAL_MB
ask_usb_device() {
    header "USB Device Selection"
    log_warn "Could not auto-detect a single USB storage device."
    printf "\nAvailable block devices:\n"

    local name size_sectors size_mb
    for sysdev in /sys/block/sd* /sys/block/vd*; do
        name=$(basename "$sysdev")
        [ -b "/dev/${name}" ] || continue
        size_sectors=$(cat "${sysdev}/size" 2>/dev/null || echo 0)
        size_mb=$(( size_sectors / 2048 ))
        printf "  /dev/%-8s  %d MB\n" "$name" "$size_mb"
    done

    printf "\n"
    local input
    while true; do
        input=$(ask_value "Enter device path (e.g. /dev/sda)" "/dev/sda")
        if [ -b "$input" ]; then
            USB_DEV="$input"
            USB_BASE=$(basename "$input")
            size_sectors=$(cat "/sys/block/${USB_BASE}/size" 2>/dev/null || echo 0)
            USB_TOTAL_MB=$(( size_sectors / 2048 ))
            log_info "Selected: ${USB_DEV} (${USB_TOTAL_MB} MB)"
            return 0
        else
            log_error "Device '${input}' does not exist or is not a block device."
        fi
    done
}

# Interactive partition layout wizard.
# Populates globals: PART_EXTROOT_MB, PART_SWAP_MB, PART_STORAGE_MB
ask_partition_layout() {
    local total_mb="$1"
    local avail_mb
    avail_mb=$(( total_mb - 2 ))   # 2 MB for GPT metadata

    header "Partition Layout"
    printf "Total disk size: ${C_BOLD}%d MB${C_RESET} (~%d GB)\n\n" \
        "$total_mb" "$(( total_mb / 1024 ))"

    local suggested_storage
    suggested_storage=$(( avail_mb - SUGGEST_EXTROOT_MB - SUGGEST_SWAP_MB ))

    printf "Suggested layout (Docker data on storage, not extroot):\n"
    printf "  %-12s  %5d MB  (%d GB)\n" \
        "sda1 extroot" "$SUGGEST_EXTROOT_MB" "$(( SUGGEST_EXTROOT_MB / 1024 ))"
    printf "  %-12s  %5d MB  (%d GB)\n" \
        "sda2 swap"    "$SUGGEST_SWAP_MB"    "$(( SUGGEST_SWAP_MB    / 1024 ))"
    printf "  %-12s  %5d MB  (%d GB)\n\n" \
        "sda3 storage" "$suggested_storage"  "$(( suggested_storage  / 1024 ))"

    if ask_yn "Use suggested layout?" "y"; then
        PART_EXTROOT_MB=$SUGGEST_EXTROOT_MB
        PART_SWAP_MB=$SUGGEST_SWAP_MB
        PART_STORAGE_MB=$suggested_storage
        return 0
    fi

    printf "\nEnter custom sizes (remaining space goes to storage):\n"
    while true; do
        PART_EXTROOT_MB=$(ask_value "extroot size (MB)" "$SUGGEST_EXTROOT_MB")
        PART_SWAP_MB=$(ask_value    "swap size (MB)"    "$SUGGEST_SWAP_MB")
        PART_STORAGE_MB=$(( avail_mb - PART_EXTROOT_MB - PART_SWAP_MB ))

        if [ "$PART_STORAGE_MB" -lt 1024 ]; then
            log_error "Storage would be less than 1 GB. Please adjust values."
            continue
        fi
        printf "\n  extroot : %d MB\n  swap    : %d MB\n  storage : %d MB\n\n" \
            "$PART_EXTROOT_MB" "$PART_SWAP_MB" "$PART_STORAGE_MB"
        ask_yn "Confirm this layout?" "y" && break
    done
}

# Optional services selection menu.
# Sets globals: OPT_SAMBA OPT_DOCKER OPT_PORTAINER OPT_ADGUARD
#               OPT_TRANSMISSION OPT_WIREGUARD
ask_optional_services() {
    header "Optional Services"
    printf "Select services to install after reboot (packages land on extroot).\n\n"

    ask_yn "Samba (SMB/CIFS file sharing)"          "y" && OPT_SAMBA=1        || OPT_SAMBA=0
    ask_yn "Docker + docker-compose + LuCI app"     "n" && OPT_DOCKER=1       || OPT_DOCKER=0

    if [ "$OPT_DOCKER" = "1" ]; then
        ask_yn "  Portainer CE (Docker Web UI)"     "n" && OPT_PORTAINER=1    || OPT_PORTAINER=0
    else
        OPT_PORTAINER=0
    fi

    ask_yn "AdGuard Home (DNS ad-blocking)"         "n" && OPT_ADGUARD=1      || OPT_ADGUARD=0
    ask_yn "Transmission (torrent daemon + LuCI)"   "n" && OPT_TRANSMISSION=1 || OPT_TRANSMISSION=0

    # WireGuard ships by default in GL.iNet firmware; only ask on vanilla OpenWrt
    if [ "${FIRMWARE:-openwrt}" = "openwrt" ]; then
        ask_yn "WireGuard VPN (kernel module + tools)" "n" && OPT_WIREGUARD=1 || OPT_WIREGUARD=0
    else
        OPT_WIREGUARD=0
    fi
}

# Helper for print_service_summary — defined at top-level (ash limitation)
_print_svc() {
    local label="$1" val="$2"
    if [ "$val" = "1" ]; then
        printf "  %-22s ${C_GREEN}YES${C_RESET}\n" "$label"
    else
        printf "  %-22s ${C_DIM}no${C_RESET}\n"   "$label"
    fi
}

# Print a summary of chosen services.
print_service_summary() {
    printf "\n${C_BOLD}Selected optional services:${C_RESET}\n"
    _print_svc "Samba"        "$OPT_SAMBA"
    _print_svc "Docker"       "$OPT_DOCKER"
    _print_svc "Portainer CE" "$OPT_PORTAINER"
    _print_svc "AdGuard Home" "$OPT_ADGUARD"
    _print_svc "Transmission" "$OPT_TRANSMISSION"
    _print_svc "WireGuard"    "$OPT_WIREGUARD"
    printf "\n"
}

# Countdown with Ctrl+C cancel, then reboots.
reboot_countdown() {
    local secs="${REBOOT_COUNTDOWN:-10}"
    printf "\n${C_YELLOW}The router will reboot in %d seconds.${C_RESET}\n" "$secs"
    printf "Press ${C_BOLD}Ctrl+C${C_RESET} to cancel.\n\n"
    while [ "$secs" -gt 0 ]; do
        printf "\r  Rebooting in ${C_BOLD}%2d${C_RESET}s...  " "$secs"
        sleep 1
        secs=$(( secs - 1 ))
    done
    printf "\r  Rebooting now...             \n"
    log_info "Initiating reboot."
    reboot
}

press_enter() {
    printf "${C_DIM}Press Enter to continue...${C_RESET}"
    read -r _dummy
}
