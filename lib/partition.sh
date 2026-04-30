#!/bin/sh
# Partition detection, validation, formatting, and layout creation

# Validate that the three expected partitions exist on USB_DEV.
# Sets globals: PART1, PART2, PART3
resolve_partitions() {
    local base="$1"   # e.g. /dev/sda
    PART1="${base}1"
    PART2="${base}2"
    PART3="${base}3"
}

# Print a human-readable partition table for the given device.
show_partition_table() {
    local dev="$1"
    printf "\nCurrent partition table for ${C_BOLD}%s${C_RESET}:\n" "$dev"
    if cmd_exists lsblk; then
        lsblk "$dev" 2>/dev/null || fdisk -l "$dev" 2>/dev/null || true
    else
        fdisk -l "$dev" 2>/dev/null || true
    fi
    printf "\n"
}

# Check whether a partition table already exists on device.
has_partition_table() {
    local dev="$1"
    fdisk -l "$dev" 2>/dev/null | grep -qE "^${dev}[0-9]"
}

# Create a GPT layout: sda1 (extroot), sda2 (swap), sda3 (storage).
# Sizes in MB come from globals set by ask_partition_layout.
create_gpt_layout() {
    local dev="$1"

    log_step "Creating GPT partition table on ${dev}"
    log_warn "ALL DATA ON ${dev} WILL BE ERASED."

    local extroot_end=$(( PART_EXTROOT_MB ))
    local swap_end=$(( extroot_end + PART_SWAP_MB ))

    # Use parted for reliable GPT + MiB-aligned partitioning
    if cmd_exists parted; then
        run_cmd parted -s "$dev" mklabel gpt
        run_cmd parted -s "$dev" mkpart primary ext4  1MiB "${extroot_end}MiB"
        run_cmd parted -s "$dev" mkpart primary linux-swap "${extroot_end}MiB" "${swap_end}MiB"
        run_cmd parted -s "$dev" mkpart primary ext4  "${swap_end}MiB" 100%
        run_cmd parted -s "$dev" name 1 extroot
        run_cmd parted -s "$dev" name 2 swap
        run_cmd parted -s "$dev" name 3 storage
    else
        # Fallback: sfdisk (available on most OpenWrt builds)
        local extroot_sectors=$(( PART_EXTROOT_MB * 2048 ))
        local swap_sectors=$(( PART_SWAP_MB * 2048 ))
        printf "label: gpt\n\
,${extroot_sectors},linux,\n\
,${swap_sectors},swap,\n\
,,linux,\n" | run_cmd sfdisk "$dev"
    fi

    # Inform kernel of new table
    partprobe "$dev" 2>/dev/null || blockdev --rereadpt "$dev" 2>/dev/null || true
    sleep 1
    log_ok "GPT partition table created."
}

# Format sda1 as ext4 (extroot)
format_extroot() {
    local part="$1"
    log_step "Formatting ${part} as ext4 (extroot)"
    run_cmd mkfs.ext4 -F -L "extroot" "$part"
    log_ok "Formatted ${part} as ext4."
}

# Format sda2 as swap
format_swap() {
    local part="$1"
    log_step "Formatting ${part} as swap"
    run_cmd mkswap -L "swap" "$part"
    log_ok "Formatted ${part} as swap."
}

# Format sda3 as ext4 (storage) and remove reserved root blocks
format_storage() {
    local part="$1"
    log_step "Formatting ${part} as ext4 (storage)"
    run_cmd mkfs.ext4 -F -L "storage" "$part"
    log_info "Removing reserved block space (tune2fs -m 0)"
    run_cmd tune2fs -m 0 "$part"
    log_ok "Formatted ${part} as ext4, reserved blocks = 0%%."
}

# Verify a partition has the expected filesystem type.
# Returns 0 if correct, 1 otherwise.
verify_fs() {
    local part="$1" expected_type="$2"
    local actual_type
    actual_type=$(get_fs_type "$part")
    if [ "$actual_type" = "$expected_type" ]; then
        return 0
    else
        log_warn "${part}: expected '${expected_type}', found '${actual_type:-none}'."
        return 1
    fi
}

# Full partition check/format flow.
# Handles: already-correct, needs-format, needs-repartition.
# USB_DEV must be set before calling.
ensure_partitions() {
    resolve_partitions "$USB_DEV"

    show_partition_table "$USB_DEV"

    local need_repartition=0
    local need_format_p1=0 need_format_p2=0 need_format_p3=0

    # Check partition table existence
    if ! has_partition_table "$USB_DEV"; then
        log_warn "No partition table found on ${USB_DEV}."
        need_repartition=1
    else
        [ -b "$PART1" ] || need_repartition=1
        [ -b "$PART2" ] || need_repartition=1
        [ -b "$PART3" ] || need_repartition=1
    fi

    if [ "$need_repartition" = "1" ]; then
        log_warn "Partition table is missing or incomplete."
        ask_yn "Create new GPT layout on ${USB_DEV}? (DESTRUCTIVE)" "n" || die "Aborted by user."
        ask_partition_layout "$USB_TOTAL_MB"
        create_gpt_layout "$USB_DEV"
        need_format_p1=1; need_format_p2=1; need_format_p3=1
    else
        # Partitions exist — check filesystems
        verify_fs "$PART1" "ext4" || need_format_p1=1
        verify_fs "$PART2" "swap" || need_format_p2=1
        verify_fs "$PART3" "ext4" || need_format_p3=1
    fi

    # Format only what's needed, always with confirmation
    if [ "$need_format_p1" = "1" ]; then
        log_warn "${PART1} is not ext4."
        ask_yn "Format ${PART1} as ext4 (extroot)? Data will be lost." "n" || die "Aborted."
        format_extroot "$PART1"
    else
        log_ok "${PART1} already ext4 — skipping format."
        # Ensure reserved blocks are removed in case partition was reused
        log_info "Ensuring reserved blocks = 0%% on ${PART1}..."
        tune2fs -m 0 "$PART1" >> "$LOG_FILE" 2>&1 || true
    fi

    if [ "$need_format_p2" = "1" ]; then
        log_warn "${PART2} is not swap."
        ask_yn "Format ${PART2} as swap? Data will be lost." "n" || die "Aborted."
        format_swap "$PART2"
    else
        log_ok "${PART2} already swap — skipping format."
    fi

    if [ "$need_format_p3" = "1" ]; then
        log_warn "${PART3} is not ext4."
        ask_yn "Format ${PART3} as ext4 (storage)? Data will be lost." "n" || die "Aborted."
        format_storage "$PART3"
    else
        log_ok "${PART3} already ext4 — skipping format."
        log_info "Ensuring reserved blocks = 0%% on ${PART3}..."
        tune2fs -m 0 "$PART3" >> "$LOG_FILE" 2>&1 || true
    fi
}
