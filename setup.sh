#!/bin/sh
# GL-MT6000 Setup Tool — Main entry point
# Usage: ./setup.sh [/dev/sdX]
#
# Requires vanilla OpenWrt 25.12.3+ on the GL-MT6000 (Flint 2).
# The script detects which phase it is in and continues automatically.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load defaults first, then libraries
. "${SCRIPT_DIR}/config/defaults.sh"
. "${SCRIPT_DIR}/lib/common.sh"
. "${SCRIPT_DIR}/lib/detect.sh"
. "${SCRIPT_DIR}/lib/ui.sh"
. "${SCRIPT_DIR}/lib/partition.sh"
. "${SCRIPT_DIR}/lib/packages.sh"
. "${SCRIPT_DIR}/lib/storage.sh"
. "${SCRIPT_DIR}/phases/phase1_prereboot.sh"
. "${SCRIPT_DIR}/phases/phase2_postreboot.sh"

# ── Argument parsing ───────────────────────────────────────────────────────────
CLI_USB_DEV=""
for arg in "$@"; do
    case "$arg" in
        --uninstall) exec "${SCRIPT_DIR}/uninstall.sh" ;;
        --help|-h)
            printf "Usage: %s [/dev/sdX] [--uninstall]\n" "$0"
            printf "\n  /dev/sdX     Specify USB device (default: auto-detect)\n"
            printf "  --uninstall  Reverse all changes made by this tool\n\n"
            exit 0
            ;;
        /dev/*)
            CLI_USB_DEV="$arg"
            ;;
        *)
            printf "Unknown argument: %s\n" "$arg" >&2
            exit 1
            ;;
    esac
done

# ── Sanity checks ──────────────────────────────────────────────────────────────
require_root

printf "${C_BOLD}%s v%s${C_RESET}\n" "$TOOL_NAME" "$TOOL_VERSION"
printf "${C_DIM}For GL-MT6000 (Flint 2) running vanilla OpenWrt 25.12.3+${C_RESET}\n"

# ── Uninstall guard ────────────────────────────────────────────────────────────
STATE_FILE="/${GL_SETUP_STATE_DIR}/${STATE_FILE_NAME}"
if [ -f "$STATE_FILE" ] && grep -q "^PHASE=COMPLETE" "$STATE_FILE"; then
    printf "\n${C_YELLOW}[WARN]${C_RESET} This tool has already completed setup on this device.\n"
    printf "  To remove all changes, run: ${C_BOLD}%s --uninstall${C_RESET}\n\n" "$0"
    ask_yn "Run setup again from scratch?" "n" || exit 0
fi

# ── Phase routing ──────────────────────────────────────────────────────────────
if is_extroot_active; then
    log_info "Extroot is active — resuming Phase 2."
    run_phase2
else
    if is_extroot_configured; then
        printf "\n${C_YELLOW}[WARN]${C_RESET} Extroot is configured in fstab but NOT currently active.\n"
        printf "  → The router may need a reboot for extroot to activate.\n\n"
        ask_yn "Reboot now?" "y" && reboot_countdown
        exit 0
    fi
    run_phase1
fi
