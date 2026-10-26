#!/bin/sh
# System and hardware detection

# apk add for the pre-detection bootstrap. A freshly flashed or upgraded image
# has no package index yet, so a bare "apk add" fails; refresh it once per run.
_APK_INDEX_FRESH=0
_bootstrap_apk_add() {
    if [ "$_APK_INDEX_FRESH" = "0" ]; then
        apk update >> "$LOG_FILE" 2>&1 || log_warn "apk update failed - check internet connectivity."
        _APK_INDEX_FRESH=1
    fi
    apk add "$@" >> "$LOG_FILE" 2>&1
}

# Load USB storage modules required for GL-MT6000 (USB 3.0 SuperSpeed).
# Must run before phase detection so /dev/sda is visible.
# No-op if both modules are already loaded.
ensure_usb_modules() {
    local _changed=0

    if ! grep -q "^usb_storage " /proc/modules 2>/dev/null; then
        if ! modprobe usb-storage 2>/dev/null; then
            log_info "Installing kmod-usb-storage..."
            _bootstrap_apk_add kmod-usb-storage || true
            modprobe usb-storage 2>/dev/null || log_warn "Could not load usb-storage."
        fi
        _changed=1
    fi

    # uas (USB Attached SCSI) is required for USB 3.0 SuperSpeed on GL-MT6000 -
    # usb-storage alone does not bind SuperSpeed devices on this kernel.
    if ! grep -q "^uas " /proc/modules 2>/dev/null; then
        if ! modprobe uas 2>/dev/null; then
            log_info "Installing kmod-usb-storage-uas..."
            _bootstrap_apk_add kmod-usb-storage-uas || true
            modprobe uas 2>/dev/null || log_warn "Could not load uas."
        fi
        _changed=1
    fi

    if [ "$_changed" = "1" ]; then
        local _i=0
        printf "[INFO]  Waiting for USB block device..."
        while [ $_i -lt 10 ]; do
            ls /sys/block/sd* /sys/block/vd* > /dev/null 2>&1 && break
            printf "."
            sleep 1
            _i=$(( _i + 1 ))
        done
        printf "\n"
    fi
}

# Make sure the tools needed to inspect sda1 exist before phase detection.
# The stock image ships neither "block" (block-mount) nor an ext4 driver (the
# internal overlay is f2fs), and a sysupgrade removes the copies installed
# during the original setup. Without them is_post_upgrade() cannot look
# inside sda1 and the router would be routed to Phase 1 (partitioning wizard)
# instead of Phase 3.
ensure_extroot_tools() {
    local _rc=0

    if ! cmd_exists block; then
        log_info "Installing block-mount..."
        _bootstrap_apk_add block-mount || true
        cmd_exists block || { log_warn "block-mount is not available."; _rc=1; }
    fi

    if ! grep -qw ext4 /proc/filesystems 2>/dev/null; then
        modprobe ext4 2>/dev/null
        if ! grep -qw ext4 /proc/filesystems 2>/dev/null; then
            log_info "Installing kmod-fs-ext4..."
            _bootstrap_apk_add kmod-fs-ext4 || true
            modprobe ext4 2>/dev/null
        fi
        grep -qw ext4 /proc/filesystems 2>/dev/null \
            || { log_warn "ext4 support is not available."; _rc=1; }
    fi

    return $_rc
}

# Return 0 if a previous gl-setup extroot is present on sda1 but NOT currently
# mounted. This indicates a post-upgrade state: data intact, modules missing.
# Detection: sda1 is ext4 and contains an overlayfs upper/ directory.
# A pending re-pivot (Phase 1 or Phase 3 finished, reboot not done yet) is
# not a post-upgrade state: the fresh upper carries PHASE=2 and fstab already
# points /overlay at sda1, so running Phase 3 again would archive it.
is_post_upgrade() {
    is_extroot_active && return 1
    [ -b /dev/sda1 ] || return 1
    local _fstype
    _fstype=$(get_fs_type /dev/sda1 2>/dev/null)
    [ "$_fstype" = "ext4" ] || return 1
    local _mp="/tmp/gl-upgrade-check"
    mkdir -p "$_mp"
    if ! mount -t ext4 -o ro /dev/sda1 "$_mp" 2>/dev/null; then
        rmdir "$_mp" 2>/dev/null || true
        return 1
    fi
    local _rc=1
    [ -d "${_mp}/upper" ] && _rc=0
    if [ "$_rc" = "0" ] && is_extroot_configured \
        && grep -q "^PHASE=2" "${_mp}/upper/${GL_SETUP_STATE_DIR}/${STATE_FILE_NAME}" 2>/dev/null; then
        _rc=1
    fi
    umount "$_mp" 2>/dev/null || true
    rmdir "$_mp" 2>/dev/null || true
    return $_rc
}

# Return 0 if sda1 exists but cannot be inspected (no "block" tool or no
# ext4 driver). Used to refuse Phase 1 rather than offer to repartition a
# disk that may hold a previous installation.
is_unreadable_usb_disk() {
    [ -b /dev/sda1 ] || return 1
    cmd_exists block || return 0
    grep -qw ext4 /proc/filesystems 2>/dev/null || return 0
    return 1
}

# Reads OpenWrt version and device model. Dies if not running on OpenWrt.
# Sets globals: OPENWRT_VERSION, DEVICE_MODEL
detect_firmware() {
    if [ -f /etc/openwrt_release ]; then
        . /etc/openwrt_release
        OPENWRT_VERSION="${DISTRIB_RELEASE:-unknown}"
    else
        die "Not an OpenWrt system. This tool requires vanilla OpenWrt 25.12.3+."
    fi

    DEVICE_MODEL=$(cat /tmp/sysinfo/model 2>/dev/null || echo "GL-MT6000")

    log_info "OpenWrt version : ${OPENWRT_VERSION}"
    log_info "Device          : ${DEVICE_MODEL}"

    case "$OPENWRT_VERSION" in
        25.*) ;;
        *) log_warn "Tested on OpenWrt 25.12.3 - running '${OPENWRT_VERSION}', proceed with caution." ;;
    esac
}

# Sets globals: DETECTED_USB_DEV (e.g. sda), USB_TOTAL_MB
detect_usb_device() {
    local candidates=""

    for sysdev in /sys/block/sd* /sys/block/vd*; do
        [ -b "/dev/$(basename "$sysdev")" ] || continue
        if grep -q "$(basename "$sysdev")" /proc/cmdline 2>/dev/null; then
            continue
        fi
        local size_sectors
        size_sectors=$(cat "${sysdev}/size" 2>/dev/null || echo 0)
        [ "$size_sectors" -gt 0 ] 2>/dev/null || continue
        candidates="${candidates} $(basename "$sysdev")"
    done

    local count
    count=$(echo "$candidates" | tr ' ' '\n' | grep -c '[a-z]' || true)

    if [ "$count" -eq 0 ]; then
        DETECTED_USB_DEV=""
        return 1
    elif [ "$count" -eq 1 ]; then
        DETECTED_USB_DEV=$(echo "$candidates" | tr -s ' ' | sed 's/^ //')
    else
        log_warn "Multiple block devices found: ${candidates}"
        DETECTED_USB_DEV=""
        return 1
    fi

    local size_sectors
    size_sectors=$(cat "/sys/block/${DETECTED_USB_DEV}/size" 2>/dev/null || echo 0)
    USB_TOTAL_MB=$(( size_sectors / 2048 ))

    log_info "Detected USB device : /dev/${DETECTED_USB_DEV} (${USB_TOTAL_MB} MB)"
}

# Check if extroot is currently active (sda1 mounted as /overlay)
is_extroot_active() {
    local overlay_dev
    overlay_dev=$(awk '$2 == "/overlay" {print $1}' /proc/mounts 2>/dev/null)
    [ -n "$overlay_dev" ] && echo "$overlay_dev" | grep -qE "^/dev/(sd|hd|vd|mmcblk)"
}

# Check if extroot is configured in fstab (UCI)
is_extroot_configured() {
    uci show fstab 2>/dev/null | grep -q "target='/overlay'"
}

# Check if swap partition is active
is_swap_active() {
    local dev="$1"
    [ -n "$dev" ] && grep -q "^${dev}" /proc/swaps 2>/dev/null
}

# Check if storage is mounted
is_storage_mounted() {
    grep -q " ${STORAGE_MOUNT_POINT} " /proc/mounts 2>/dev/null
}

# Determine partition filesystem type.
get_fs_type() {
    local dev="$1"
    local fstype
    fstype=$(block info "$dev" 2>/dev/null | grep -o 'TYPE="[^"]*"' | cut -d'"' -f2)
    [ -n "$fstype" ] && printf "%s" "$fstype" && return 0
    blkid -s TYPE -o value "$dev" 2>/dev/null
}

# Return partition size in MB from /sys
get_part_size_mb() {
    local dev
    dev=$(basename "$1")
    local sectors
    sectors=$(cat "/sys/block/${dev%[0-9]*}/${dev}/size" 2>/dev/null || echo 0)
    echo $(( sectors / 2048 ))
}
