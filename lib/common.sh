#!/bin/sh
# Common utilities: colors, logging, helpers

# ANSI colors (disabled automatically if not a TTY)
if [ -t 1 ]; then
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[1;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_RESET='\033[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
    C_BOLD='' C_DIM='' C_RESET=''
fi

log_info()    { printf "${C_GREEN}[INFO]${C_RESET}  %s\n" "$*"; _log "INFO"  "$*"; }
log_warn()    { printf "${C_YELLOW}[WARN]${C_RESET}  %s\n" "$*"; _log "WARN"  "$*"; }
log_error()   { printf "${C_RED}[ERROR]${C_RESET} %s\n" "$*" >&2; _log "ERROR" "$*"; }
log_step()    { printf "\n${C_BOLD}${C_BLUE}==>${C_RESET}${C_BOLD} %s${C_RESET}\n" "$*"; _log "STEP"  "$*"; }
log_ok()      { printf "${C_GREEN}[OK]${C_RESET}    %s\n" "$*"; _log "OK"    "$*"; }
log_debug()   { [ "${DEBUG:-0}" = "1" ] && printf "${C_DIM}[DEBUG] %s${C_RESET}\n" "$*"; }

_log() {
    local level="$1"; shift
    printf "[%s] [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "${LOG_FILE:-/tmp/gl-setup.log}"
}

die() {
    log_error "$*"
    exit 1
}

# Print a horizontal separator
separator() {
    printf "${C_DIM}%s${C_RESET}\n" "──────────────────────────────────────────────────────────"
}

# Print section header
header() {
    printf "\n${C_BOLD}${C_CYAN}%s${C_RESET}\n" "$*"
    separator
}

# Check if running as root
require_root() {
    [ "$(id -u)" -eq 0 ] || die "This script must be run as root."
}

# Check if a command exists
cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Run a command, log it, die on failure
run_cmd() {
    log_debug "Running: $*"
    _log "CMD" "$*"
    if ! "$@" >> "${LOG_FILE:-/tmp/gl-setup.log}" 2>&1; then
        log_error "Command failed: $*"
        return 1
    fi
}

# Run with visible output (for long-running ops like tar, mkfs)
run_cmd_verbose() {
    log_debug "Running (verbose): $*"
    _log "CMD" "$*"
    # ash has no $PIPESTATUS — capture exit status via temp file
    local _ret_file="/tmp/gl-setup-ret.$$"
    { "$@" 2>&1; echo $? > "$_ret_file"; } | tee -a "${LOG_FILE:-/tmp/gl-setup.log}"
    local _ret
    _ret=$(cat "$_ret_file" 2>/dev/null || echo 1)
    rm -f "$_ret_file"
    return "$_ret"
}

# Fetch UUID of a block device.
# Uses OpenWrt's 'block info' (always available via block-mount) with
# blkid as fallback for non-OpenWrt environments.
get_uuid() {
    local dev="$1"
    local uuid
    uuid=$(block info "$dev" 2>/dev/null | grep -o 'UUID="[^"]*"' | cut -d'"' -f2)
    [ -n "$uuid" ] && printf "%s" "$uuid" && return 0
    blkid -s UUID -o value "$dev" 2>/dev/null
}

# Check if a device is already mounted
is_mounted() {
    grep -q "^$1 " /proc/mounts 2>/dev/null
}

# Safely unmount if mounted
safe_umount() {
    if is_mounted "$1"; then
        umount "$1" 2>/dev/null || umount -l "$1" 2>/dev/null
    fi
}

# Ensure a mount point directory exists
ensure_mountpoint() {
    mkdir -p "$1" 2>/dev/null || true
}
