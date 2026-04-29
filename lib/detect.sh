#!/bin/sh
# System and hardware detection

# Sets globals: FIRMWARE (glinet|openwrt), OPENWRT_VERSION, DEVICE_MODEL
detect_firmware() {
    if [ -f /etc/openwrt_release ]; then
        . /etc/openwrt_release
        OPENWRT_VERSION="${DISTRIB_RELEASE:-unknown}"
    else
        die "Not an OpenWrt-based system. Aborting."
    fi

    if [ -f /etc/glinet ] \
    || [ -d /etc/config/glconfig ] \
    || [ -f /usr/bin/gl_health ] \
    || grep -qiE "glinet|gl-inet" /etc/openwrt_release 2>/dev/null; then
        FIRMWARE="glinet"
        DEVICE_MODEL=$(cat /tmp/sysinfo/model 2>/dev/null || uci get glconfig.general.model 2>/dev/null || echo "GL.iNet device")
    else
        FIRMWARE="openwrt"
        DEVICE_MODEL=$(cat /tmp/sysinfo/model 2>/dev/null || echo "OpenWrt device")
    fi

    log_info "Firmware : ${FIRMWARE} (OpenWrt ${OPENWRT_VERSION})"
    log_info "Device   : ${DEVICE_MODEL}"
}

# Sets globals: DETECTED_USB_DEV (e.g. sda), USB_TOTAL_MB
detect_usb_device() {
    local candidates=""

    for sysdev in /sys/block/sd* /sys/block/vd*; do
        [ -b "/dev/$(basename "$sysdev")" ] || continue
        # Skip if it's the root device
        if grep -q "$(basename "$sysdev")" /proc/cmdline 2>/dev/null; then
            continue
        fi
        # Accept only devices with a valid size > 0
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
    mountpoint -q "${STORAGE_MOUNT_POINT}" 2>/dev/null
}

# Determine partition type as reported by blkid
get_fs_type() {
    blkid -s TYPE -o value "$1" 2>/dev/null
}

# Return partition size in MB from /sys
get_part_size_mb() {
    local dev
    dev=$(basename "$1")
    local sectors
    sectors=$(cat "/sys/block/${dev%[0-9]*}/${dev}/size" 2>/dev/null || echo 0)
    echo $(( sectors / 2048 ))
}
