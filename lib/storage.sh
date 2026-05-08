#!/bin/sh
# Extroot, swap, and storage configuration

TMP_EXTROOT_MOUNT="/tmp/gl-extroot-mount"

# ── fstab helpers ──────────────────────────────────────────────────────────────

# Find existing fstab UCI section that has the given UUID, or return empty.
_fstab_section_by_uuid() {
    local uuid="$1"
    uci show fstab 2>/dev/null \
        | grep "uuid='${uuid}'" \
        | head -1 \
        | cut -d. -f1-2
}

# Add or update a fstab mount entry.
_uci_set_mount() {
    local uuid="$1" target="$2" fstype="$3" opts="$4"

    local section
    section=$(_fstab_section_by_uuid "$uuid")

    if [ -z "$section" ]; then
        uci add fstab mount > /dev/null
        section="fstab.@mount[-1]"
    fi

    uci set "${section}.enabled=1"
    uci set "${section}.uuid=${uuid}"
    uci set "${section}.target=${target}"
    uci set "${section}.fstype=${fstype}"
    uci set "${section}.options=${opts}"
    uci commit fstab
}

# Add or update a fstab swap entry by device path.
# BusyBox mkswap does not support -U (no UUID in header); block info skips swap
# partitions. Using device path is reliable on GL-MT6000 where USB enumerates as sda.
_uci_set_swap_by_dev() {
    local dev="$1"

    local section
    section=$(uci show fstab 2>/dev/null \
        | grep "device='${dev}'" \
        | head -1 \
        | cut -d. -f1-2)

    if [ -z "$section" ]; then
        uci add fstab swap > /dev/null
        section="fstab.@swap[-1]"
    fi

    uci set "${section}.enabled=1"
    uci set "${section}.device=${dev}"
    uci commit fstab
}

# Remove fstab entries whose target matches a given path.
_uci_remove_mount_by_target() {
    local target="$1"
    local indices i
    # Iterate in reverse so index shifts don't break removal
    indices=$(uci show fstab 2>/dev/null \
        | grep "target='${target}'" \
        | grep -oE '@mount\[[0-9]+\]' \
        | grep -oE '[0-9]+' \
        | sort -rn)
    for i in $indices; do
        uci delete "fstab.@mount[${i}]" 2>/dev/null || true
    done
    uci commit fstab 2>/dev/null || true
}

# ── Extroot ────────────────────────────────────────────────────────────────────

setup_extroot() {
    local part="$1"   # e.g. /dev/sda1

    log_step "Setting up extroot on ${part}"

    if is_extroot_configured; then
        log_warn "Extroot is already configured in fstab."
        if ! ask_yn "Reconfigure extroot?" "n"; then
            log_info "Skipping extroot configuration."
            return 0
        fi
        _uci_remove_mount_by_target "/overlay"
    fi

    local uuid
    uuid=$(get_uuid "$part") || die "Cannot read UUID of ${part}. Is e2fsprogs installed?"
    [ -n "$uuid" ] || die "Empty UUID for ${part}."

    log_info "UUID of ${part}: ${uuid}"

    # Install USB wait preinit script into current overlay so it is included
    # in the tar copy below and survives on both eMMC and extroot overlays.
    local preinit_wait="${SCRIPT_DIR}/lib/79_wait_for_extroot"
    if [ -f "$preinit_wait" ]; then
        mkdir -p /lib/preinit
        cp "$preinit_wait" /lib/preinit/79_wait_for_extroot
        log_info "Preinit USB wait script installed."
    fi

    # Mount partition temporarily to copy current overlay
    ensure_mountpoint "$TMP_EXTROOT_MOUNT"
    safe_umount "$TMP_EXTROOT_MOUNT"
    run_cmd mount -t ext4 "$part" "$TMP_EXTROOT_MOUNT" \
        || die "Cannot mount ${part} to ${TMP_EXTROOT_MOUNT}."

    log_info "Copying current /overlay to ${part} (this may take a moment)..."
    run_cmd_verbose tar -C /overlay -cf - . | tar -C "$TMP_EXTROOT_MOUNT" -xf -

    # block-mount validates upper/etc/.extroot-uuid against the UUID of the device
    # currently mounted at /overlay. On vanilla OpenWrt this is an eMMC partition.
    # Must NOT use sda1's UUID — that's only for the fstab entry.
    local overlay_src overlay_uuid
    overlay_src=$(grep " /overlay " /proc/mounts | cut -d' ' -f1)
    overlay_uuid=""
    [ -n "$overlay_src" ] && overlay_uuid=$(get_uuid "$overlay_src")

    if [ -n "$overlay_uuid" ]; then
        mkdir -p "${TMP_EXTROOT_MOUNT}/upper/etc"
        printf "%s\n" "$overlay_uuid" > "${TMP_EXTROOT_MOUNT}/upper/etc/.extroot-uuid"
        log_info "Overlay UUID (${overlay_uuid}) written to upper/etc/.extroot-uuid"
    else
        log_warn "Cannot determine overlay device UUID — upper/etc/.extroot-uuid not written."
        log_warn "Extroot UUID validation will be skipped by block-mount."
    fi

    # Set overlay state to FS_PENDING (1) so mount_root activates extroot.
    # tar-copying the current overlay copies .fs_state -> 2 (FS_DONE = active),
    # which mount_extroot() skips. Must be 1 (FS_PENDING) to trigger activation.
    ln -sf 1 "${TMP_EXTROOT_MOUNT}/.fs_state"

    # Write service config into overlay upper layer so Phase 2 can read it
    local state_dir="${TMP_EXTROOT_MOUNT}/upper/${GL_SETUP_STATE_DIR}"
    mkdir -p "$state_dir"
    save_service_config "${state_dir}/${CONFIG_FILE_NAME}"
    printf "PHASE=2\n" > "${state_dir}/${STATE_FILE_NAME}"

    safe_umount "$TMP_EXTROOT_MOUNT"

    # Configure fstab
    _uci_set_mount "$uuid" "/overlay" "ext4" "rw,noatime"
    log_ok "Extroot configured (UUID: ${uuid})."
}

# Save the selected optional services to a config file readable in Phase 2.
save_service_config() {
    local file="$1"
    cat > "$file" <<EOF
# GL-MT6000 Setup Tool — service selections (auto-generated)
OPT_SAMBA=${OPT_SAMBA:-0}
OPT_DOCKER=${OPT_DOCKER:-0}
OPT_PORTAINER=${OPT_PORTAINER:-0}
OPT_ADGUARD=${OPT_ADGUARD:-0}
OPT_TRANSMISSION=${OPT_TRANSMISSION:-0}
OPT_WIREGUARD=${OPT_WIREGUARD:-0}
STORAGE_MOUNT_POINT=${STORAGE_MOUNT_POINT}
EOF
    log_info "Service config saved to ${file}."
}

# Load service config written during Phase 1.
load_service_config() {
    local file="/${GL_SETUP_STATE_DIR}/${CONFIG_FILE_NAME}"
    if [ -f "$file" ]; then
        . "$file"
        log_info "Loaded service config from ${file}."
    else
        log_warn "Service config not found at ${file}. Optional services will be skipped."
    fi
}

# ── Swap ───────────────────────────────────────────────────────────────────────

setup_swap() {
    local part="$1"   # e.g. /dev/sda2

    log_step "Setting up swap on ${part}"

    if is_swap_active "$part"; then
        log_ok "Swap on ${part} is already active — skipping."
        return 0
    fi

    log_info "Writing swap header on ${part}..."
    run_cmd mkswap -L "swap" "$part" || die "mkswap failed on ${part}."

    _uci_set_swap_by_dev "$part"

    # Activate immediately (survives reboot via fstab)
    run_cmd swapon "$part" || log_warn "swapon failed — swap will activate after next reboot."
    log_ok "Swap configured on ${part}."
}

# ── Storage mount ──────────────────────────────────────────────────────────────

setup_storage() {
    local part="$1"   # e.g. /dev/sda3

    log_step "Setting up storage mount on ${part} → ${STORAGE_MOUNT_POINT}"

    if is_storage_mounted; then
        log_ok "${STORAGE_MOUNT_POINT} is already mounted — skipping."
        return 0
    fi

    local uuid
    uuid=$(get_uuid "$part") || die "Cannot read UUID of ${part}."
    [ -n "$uuid" ] || die "Empty UUID for ${part}."

    log_info "UUID of ${part}: ${uuid}"

    # Remove reserved blocks if not already done
    log_info "Ensuring reserved blocks = 0%% on ${part}..."
    tune2fs -m 0 "$part" >> "$LOG_FILE" 2>&1 || true

    ensure_mountpoint "$STORAGE_MOUNT_POINT"
    _uci_set_mount "$uuid" "$STORAGE_MOUNT_POINT" "ext4" "rw,async,noatime"

    run_cmd mount -t ext4 "$part" "$STORAGE_MOUNT_POINT" \
        || die "Cannot mount ${part} to ${STORAGE_MOUNT_POINT}."

    log_ok "Storage mounted at ${STORAGE_MOUNT_POINT} (UUID: ${uuid})."
}

# ── Post-install service configuration ────────────────────────────────────────

configure_samba() {
    log_step "Configuring Samba"
    local share_dir="${STORAGE_MOUNT_POINT}/shared"
    mkdir -p "$share_dir"

    # Only add share if not already present
    if ! uci show samba4 2>/dev/null | grep -q "path='${share_dir}'"; then
        uci add samba4 sambashare > /dev/null
        uci set "samba4.@sambashare[-1].name=Storage"
        uci set "samba4.@sambashare[-1].path=${share_dir}"
        uci set "samba4.@sambashare[-1].read_only=no"
        uci set "samba4.@sambashare[-1].guest_ok=no"
        uci commit samba4
        log_ok "Samba share configured at ${share_dir}."
    else
        log_ok "Samba share already configured — skipping."
    fi
    /etc/init.d/samba4 enable 2>/dev/null && /etc/init.d/samba4 start 2>/dev/null || true
}

configure_docker() {
    log_step "Configuring Docker"
    local docker_data="${STORAGE_MOUNT_POINT}/docker"
    mkdir -p "$docker_data"

    local docker_cfg="/etc/docker/daemon.json"
    if [ ! -f "$docker_cfg" ] || ! grep -q "data-root" "$docker_cfg"; then
        mkdir -p /etc/docker
        cat > "$docker_cfg" <<EOF
{
  "data-root": "${docker_data}",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
        log_ok "Docker data-root → ${docker_data}."
    else
        log_ok "Docker daemon.json already configured — skipping."
    fi
    /etc/init.d/docker enable 2>/dev/null && /etc/init.d/docker start 2>/dev/null || true
}

configure_portainer() {
    log_step "Configuring Portainer CE"
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^portainer$"; then
        docker volume create portainer_data >> "$LOG_FILE" 2>&1
        docker run -d \
            --name portainer \
            --restart always \
            -p 9443:9443 \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v portainer_data:/data \
            portainer/portainer-ce:latest >> "$LOG_FILE" 2>&1 \
            && log_ok "Portainer CE started on port 9443." \
            || log_warn "Portainer startup failed — check Docker status."
    else
        log_ok "Portainer container already running — skipping."
    fi
}

configure_transmission() {
    log_step "Configuring Transmission"
    local dl_dir="${STORAGE_MOUNT_POINT}/downloads"
    mkdir -p "$dl_dir"

    if uci show transmission >/dev/null 2>&1; then
        uci set transmission.@transmission[0].download_dir="$dl_dir"
        uci commit transmission
        log_ok "Transmission download dir → ${dl_dir}."
    else
        log_warn "Transmission UCI config not found — set download dir manually."
    fi
    /etc/init.d/transmission enable 2>/dev/null && /etc/init.d/transmission start 2>/dev/null || true
}
