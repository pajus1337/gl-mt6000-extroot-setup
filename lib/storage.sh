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

# Remove mount entries for a target that point at a different UUID.
# Left behind when a partition is reformatted (new UUID); two entries for the
# same target make block try a device that no longer exists.
_uci_remove_stale_by_target() {
    local target="$1" keep_uuid="$2"
    local indices i entry_uuid
    indices=$(uci show fstab 2>/dev/null \
        | grep "target='${target}'" \
        | grep -oE '@mount\[[0-9]+\]' \
        | grep -oE '[0-9]+' \
        | sort -rn)
    for i in $indices; do
        entry_uuid=$(uci -q get "fstab.@mount[${i}].uuid")
        [ "$entry_uuid" = "$keep_uuid" ] && continue
        log_info "Removing stale fstab entry for ${target} (UUID: ${entry_uuid:-none})."
        uci delete "fstab.@mount[${i}]" 2>/dev/null || true
    done
}

# Add or update a fstab mount entry.
_uci_set_mount() {
    local uuid="$1" target="$2" fstype="$3" opts="$4"

    _uci_remove_stale_by_target "$target" "$uuid"

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

    populate_extroot "$TMP_EXTROOT_MOUNT"

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

# Copy the running overlay (internal eMMC) onto a mounted extroot partition
# and mark it for activation on the next boot.
#
# Note on .extroot-uuid: fstools (block.c, check_extroot) only validates the
# root device UUID when <extroot>/etc/.extroot-default exists, and it looks at
# the top of the partition, not inside upper/. Nothing needs to be written.
populate_extroot() {
    local mnt="$1"

    log_info "Copying current /overlay to the extroot partition (this may take a moment)..."
    run_cmd_verbose tar -C /overlay -cf - . | tar -C "$mnt" -xf -

    # Set overlay state to FS_PENDING (1) so mount_root activates extroot.
    # tar-copying the current overlay copies .fs_state -> 2 (FS_DONE = active),
    # which mount_extroot() skips. Must be 1 (FS_PENDING) to trigger activation.
    ln -sf 1 "${mnt}/.fs_state"
}

# Move the overlay of a previous installation out of the way so a fresh copy
# can take its place. After a firmware upgrade the old upper is unusable as-is:
# its apk database (lib/apk/db) shadows the new ROM's, /etc/apk/world pins the
# old kernel, and its kmods are built for the old kernel. Kept for rollback.
# Prints the archive suffix on stdout.
archive_old_overlay() {
    local mnt="$1"
    local suffix kver

    kver=$(ls "${mnt}/upper/lib/modules" 2>/dev/null | head -1)
    suffix="${kver:-unknown}.$(date +%Y%m%d-%H%M%S)"

    mv "${mnt}/upper" "${mnt}/upper.${suffix}" || return 1
    if [ -d "${mnt}/work" ]; then
        mv "${mnt}/work" "${mnt}/work.${suffix}" || return 1
    fi
    rm -f "${mnt}/.fs_state"
    printf "%s" "$suffix"
}

# Write the packages a previous installation had added on top of its ROM.
# Version pins (name=version) are stripped; kernel, libc and base-files are
# tied to the image and never reinstalled by hand. Phase 2 offers to
# reinstall whatever the new image does not already provide.
save_user_packages() {
    local old_world="$1" out="$2"
    local rom_names="/tmp/gl-setup-rom-world.$$"
    [ -f "$old_world" ] || return 1
    sed 's/[=<>~].*$//' /rom/etc/apk/world > "$rom_names" 2>/dev/null
    sed 's/[=<>~].*$//' "$old_world" \
        | grep -vxE 'kernel|libc|base-files' \
        | grep -vxF -f "$rom_names" \
        | sort -u > "$out"
    rm -f "$rom_names"
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

    if is_swap_active "$part"; then
        local swap_kb
        swap_kb=$(grep "^${part}" /proc/swaps | awk '{print $3}')
        log_ok "Swap active on ${part} (${swap_kb} kB)."
    else
        log_warn "Swap not active after swapon — will activate on next reboot via fstab."
    fi
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

    # Package install does not create /etc/config/samba4 — uci add fails without it.
    if [ ! -f /etc/config/samba4 ]; then
        cat > /etc/config/samba4 <<'EOF'
config samba
	option name 'OpenWrt'
	option workgroup 'WORKGROUP'
	option description 'OpenWrt Samba4 Server'
	option homes 0
EOF
        log_info "Created default /etc/config/samba4."
    fi

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

    # The dockerd init script builds its runtime config from UCI
    # (/etc/config/dockerd → /tmp/dockerd/daemon.json) and only looks at
    # /etc/docker/daemon.json if `alt_config_file` is explicitly set — which
    # it isn't. Writing data-root to /etc/docker/daemon.json is silently
    # ignored, so Docker keeps its default /opt/docker/, which lives on the
    # small root overlay instead of the storage partition. Confirmed live:
    # this also made overlay2 fail outright ("mount source: overlay ...
    # invalid argument") since it can't stack on the root's own overlayfs.
    # Set data_root via UCI instead so it actually takes effect.
    uci -q get dockerd.globals >/dev/null 2>&1 || uci set dockerd.globals='globals'
    uci set dockerd.globals.data_root="${docker_data}/"
    uci set dockerd.globals.iptables='0'
    uci commit dockerd
    log_ok "Docker data-root → ${docker_data} (via UCI, iptables management disabled)."

    # The service is "dockerd" (there is no /etc/init.d/docker). The package
    # post-install has already started it, and on 25.12.6 that first instance
    # came up on /var/lib/docker (tmpfs) despite data_root being set, so a
    # restart is required for data_root to take effect.
    /etc/init.d/dockerd enable 2>/dev/null
    /etc/init.d/dockerd restart 2>/dev/null || true
    _check_docker_root "$docker_data"

    configure_docker_fw4
}

# Warn if the running daemon does not use the expected data root.
_check_docker_root() {
    local want="$1" root="" _i=0
    while [ $_i -lt 15 ]; do
        root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
        [ -n "$root" ] && break
        sleep 1
        _i=$(( _i + 1 ))
    done
    if [ "${root%/}" = "${want%/}" ]; then
        log_ok "Docker daemon running with data-root ${root}."
    else
        log_warn "Docker daemon reports data-root '${root:-unknown}', expected ${want}."
        log_warn "Run: /etc/init.d/dockerd restart"
    fi
}

# configure_docker_fw4 — dockerd's own init script auto-creates a 'docker'
# network interface/bridge device and firewall zone the first time it starts
# (see uciadd() in /etc/init.d/dockerd), but leaves the zone without
# masquerade or a forwarding rule to wan. Combined with iptables='0' above
# (Docker no longer adds its own NAT either), containers have no route out
# until this runs — verified live: 100% ping loss before, 0% after.
configure_docker_fw4() {
    local tries=0
    while ! uci -q get firewall.docker >/dev/null 2>&1 && [ "$tries" -lt 10 ]; do
        sleep 1
        tries=$(( tries + 1 ))
    done
    if ! uci -q get firewall.docker >/dev/null 2>&1; then
        log_warn "Firewall zone 'docker' not found after starting dockerd — skipping fw4 patch."
        log_warn "Run this module again after Docker has started at least once."
        return 0
    fi

    uci set firewall.docker.masq='1'
    uci set firewall.docker.mtu_fix='1'

    if ! uci -q get firewall.docker_wan_fwd >/dev/null 2>&1; then
        local fwd
        fwd="$(uci add firewall forwarding)"
        uci rename "firewall.${fwd}=docker_wan_fwd"
        uci set firewall.docker_wan_fwd.src='docker'
        uci set firewall.docker_wan_fwd.dest='wan'
    fi

    uci commit firewall
    service firewall reload 2>/dev/null || true
    log_ok "Firewall zone 'docker' patched: masquerade + forwarding to wan enabled."
}

configure_portainer() {
    log_step "Configuring Portainer CE"
    # Docker daemon needs a moment to be ready after configure_docker starts it.
    local _i=0
    printf "[INFO]  Waiting for Docker daemon"
    while [ $_i -lt 15 ]; do
        docker info >/dev/null 2>&1 && break
        printf "."
        sleep 2
        _i=$(( _i + 1 ))
    done
    printf "\n"
    if ! docker info >/dev/null 2>&1; then
        log_warn "Docker daemon not ready — Portainer skipped. Run manually after Docker starts."
        return 0
    fi
    # A container kept on the storage partition (e.g. after a firmware
    # upgrade) only needs to be started; "docker run" would fail on the name.
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^portainer$"; then
        log_ok "Portainer container already running - skipping."
        return 0
    fi
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^portainer$"; then
        docker start portainer >> "$LOG_FILE" 2>&1 \
            && log_ok "Existing Portainer container started on port 9443." \
            || log_warn "Existing Portainer container failed to start - check Docker status."
        return 0
    fi
    docker volume create portainer_data >> "$LOG_FILE" 2>&1
    docker run -d \
        --name portainer \
        --restart always \
        -p 9443:9443 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        portainer/portainer-ce:latest >> "$LOG_FILE" 2>&1 \
        && log_ok "Portainer CE started on port 9443." \
        || log_warn "Portainer startup failed - check Docker status."
}

# Add gl-setup's critical files to /etc/sysupgrade.conf so they survive a
# firmware upgrade. Preserving the preinit hook + fstab means extroot has a
# better chance of mounting without a full Phase 3 recovery after the next upgrade.
setup_sysupgrade_conf() {
    local _conf="/etc/sysupgrade.conf"
    local _changed=0

    if ! grep -q "79_wait_for_extroot" "$_conf" 2>/dev/null; then
        printf "/lib/preinit/79_wait_for_extroot\n" >> "$_conf"
        _changed=1
    fi
    if ! grep -q "/etc/config/fstab" "$_conf" 2>/dev/null; then
        printf "/etc/config/fstab\n" >> "$_conf"
        _changed=1
    fi
    # Only the package snapshot, never the whole state dir: a preserved
    # state file (PHASE=COMPLETE) would make setup.sh refuse to run Phase 3.
    local _snapshot="/${GL_SETUP_STATE_DIR}/${SNAPSHOT_FILE_NAME}"
    if ! grep -qxF "$_snapshot" "$_conf" 2>/dev/null; then
        printf "%s\n" "$_snapshot" >> "$_conf"
        _changed=1
    fi

    if [ "$_changed" = "1" ]; then
        log_ok "Upgrade resilience: preinit hook, fstab and package snapshot added to ${_conf}."
    else
        log_info "Upgrade resilience already configured in ${_conf}."
    fi
}

configure_transmission() {
    log_step "Configuring Transmission"
    local dl_dir="${STORAGE_MOUNT_POINT}/downloads"
    mkdir -p "$dl_dir"

    # Package install does not create /etc/config/transmission.
    # Always write — config is minimal and ours; named section required by init script.
    cat > /etc/config/transmission <<EOF
config transmission 'transmission'
	option enabled 1
	option download_dir '${dl_dir}'
EOF
    log_ok "Transmission download dir → ${dl_dir}."
    /etc/init.d/transmission enable 2>/dev/null && /etc/init.d/transmission start 2>/dev/null || true
}
