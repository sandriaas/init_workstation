# init_workstation — Rev5.7.2

> Zero-to-hero workstation setup: CachyOS host → Cloudflare SSH tunnel → KVM Ubuntu VM with Intel iGPU SR-IOV passthrough → Dokploy PaaS

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

# Host SSH client: configure SSH on your phone/laptop to connect to the host
bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase1-client.sh)

# VM SSH client: configure SSH on your phone/laptop to connect to the VM
bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase3-client.sh)
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

# Client SSH — host
bash scripts/phase1-client.sh

# Client SSH — VM
bash scripts/phase3-client.sh
```

### Standalone scripts (run independently, after Phase 3)

```bash
# Cockpit + SSH tunnel on host (alternative to Phase 1's tunnel)
sudo bash scripts/cockpit-cloudflared.sh

# Dokploy + Cloudflare app tunnel on VM (deploys PaaS platform)
sudo bash scripts/dokploy-cloudflared.sh

# Add a DNS record for a new Dokploy app
sudo bash scripts/dokploy-cloudflared.sh add-domain myapp

# Verify the entire setup (read-only)
bash scripts/check.sh
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

cockpit-cloudflared.sh ─────────────────────────── standalone
  └─ install cloudflared on host
     auth (browser / API token, reuses saved creds)
     create/reuse tunnel "minipc-ssh"
     route DNS: ssh.domain → :22, cockpit.domain → :9090
     wrong-tunnel CNAME detection + auto-fix
     install systemd service

dokploy-cloudflared.sh ─────────────────────────── standalone (run after phase3)
  └─ select VM conf
     install cloudflared on host (if missing)
     auth (reuses saved creds)
     create tunnel "dokploy-<vmname>"
     SSH into VM → install Dokploy
     deploy cloudflared container (host network → localhost:80)
     install DNS auto-sync watcher (systemd service)
       └─ docker events → instant CNAME creation (~2s)
          periodic full scan every 60s (fallback)
     subcommand: add-domain <sub> → manual CNAME creation

phase1-client.sh / phase1-client.ps1  (host SSH)
  └─ install websocat + openssh
     write ~/.ssh/config → ssh minipc

phase2-client.sh  (VM SSH — legacy alias)
  └─ install websocat + openssh
     write ~/.ssh/config → ssh server-vm

phase3-client.sh / phase3-client.ps1  (VM SSH)
  └─ install websocat + openssh
     write ~/.ssh/config → ssh <vm-alias>
     test SSH connection (DNS propagation tolerance)

check.sh  (read-only verification)
  └─ system specs, Phase 1/2/3 status
     SR-IOV state, VM config, tunnel health
     pass/fail/warn summary
```

### All scripts

| Script | Target | Purpose |
|--------|--------|---------|
| `phase1.sh` | Host | Packages, IOMMU, SR-IOV, sleep mask, static IP, SSH, CF tunnel |
| `phase2.sh` | Host | Create KVM VM, GPU passthrough, virtiofs, vm.conf |
| `phase3.sh` | Host → VM | VM packages, static IP, cloudflared tunnel, autostart |
| `phase1-client.sh` | Any device | SSH client for host (websocat + SSH config) |
| `phase1-client.ps1` | Windows | SSH client for host (Scoop + websocat + SSH config) |
| `phase2-client.sh` | Any device | SSH client for VM (legacy, same as phase3-client) |
| `phase3-client.sh` | Any device | SSH client for VM (websocat + SSH config + test) |
| `phase3-client.ps1` | Windows | SSH client for VM (Scoop + websocat + SSH config + test) |
| `cockpit-cloudflared.sh` | Host | Standalone CF tunnel for Cockpit (:9090) + SSH (:22) |
| `dokploy-cloudflared.sh` | Host → VM | Install Dokploy + CF tunnel + DNS auto-sync watcher |
| `check.sh` | Host | Read-only system verification (all phases) |

---

1. [Phase 0 — Pre-Install Prep + BIOS](#phase-0--pre-install-prep--bios)
2. [Phase 1 — Host Setup](#phase-1--host-setup)
3. [Phase 2/3 — VM Provision + VM Setup](#phase-23--vm-provision--vm-setup)
4. [SSH from Phone / Other Devices](#ssh-from-phone--other-devices)
5. [Cockpit + SSH Tunnel (Standalone)](#cockpit--ssh-tunnel-standalone)
6. [Dokploy + Cloudflare App Tunnel](#dokploy--cloudflare-app-tunnel)
7. [Config File Backups](#config-file-backups)
8. [Current Status](#current-status)
9. [Next Steps](#next-steps)
10. [Legacy Guide](#legacy-guide)

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
┌─────────────────────────────────────────┐
│  Host Machine  192.168.110.90           │  ← Physical LAN (your router)
│  CachyOS / Arch                         │
│                                         │
│  cloudflared ──► minipc-ssh             │  ← Host tunnel (phase1 / cockpit-cloudflared)
│    ssh.easyrentbali.com     → :22       │
│    cockpit.easyrentbali.com → :9090     │
│                                         │
│  virbr0 NAT  192.168.122.1              │  ← libvirt internal bridge
│       │                                 │
│       ▼                                 │
│  ┌──────────────────────────────────┐   │
│  │  VM  192.168.122.50              │   │
│  │  Ubuntu Server                   │   │
│  │                                  │   │
│  │  cloudflared ──► vm tunnel       │   │  ← VM SSH tunnel (phase 3)
│  │    vm.easyrentbali.com → :22     │   │
│  │                                  │   │
│  │  cloudflared ──► dokploy tunnel  │   │  ← App tunnel (dokploy-cloudflared)
│  │    dokploy.domain   → :3000     │   │     cloudflared container (host net)
│  │    *.domain         → :80       │   │     Traefik routes to app containers
│  │                                  │   │
│  │  Dokploy (:3000)                 │   │  ← PaaS dashboard
│  │  Traefik (:80)                   │   │  ← Reverse proxy for all apps
│  │  dokploy-dns-sync (systemd)      │   │  ← Auto-creates CF CNAMEs
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────┘

App traffic flow:
  Browser → CF CDN → CF Tunnel → cloudflared → Traefik:80 → app container
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

# Client side for VM SSH tunnel (run on your phone/laptop/desktop)
bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase3-client.sh)
```

`phase2.sh` writes `generated-vm/<name>.conf` and reuses it in `phase3.sh`.

---

## SSH from Phone / Other Devices

### Host SSH — `phase1-client.sh`

Run on any device to SSH into the **host machine** via Cloudflare tunnel.
Detects OS (Arch · Ubuntu/Debian · Fedora · macOS · Android/Termux), installs websocat + openssh, writes `~/.ssh/config`.

#### Unix/macOS/Android (Termux)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase1-client.sh)
```

#### Windows (PowerShell)

```powershell
irm "https://api.github.com/repos/sandriaas/init_workstation/contents/scripts/phase1-client.ps1" | % { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_.content)) } | iex
```

> Installs Scoop, winget, websocat, and OpenSSH client automatically.

Then: `ssh minipc`

### VM SSH — `phase3-client.sh`

Run on any device to SSH into the **KVM VM** via Cloudflare tunnel.
Same OS detection + websocat + openssh install. Tests SSH connection with DNS propagation tolerance (~2 min).

#### Unix/macOS/Android (Termux)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase3-client.sh)
```

#### Windows (PowerShell)

```powershell
irm "https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase3-client.ps1" | iex
```

Then: `ssh server-vm` (or the alias you chose)

### Legacy VM client — `phase2-client.sh`

Same as `phase3-client.sh` but with Host alias `server-vm`. Kept for backward compatibility.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase2-client.sh)
```

### Manual `~/.ssh/config`

```
# Host machine
Host minipc
  HostName b8sqa0n0v48o.easyrentbali.com
  ProxyCommand websocat -E --binary - wss://%h
  User sandriaas

# VM
Host server-vm
  HostName vm-subdomain.easyrentbali.com
  ProxyCommand websocat -E --binary - wss://%h
  User sandriaas
```

---

## Cockpit + SSH Tunnel (Standalone)

`cockpit-cloudflared.sh` sets up a dedicated Cloudflare tunnel for **host Cockpit** (web UI on `:9090`) and **SSH** (`:22`). Runs independently of Phase 1's tunnel — useful if you want separate tunnels for different services.

```bash
sudo bash scripts/cockpit-cloudflared.sh
```

**What it does:**

1. Installs cloudflared on host (pacman/apt/dnf)
2. Authenticates with Cloudflare (browser login or API token — reuses saved credentials)
3. Lists domains from your CF account → select one
4. Creates/reuses tunnel `minipc-ssh`
5. Configures ingress: `ssh.domain → localhost:22`, `cockpit.domain → localhost:9090`
6. Routes DNS CNAMEs (with wrong-tunnel detection — auto-detects stale CNAMEs pointing to old tunnels)
7. Installs systemd service → tunnel starts on boot

**After running:**

- Cockpit: `https://cockpit.easyrentbali.com`
- SSH: via `ssh minipc` (uses websocat ProxyCommand)

---

## Dokploy + Cloudflare App Tunnel

`dokploy-cloudflared.sh` deploys **Dokploy** (PaaS platform) on the VM and wires all app traffic through a Cloudflare tunnel via Traefik.

```bash
# Full setup (run once, after phase3)
sudo bash scripts/dokploy-cloudflared.sh

# Add a DNS record for a new app (manual, if auto-sync misses it)
sudo bash scripts/dokploy-cloudflared.sh add-domain myapp
```

**What it does:**

1. Selects VM config (`generated-vm/*.conf`)
2. Verifies VM is reachable via SSH
3. Authenticates with Cloudflare (reuses saved API token)
4. Creates tunnel `dokploy-<vmname>`
5. SSHs into VM → installs Dokploy + deploys cloudflared container
6. Configures ingress: `dokploy.domain → localhost:3000`, `*.domain → localhost:80` (Traefik)
7. Installs **DNS auto-sync watcher** (systemd service on VM)

### DNS Auto-Sync Watcher

The `dokploy-dns-sync` systemd service runs on the VM and **automatically creates Cloudflare CNAME records** for new app domains deployed in Dokploy.

- **Instant detection** — listens to `docker events` and creates CNAMEs within ~2 seconds of container start
- **Periodic fallback** — full scan of all containers every 60 seconds
- **Idempotent** — tracks created records in `/var/lib/dokploy-dns-sync/` to avoid duplicate API calls
- **Self-healing** — reconnects automatically if Docker daemon restarts

**Flow:** Deploy app in Dokploy → add domain `myapp.easyrentbali.com` (port 80, HTTP) → watcher auto-creates CF CNAME → app is live at `https://myapp.easyrentbali.com`

**No manual DNS steps required** after initial setup.

### First-time Dokploy setup (after script runs)

1. Open `http://<VM_IP>:3000` → Settings → General → Server Domain → `dokploy.easyrentbali.com`
2. Settings → Traefik → Disable Let's Encrypt (Cloudflare handles SSL) → Entrypoint: `web` (HTTP port 80)
3. Cloudflare Dashboard → SSL/TLS → set to **Full** (not Flexible)

### `add-domain` subcommand

Manually create a CF CNAME for a new app (if auto-sync doesn't cover it):

```bash
sudo bash scripts/dokploy-cloudflared.sh add-domain n8n-test
# Creates CNAME: n8n-test.easyrentbali.com → tunnel
```

### Cloudflare API Token Permissions

One token covers everything (tunnels, DNS routing, DNS auto-sync):

- Account → Cloudflare Tunnel → **Edit**
- Zone → Zone → **Read**
- Zone → DNS → **Edit**

Token is saved on both host (`~/.cloudflared/api-token`) and VM for reuse across all scripts.

---

## Config File Backups

Copies saved in `configs/` for reference and restore.

| File | Original Path | Description |
|------|---------------|-------------|
| `cloudflared-config.yml` | `~/.cloudflared/config.yml` | Tunnel ingress — maps hostname → `ssh://localhost:22` |
| `ssh-config` | `~/.ssh/config` | SSH client alias with websocat ProxyCommand |
| `limine-default` | `/etc/default/limine` | Bootloader cmdline — includes `intel_iommu=on iommu=pt` |
| `cloudflared.service` | `/etc/systemd/system/cloudflared.service` | systemd unit for cloudflared daemon |
| `vm.conf` | Generated by phase2 | Template VM config (CPU, RAM, disk, GPU, tunnel) |
| `vm.conf.example` | — | Example with all available fields documented |
| `macos-vm.conf` | — | macOS VM config (Haswell-noTSX, vmware-svga, OpenCore) |
| `windows-vm.conf` | — | Windows 11 VM config (VF #2, virtio-win drivers) |

Generated configs (per-VM, created by phase2/3):

| File | Description |
|------|-------------|
| `generated-vm/<name>.conf` | VM-specific config with tunnel IDs, IPs, GPU assignment |
| `generated-vm/.state` | Phase completion tracking |

---

## Current Status

| Item | Status |
|------|--------|
| Packages (docker, fail2ban, etc.) | ✅ Installed & enabled |
| `sandriaas` in docker group | ✅ Active |
| Sleep targets masked | ✅ Done |
| IOMMU + SR-IOV kernel args | ✅ Active |
| Static IP | ✅ Configured |
| Host Cloudflare tunnel | ✅ Live |
| KVM VM (vm_1) | ✅ Running, autostart enabled |
| VM Cloudflare tunnel | ✅ Live |
| Dokploy | ✅ Deployed on VM |
| Dokploy app tunnel | ✅ Live (cloudflared container, host network) |
| DNS auto-sync watcher | ✅ Running (docker events + 60s poll) |
| Terminal SSH via websocat | ✅ Working (host + VM) |

---

## Next Steps

| Priority | Action |
|----------|--------|
| **Verify** | `bash scripts/check.sh` — full system audit |
| **Dokploy** | Deploy apps, add domains — DNS auto-sync handles CNAMEs |
| **Phase 5** | Security hardening — fail2ban tuning, UFW |
| **Phase 6+** | RustDesk, Server HUD, backups (see Legacy Guide) |

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
