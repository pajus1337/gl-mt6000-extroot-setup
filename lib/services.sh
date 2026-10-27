#!/bin/sh
# Service manager: add, remove (with backup or purge) and restore the
# optional services offered by Phase 1, one at a time.
# Requires: common.sh, detect.sh, ui.sh, packages.sh, storage.sh
# Ash compatible - no arrays, so the service table is a set of case functions.

SERVICES="samba docker portainer adguard transmission wireguard syslog"
SERVICE_BACKUP_SUBDIR="backup/gl-setup-services"   # relative to STORAGE_MOUNT_POINT

# ── Service table ──────────────────────────────────────────────────────────────

svc_label() {
    case "$1" in
        samba)        printf "Samba" ;;
        docker)       printf "Docker" ;;
        portainer)    printf "Portainer CE" ;;
        adguard)      printf "AdGuard Home" ;;
        transmission) printf "Transmission" ;;
        wireguard)    printf "WireGuard" ;;
        syslog)       printf "Persistent log" ;;
    esac
}

svc_flag() {
    case "$1" in
        samba)        printf "OPT_SAMBA" ;;
        docker)       printf "OPT_DOCKER" ;;
        portainer)    printf "OPT_PORTAINER" ;;
        adguard)      printf "OPT_ADGUARD" ;;
        transmission) printf "OPT_TRANSMISSION" ;;
        wireguard)    printf "OPT_WIREGUARD" ;;
        syslog)       printf "OPT_SYSLOG" ;;
    esac
}

svc_packages() {
    case "$1" in
        samba)        printf "%s" "$PKG_SAMBA" ;;
        docker)       printf "%s" "$PKG_DOCKER" ;;
        portainer)    printf "%s" "$PKG_PORTAINER" ;;
        adguard)      printf "%s" "$PKG_ADGUARD" ;;
        transmission) printf "%s" "$PKG_TRANSMISSION" ;;
        wireguard)    printf "%s" "$PKG_WIREGUARD" ;;
    esac
}

# procd init script name, empty if the service has none.
svc_init() {
    case "$1" in
        samba)        printf "samba4" ;;
        docker)       printf "dockerd" ;;
        adguard)      printf "adguardhome" ;;
        transmission) printf "transmission" ;;
    esac
}

# Config and service state: saved in the backup, deleted by purge.
svc_configs() {
    case "$1" in
        samba)        printf "/etc/config/samba4 /etc/samba" ;;
        docker)       printf "/etc/config/dockerd" ;;
        adguard)      printf "/etc/config/adguardhome /etc/adguardhome /var/lib/adguardhome" ;;
        transmission) printf "/etc/config/transmission /var/etc/transmission" ;;
    esac
}

# System users created by the package scripts (apk del leaves them behind).
svc_users() {
    case "$1" in
        adguard)      printf "adguardhome" ;;
        transmission) printf "transmission" ;;
    esac
}

# User data on the storage partition. Never part of a backup (it stays in
# place) and only deleted by purge after a separate typed confirmation.
svc_userdata() {
    case "$1" in
        docker)       printf "%s/docker" "$STORAGE_MOUNT_POINT" ;;
        transmission) printf "%s/downloads" "$STORAGE_MOUNT_POINT" ;;
    esac
}

# ── State ──────────────────────────────────────────────────────────────────────

_in_world() {
    grep -qxE "${1}([=<>~].*)?" /etc/apk/world 2>/dev/null
}

# Packages of the service that are currently in /etc/apk/world.
svc_installed_packages() {
    local pkg out=""
    for pkg in $(svc_packages "$1"); do
        _in_world "$pkg" && out="${out} ${pkg}"
    done
    printf "%s" "${out# }"
}

_syslog_file() {
    uci -q get system.@system[0].log_file
}

svc_is_installed() {
    if [ "$1" = "syslog" ]; then
        [ -n "$(_syslog_file)" ]
        return
    fi
    if [ "$1" = "portainer" ]; then
        cmd_exists docker || return 1
        docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx portainer
        return
    fi
    [ -n "$(svc_installed_packages "$1")" ]
}

svc_is_running() {
    local init
    case "$1" in
        portainer)
            docker ps --format '{{.Names}}' 2>/dev/null | grep -qx portainer
            return ;;
        wireguard)
            [ -n "$(ip link show type wireguard 2>/dev/null)" ]
            return ;;
        syslog)
            ps w 2>/dev/null | grep -q "[l]ogread -f -F"
            return ;;
    esac
    init=$(svc_init "$1")
    [ -n "$init" ] && [ -x "/etc/init.d/${init}" ] && "/etc/init.d/${init}" running 2>/dev/null
}

svc_state() {
    if ! svc_is_installed "$1"; then
        printf "not installed"
    elif svc_is_running "$1"; then
        printf "installed, running"
    else
        printf "installed, stopped"
    fi
}

svc_is_known() {
    case " $SERVICES " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# WireGuard interfaces configured in /etc/config/network.
_wireguard_interfaces() {
    uci show network 2>/dev/null | grep "\.proto='wireguard'" \
        | sed 's/^network\.\([^.]*\)\..*/\1/' | tr '\n' ' '
}

# ── Shared helpers ─────────────────────────────────────────────────────────────

_services_conf() {
    printf "/%s/%s" "$GL_SETUP_STATE_DIR" "$CONFIG_FILE_NAME"
}

load_services_conf_quiet() {
    local file
    file=$(_services_conf)
    [ -f "$file" ] && . "$file"
    return 0
}

# Keep services.conf in sync so Phase 2 and Phase 3 do not bring a removed
# service back (or forget a restored one) after the next firmware upgrade.
_svc_set_flag() {
    local flag file
    flag=$(svc_flag "$1")
    file=$(_services_conf)
    [ -f "$file" ] || return 0
    if grep -q "^${flag}=" "$file"; then
        sed -i "s/^${flag}=.*/${flag}=${2}/" "$file"
    else
        printf "%s=%s\n" "$flag" "$2" >> "$file"
    fi
}

# Rewrite the package snapshot from the current world, same as Phase 2 does.
_svc_refresh_snapshot() {
    local snap="/${GL_SETUP_STATE_DIR}/${SNAPSHOT_FILE_NAME}"
    [ -f "$snap" ] || return 0
    save_user_packages /etc/apk/world "$snap" \
        && log_info "Package snapshot updated (${snap})."
}

_svc_clear_luci_cache() {
    rm -f /tmp/luci-indexcache* 2>/dev/null
    rm -rf /tmp/luci-modulecache 2>/dev/null
}

_svc_backup_root() {
    printf "%s/%s" "$STORAGE_MOUNT_POINT" "$SERVICE_BACKUP_SUBDIR"
}

# Ask the user to type a word before something destructive. Default is no.
_confirm_typed() {
    local word="$1" question="$2" answer
    printf "${C_RED}${C_BOLD}%s${C_RESET}\n" "$question"
    printf "Type ${C_BOLD}%s${C_RESET} to confirm, anything else skips: " "$word"
    read -r answer </dev/tty
    [ "$answer" = "$word" ]
}

_remove_users() {
    local user f
    for user in $(svc_users "$1"); do
        for f in /etc/passwd /etc/shadow /etc/group; do
            sed -i "/^${user}:/d" "$f"
        done
        log_info "System user '${user}' removed."
    done
}

# Undo the docker network/firewall entries that dockerd and
# configure_docker_fw4 created. Purge only: a backup keeps them for restore.
_purge_docker_netfw() {
    local idx
    uci -q delete firewall.docker_wan_fwd
    uci -q delete firewall.docker
    uci -q delete network.docker
    idx=$(uci show network 2>/dev/null | grep "\.name='docker0'" \
        | grep -oE '@device\[[0-9]+\]' | head -1)
    [ -n "$idx" ] && uci -q delete "network.${idx}"
    uci commit firewall
    uci commit network
    service firewall reload >/dev/null 2>&1 || true
    log_info "Docker network interface and firewall zone removed."
}

# ── List ───────────────────────────────────────────────────────────────────────

svc_print_list() {
    local i=0 s
    printf "\n  ${C_BOLD}%-3s %-14s %-14s %s${C_RESET}\n" "#" "Service" "Name" "State"
    for s in $SERVICES; do
        i=$(( i + 1 ))
        printf "  %-3s %-14s %-14s %s\n" "$i" "$(svc_label "$s")" "$s" "$(svc_state "$s")"
    done
    printf "\n"
}

# Map a list number or a name to a service name. Prints nothing if unknown.
svc_resolve() {
    local i=0 s
    for s in $SERVICES; do
        i=$(( i + 1 ))
        if [ "$1" = "$i" ] || [ "$1" = "$s" ]; then
            printf "%s" "$s"
            return 0
        fi
    done
    return 1
}

# ── Add ────────────────────────────────────────────────────────────────────────

svc_add() {
    local name="$1"
    svc_is_installed "$name" && { log_info "$(svc_label "$name") is already installed."; return 0; }

    # Packages must land on extroot, not on the small internal flash.
    is_extroot_active || { log_error "Extroot is not active - install services after setup.sh has finished."; return 1; }
    if [ "$name" = "portainer" ] && ! svc_is_installed docker; then
        log_error "Portainer runs on Docker - add Docker first."
        return 1
    fi

    ask_yn "Install $(svc_label "$name")?" "y" || { log_info "Aborted."; return 0; }

    log_step "Installing $(svc_label "$name")"
    if [ -n "$(svc_packages "$name")" ]; then
        pkg_update
        pkg_install "$(svc_packages "$name")" "$(svc_label "$name")" || return 1
    fi
    _svc_configure "$name"
    _svc_set_flag "$name" 1
    _svc_refresh_snapshot
    _svc_clear_luci_cache
    log_ok "$(svc_label "$name") installed."
}

# Same configuration steps Phase 2 runs for a freshly selected service.
_svc_configure() {
    case "$1" in
        samba)        configure_samba ;;
        docker)       configure_docker ;;
        portainer)    configure_portainer ;;
        transmission) configure_transmission ;;
        adguard)
            /etc/init.d/adguardhome enable 2>/dev/null
            /etc/init.d/adguardhome start 2>/dev/null || true
            log_info "AdGuard Home setup wizard: http://<router-ip>:3000"
            ;;
        wireguard)
            log_info "WireGuard tools installed. Create interfaces in LuCI: Network > Interfaces."
            ;;
        syslog)       configure_syslog ;;
    esac
}

# ── Remove ─────────────────────────────────────────────────────────────────────

# Usage: svc_remove <name> <backup|purge>
svc_remove() {
    local name="$1" mode="$2" label init pkgs bdir="" wg logf=""
    label=$(svc_label "$name")
    [ "$name" = "syslog" ] && logf=$(_syslog_file)

    svc_is_installed "$name" || { log_info "${label} is not installed."; return 0; }

    if [ "$name" = "wireguard" ]; then
        wg=$(_wireguard_interfaces)
        if [ -n "$wg" ]; then
            log_error "WireGuard interfaces are configured: ${wg}"
            log_error "Remove them first (LuCI: Network > Interfaces). If you are connected"
            log_error "through the tunnel, do it from the LAN side."
            return 1
        fi
    fi

    if [ "$name" = "docker" ] && svc_is_installed portainer; then
        log_warn "Portainer runs on Docker and has to go first."
        ask_yn "Remove Portainer CE too (same mode: ${mode})?" "y" || { log_info "Aborted."; return 0; }
        svc_remove portainer "$mode" || return 1
    fi

    if [ "$mode" = "backup" ] && ! is_storage_mounted; then
        log_error "${STORAGE_MOUNT_POINT} is not mounted - no place for the backup."
        log_error "Mount the storage partition, or use purge mode."
        return 1
    fi

    pkgs=$(svc_installed_packages "$name")
    init=$(svc_init "$name")

    header "Remove ${label}"
    printf "  Packages:      %s\n" "${pkgs:-none}"
    [ -n "$(svc_configs "$name")" ] && printf "  Config/state:  %s\n" "$(svc_configs "$name")"
    [ "$name" = "portainer" ] && printf "  Container:     portainer (volume portainer_data)\n"
    [ "$name" = "syslog" ] && printf "  Settings:      system log_file / log_size (log goes back to RAM only)\n"
    [ -n "$logf" ] && printf "  User data:     %s (kept unless you confirm separately)\n" "$logf"
    if [ "$mode" = "backup" ]; then
        printf "  Mode:          ${C_GREEN}remove, keep a backup${C_RESET} (restore later with: services.sh restore)\n"
    else
        printf "  Mode:          ${C_RED}purge${C_RESET} - config, state and system users are deleted, no backup\n"
    fi
    [ -n "$(svc_userdata "$name")" ] && printf "  User data:     %s (kept unless you confirm separately)\n" "$(svc_userdata "$name")"
    printf "\n"
    ask_yn "Continue?" "n" || { log_info "Aborted."; return 0; }

    # 1. Backup first, so nothing is lost if a later step fails.
    if [ "$mode" = "backup" ]; then
        bdir="$(_svc_backup_root)/$(date +%Y%m%d-%H%M%S)-${name}"
        _svc_backup "$name" "$bdir" "$pkgs" || { log_error "Backup failed - nothing was removed."; return 1; }
    fi

    # 2. Stop the service.
    if [ -n "$init" ] && [ -x "/etc/init.d/${init}" ]; then
        "/etc/init.d/${init}" stop >> "$LOG_FILE" 2>&1
        "/etc/init.d/${init}" disable >> "$LOG_FILE" 2>&1
        log_info "Service ${init} stopped and disabled."
    fi
    if [ "$name" = "portainer" ]; then
        docker rm -f portainer >> "$LOG_FILE" 2>&1 && log_info "Container portainer removed."
    fi
    [ "$name" = "syslog" ] && unconfigure_syslog

    # 3. Packages (apk also drops dependencies nothing else needs).
    if [ -n "$pkgs" ]; then
        log_info "Removing packages: ${pkgs}"
        apk del $pkgs >> "$LOG_FILE" 2>&1 || { log_error "apk del failed. Check log: ${LOG_FILE}"; return 1; }
    fi

    # 4. Purge: config, state, users and leftovers.
    if [ "$mode" = "purge" ]; then
        local p
        for p in $(svc_configs "$name"); do
            rm -rf "$p"
        done
        _remove_users "$name"
        [ "$name" = "docker" ] && _purge_docker_netfw
        if [ "$name" = "portainer" ]; then
            docker volume rm portainer_data >> "$LOG_FILE" 2>&1
            docker rmi portainer/portainer-ce:latest >> "$LOG_FILE" 2>&1
            log_info "Portainer volume and image removed."
        fi
        _svc_purge_userdata "$name"
        [ -n "$logf" ] && _svc_purge_logfile "$logf"
    fi

    # 5. Bookkeeping.
    _svc_set_flag "$name" 0
    [ "$name" = "docker" ] && _svc_set_flag portainer 0
    _svc_refresh_snapshot
    _svc_clear_luci_cache

    log_ok "${label} removed."
    [ -n "$bdir" ] && printf "  Backup: %s\n  Restore: ./services.sh restore %s\n" "$bdir" "$bdir"
    return 0
}

_svc_backup() {
    local name="$1" dir="$2" pkgs="$3" p list="" user f
    mkdir -p "$dir" || return 1

    for p in $(svc_configs "$name"); do
        [ -e "$p" ] && list="${list} ${p#/}"
    done
    if [ -n "$list" ]; then
        tar -czf "${dir}/config.tar.gz" -C / $list 2>> "$LOG_FILE" || return 1
    fi

    for user in $(svc_users "$name"); do
        for f in passwd shadow group; do
            grep "^${user}:" "/etc/${f}" >> "${dir}/${f}" 2>/dev/null
        done
    done

    cat > "${dir}/meta" <<EOF
# ${TOOL_NAME} service backup
SERVICE=${name}
CREATED="$(date '+%Y-%m-%d %H:%M:%S')"
TOOL_VERSION="${TOOL_VERSION}"
PACKAGES="${pkgs}"
EOF
    if [ "$name" = "syslog" ]; then
        cat >> "${dir}/meta" <<EOF
LOG_FILE_SETTING="$(_syslog_file)"
LOG_SIZE_SETTING="$(uci -q get system.@system[0].log_size)"
LOG_BUFFER_SETTING="$(uci -q get system.@system[0].log_buffer_size)"
EOF
    fi
    log_ok "Backup written to ${dir}."
}

_svc_purge_userdata() {
    local name="$1" path size
    path=$(svc_userdata "$name")
    [ -n "$path" ] && [ -d "$path" ] || return 0
    if [ -z "$(ls -A "$path" 2>/dev/null)" ]; then
        rmdir "$path" 2>/dev/null
        return 0
    fi
    size=$(du -sh "$path" 2>/dev/null | cut -f1)
    if _confirm_typed "$name" "Also delete ${path} (${size})? This cannot be undone."; then
        # dockerd bind-mounts its root onto itself; make sure it is released.
        grep -q " ${path} " /proc/mounts && umount "$path" 2>/dev/null
        rm -rf "$path" && log_ok "${path} deleted."
    else
        log_info "Kept ${path}."
    fi
}

# Only the log file and its rotated copy are deleted, never the directory
# tree, because log_file can point anywhere.
_svc_purge_logfile() {
    local f="$1" size
    [ -f "$f" ] || [ -f "${f}.old" ] || return 0
    size=$(du -ch "$f" "${f}.old" 2>/dev/null | tail -1 | cut -f1)
    if _confirm_typed syslog "Also delete ${f} and ${f}.old (${size})? This cannot be undone."; then
        rm -f "$f" "${f}.old"
        rmdir "$(dirname "$f")" 2>/dev/null
        log_ok "Log files deleted."
    else
        log_info "Kept ${f}."
    fi
}

# ── Restore ────────────────────────────────────────────────────────────────────

svc_list_backups() {
    local root d n=0
    root=$(_svc_backup_root)
    for d in "$root"/*; do
        [ -f "${d}/meta" ] || continue
        n=$(( n + 1 ))
        printf "  %-3s %s\n" "$n" "$d"
    done
    [ "$n" -eq 0 ] && printf "  No service backups in %s\n" "$root"
    return 0
}

# Map a number from svc_list_backups to a directory.
svc_backup_by_number() {
    local root d n=0
    root=$(_svc_backup_root)
    for d in "$root"/*; do
        [ -f "${d}/meta" ] || continue
        n=$(( n + 1 ))
        [ "$n" = "$1" ] && { printf "%s" "$d"; return 0; }
    done
    return 1
}

svc_restore() {
    local dir="${1%/}" SERVICE="" PACKAGES="" CREATED="" label init user f
    local LOG_FILE_SETTING="" LOG_SIZE_SETTING="" LOG_BUFFER_SETTING=""
    [ -f "${dir}/meta" ] || { log_error "Not a service backup: ${dir}"; return 1; }
    . "${dir}/meta"
    svc_is_known "$SERVICE" || { log_error "Unknown service in backup: ${SERVICE}"; return 1; }
    label=$(svc_label "$SERVICE")

    svc_is_installed "$SERVICE" && { log_error "${label} is installed - remove it before restoring."; return 1; }
    is_extroot_active || { log_error "Extroot is not active - restore after setup.sh has finished."; return 1; }
    if [ "$SERVICE" = "portainer" ] && ! svc_is_installed docker; then
        log_error "Portainer runs on Docker - add or restore Docker first."
        return 1
    fi

    header "Restore ${label}"
    printf "  Backup:   %s (created %s)\n" "$dir" "$CREATED"
    printf "  Packages: %s\n\n" "${PACKAGES:-none}"
    ask_yn "Restore ${label}?" "y" || { log_info "Aborted."; return 0; }

    if [ -n "$PACKAGES" ]; then
        pkg_update
        pkg_install "$PACKAGES" "$label" || return 1
    fi

    # Package scripts may have started the service with default settings.
    init=$(svc_init "$SERVICE")
    [ -n "$init" ] && [ -x "/etc/init.d/${init}" ] && "/etc/init.d/${init}" stop >> "$LOG_FILE" 2>&1

    if [ -f "${dir}/config.tar.gz" ]; then
        tar -xzf "${dir}/config.tar.gz" -C / 2>> "$LOG_FILE" \
            && log_ok "Configuration restored." \
            || log_warn "Some files could not be restored. Check log: ${LOG_FILE}"
    fi

    for user in $(svc_users "$SERVICE"); do
        for f in passwd shadow group; do
            [ -f "${dir}/${f}" ] || continue
            grep -q "^${user}:" "/etc/${f}" || grep "^${user}:" "${dir}/${f}" >> "/etc/${f}"
        done
    done

    case "$SERVICE" in
        docker)    configure_docker ;;     # data_root + fw4, idempotent
        portainer) configure_portainer ;;  # reuses the kept portainer_data volume
        syslog)
            mkdir -p "$(dirname "$LOG_FILE_SETTING")"
            uci set system.@system[0].log_file="$LOG_FILE_SETTING"
            [ -n "$LOG_SIZE_SETTING" ] && uci set system.@system[0].log_size="$LOG_SIZE_SETTING"
            [ -n "$LOG_BUFFER_SETTING" ] && uci set system.@system[0].log_buffer_size="$LOG_BUFFER_SETTING"
            uci commit system
            /etc/init.d/log reload >/dev/null 2>&1
            ;;
        *)
            if [ -n "$init" ] && [ -x "/etc/init.d/${init}" ]; then
                "/etc/init.d/${init}" enable >> "$LOG_FILE" 2>&1
                "/etc/init.d/${init}" start >> "$LOG_FILE" 2>&1
            fi
            ;;
    esac

    _svc_set_flag "$SERVICE" 1
    _svc_refresh_snapshot
    _svc_clear_luci_cache
    log_ok "${label} restored (backup kept in ${dir})."
}

# ── Interactive menu ───────────────────────────────────────────────────────────

_menu_pick_service() {
    local choice name
    choice=$(ask_value "Service (number or name, empty to go back)" "")
    [ -n "$choice" ] || return 1
    name=$(svc_resolve "$choice") || { log_error "Unknown service: ${choice}"; return 1; }
    printf "%s" "$name"
}

_menu_remove() {
    local name mode
    name=$(_menu_pick_service) || return 0
    printf "\n  1) Remove and keep a backup (can be restored later)\n"
    printf "  2) Purge: delete config, state and system users, no backup\n\n"
    mode=$(ask_value "Mode" "1")
    case "$mode" in
        1) svc_remove "$name" backup ;;
        2) svc_remove "$name" purge ;;
        *) log_error "Unknown mode: ${mode}" ;;
    esac
}

_menu_restore() {
    local n dir
    printf "\n${C_BOLD}Service backups:${C_RESET}\n"
    svc_list_backups
    printf "\n"
    n=$(ask_value "Backup number (empty to go back)" "")
    [ -n "$n" ] || return 0
    dir=$(svc_backup_by_number "$n") || { log_error "No backup number ${n}."; return 0; }
    svc_restore "$dir"
}

services_menu() {
    local action name
    while true; do
        header "Service Manager"
        svc_print_list
        printf "  ${C_BOLD}a${C_RESET}) add   ${C_BOLD}r${C_RESET}) remove   ${C_BOLD}b${C_RESET}) restore from backup   ${C_BOLD}q${C_RESET}) quit\n\n"
        action=$(ask_value "Action" "q")
        case "$action" in
            a|A) name=$(_menu_pick_service) && svc_add "$name" ;;
            r|R) _menu_remove ;;
            b|B) _menu_restore ;;
            q|Q) return 0 ;;
            *)   log_error "Unknown action: ${action}" ;;
        esac
        press_enter
    done
}
