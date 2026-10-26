#!/bin/sh
# GL-MT6000 Setup Tool — Uninstaller
# Reverses changes made by setup.sh (fstab entries, mounts, optional services)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/config/defaults.sh"
. "${SCRIPT_DIR}/lib/common.sh"
. "${SCRIPT_DIR}/lib/detect.sh"
. "${SCRIPT_DIR}/lib/ui.sh"

require_root

printf "\n${C_BOLD}${C_YELLOW}"
printf "╔══════════════════════════════════════════════════════════╗\n"
printf "║         GL-MT6000 Setup Tool — Uninstaller              ║\n"
printf "╚══════════════════════════════════════════════════════════╝\n"
printf "${C_RESET}\n"

printf "${C_RED}${C_BOLD}WARNING:${C_RESET} This will remove the following:\n"
printf "  • Extroot fstab entry (/overlay mount)\n"
printf "  • Swap fstab entry\n"
printf "  • Storage fstab entry (%s)\n" "$STORAGE_MOUNT_POINT"
printf "  • State files under /%s\n\n" "$GL_SETUP_STATE_DIR"
printf "Your data on the USB partitions will ${C_BOLD}NOT${C_RESET} be deleted.\n"
printf "Optional service configs (Samba, Docker, etc.) are left intact.\n\n"

ask_yn "Are you sure you want to uninstall?" "n" || { log_info "Aborted."; exit 0; }

# ── Remove fstab entries ───────────────────────────────────────────────────────

_remove_fstab_by_target() {
    local target="$1"
    local indices i
    indices=$(uci show fstab 2>/dev/null \
        | grep "target='${target}'" \
        | grep -oE '@mount\[[0-9]+\]' \
        | grep -oE '[0-9]+' \
        | sort -rn)
    for i in $indices; do
        log_info "Removing fstab mount entry @mount[${i}] (target: ${target})"
        uci delete "fstab.@mount[${i}]" 2>/dev/null || true
    done
}

_remove_fstab_swaps() {
    local indices i
    indices=$(uci show fstab 2>/dev/null \
        | grep -oE '@swap\[[0-9]+\]' \
        | grep -oE '[0-9]+' \
        | sort -rn)
    for i in $indices; do
        log_info "Removing fstab swap entry @swap[${i}]"
        uci delete "fstab.@swap[${i}]" 2>/dev/null || true
    done
}

log_step "Removing fstab entries"
_remove_fstab_by_target "/overlay"
_remove_fstab_by_target "$STORAGE_MOUNT_POINT"
_remove_fstab_swaps
uci commit fstab 2>/dev/null && log_ok "fstab updated."

# ── Deactivate swap ────────────────────────────────────────────────────────────
log_step "Deactivating swap"
swapoff -a 2>/dev/null && log_ok "Swap deactivated." || log_warn "swapoff failed (may not have been active)."

# ── Unmount storage ────────────────────────────────────────────────────────────
log_step "Unmounting storage"
# mountpoint(1) does not exist on OpenWrt 25.12, use /proc/mounts instead.
if is_storage_mounted; then
    umount "$STORAGE_MOUNT_POINT" && log_ok "${STORAGE_MOUNT_POINT} unmounted." \
        || log_warn "Could not unmount ${STORAGE_MOUNT_POINT} — may be in use."
else
    log_info "${STORAGE_MOUNT_POINT} is not mounted."
fi

# ── Remove state files ─────────────────────────────────────────────────────────
log_step "Removing state files"
if [ -d "/${GL_SETUP_STATE_DIR}" ]; then
    rm -rf "/${GL_SETUP_STATE_DIR}" && log_ok "State files removed."
else
    log_info "No state files found."
fi

# ── Done ───────────────────────────────────────────────────────────────────────
separator
printf "\n${C_GREEN}${C_BOLD}Uninstall complete.${C_RESET}\n"

if is_extroot_active; then
    # The /overlay entry that activates extroot is read by mount_root from the
    # fstab on the internal flash, which is not reachable while extroot is
    # active. The fstab edited above is the copy on the USB drive.
    printf "\n${C_YELLOW}[WARN]${C_RESET} Extroot is still active. Its /overlay entry lives in the fstab on the\n"
    printf "  internal flash, which this script cannot edit while extroot is running.\n"
    printf "  To return to the internal overlay: unplug the USB drive and reboot, then run\n"
    printf "  'uci delete' on the /overlay mount entry (uci show fstab) and 'uci commit fstab'.\n\n"
else
    printf "  Reboot to restore the internal overlay.\n\n"
fi

# Archived overlays from post-upgrade recovery (Phase 3) are left on sda1.
_list_archives() {
    for _d in "$1"/upper.*; do
        [ -d "$_d" ] || continue
        printf "  Archived overlay kept on sda1: %s (%s)\n" \
            "$(basename "$_d")" "$(du -sh "$_d" 2>/dev/null | cut -f1)"
    done
}
if is_extroot_active; then
    _list_archives /overlay
elif [ -b /dev/sda1 ]; then
    _mp="/tmp/gl-uninstall-check"
    mkdir -p "$_mp"
    if mount -t ext4 -o ro /dev/sda1 "$_mp" 2>/dev/null; then
        _list_archives "$_mp"
        umount "$_mp" 2>/dev/null
    fi
    rmdir "$_mp" 2>/dev/null
fi

ask_yn "Reboot now?" "y" && reboot
