# GL-MT6000 Setup Tool

Automated setup script for the **GL-MT6000 (Flint 2)** running **vanilla OpenWrt 25.12.x**.

Automates extroot (USB overlay), swap, storage mounting, and optional services —
in a multi-phase, reboot-safe, idempotent flow that also handles post-upgrade recovery.

---

## Requirements

| Requirement | Details |
|-------------|---------|
| Router      | GL.iNet GL-MT6000 (Flint 2) — 1 GB RAM, 4-core MediaTek MT7986 |
| Firmware    | Vanilla OpenWrt 25.12.x (tested on 25.12.3 and 25.12.5) |
| USB Drive   | Any USB 2.0/3.x drive, GPT-partitioned (256 GB recommended) |

> **GL.iNet stock firmware is not supported.**  
> Flash vanilla OpenWrt first: [OpenWrt Table of Hardware — GL-MT6000](https://openwrt.org/toh/gl.inet/gl-mt6000)

### Recommended Partition Layout (GPT)

| Partition | Size      | Filesystem | Purpose |
|-----------|-----------|------------|---------|
| sda1      | 20 GB     | ext4       | extroot (`/overlay`) |
| sda2      | 2 GB      | swap       | Swap |
| sda3      | remainder | ext4       | Storage · Samba · Docker data |

> The script can create this layout automatically if the drive is unpartitioned,
> or work with your existing layout — formatting only what is necessary.

---

## Features

- **Automatic phase detection** — run `./setup.sh` at any point; it figures out what to do next
- **Phase 1** — configures extroot (USB overlay) and partitions, then reboots
- **Phase 2** — activates swap, storage, and installs selected services
- **Phase 3** — post-upgrade recovery: restores extroot without reformatting after `sysupgrade`
- **Idempotent** — safe to re-run; skips already-configured steps
- **Partition wizard** — detects existing partitions, formats only if needed (with confirmation)
- **fstab via `uci`** — ext4 mounts by UUID; swap by device path (BusyBox `mkswap` has no `-U` flag)
- **Docker data-root on storage** — images and volumes go to sda3, not extroot
- **Upgrade resilience** — writes `/etc/sysupgrade.conf` to preserve the preinit hook and fstab across future firmware upgrades
- **Optional services** (selected interactively in Phase 1, installed in Phase 2):
  - Samba (SMB/CIFS file sharing)
  - Docker + docker-compose + LuCI app
  - Portainer CE (Docker Web UI, deployed as container)
  - AdGuard Home (DNS ad-blocking)
  - Transmission (torrent client + LuCI)
  - WireGuard VPN (kernel module + tools)
- **Uninstaller** — reverses all fstab changes, leaves data intact

---

## Quick Start

```sh
# 1. Flash vanilla OpenWrt 25.12.x on the GL-MT6000

# 2. Connect USB drive to the router

# 3. SSH in
ssh root@192.168.1.1

# 4. Install git with HTTPS support
apk update && apk add git git-http ca-bundle

# 5. Clone
git clone https://github.com/pajus1337/gl-mt6000-extroot-setup.git
cd gl-mt6000-extroot-setup
chmod +x setup.sh uninstall.sh

# 6. Run — phase is detected automatically
./setup.sh
# Phase 1: configures extroot, reboots

# 7. SSH back in and run again
cd gl-mt6000-extroot-setup
./setup.sh
# Phase 2: installs services, done
```

**Specify device explicitly** (if auto-detection picks the wrong drive):

```sh
./setup.sh /dev/sdb
```

---

## After a Firmware Upgrade

OpenWrt `sysupgrade` replaces the base firmware. Your USB data (sda1 extroot, sda3 storage/Samba files) **is always preserved** — it lives on the USB drive, not the flash.

What is lost after upgrade:
- Installed packages (kernel modules, services) — need reinstallation
- The USB preinit hook (if not in `sysupgrade.conf`)
- fstab entries (if not in `sysupgrade.conf`)

**The script handles this automatically.** Simply run `./setup.sh` after upgrading:

```sh
# After sysupgrade — just run the script again
cd gl-mt6000-extroot-setup
./setup.sh
# Detects post-upgrade state → runs Phase 3 recovery (no disk formatting)
# Restores extroot config + preinit hook → reboots

# After reboot — run once more for Phase 2
./setup.sh
# Reinstalls services, done
```

Phase 3 recovery takes ~30 seconds and does not touch your data.

After the first full setup (Phase 1 + 2), the script also writes `/etc/sysupgrade.conf`
to preserve the preinit hook and fstab. Future upgrades may mount extroot automatically
without needing Phase 3 — depending on the kernel version change.

---

## Script Structure

```
gl-mt6000-extroot-setup/
├── setup.sh                   # Entry point — auto-detects phase (1 / 2 / 3)
├── uninstall.sh               # Reverses all changes
├── config/
│   └── defaults.sh            # Package lists, size defaults, constants
├── lib/
│   ├── common.sh              # Logging, colors, ash-safe utilities
│   ├── detect.sh              # OpenWrt detection, USB module loading,
│   │                          # phase state detection (is_post_upgrade)
│   ├── ui.sh                  # Interactive prompts and menus
│   ├── partition.sh           # Partition check, format, GPT creation
│   ├── packages.sh            # apk wrapper (pkg_install, pkg_update)
│   ├── storage.sh             # Extroot, swap, storage, service config,
│   │                          # sysupgrade.conf resilience
│   └── 79_wait_for_extroot    # Preinit hook: waits for USB before mount_root
└── phases/
    ├── phase1_prereboot.sh    # Fresh setup — pre-reboot
    ├── phase2_postreboot.sh   # Service installation — post-reboot
    └── phase3_postupgrade.sh  # Post-sysupgrade recovery — no reformat
```

---

## Phase Details

### Phase 1 — Pre-reboot (fresh setup)

1. Check OpenWrt version and device model
2. Load USB storage modules (`usb-storage` + `uas`) — required for USB 3.0 on GL-MT6000
3. Detect or prompt for USB device
4. Validate partitions — create GPT layout and/or format only what is needed
5. Install base packages (`block-mount`, `kmod-fs-ext4`, `e2fsprogs`, …)
6. Select optional services to install later
7. Copy `/overlay` to sda1, configure fstab via UCI (UUID-based), install preinit hook, reboot

### Phase 2 — Post-reboot (service installation)

1. Verify extroot is active (exits with diagnostics if not)
2. Activate swap (sda2) and register in fstab
3. Mount storage (sda3 → `/mnt/storage`) and register in fstab
4. Install and configure selected optional services
5. Write `/etc/sysupgrade.conf` for upgrade resilience
6. Print final system status report

### Phase 3 — Post-upgrade recovery

Triggered automatically when `./setup.sh` detects a previous extroot on sda1
that is not currently mounted (typical state after `sysupgrade`).

1. Mount sda1 read-only, read previous service selections
2. Restore preinit hook to `/lib/preinit/`
3. Restore all fstab entries (extroot, swap, storage) via UCI
4. Write `/etc/sysupgrade.conf`
5. Reboot → extroot mounts → run `./setup.sh` again for Phase 2

**No data is modified. No partitions are reformatted.**

---

## USB Timing & USB 3.0 Note

The GL-MT6000 USB controller enumerates ~4 s after preinit starts. The preinit hook
`/lib/preinit/79_wait_for_extroot` waits for `/dev/sda1` before `mount_root` proceeds.

Additionally, **`kmod-usb-storage-uas`** is required for USB 3.0 (SuperSpeed) on this
kernel — `kmod-usb-storage` alone does not bind SuperSpeed devices. The script installs
and loads both modules automatically.

---

## Uninstall

```sh
./setup.sh --uninstall
# or
./uninstall.sh
```

Removes fstab entries, deactivates swap, unmounts storage.
**Data on the USB drive is not touched.**

---

## Compatibility

| Firmware        | Version   | Status   |
|-----------------|-----------|----------|
| Vanilla OpenWrt | 25.12.3   | Tested   |
| Vanilla OpenWrt | 25.12.5   | Tested   |
| Vanilla OpenWrt | 25.12.x   | Expected |
| GL.iNet stock   | any       | Not supported |

Shell: `/bin/sh` — BusyBox ash compatible, no bash required.

---

## Contributing

Issues and pull requests are welcome.
Please test on a real device before submitting — or clearly mark as untested.

---

## License

[MIT](LICENSE) © 2026 pajus1337
