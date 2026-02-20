# init_workstation — Rev5.7.2

> Zero-to-hero workstation setup: CachyOS host → Cloudflare SSH tunnel → KVM Ubuntu VM with Intel iGPU SR-IOV passthrough

**Machine:** Intel Core i9-12900H · 24GB RAM · CachyOS (Limine bootloader, BTRFS)
**Domain:** `easyrentbali.com` (Cloudflare) · **User:** `sandriaas`

---

## ⚡ Quickstart

### Option A — curl (no git required)

```bash
# Phase 1: Host setup (packages, IOMMU, static IP, SSH, Cloudflare tunnel)
bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase1.sh)

# → Reboot after phase 1 ←
sudo reboot

# Phase 2: Create KVM VM + SR-IOV host prep (run after reboot)
bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase2.sh)

# Phase 3: Configure VM internals (SSH, cloudflared, static IP, i915-sriov-dkms)
bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase3.sh)

# Client: configure SSH on your phone/laptop to connect via Cloudflare tunnel
bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase1-client.sh)
```

### Option B — git clone and run locally

```bash
git clone https://github.com/sandriaas/init_workstation.git
cd init_workstation

# Verify system state at any time (read-only, no changes)
bash scripts/check.sh

# Phase 1
sudo bash scripts/phase1.sh

# → Reboot ←
sudo reboot

# Phase 2 (edit configs/vm.conf first if you want to pre-set values)
sudo bash scripts/phase2.sh

# Phase 3
sudo bash scripts/phase3.sh

# Client (no sudo needed)
bash scripts/phase1-client.sh
```

### Script flow

```
phase1.sh ──────────────────────────────────────► reboot
  └─ packages + IOMMU + sleep mask + static IP
     + SSH + Cloudflare tunnel (systemd service)

              phase2.sh ──────────────────────────► writes vm.conf
                └─ detect system specs             (VM_NAME, RAM, disk, ISO,
                   prompt: CPU/RAM/disk/ISO           GPU gen/ROM, tunnel host)
                   GPU gen selection + ROM download
                   install i915-sriov-dkms (host)
                   patch kernel args (limine/grub)
                   virt-install (i440fx/OVMF/headless)
                   attach virtiofs + VF hostdev XML

                            phase3.sh ──────────────► updates vm.conf
                               └─ reads vm.conf
                                  installs cloudflared on host (if missing)
                                  detects existing VM tunnel (shows hostname)
                                  auth check (browser login / API token)
                                  lists domains → select subdomain
                                  creates CF tunnel, fetches token, routes DNS
                                  SSH into VM → packages + headers
                                  static IP + cloudflared install + token
                                  enables cloudflared autostart in VM

phase1-client.sh  (run on phone/laptop/desktop)
  └─ install websocat + openssh
     write ~/.ssh/config → ssh minipc / ssh server-vm
```

---

1. [Phase 0 — Pre-Install Prep + BIOS](#phase-0--pre-install-prep--bios)
2. [Phase 1 — Host Setup](#phase-1--host-setup)
3. [Phase 2/3 — VM Provision + VM Setup](#phase-23--vm-provision--vm-setup)
4. [SSH from Phone / Other Devices](#ssh-from-phone--other-devices)
5. [Config File Backups](#config-file-backups)
6. [Current Status](#current-status)
7. [Next Steps](#next-steps)
8. [Legacy Guide](#legacy-guide)

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
| **1. Packages & Services** | System update, installs required packages + virt stack (`qemu/libvirt/virt-manager/cockpit`), enables sshd/docker/fail2ban/libvirtd/cockpit, adds user to docker/libvirt/kvm groups |
| **2. Disable Sleep** | Masks all sleep/suspend/hibernate targets so the server never suspends |
| **3. Static IP** | Detects interface + gateway, asks for desired static IP/gateway/DNS, applies via NetworkManager or Netplan |
| **4. SSH Setup** | Ensures sshd is active, explicitly enables password authentication |
| **5. Cloudflare SSH Tunnel** | Auth (browser login or API token) → lists domains from account → creates tunnel + DNS CNAME → installs systemd service. API tokens are saved for reuse; domains are listed automatically |
| **6. Intel iGPU SR-IOV + IOMMU** | Prompts GPU gen → installs `i915-sriov-dkms` → configures vfio-pci + udev rules → sets VF count at boot → rebuilds initramfs → patches kernel cmdline (`intel_iommu=on iommu=pt i915.enable_guc=3 i915.max_vfs=N`) → runs bootloader update |

> **⚠ Kernel compatibility note:** `i915-sriov-dkms` has a `BUILD_EXCLUSIVE_KERNEL` constraint and may not build for the latest mainline kernel. If the module is excluded from your running kernel, the script **automatically detects** this and sets the compatible kernel (e.g. LTS) as the default boot entry across Limine, GRUB, and systemd-boot. You'll see a warning like:
> ```
> [WARN] i915-sriov-dkms is NOT built for running kernel (6.19.x)
> [WARN] It is built for: 6.18.x-lts — SR-IOV requires booting that kernel.
> [OK]  Limine default boot set to: *lts (kernel 6.18.x-lts)
> ```
> After reboot the system will run the compatible kernel and SR-IOV will be active.

### Run — full setup

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase1.sh)
```

### Post-run (reboot required)

```bash
sudo reboot

# After reboot verify:
cat /proc/cmdline | grep iommu      # → intel_iommu=on iommu=pt
cat /proc/cmdline | grep i915       # → i915.enable_guc=3 i915.max_vfs=2
dkms status                         # → i915-sriov-dkms/..., <kernel>: installed
cat /sys/devices/pci0000:00/0000:00:02.0/sriov_numvfs  # → 2 (default)
docker run --rm hello-world         # → works without sudo
systemctl status cloudflared        # → active (running)
```

### Troubleshooting: Blank Screen on Boot (Alder Lake + SR-IOV)

If you experience a blank screen after the CachyOS logo when booting the LTS kernel (required for `i915-sriov-dkms`):

1. **Reduce VFs:** High VF counts (e.g. 7) can cause resource contention on the host display. The scripts now default to **2 VFs** to ensure stability.
2. **Remove Framebuffer Args:** Do **NOT** use `video=efifb:off video=vesafb:off`. These arguments disable the display fallback, leaving you with a black screen if the i915 driver hangs during initialization.
3. **Check Kernel:** Ensure you are booting the LTS kernel (`linux-cachyos-lts`) as `i915-sriov-dkms` is often not built for the latest rolling kernel.

The scripts have been updated to reflect these fixes automatically.

### Automated Cloudflare Tunnel (Phase 1 + Phase 3)

**Zero dashboard interaction required** — the entire Cloudflare Tunnel lifecycle is CLI-driven.

#### Phase 1 (Host Tunnel)
1. **Auth choice** — browser login (`cloudflared tunnel login`) or API token (saved for reuse in `~/.cloudflared/api-token`)
2. **Domain listing** — if API token is used, fetches available domains from your account automatically; otherwise asks for domain
3. **Hostname defaults** — suggests `<user>.<domain>` and `cockpit.<domain>` based on selected domain
4. **Creates tunnel + DNS** — fully automated

#### Phase 3 (VM Tunnel)
1. **Installs cloudflared on host** if missing (auto-detects pacman/apt/dnf)
2. **Detects existing VM tunnel** — if cloudflared is already running in the VM, shows current hostname and asks to keep or reconfigure
3. **Auth check** — verifies host auth; if missing, offers browser login or API token (same flow as phase1)
4. **Domain selection** — lists domains (API token) or loads saved domain, lets you pick subdomain
5. **Creates tunnel + token + DNS** — `cloudflared tunnel create` → `token` → `route dns`
6. **Injects into VM** — SSHs into VM, installs `cloudflared service install <token>`, enables autostart
7. **VM autostart** — VM starts automatically on host boot (`virsh autostart`)
8. **cloudflared autostart** — tunnel service starts on VM boot via `systemctl enable cloudflared`

```bash
# Phase 1 handles host auth + tunnel (no separate login step needed):
sudo bash scripts/phase1.sh

# Phase 3 handles everything for the VM:
sudo bash scripts/phase3.sh
```

### Verification (Successful SR-IOV)

If everything works, you should see output similar to this:

```bash
$ uname -r
6.18.12-2-cachyos-lts

$ dkms status
i915-sriov-dkms/2025.12.10, 6.18.12-2-cachyos-lts, x86_64: installed (Original modules exist)

$ cat /sys/devices/pci0000:00/0000:00:02.0/sriov_numvfs
2

$ lspci | grep -i "vga\|display"
00:02.0 VGA compatible controller: Intel Corporation Alder Lake-P GT2 [Iris Xe Graphics] (rev 0c)
00:02.1 VGA compatible controller: Intel Corporation Alder Lake-P GT2 [Iris Xe Graphics] (rev 0c)
00:02.2 VGA compatible controller: Intel Corporation Alder Lake-P GT2 [Iris Xe Graphics] (rev 0c)

$ sudo dmesg | grep -i "SR-IOV\|Enabled.*VF\|PF mode" | head -5
[    4.192063] i915: You are using the i915-sriov-dkms module, a ported version of the i915/xe module with SR-IOV support.
[    4.192417] i915 0000:00:02.0: Running in SR-IOV PF mode
[    4.634038] i915 0000:00:02.1: Running in SR-IOV VF mode
[    4.639166] i915 0000:00:02.1: GuC firmware PRELOADED version 0.0 submission:SR-IOV VF
[    4.645212] i915 0000:00:02.2: Running in SR-IOV VF mode
```

---

## VM Configuration Examples

The `configs/` directory contains templates for different OS types.

### 1. Ubuntu Server (Default)
- **Use Case:** Headless server, Docker, Coolify
- **GPU:** Uses `0000:00:02.1` (VF #1)
- **Config:** `configs/server-vm.conf` (generated by phase2.sh)

### 2. Windows 11
- **Use Case:** RDP workstation, gaming (light), Office
- **GPU:** Uses `0000:00:02.2` (VF #2)
- **Config:** `configs/windows-vm.conf`
- **Notes:** Requires `virtio-win` ISO for network/disk drivers during install. Install Intel Arc/Iris Xe drivers inside Windows for 3D acceleration.

### 3. macOS (Sonoma/Sequoia)
- **Use Case:** iOS dev, Xcode
- **GPU:** **No SR-IOV support.** macOS has no drivers for Intel Iris Xe VFs. Requires dedicated AMD GPU (RX 6600 recommended) for passthrough.
- **CPU:** Use `Haswell-noTSX` for Sonoma+ (Penryn causes kernel panics)
- **Display:** `vmware-svga` for best resolution control via OpenCore
- **Config:** `configs/macos-vm.conf`
- **Reference:** [OSX-KVM](https://github.com/kholia/OSX-KVM) — OpenCore bootloader + macOS installer scripts
- **Notes:** Requires OpenCore bootloader image. Fetch macOS installer with `fetch-macOS-v2.py` from OSX-KVM repo.

---

## Network Architecture

```
Internet / Phone / Laptop
         │
         │  SSH via Cloudflare Tunnel
         ▼
┌─────────────────────────────────────┐
│  Host Machine  192.168.110.90       │  ← Physical LAN (your router)
│  CachyOS / Arch                     │
│                                     │
│  cloudflared ──► b8sqa0n0v48o       │  ← Host tunnel (phase 1)
│  .easyrentbali.com                  │
│                                     │
│  virbr0 NAT  192.168.122.1          │  ← libvirt internal bridge
│       │                             │     completely separate from LAN
│       ▼                             │
│  ┌──────────────────────┐           │
│  │  VM  192.168.122.50  │           │
│  │  Ubuntu Server       │           │
│  │                      │           │
│  │  cloudflared ──────► │           │  ← VM tunnel (phase 3)
│  │  vm-xxxx.easyrent..  │           │
│  └──────────────────────┘           │
└─────────────────────────────────────┘
```

> **Why two separate IPs?**  
> The VM (`192.168.122.x`) lives on libvirt's private NAT bridge — it has no direct LAN presence.  
> External SSH access always goes through the VM's Cloudflare tunnel, so the VM never needs a LAN IP.  
> The host IP (`192.168.110.90`) is only used for local management.

## Phase 2/3 — VM Provision + VM Setup

Use these scripts in order:

```bash
# Phase 2: create VM + vm.conf + virtiofs + SR-IOV host prep
bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase2.sh)

# Phase 3: configure inside VM (SSH, static IP, cloudflared tunnel — automated)
bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase3.sh)

# Client side for VM tunnel
bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase2-client.sh)
```

`phase2.sh` writes `configs/vm.conf` and reuses it in `phase3.sh`.

---

## SSH from Phone / Other Devices

Run `phase1-client.sh` on any device you want to SSH from.
It detects the OS, installs websocat + openssh, and writes `~/.ssh/config`.

### Run

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase1-client.sh)
```

### Windows (PowerShell)

```powershell
irm "https://api.github.com/repos/sandriaas/init_workstation/contents/scripts/phase1-client.ps1" | % { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_.content)) } | iex
```

> Installs Scoop, winget, websocat, and OpenSSH client automatically.

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
