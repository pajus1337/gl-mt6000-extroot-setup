#!/bin/sh
# GL-MT6000 Setup Tool — Uninstaller
# Reverses changes made by setup.sh (fstab entries, mounts, optional services)

set -e

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
if mountpoint -q "$STORAGE_MOUNT_POINT" 2>/dev/null; then
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
printf "  Reboot to fully deactivate extroot and restore internal overlay.\n\n"

ask_yn "Reboot now?" "y" && reboot
