# init_workstation — Rev5.7.2

> Zero-to-hero workstation setup: CachyOS host → Cloudflare SSH tunnel → KVM Ubuntu VM

**Machine:** Intel Core i9-12900H · 24GB RAM · CachyOS (Limine bootloader, BTRFS)
**Domain:** `easyrentbali.com` (Cloudflare) · **User:** `sandriaas`

---

## Table of Contents

1. [Phase 0 — Pre-Install Prep + BIOS](#phase-0--pre-install-prep--bios)
2. [Phase 1 — Host Setup](#phase-1--host-setup)
3. [SSH from Phone / Other Devices](#ssh-from-phone--other-devices)
4. [Config File Backups](#config-file-backups)
5. [Current Status](#current-status)
6. [Next Steps](#next-steps)
7. [Legacy Guide](#legacy-guide)

---

## Phase 0 — Pre-Install Prep + BIOS

*Do these steps before CachyOS is installed.*

### 1. Prep on Another PC

1. Download **CachyOS KDE ISO**: https://cachyos.org/download/
2. Download **Ubuntu Server ISO** (for VM in Phase 2): https://ubuntu.com/download/server
3. Download **Proxmox VE ISO** (for Phase 12 Option B): https://www.proxmox.com/en/downloads
4. Save macOS resources for Phase 11:
   - ISO builder (no Mac required): https://github.com/LongQT-sea/macos-iso-builder
   - Apple installer downloader: https://github.com/corpnewt/gibMacOS
   - VM reference: https://github.com/kholia/OSX-KVM
5. Download **BalenaEtcher**, flash CachyOS ISO to 4GB+ USB.

### 2. Stack Choice

| | Cloudflare Tunnel ⭐ | RackNerd VPS + Rathole |
|---|---|---|
| Cost | Free | ~$1/mo |
| Works with Coolify/Dokploy | Yes | Yes |
| Works with Zeabur | No (proxy URL only) | Yes (real IP:port) |

**Selected:** Cloudflare Tunnel + Coolify/Dokploy

### 3. BIOS Settings

- **Secure Boot:** `DISABLED`
- **VT-d / VT-x:** `ENABLED`
- **IGPU Multi-Monitor:** `ENABLED` (if available)

### 4. CachyOS Installer Settings

- **Filesystem:** BTRFS
- **User:** `sandriaas`
- **Kernel:** CachyOS Default (BORE scheduler)

---

## Phase 1 — Host Setup

All Phase 1 setup is handled by a single idempotent script.
- Auto-detects OS (CachyOS/Arch · Ubuntu/Debian · Fedora · Proxmox)
- Auto-detects current user
- Asks confirmation before each step
- Skips already-completed steps

### Steps performed

| Step | What it does |
|------|--------------|
| **1. Packages & Services** | System update, installs all required packages (distro-aware), enables sshd/docker/fail2ban, adds user to docker group |
| **2. IOMMU** | Detects bootloader (Limine/GRUB/systemd-boot), patches kernel cmdline with `intel_iommu=on iommu=pt`, regenerates bootloader |
| **3. Disable Sleep** | Masks all sleep/suspend/hibernate targets so the server never suspends |
| **4. Static IP** | Detects interface + gateway, asks for desired static IP/gateway/DNS, applies via NetworkManager or Netplan |
| **5. SSH Setup** | Ensures sshd is active, explicitly enables password authentication |
| **6. Cloudflare SSH Tunnel** | Asks tunnel hostname + name + auth (browser login or API token), creates tunnel, DNS CNAME, installs systemd service |

### Run — full setup

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase1.sh)
```

### Run — skip SSH + Cloudflare (already configured)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase1-nossh.sh)
```

### Post-run (reboot required)

```bash
sudo reboot

# After reboot verify:
cat /proc/cmdline | grep iommu      # → intel_iommu=on iommu=pt
docker run --rm hello-world         # → works without sudo
systemctl status cloudflared        # → active (running)
```

---

## SSH from Phone / Other Devices

Run `phase1-client.sh` on any device you want to SSH from.
It detects the OS, installs websocat + openssh, and writes `~/.ssh/config`.

### Run

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase1-client.sh)
```

### Android (Termux from [F-Droid](https://f-droid.org/packages/com.termux/))

```bash
curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase1-client.sh | bash
```

### Manual `~/.ssh/config`

```
Host minipc
  HostName b8sqa0n0v48o.easyrentbali.com
  ProxyCommand websocat -E --binary - wss://%h
  User sandriaas
```

Then: `ssh minipc`

> **Windows:** use full path in ProxyCommand: `C:\Users\<you>\bin\websocat.exe`

---

## Config File Backups

Copies saved in `configs/` for reference and restore.

| File | Original Path | Description |
|------|---------------|-------------|
| `cloudflared-config.yml` | `~/.cloudflared/config.yml` | Tunnel ingress — maps `b8sqa0n0v48o.easyrentbali.com` → `ssh://localhost:22` |
| `ssh-config` | `~/.ssh/config` | SSH client alias with websocat ProxyCommand |
| `limine-default` | `/etc/default/limine` | Bootloader cmdline — includes `intel_iommu=on iommu=pt` |
| `cloudflared.service` | `/etc/systemd/system/cloudflared.service` | systemd unit for cloudflared daemon |

---

## Current Status

| Item | Status |
|------|--------|
| Packages (docker, fail2ban, etc.) | ✅ Installed & enabled |
| `sandriaas` in docker group | ✅ Set (active after reboot) |
| Sleep targets masked | ✅ Done |
| IOMMU in Limine cmdline | ✅ Set (active after reboot) |
| Static IP | ✅ Configured |
| BTRFS snapshot | ✅ `/snapshots/pre-phase1-20260219-134445` |
| Cloudflare tunnel `minipc-ssh` | ✅ Live |
| DNS `b8sqa0n0v48o.easyrentbali.com` | ✅ CNAME → tunnel |
| Terminal SSH via websocat | ✅ Working |

---

## Next Steps

| Priority | Action |
|----------|--------|
| **Now** | `sudo reboot` → activate IOMMU + docker group |
| **Verify** | `cat /proc/cmdline \| grep iommu` · `docker run --rm hello-world` · `systemctl status cloudflared` |
| **Phase 2** | Build isolated Ubuntu Server KVM VM (see guide Phase 2) |
| **Phase 5** | Security hardening — fail2ban tuning, UFW |

---

## Legacy Guide

The original Rev5.7.2 guide is preserved at [`(2) vm-Rev5.7.2-formatted.md`](<(2)%20vm-Rev5.7.2-formatted.md>) for full reference including:

- Phase 2: KVM Ubuntu VM setup
- Phase 3: Tunnel deep-dive
- Phase 4: Coolify/Dokploy deployment
- Phase 5: Security hardening
- Phase 6: RustDesk remote desktop
- Phase 7: Server HUD
- Phase 8–12: Backups, dev environment, macOS VM, Proxmox path
