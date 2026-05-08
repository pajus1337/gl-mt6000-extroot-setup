# GL-MT6000 Setup Tool

Automated setup script for the **GL-MT6000 (Flint 2)** running **vanilla OpenWrt 25.12.3+**.

Automates extroot (USB overlay), swap, storage mounting, and optional services —
in a two-phase, reboot-safe, idempotent flow.

---

## Requirements

| Requirement | Details |
|-------------|---------|
| Router      | GL.iNet GL-MT6000 (Flint 2) — 1 GB RAM, 4-core MediaTek MT7986 |
| Firmware    | Vanilla OpenWrt 25.12.3 (r32912-6639b15f62) or newer |
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

- **Two-phase setup** — Phase 1 (pre-reboot) configures extroot;
  Phase 2 (post-reboot) activates swap, storage, and services
- **Idempotent** — safe to re-run; skips already-configured steps
- **Partition wizard** — detects existing partitions, formats only if needed (with confirmation)
- **UUID-based fstab** — reliable mounts configured via `uci`
- **Docker data-root on storage** — images and volumes go to sda3, not extroot
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
# 1. Flash vanilla OpenWrt 25.12.3 on the GL-MT6000

# 2. Connect USB drive to the router

# 3. SSH in (default IP on vanilla OpenWrt)
ssh root@192.168.1.1

# 4. Install git with HTTPS support
apk update && apk add git git-http ca-bundle

# 5. Clone
git clone https://github.com/pajus1337/gl-mt6000-extroot-setup.git
cd gl-mt6000-extroot-setup
chmod +x setup.sh uninstall.sh

# 6. Run Phase 1
./setup.sh
# → router reboots

# 7. SSH back in — Phase 2 is detected automatically
cd gl-mt6000-extroot-setup
./setup.sh
```

**Specify device explicitly** (if auto-detection picks the wrong drive):

```sh
./setup.sh /dev/sdb
```

---

## Script Structure

```
gl-mt6000-extroot-setup/
├── setup.sh                   # Entry point — routes to Phase 1 or 2
├── uninstall.sh               # Reverses all changes
├── config/
│   └── defaults.sh            # Package lists, size defaults, constants
├── lib/
│   ├── common.sh              # Logging, colors, ash-safe utilities
│   ├── detect.sh              # OpenWrt version & hardware detection
│   ├── ui.sh                  # Interactive prompts and menus
│   ├── partition.sh           # Partition check, format, GPT creation
│   ├── packages.sh            # apk wrapper (pkg_install, pkg_update)
│   ├── storage.sh             # Extroot, swap, storage, service config
│   └── 79_wait_for_extroot    # Preinit hook: waits for USB before mount_root
└── phases/
    ├── phase1_prereboot.sh    # Steps before reboot
    └── phase2_postreboot.sh   # Steps after reboot
```

---

## Phase Details

### Phase 1 — Pre-reboot

1. Check OpenWrt version and device model
2. Detect or prompt for USB device
3. Validate partitions — create GPT layout and/or format only what is needed
4. Install base packages (`block-mount`, `kmod-fs-ext4`, `e2fsprogs`, …)
5. Select optional services to install later
6. Copy `/overlay` to sda1, configure fstab via UCI (UUID-based); install preinit USB wait hook; reboot prompt

### Phase 2 — Post-reboot

1. Verify extroot is active (exits with diagnostics if not)
2. Activate swap (sda2) and register in fstab
3. Mount storage (sda3 → `/mnt/storage`) and register in fstab
4. Install and configure selected optional services
5. Print final system status report

---

## USB Timing Note

The GL-MT6000 USB controller enumerates ~4 s after preinit starts. Without intervention,
`mount_root` runs before `/dev/sda1` appears and falls back to the internal eMMC overlay.

Phase 1 installs `/lib/preinit/79_wait_for_extroot` — a small hook that waits for
`/dev/sda1` before `mount_root` proceeds. This file is copied into the extroot image
and survives reboots automatically.

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

| Firmware        | Version                              | Status   |
|-----------------|--------------------------------------|----------|
| Vanilla OpenWrt | 25.12.3 (r32912-6639b15f62)          | Tested   |
| Vanilla OpenWrt | 25.12.x newer                        | Expected |
| GL.iNet stock   | any                                  | Not supported |

Shell: `/bin/sh` — BusyBox ash compatible, no bash required.

---

## Contributing

Issues and pull requests are welcome.
Please test on a real device before submitting — or clearly mark as untested.

---

## License

[MIT](LICENSE) © 2026 pajus1337
