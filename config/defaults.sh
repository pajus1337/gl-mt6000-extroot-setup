#!/bin/sh
# Project-wide defaults and constants
#
# Tested firmware:
#   GL.iNet GL-MT6000  — OpenWrt 21.02-SNAPSHOT, BusyBox v1.33.2 (ash)
#   Vanilla OpenWrt    — 25.12.2 (r32802-f505120278)

TOOL_NAME="GL-MT6000 Setup Tool"
TOOL_VERSION="1.0.0"

STORAGE_MOUNT_POINT="/mnt/storage"
GL_SETUP_STATE_DIR="etc/gl-setup"   # relative to overlay root (sda1/upper/)
STATE_FILE_NAME="state"
CONFIG_FILE_NAME="services.conf"
LOG_FILE="/tmp/gl-setup.log"

# Base packages required before reboot
# tune2fs is bundled inside e2fsprogs on OpenWrt; listed separately as a
# safety net for minimal builds that split it out.
BASE_PACKAGES="block-mount kmod-fs-ext4 kmod-usb-storage e2fsprogs"
EXTRA_BASE_PACKAGES="tune2fs lsblk"   # best-effort; non-fatal if missing

# Optional service package lists
PKG_SAMBA="luci-app-samba4 samba4-server"
PKG_DOCKER="docker dockerd docker-compose luci-app-dockerman"
PKG_PORTAINER=""           # installed via Docker image, not opkg
PKG_ADGUARD="adguardhome"
PKG_TRANSMISSION="transmission-daemon luci-app-transmission"
PKG_WIREGUARD="kmod-wireguard wireguard-tools luci-app-wireguard"

# Suggested partition layout sizes (MB) used when proposing layout to user
SUGGEST_EXTROOT_MB=20480   # 20 GB
SUGGEST_SWAP_MB=2048       # 2 GB
# Storage = remainder of disk

# Reboot countdown (seconds)
REBOOT_COUNTDOWN=10
