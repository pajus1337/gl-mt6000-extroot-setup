#!/bin/sh
# GL-MT6000 Setup Tool - Service manager
# Add, remove (with backup or purge) and restore optional services one by one.
# Without arguments an interactive menu is shown.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/config/defaults.sh"
. "${SCRIPT_DIR}/lib/common.sh"
. "${SCRIPT_DIR}/lib/detect.sh"
. "${SCRIPT_DIR}/lib/ui.sh"
. "${SCRIPT_DIR}/lib/packages.sh"
. "${SCRIPT_DIR}/lib/storage.sh"
. "${SCRIPT_DIR}/lib/services.sh"

usage() {
    printf "Usage: %s [command]\n\n" "$0"
    printf "  (no command)              Interactive menu\n"
    printf "  list                      Show services and their state\n"
    printf "  add <service>             Install and configure a service\n"
    printf "  remove <service>          Remove a service, keep a backup for restore\n"
    printf "  remove <service> --purge  Remove a service with its config, no backup\n"
    printf "  backups                   List service backups\n"
    printf "  restore <backup-dir>      Restore a service from a backup\n\n"
    printf "Services: %s\n" "$SERVICES"
    printf "User data on %s (Docker images, downloads) is only deleted by\n" "$STORAGE_MOUNT_POINT"
    printf "purge, after a separate typed confirmation. The Samba share is never deleted.\n\n"
}

_require_service() {
    [ -n "$1" ] || { usage; exit 1; }
    svc_is_known "$1" || die "Unknown service: $1 (one of: ${SERVICES})"
}

require_root
load_services_conf_quiet

cmd="$1"
[ $# -gt 0 ] && shift

case "$cmd" in
    "")
        services_menu
        ;;
    list)
        svc_print_list
        ;;
    add)
        _require_service "$1"
        svc_add "$1"
        ;;
    remove)
        _require_service "$1"
        if [ "$2" = "--purge" ]; then
            svc_remove "$1" purge
        elif [ -z "$2" ]; then
            svc_remove "$1" backup
        else
            die "Unknown option: $2"
        fi
        ;;
    backups)
        svc_list_backups
        ;;
    restore)
        [ -n "$1" ] || { svc_list_backups; printf "\nUsage: %s restore <backup-dir>\n" "$0"; exit 1; }
        svc_restore "$1"
        ;;
    --help|-h|help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
