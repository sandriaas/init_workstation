# MiniPC Setup Log — Rev5.7.2

**Machine:** Intel Core i9-12900H · 24GB RAM · CachyOS (Limine bootloader, BTRFS)
**Date:** 2026-02-19 · **User:** `sandriaas` · **Domain:** `easyrentbali.com` (Cloudflare)

---

## Table of Contents

1. [Phase 0 — Pre-Install Prep + BIOS](#phase-0--pre-install-prep--bios)
2. [Phase 1 — Host Setup Script](#phase-1--host-setup-script)
3. [Phase 2/3 — VM Provision + VM Setup](#phase-23--vm-provision--vm-setup)
4. [SSH from Phone / Other Devices](#ssh-from-phone--other-devices)
5. [Config File Backups](#config-file-backups)
6. [Current Status](#current-status)
7. [Next Steps](#next-steps)

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

## Phase 1 — Host Setup Script

All Phase 1 setup is handled by a single idempotent script. Run it once — already-done steps are detected and skipped automatically.

### Run

```bash
bash scripts/phase1.sh
```

The script will:
- Auto-detect OS (CachyOS/Arch · Ubuntu/Debian · Fedora · Proxmox)
- Auto-detect current user
- Ask confirmation before each step
- Skip steps already completed (SSH active, static IP set, tunnel running, etc.)

### Steps performed

| Step | What it does |
|------|--------------|
| **1. Packages & Services** | System update, installs required packages + virt stack (`qemu/libvirt/virt-manager/cockpit`), enables sshd/docker/fail2ban/libvirtd/cockpit, adds user to docker/libvirt/kvm groups |
| **2. IOMMU** | Detects bootloader (Limine/GRUB/systemd-boot), patches kernel cmdline with `intel_iommu=on iommu=pt i915.enable_guc=3 i915.max_vfs=7 module_blacklist=xe`, regenerates bootloader |
| **3. Disable Sleep** | Masks all sleep/suspend/hibernate targets so the server never suspends |
| **4. Static IP** | Detects interface + gateway, asks for desired static IP/gateway/DNS, applies via NetworkManager or Netplan |
| **5. SSH Setup** | Ensures sshd is active, explicitly enables password authentication |
| **6. Cloudflare SSH Tunnel** | Asks tunnel hostname + name + auth (browser login or API token), creates tunnel, DNS CNAME, installs systemd service |
### Post-run (reboot required)

```bash
sudo reboot

# After reboot verify:
cat /proc/cmdline | grep iommu      # → intel_iommu=on iommu=pt
docker run --rm hello-world         # → works without sudo
systemctl status cloudflared        # → active (running)
```

---

## Phase 2/3 — VM Provision + VM Setup

Use these scripts in order:

```bash
# Phase 2: create VM + vm.conf + virtiofs + SR-IOV host prep
bash scripts/phase2.sh

# Phase 3: configure inside VM (SSH, static IP, cloudflared, websocat)
bash scripts/phase3.sh

# Client side for VM tunnel
bash scripts/phase2-client.sh
```

`phase2.sh` writes `configs/vm.conf` and `phase3.sh` reuses it.

---

## SSH from Phone / Other Devices

Run `phase1-client.sh` on any device you want to SSH from. It detects the OS, installs websocat + openssh, and writes `~/.ssh/config` automatically.

### Run

```bash
# Linux / macOS:
bash scripts/phase1-client.sh

# Android (Termux — paste directly):
curl -sL https://raw.githubusercontent.com/.../phase1-client.sh | bash
# or paste the script manually into Termux
```

The script asks for your tunnel hostname and server username, then ends with:
```
ssh minipc
```

### Manual (if you prefer)

Install websocat:

| OS | Command |
|----|---------|
| **Arch / CachyOS** | `sudo pacman -S websocat` |
| **Ubuntu / Debian** | `curl -sL https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-musl -o /usr/local/bin/websocat && chmod +x /usr/local/bin/websocat` |
| **Fedora** | `sudo dnf install websocat` |
| **macOS** | `brew install websocat` |
| **Windows** | `winget install vi.websocat` |
| **Android (Termux)** | `pkg install websocat` |

`~/.ssh/config`:

```
Host minipc
  HostName b8sqa0n0v48o.easyrentbali.com
  ProxyCommand websocat -E --binary - wss://%h
  User sandriaas
```

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
| **Phase 2/3** | Run `phase2.sh` then `phase3.sh` for VM + tunnel setup |
| **Phase 5** | Security hardening — fail2ban tuning, UFW |
