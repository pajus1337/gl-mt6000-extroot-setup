# GL-MT6000 Setup Tool

Automated setup script for the **GL-MT6000 (Flint 2)** running **vanilla OpenWrt 25.12.x**.

Automates extroot (USB overlay), swap, storage mounting, and optional services —
in a multi-phase, reboot-safe, idempotent flow that also handles post-upgrade recovery.

---

## Requirements

| Requirement | Details |
|-------------|---------|
| Router      | GL.iNet GL-MT6000 (Flint 2) — 1 GB RAM, 4-core MediaTek MT7986 |
| Firmware    | Vanilla OpenWrt 25.12.x (tested on 25.12.3, 25.12.5 and 25.12.6) |
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
- **Phase 3** - post-upgrade recovery: rebuilds extroot on a fresh overlay after `sysupgrade` (no reformatting, old overlay kept for rollback)
- **Idempotent** — safe to re-run; skips already-configured steps
- **Partition wizard** — detects existing partitions, formats only if needed (with confirmation)
- **fstab via `uci`** — ext4 mounts by UUID; swap by device path (BusyBox `mkswap` has no `-U` flag)
- **Docker data-root on storage** — images and volumes go to sda3, not extroot
- **Upgrade resilience** - writes `/etc/sysupgrade.conf` to preserve the preinit hook and fstab, and reinstalls the packages you had added after an upgrade
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

OpenWrt `sysupgrade` replaces the base firmware. Your USB data (sda1 extroot, sda3 storage/Samba files) **is always preserved**: it lives on the USB drive, not the flash.

After the upgrade the router boots from its internal flash, **without extroot**. This is expected:

- Every OpenWrt release so far ships a new kernel, so the kernel modules in the old overlay no longer load.
- `block-mount`, `kmod-fs-ext4` and the USB storage modules are not part of the stock image.
- The old overlay cannot simply be mounted again. Its package database would hide the new
  firmware's, and `/etc/apk/world` still pins the old kernel version.

**The script handles this.** Run it again after upgrading:

```sh
# After sysupgrade (internet access needed for apk)
cd gl-mt6000-extroot-setup
./setup.sh
# Installs block-mount + ext4/USB modules, detects the previous extroot,
# runs Phase 3: archives the old overlay on sda1 as upper.<old-kernel>.<date>,
# copies the current system to sda1 -> reboots

# After reboot, run once more for Phase 2
./setup.sh
# Offers to reinstall the packages you had added, configures services, done
```

Phase 3 never formats anything. Once everything works you can delete the archived
`upper.*` and `work.*` directories from the root of sda1. Until then they let you roll
back by flashing the previous firmware and swapping the directories back.

**Tip:** upgrading with `owut` (attended sysupgrade) builds an image that already contains
every package you installed, including the extroot prerequisites for the new kernel.
Phase 3 is still needed to rebuild the overlay, but there is much less to reinstall.

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
4. After an upgrade: offer to reinstall the packages the previous installation had added
5. Install and configure selected optional services
6. Save a package snapshot to `/etc/gl-setup/packages-snapshot` and write `/etc/sysupgrade.conf`
   (preinit hook, fstab, package snapshot) for upgrade resilience
7. Print final system status report

### Phase 3 — Post-upgrade recovery

Triggered automatically when `./setup.sh` detects a previous extroot on sda1
that is not currently mounted (typical state after `sysupgrade`).

1. Mount sda1 read-only, read previous service selections and the list of packages
   the previous installation had added on top of its firmware (falls back to the
   package snapshot kept across the upgrade, see below)
2. Install base packages (`block-mount`, ext4 and USB storage modules) on the internal flash,
   restore the preinit hook
3. Set swap and storage fstab entries, archive the old overlay on sda1
   (`upper.<old-kernel>.<date>`), copy the current system to sda1, set the extroot fstab entry
4. Write `/etc/sysupgrade.conf`
5. Reboot → extroot mounts → run `./setup.sh` again for Phase 2

**No partitions are reformatted and nothing is deleted.** If `/dev/sda1` exists but cannot
be inspected (no internet to install `block-mount`/ext4 support), the script stops instead
of offering the partitioning wizard.

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

While extroot is active, the `/overlay` entry that activates it lives in the fstab on the
internal flash, which cannot be edited from the running system. The uninstaller tells you
how to finish: unplug the USB drive, reboot, then delete that entry with `uci`.

---

## Compatibility

| Firmware        | Version   | Status   |
|-----------------|-----------|----------|
| Vanilla OpenWrt | 25.12.3   | Tested   |
| Vanilla OpenWrt | 25.12.5   | Tested   |
| Vanilla OpenWrt | 25.12.6   | Tested (incl. upgrade from 25.12.5) |
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
