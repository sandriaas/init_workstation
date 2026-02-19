# (2) vm-Rev5.7.2-formatted

# 📘 The Definitive "Zero to Hero" Guide — Rev5.7.2 (Fortress + Legacy-Depth Edition)

> **Status:** Final Fortress + Full Legacy Depth — Feb 2026**Architecture:** Bare Metal CachyOS Host + Isolated Ubuntu VM (KVM)**Replaces:** Rev2 (Native Docker) & Rev1 (Proxmox)**Hardware Target:** Intel Core i9-12900H (14 Cores) + 32GB RAM

## The "WSL-Like" Philosophy

We do not use Proxmox (which kills your desktop) or Raw Docker (which risks your host stability).

Instead, we run **CachyOS on Bare Metal** for maximum performance and use **KVM/QEMU** to create a "hidden" Ubuntu Server inside it.

* **Dynamic Resources:** The VM borrows RAM/CPU only when needed (virtio-balloon).
* **Total Isolation:** If you break the server (Coolify/Zeabur), your desktop survives.
* **Snapshots:** One-click backup/restore of the entire server stack.

***

## 📑 Table of Contents

* [🏗️ Architecture Comparison & Stack Explained](#-architecture-comparison--stack-explained)
* [⚔️ Distro War: CachyOS vs. Fedora](#-distro-war-cachyos-vs-fedora)
* [🛑 Phase 0: Pre-Install Prep + BIOS](#-phase-0-pre-install-prep--bios)
* [💿 Phase 1: Install CachyOS (The Host)](#-phase-1-install-cachyos-the-host)
* [🏰 Phase 2: Build the Isolated VM (The Core)](#-phase-2-build-the-isolated-vm-the-core)
* [☁️ Phase 3: Tunnel Setup (Bridge to VM)](#-phase-3-tunnel-setup-bridge-to-vm)
* [📦 Phase 4: Deploy Platform (Inside VM)](#-phase-4-deploy-platform-inside-vm)
* [🛡️ Phase 5: Security Hardening (Crucial)](#-phase-5-security-hardening-crucial)
* [🦸 Phase 6: Remote Access (RustDesk)](#-phase-6-remote-access-rustdesk)
* [☀️ Phase 7: Server HUD (Premium)](#-phase-7-server-hud-premium)
* [🔗 Phase 8: Verify & Done](#-phase-8-verify--done)
* [🔄 Phase 9: Backup & Recovery](#-phase-9-backup--recovery)
* [🛠️ Phase 10: CachyOS Dev Environment (Host)](#-phase-10-cachyos-dev-environment-host)
* [🍎 Phase 11: Optional Isolated macOS VM (CachyOS Host)](#-phase-11-optional-isolated-macos-vm-cachyos-host)
* [📝 Notes & Caveats](#-notes--caveats)
* [📊 Quick Reference](#-quick-reference)
* [🚀 Phase 12: Direct-Boot macOS Daily Driver Mode (Additional)](#-phase-12-direct-boot-macos-daily-driver-mode-additional)
* [📝 Phase 12 Notes & Caveats (Specific)](#-phase-12-notes--caveats-specific)
* [📊 Phase 12 Quick Reference (Specific)](#-phase-12-quick-reference-specific)
* [🧯 Phase 12 Troubleshooting (Specific)](#-phase-12-troubleshooting-specific)

***

## 🏗️ Architecture Comparison & Stack Explained

### Architecture Comparison

| Feature               | WSL2 (Reference)    | Proxmox (Rev1)       | Isolated VM (Rev3+) 🏆       | Raw Docker (Rev2)            |
| --------------------- | ------------------- | -------------------- | ---------------------------- | ---------------------------- |
| **Dynamic CPU**       | ✅ Shared            | ⚠️ Pinned to VM      | ✅ **Overprovisioned**        | ✅ Native                     |
| **Dynamic RAM**       | ✅ Auto Balloon      | ⚠️ Fixed per VM      | ✅ **virtio-balloon**         | ✅ Native                     |
| **Dynamic Storage**   | ✅ Virtual VHDX      | ❌ Fixed Disk         | ✅ **virtiofs (Shared)**      | ✅ Native                     |
| **GPU Sharing**       | ✅ vGPU              | ✅ SR-IOV             | ✅ **SR-IOV**                 | ❌ Host Only                  |
| **Network Isolation** | ✅ Isolated          | ✅ Isolated           | ✅ **Isolated Stack**         | ❌ Shared w/ Host             |
| **K3s/Swarm Safe?**   | ✅ Yes               | ✅ Yes                | ✅ **Yes**                    | ❌ Conflicts                  |
| **Host Desktop**      | ✅ Windows           | ❌ None (Hypervisor)  | ✅ **CachyOS KDE**            | ✅ CachyOS KDE                |
| **Snapshots**         | ❌ Difficult         | ✅ Easy               | ✅ **Instant (1-click)**      | ❌ Manual                     |
| **Power Efficiency**  | 🟡 Medium (Windows) | 🟡 Standard (Server) | 🟢 **High (CachyOS Kernel)** | 🟢 **High (CachyOS Kernel)** |

> **Note on Power Efficiency:**

### Phase 12 Daily-macOS Host Comparison (CachyOS vs Proxmox)

| Metric                                 | CachyOS (Desktop Enabled)              | CachyOS (Headless Direct-Boot Mode)                           | Proxmox VE (Baseline)                     |
| -------------------------------------- | -------------------------------------- | ------------------------------------------------------------- | ----------------------------------------- |
| **macOS VM CPU Throughput vs Proxmox** | \~3-8% lower                           | \~1-4% lower                                                  | Baseline                                  |
| **Extra Host RAM vs Proxmox**          | +1.5 to +3.5 GB                        | +0.5 to +1.5 GB                                               | Baseline                                  |
| **24 GB RAM Impact**                   | +6.3% to +14.6%                        | +2.1% to +6.3%                                                | 0%                                        |
| **User Experience**                    | Best Linux+macOS dual-use              | Near-Proxmox performance with Linux fallback                  | Best pure VM-host consistency             |
| **Best Use Case**                      | You regularly need CachyOS GUI + tools | You want direct-boot macOS feel but keep CachyOS control path | You want a dedicated hypervisor appliance |

> Practical read: if you disable the host desktop and boot CachyOS into multi-user mode, the performance gap to Proxmox is typically small.Baseline rationale: KVM virtualization is near-native versus emulation; the main difference here is host userspace/service footprint, not the hypervisor core itself.

### The "Isolated VM" Stack Explained

You are building a "Proxmox without Proxmox" setup. Everything is available in CachyOS repos.

**The Stack:**

```
┌─────────────────────────────────────────┐
│  Host: CachyOS KDE + AI Workloads       │
│  Hypervisor: libvirt/QEMU               │
│  UI: Cockpit (Web UI at localhost:9090) │
│  Guest: Ubuntu Server VM (~1s boot)     │
└─────────────────────────────────────────┘
```

**What each piece does:**

| Component          | Package      | Purpose                                             |
| ------------------ | ------------ | --------------------------------------------------- |
| **QEMU + KVM**     | `qemu-full`  | The VM hypervisor (same technology Proxmox uses).   |
| **libvirt**        | `libvirt`    | VM lifecycle management (start/stop/balloon).       |
| **Cockpit**        | `cockpit`    | **Web UI at :9090** — create/manage VMs in browser. |
| **virtio-balloon** | *(Built-in)* | **Dynamic RAM** — VM returns unused memory to host. |
| **virtiofs**       | *(Built-in)* | **Shared Storage** — Mount host folders into VM.    |
| **i915-sriov**     | AUR          | **GPU Split** — VF0 for Host, VF1 for VM.           |

***

### ⚔️ Distro War: CachyOS vs. Fedora

Why this guide defaults to CachyOS, but acknowledges Fedora as a strong alternative.

| Feature           | CachyOS (Recommended) 🏆     | Fedora Workstation (COPR)      | Fedora Atomic (COSMIC/OStree) |
| ----------------- | ---------------------------- | ------------------------------ | ----------------------------- |
| **Kernel Source** | **Native** (Main Repo)       | Third-Party (COPR)             | Third-Party (Layered)         |
| **SR-IOV Driver** | **AUR** (`yay -S`)           | COPR (matte23/akmod)           | ❌ Hard (Container/Layering)   |
| **Tunnel Tool**   | **AUR** (rathole-bin)        | Manual Binary Install          | Manual Binary Install         |
| **Update Safety** | 🟢 Rolling (Tested together) | 🟡 Kernel/Module Mismatch Risk | 🔴 Reboot hell for layers     |
| **Setup Time**    | ⚡ **15 Minutes**             | ⏳ 30+ Minutes                  | ⏳ 60+ Minutes                 |
| **Zero-to-Hero**  | ✅ One Command                | ⚠️ Multiple Steps              | ❌ Requires OStree Knowledge   |

**Verdict:** Use CachyOS for the fastest path. Use Fedora if you prefer dnf/SELinux and don't mind managing COPRs and manual binaries.

### Phase 3 + Phase 4 Stack Choice Matrix

#### Phase 3 Tunnel Comparison (Cloudflare vs VPS + Rathole)

| Feature                    | Cloudflare Tunnel                   | RackNerd VPS + Rathole                      |
| -------------------------- | ----------------------------------- | ------------------------------------------- |
| **Cost**                   | Free (plus domain)                  | VPS cost (\~\$1/mo)                         |
| **Exposure Model**         | HTTP/HTTPS proxy hostnames          | Raw public IP + multi-port forwarding       |
| **TCP/Port Flexibility**   | Limited for this workflow           | Full TCP mapping (22/80/443/4222/6443/etc.) |
| **Zeabur Compatibility**   | No (not raw IP:port path)           | Yes                                         |
| **RustDesk Relay Quality** | Usable but indirect                 | Best (direct VPS relay setup)               |
| **Setup Difficulty**       | Lower                               | Higher                                      |
| **Best Fit**               | Coolify/Dokploy public app exposure | Zeabur + advanced multi-port flows          |

#### Phase 4 Platform Comparison (Direct Docker vs Coolify vs Dokploy vs Zeabur)

| Feature                                   | Direct Docker                                           | Coolify                                                | Dokploy                               | Zeabur                                                                             |
| ----------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------ | ------------------------------------- | ---------------------------------------------------------------------------------- |
| **Runtime / Orchestrator**                | Docker Engine + Compose/CLI                             | Docker Compose + Traefik                               | Docker Swarm + Traefik                | Managed K3s/Kubernetes                                                             |
| **AI-Assisted App Creation**              | None built-in                                           | MCP-style AI management/integration ecosystem          | AI Docker Compose generation workflow | Framework/language auto-detect style onboarding                                    |
| **Copy/Duplicate Service (Same Server)**  | Manual compose clone                                    | Manual clone/compose pattern                           | Manual duplicate/service recreate     | Dashboard-driven project/service duplication                                       |
| **Copy/Migrate Project (Another Server)** | Manual export/import + volume migration                 | Manual export/import + volume migration                | Mostly manual migration               | Strongest built-in project copy/move workflow                                      |
| **Reverse Proxy Model**                   | User-selected (Traefik/Caddy/Nginx)                     | Traefik-based                                          | Traefik-based                         | K8s ingress model (not user Traefik-first)                                         |
| **Control-Plane Baseline CPU**            | Reference (near-zero extra control plane)               | \~1-3% of one core                                     | \~1-3% of one core                    | \~5-6% of one core (K3s baseline)                                                  |
| **Control-Plane Baseline RAM**            | Reference                                               | \~0.3-0.8 GB                                           | \~0.3-0.8 GB                          | \~1.4-1.6 GB (K3s baseline profile)                                                |
| **24 GB Host RAM Share (Baseline)**       | Reference                                               | \~1.3-3.3%                                             | \~1.3-3.3%                            | \~5.8-6.7%                                                                         |
| **Marginal vs Direct Docker**             | 0% (baseline)                                           | +\~1-3% CPU, +\~0.3-0.8 GB RAM                         | +\~1-3% CPU, +\~0.3-0.8 GB RAM        | +\~2-5% CPU and +\~0.6-1.2 GB RAM vs Docker-first stacks                           |
| **Cloudflare Tunnel Fit**                 | Strong                                                  | Strong                                                 | Strong                                | Not primary path                                                                   |
| **VPS + Rathole Fit**                     | Strong                                                  | Works                                                  | Works                                 | Required                                                                           |
| **Best Fit**                              | Maximum efficiency + manual ops                         | Best default for this guide                            | Swarm users + AI compose preference   | Managed K8s with VPS path                                                          |
| **Your Choice Rank**                      | **#2 (Secondary)**                                      | **#4**                                                 | **#3**                                | **#1 (Primary)**                                                                   |
| **Reason for Your Rank**                  | Best efficiency fallback with minimal baseline overhead | Lower priority than your preferred Zeabur/Docker paths | Swarm + AI-compose middle option      | Preferred for Kubernetes workflows (self-heal, rolling updates, scaling, CronJobs) |

> Practical rule (general): use Direct Docker/Coolify/Dokploy for best efficiency. Choose Zeabur when you specifically need Kubernetes features and Zeabur workflows.Your current selected order: **Zeabur (primary) → Direct Docker (secondary) → Dokploy (third) → Coolify (fourth)**.Kubernetes features worth the overhead: self-healing pods, rolling updates, replica-based scaling/autoscaling, ingress/service discovery, and CronJob/Job orchestration.Resource note: K3s baseline figures come from official K3s profiling docs; Docker-first platform ranges above are practical planning estimates and can vary by workload.

***

## 🛑 Phase 0: Pre-Install Prep + BIOS

*Do these steps before CachyOS is installed.*

### 1. Prep on Another PC

1. Download **CachyOS KDE ISO** (host OS): https://cachyos.org/download/
2. Download **Ubuntu Server ISO** (for VM in Phase 2): https://ubuntu.com/download/server
3. Download **Proxmox VE ISO** (for Phase 12 Option B path): https://www.proxmox.com/en/downloads
4. Save **macOS resources** for later Phase 11 use:
   * Installer ISO builder (no Mac required): https://github.com/LongQT-sea/macos-iso-builder
   * Direct Apple installer downloader: https://github.com/corpnewt/gibMacOS
   * VM setup reference/troubleshooting: https://github.com/kholia/OSX-KVM
5. Download **BalenaEtcher**.
6. Flash a 4GB+ USB installer (CachyOS ISO).

> Install **CachyOS first**. If you want COSMIC later, add it after the base host setup is stable.

### 2. Choose Your Stack (Do This FIRST)

|                            | Cloudflare Tunnel ⭐ | RackNerd VPS + Rathole |
| -------------------------- | ------------------- | ---------------------- |
| Cost                       | Free                | \~\$1/mo               |
| Works with Zeabur          | No (proxy URL only) | Yes (real IP:port)     |
| Works with Coolify/Dokploy | Yes                 | Yes                    |
| RustDesk Relay             | Medium              | Best                   |

| Goal                | Tunnel                 | Platform           |
| ------------------- | ---------------------- | ------------------ |
| Free + self-hosted  | Cloudflare Tunnel      | Coolify or Dokploy |
| Managed Zeabur node | RackNerd VPS + Rathole | Zeabur             |

### 3. BIOS Settings

* **Secure Boot:** `DISABLED`
* **VT-d / VT-x:** `ENABLED`
* **IGPU Multi-Monitor:** `ENABLED` (if available)

> Kernel parameters and IOMMU configuration are done in **Phase 1** after CachyOS installation.

***

## 💿 Phase 1: Install CachyOS (The Host)

### 1. Boot from USB

Use CachyOS KDE ISO and launch installer.

### 2. Installer

* **Filesystem:** BTRFS (recommended)
* **User:** `sandria` (host user)
* **Kernel:** CachyOS Default (BORE scheduler)

### 3. Post-Install System Prep

```shellscript
sudo pacman -Syu --noconfirm
sudo pacman -S --noconfirm git base-devel curl wget htop net-tools openssh \
  docker docker-compose cloudflared sysfsutils fail2ban lm_sensors micro

# Explicit service enables (Rev5.6 parity)
sudo systemctl enable --now sshd
sudo systemctl enable --now sysfsutils
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
sudo sensors-detect --auto
```

### 4. Kernel Parameters (Enable IOMMU)

```shellscript
# Optional explicit editor install (Rev5.6 parity)
sudo pacman -S micro

sudo micro /etc/default/grub
# Append to GRUB_CMDLINE_LINUX_DEFAULT:
# intel_iommu=on iommu=pt
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

### 5. Reboot + Verify Docker

```shellscript
sudo reboot
# after reboot
docker run --rm hello-world
```

### 6. Disable System Sleep (CRITICAL)

```shellscript
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

### 7. Set Host Static IP (Recommended)

GUI: **System Settings → Network → IPv4 → Manual**

CLI alternative:

```shellscript
sudo nmcli con mod "Wired connection 1" ipv4.method manual   ipv4.addresses 192.168.1.50/24   ipv4.gateway 192.168.1.1   ipv4.dns "1.1.1.1,8.8.8.8"
sudo nmcli con up "Wired connection 1"
```

***

## 🏰 Phase 2: Build the Isolated VM (The Core)

*We will create a "Server VM" that acts like a dedicated server inside your computer.*

### 2A: Install Virtualization Stack

```shellscript
# 1. Install KVM, QEMU, Libvirt, and Cockpit
sudo pacman -S qemu-full libvirt virt-manager cockpit cockpit-machines dnsmasq bridge-utils

# 2. Enable Services
sudo systemctl enable --now libvirtd.socket
sudo systemctl enable --now cockpit.socket

# 3. Add User to Groups (Required for permissions)
sudo usermod -aG libvirt $USER
sudo usermod -aG kvm $USER

# 4. Start Default Network (NAT)
sudo virsh net-autostart default
sudo virsh net-start default

# 5. REBOOT NOW (Required for group permissions to take effect)
sudo reboot
```

### 2B: Create VM via Cockpit

1. **Cockpit** (`localhost:9090`) → **Virtual Machines** → **Create VM**
2. **Name:** `server-vm`
3. **OS:** **Ubuntu 24.04 LTS** (Select "Download OS" if needed)
4. **Storage:** 32 GiB *(Minimum. We add shared storage in 2D)*
5. **Memory:** 8 GiB *(Safe starting point; ballooning handles the rest)*
6. **vCPUs:** 14 *(Select "Passthrough" or "Host Model" to use all cores)*
7. **Run Immediately:** ☑️ Checked

**During Ubuntu Install:**

* **Hostname:** `ubuntu-server`
* **User:** `sandria` *(Keep consistent with host for simplicity)*
* **SSH:** Check **☑ Install OpenSSH server**

### 2C: Static IP Setup (Critical)

*The VM needs a permanent IP so tunnels don't break.*

1. Check current IP (Inside VM):
   ```shellscript
   ip addr  # Assume 192.168.122.x
   ```
2. Edit Netplan:
   ```shellscript
   sudo micro /etc/netplan/00-installer-config.yaml
   ```
3. Paste Config (Lock to `.50`):
   ```yaml
   network:
     ethernets:
       enp1s0:  # Verify this name via 'ip link'
         dhcp4: no
         addresses:
           - 192.168.122.50/24
         routes:
           - to: default
             via: 192.168.122.1
         nameservers:
           addresses: [8.8.8.8, 1.1.1.1]
     version: 2
   ```
4. Apply:
   ```shellscript
   sudo netplan apply
   ```
5. **Your&#x20;****`TARGET_IP`****&#x20;is now:&#x20;****`192.168.122.50`**

### 2D: Shared Storage (virtiofs)

*Let the VM access a folder on your Host (e.g., for Docker data).*

1. **On Host** — Create folder:
   ```shellscript
   mkdir -p /home/sandria/server-data
   ```
2. **Edit VM XML** (On Host):
   > **Note:** We use `EDITOR=micro` so you don't get stuck in `vi`.
   ```shellscript
   EDITOR=micro sudo virsh edit server-vm
   ```
3. Add inside the `<devices>` block:
   ```xml
   <filesystem type='mount' accessmode='passthrough'>
     <driver type='virtiofs'/>
     <source dir='/home/sandria/server-data'/>
     <target dir='host_data'/>
   </filesystem>
   ```
4. **Mount** (Inside VM):
   ```shellscript
   sudo mkdir -p /mnt/data
   echo "host_data /mnt/data virtiofs defaults 0 0" | sudo tee -a /etc/fstab
   sudo mount -a
   ```

### 2E: GPU Passthrough (SR-IOV) \[Required]

*Required for this target setup: give the VM its own GPU slice for AI/Transcoding.*

1. **Install Driver** (Host):
   ```shellscript
   paru -S i915-sriov-dkms
   ```

2. **Create VFs** (Host):
   ```shellscript
   # Set kernel parameters
   sudo micro /etc/default/grub
   # Append: i915.enable_guc=3 i915.max_vfs=7
   sudo grub-mkconfig -o /boot/grub/grub.cfg

   # Create persistent config for sysfsutils
   # Note: Verify PCI ID with 'lspci | grep VGA'. Usually 00:02.0
   echo "devices/pci0000:00/0000:00:02.0/sriov_numvfs = 7" | sudo tee -a /etc/sysfs.conf

   sudo reboot
   ```
3. **Pass VF to VM:**
   * **Cockpit:** VM → Hardware → Add PCI Device → Select `00:02.1` (VF1)

### 2F: Enable VM Autostart (Persistence)

*This ensures the Server VM turns on automatically if the Host reboots.*

```shellscript
# On CachyOS Host
sudo virsh autostart server-vm
```

***

## ☁️ Phase 3: Tunnel Setup (Bridge to VM)

> **⚠️ CRITICAL:** Point all tunnels to `192.168.122.50` (VM), **NOT** `localhost`.

### Option A: RackNerd VPS (Primary for Zeabur)

*Primary path for your ranked setup. Required for TCP/UDP ports or Zeabur. Also handles RustDesk Relay.*

#### Step 1: SSH into VPS

```shellscript
ssh root@YOUR_VPS_IP
```

#### Step 2: Install Rathole & RustDesk Server (VPS Side)

```shellscript
sudo apt update && sudo apt install -y curl unzip ufw fail2ban micro
sudo ufw allow 22/tcp    # VPS SSH
sudo ufw allow 2222/tcp  # Rathole SSH Forward
sudo ufw allow 80/tcp    # HTTP
sudo ufw allow 443/tcp   # HTTPS
sudo ufw allow 2333/tcp  # Rathole Server Control
sudo ufw allow 21115:21119/tcp  # RustDesk
sudo ufw allow 21116/udp       # RustDesk
sudo ufw enable

wget -O rathole.zip https://github.com/rathole-org/rathole/releases/latest/download/rathole-x86_64-unknown-linux-gnu.zip
unzip rathole.zip && sudo mv rathole /usr/local/bin/ && sudo chmod +x /usr/local/bin/rathole && rm rathole.zip

curl -fsSL https://get.docker.com | sh
sudo docker run --name hbbs -v ./data:/root -td --net=host --restart unless-stopped rustdesk/rustdesk-server hbbs
sudo docker run --name hbbr -v ./data:/root -td --net=host --restart unless-stopped rustdesk/rustdesk-server hbbr

echo "RUSTDESK KEY: $(cat ./data/id_ed25519.pub)"
```

#### Step 3: Configure Rathole Server (VPS Side)

```shellscript
tr -dc A-Za-z0-9 </dev/urandom | head -c 64 && echo
sudo micro /etc/rathole_server.toml
```

```toml
[server]
bind_addr = "0.0.0.0:2333"
default_token = "MY_SECRET_TOKEN"

[server.services.ssh]
bind_addr = "0.0.0.0:2222"

[server.services.k8s]
bind_addr = "0.0.0.0:6443"

[server.services.nats]
bind_addr = "0.0.0.0:4222"

[server.services.http]
bind_addr = "0.0.0.0:80"

[server.services.https]
bind_addr = "0.0.0.0:443"
```

#### Step 4: Create VPS System Service (Persistence)

```shellscript
sudo micro /etc/systemd/system/rathole.service
```

```ini
[Unit]
Description=Rathole Server
After=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
ExecStart=/usr/local/bin/rathole --server /etc/rathole_server.toml
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
```

```shellscript
sudo systemctl daemon-reload
sudo systemctl enable --now rathole
```

#### Step 5: Configure Rathole Client (CachyOS Host)

```shellscript
paru -S rathole-bin
sudo mkdir -p /etc/rathole
sudo micro /etc/rathole/client.toml
```

```toml
[client]
remote_addr = "YOUR_VPS_IP:2333"
default_token = "MY_SECRET_TOKEN"

[client.services.ssh]
local_addr = "192.168.122.50:22"   # VM SSH

[client.services.k8s]
local_addr = "192.168.122.50:6443" # VM K8s

[client.services.nats]
local_addr = "192.168.122.50:4222" # VM NATS

[client.services.http]
local_addr = "192.168.122.50:80"   # Zeabur/Coolify HTTP

[client.services.https]
local_addr = "192.168.122.50:443"  # Zeabur/Coolify HTTPS
```

```ini
[Unit]
Description=Rathole Client
After=network.target

[Service]
Type=simple
Restart=on-failure
ExecStart=/usr/local/bin/rathole /etc/rathole/client.toml

[Install]
WantedBy=multi-user.target
```

```shellscript
sudo systemctl daemon-reload
sudo systemctl enable --now rathole-client
```

### Option B: Cloudflare Tunnel (Secondary)

*Secondary path; best for Coolify/Dokploy/Direct Docker HTTP(S) exposure.*

1. Buy/import your domain into Cloudflare and update nameservers.
2. Install connector on host:

```shellscript
sudo pacman -S cloudflared
```

1. Create tunnel: Cloudflare Zero Trust → Networks → Tunnels → Create.
2. Install as host service:

```shellscript
sudo cloudflared service install <TOKEN>
sudo systemctl enable --now cloudflared
```

1. Configure public hostnames:
   * `coolify.yourdomain.com` → `http://192.168.122.50:8000`
   * `deploy.yourdomain.com` → `http://192.168.122.50:3000`
   * `*.yourdomain.com` → `http://192.168.122.50:80`
2. SSL/TLS mode in Cloudflare: **Full**.

***

## 📦 Phase 4: Deploy Platform (Inside VM)

> **⚠️ Stop:** SSH into the VM (`ssh sandria@192.168.122.50`) before running these commands.

### Option A: Zeabur (Primary, Managed K3s)

*Requires Option A Tunnel (VPS).*

1. Enable root SSH in VM:

```shellscript
echo "PermitRootLogin yes" | sudo tee /etc/ssh/sshd_config.d/root-login.conf
sudo systemctl restart ssh
sudo passwd root
```

1. Zeabur Dashboard → Connect your own server:
   * IP: `YOUR_VPS_IP`
   * Port: `2222`
   * User: `root`
   * Password: VM root password
2. Validate onboarding path:

```shellscript
ssh root@YOUR_VPS_IP -p 2222
```

### Option B: Direct Docker (Secondary)

```shellscript
# Inside VM
sudo apt update
sudo apt install -y docker.io docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
newgrp docker
docker ps
```

* Deploy your services with Compose stacks (Chatwoot, n8n, TanStack Start SSR).
* Use your own reverse proxy pattern (Traefik/Caddy/Nginx) and route through Phase 3 tunnel.

### Option C: Dokploy (Third, AI-Assisted)

```shellscript
# Inside VM
curl -sSL https://dokploy.com/install.sh | sudo sh
docker info | grep -i Swarm
```

* Access: `http://192.168.122.50:3000`
* Disable Let's Encrypt when using Cloudflare Tunnel SSL Full.
* Verify services after install:

```shellscript
docker service ls
```

### Option D: Coolify (Fourth)

```shellscript
# Inside VM
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash
```

* Access: `http://192.168.122.50:8000`
* Configure wildcard domain in Coolify server settings.
* Expose via Cloudflare hostname mapping from Phase 3.
* Deploy first test app (e.g., Uptime Kuma template).

***

## 🛡️ Phase 5: Security Hardening (Crucial)

*Prevent attacks on your exposed ports.*

### 1. Install Fail2Ban (Host & VPS)

* **Host:** `sudo systemctl enable --now fail2ban` *(Installed in Phase 1)*
* **VPS:** `sudo systemctl enable --now fail2ban` *(Installed in Phase 3A)*
* *Default config works: Bans IPs after 5 failed SSH attempts.*

### 2. VM Console Access (Your Safety Net)

If you lock yourself out of SSH (e.g., messed up Netplan):

1. Open **Cockpit** (`localhost:9090`) → **Virtual Machines** → **server-vm** → **Console**
2. You can log in here like a physical monitor attached to the server.

***

## 🦸 Phase 6: Remote Access (RustDesk)

*Access the&#x20;****Host Desktop****&#x20;to manage the VM.*

### 1. Install (Host)

```shellscript
paru -S rustdesk-bin
```

### 2. Mode A: RustDesk with Cloudflare Tunnel/Public Relay

```shellscript
# Optional self-host relay containers
docker run --name hbbs -v ./rustdesk-data:/root -td --net=host --restart unless-stopped rustdesk/rustdesk-server hbbs
docker run --name hbbr -v ./rustdesk-data:/root -td --net=host --restart unless-stopped rustdesk/rustdesk-server hbbr
```

### 3. Mode B: RustDesk with VPS Relay

```shellscript
sudo rustdesk --config-id-server YOUR_VPS_IP
sudo rustdesk --config-relay-server YOUR_VPS_IP
sudo rustdesk --config-key PASTE_KEY_FROM_PHASE_3
sudo rustdesk --password "ChangeThisStrongPassword"
sudo systemctl restart rustdesk
sudo rustdesk --get-id
```

### 4. Save ID

This gives you full control over CachyOS (and thus the VM).

***

## ☀️ Phase 7: Server HUD (Premium)

*Monitor the Host + VM + All 14 Cores.*

### 1. Install (Host)

```shellscript
sudo pacman -S conky-all
```

### 2. Config

```shellscript
nano ~/.config/conky/server.conf
```

```lua
conky.config = {
    own_window = true, own_window_type = 'desktop', own_window_transparent = true,
    own_window_hints = 'undecorated,below,sticky,skip_taskbar,skip_pager',
    double_buffer = true, alignment = 'top_right',
    minimum_width = 400, minimum_height = 400,
    use_xft = true, font = 'Monospace:size=10',
    default_color = 'white', color1 = '#00FF00', color2 = '#FF0000', color3 = '#FFFF00',
    update_interval = 2,
};

conky.text = [[
${font Monospace:bold:size=14}${color1}ISOLATED VM SERVER${font}
${hr 2}
${color}Host Kernel: ${color1}$kernel
${color}Uptime: ${color1}$uptime
${color}Host RAM: $mem / $memmax ($memperc%)
${color}SSD: ${fs_used /} / ${fs_size /} (${fs_used_perc /}%)
${hr 2}
${font Monospace:bold:size=11}VM STATUS (QEMU)${font}
${color}State: ${exec virsh domstate server-vm}
${color}CPU Load: ${top name 1} ${top cpu 1}%
${hr 2}
${font Monospace:bold:size=11}SYSTEM HEALTH${font}
${color}Power Draw: ${color1}${exec sudo cat /sys/class/power_supply/BAT0/power_now | awk '{print $1/1000000}'} W${color}
${color}Mini PC Temp: ${color3}${exec sensors | grep "Package id 0:" | awk '{print $4}'}${color}
${color}NVMe Temp: ${color3}${exec sensors | grep "Composite:" | awk '{print $2}'}${color}
${color}GPU Temp: ${color3}${exec sensors | grep "edge:" | awk '{print $2}'}${color}
${hr 2}
${font Monospace:bold:size=11}ALL CORES (Host + VM)${font}
${color}01-06: ${cpu cpu1}% ${cpu cpu2}% ${cpu cpu3}% ${cpu cpu4}% ${cpu cpu5}% ${cpu cpu6}%
07-12: ${cpu cpu7}% ${cpu cpu8}% ${cpu cpu9}% ${cpu cpu10}% ${cpu cpu11}% ${cpu cpu12}%
13-14: ${cpu cpu13}% ${cpu cpu14}%
${hr 2}
${font Monospace:bold:size=11}DOCKER${font}
${color}Containers: ${exec docker ps -q | wc -l} running
${hr 2}
${font Monospace:bold:size=11}SERVICES${font}
${color}Docker: ${if_match "${exec systemctl is-active docker}" == "active"}${color1}● RUNNING${else}${color2}● STOPPED${endif}
${color}SSH: ${if_match "${exec systemctl is-active sshd}" == "active"}${color1}● RUNNING${else}${color2}● STOPPED${endif}
${hr 2}
${font Monospace:bold:size=11}TUNNEL${font}
${color}Cloudflared: ${if_match "${exec systemctl is-active cloudflared}" == "active"}${color1}● ONLINE${else}${color2}● OFFLINE${endif}
]];
```

### 3. Auto-Start

```shellscript
mkdir -p ~/.config/autostart

cat > ~/.config/autostart/conky.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Conky HUD
Exec=conky -c /home/sandria/.config/conky/server.conf -d
X-GNOME-Autostart-enabled=true
EOF
```

***

## 🔗 Phase 8: Verify & Done

### 8A: If Using Zeabur

```shellscript
ssh root@YOUR_VPS_IP -p 2222
systemctl status rathole-client --no-pager
```

Ensure Zeabur dashboard shows the server as **Online**.

### 8B: If Using Direct Docker

```shellscript
docker ps
sudo systemctl status docker --no-pager
```

Confirm your app containers (Chatwoot/n8n/TanStack SSR stack) are running.

### 8C: If Using Dokploy

```shellscript
docker service ls
systemctl status cloudflared --no-pager
```

Open `https://deploy.yourdomain.com` and deploy one test app.

### 8D: If Using Coolify

```shellscript
docker ps | grep -E 'coolify|traefik|postgres'
systemctl status cloudflared --no-pager
```

Open `https://coolify.yourdomain.com` and deploy one test app.

## ✅ You Are Done!

| Action            | Expected Behavior                                                                                            |
| ----------------- | ------------------------------------------------------------------------------------------------------------ |
| Power on host     | CachyOS boots, libvirt starts, `server-vm` autostarts                                                        |
| Open platform URL | Zeabur/Dokploy/Coolify reachable through tunnel; Direct Docker reachable through your configured proxy route |
| Deploy app        | Public subdomain routes through Cloudflare/VPS path                                                          |
| Open RustDesk     | Host desktop available remotely                                                                              |
| Break deployment  | Revert VM snapshot without touching host desktop                                                             |

***

## 🔄 Phase 9: Backup & Recovery

*The "Oh Sh*t" button: snapshot + platform recovery + data archives.\*

### 1. Create Snapshot (VM)

* Cockpit → Virtual Machines → `server-vm` → Snapshots → **Create**

### 2. Create Snapshot (Host OS)

```shellscript
sudo btrfs subvolume snapshot / /snapshots/pre-update-$(date +%Y%m%d)
```

### 3. Restore

* Select Snapshot → **Revert**

### 4. Full VM Backup (Cold Storage)

```shellscript
sudo virsh shutdown server-vm
cp /var/lib/libvirt/images/ubuntu-24.04...qcow2 /run/media/sandria/USB_DRIVE/
sudo virsh start server-vm
```

### 5. Platform-Specific Recovery

```shellscript
# Coolify
cd /data/coolify && docker compose down
docker system prune -af
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash

# Dokploy
docker stack rm dokploy
docker swarm leave --force
docker system prune -af
curl -sSL https://dokploy.com/install.sh | sudo sh

# Zeabur (if K3s installed)
/usr/local/bin/k3s-uninstall.sh || true
docker system prune -af
```

### 6. Docker Data Backup

```shellscript
sudo tar czf ~/docker-volumes-$(date +%Y%m%d).tar.gz /var/lib/docker/volumes/
sudo tar czf ~/coolify-data-$(date +%Y%m%d).tar.gz /data/coolify/
sudo tar czf ~/dokploy-config-$(date +%Y%m%d).tar.gz /etc/dokploy/
```

### 7. Timeshift (GUI Snapshots)

```shellscript
sudo pacman -S --noconfirm timeshift
```

***

## 🛠️ Phase 10: CachyOS Dev Environment (Host)

*Prepare your host workstation for Android/mobile development while keeping server VMs isolated.*

### 10.1 Install `_dotfiles` (Host)

Use the repository's manual method:

```shellscript
git clone https://github.com/sandriaas/_dotfiles.git ~/_dotfiles
cd ~/_dotfiles
chmod +x install.sh
./install.sh
```

If `install.sh` is distro-targeted and fails on CachyOS, keep repo configs and apply selectively from `local/`.

### 10.2 Install Firefox + Core Apps (Host)

```shellscript
sudo pacman -S --noconfirm firefox kitty fastfetch btop unzip wl-clipboard grim slurp
```

You can add/remove apps here based on your workflow, but keep Firefox installed for web testing and dashboard access.

### 10.3 Install Customization Stack (Niri / Quickshell)

Install compositor and portal base:

```shellscript
sudo pacman -S --noconfirm niri xwayland-satellite xdg-desktop-portal-gnome xdg-desktop-portal-gtk alacritty
```

Install Quickshell ecosystem options (AUR):

```shellscript
paru -S quickshell dms-shell noctalia-shell caelestia-shell
```

Recommended profile flow:

1. **DMS / DankMaterialShell** (niri-focused):
   ```shellscript
   systemctl --user add-wants niri.service dms
   ```
2. **Noctalia**: install and follow its first-run wizard.
3. **Caelestia**: install and apply its shell profile.
4. **Exo Material 3**: use upstream repo (Ignis-based, not Quickshell package):
   ```shellscript
   git clone https://github.com/debuggyo/Exo.git ~/Exo
   ```

Use one shell profile at a time to avoid duplicate bars/launchers.

Validate niri config after edits:

```shellscript
niri validate
```

Quickshell config path:

* `~/.config/quickshell`

### 10.4 Install ADB / Fastboot (Host)

```shellscript
sudo pacman -S --noconfirm android-tools
adb version
```

### 10.5 Local Database Dev (Supabase CLI)

Use this in your app project directory for local Postgres/Auth/Studio workflow.

Install Supabase CLI globally with Bun:

```shellscript
bun add -g supabase
supabase --version
```

Ensure Docker is running, then list containers:

```shellscript
sudo systemctl enable --now docker
systemctl status docker --no-pager
docker ps
docker ps -a
```

Initialize and start local Supabase stack:

```shellscript
supabase init
supabase start
```

Useful local endpoints:

* Studio: `http://127.0.0.1:54323`
* API: `http://127.0.0.1:54321`

Stop local stack when done:

```shellscript
supabase stop
```

### 10.6 Install Android Studio + Emulator (Host)

```shellscript
sudo pacman -S --noconfirm android-studio jdk17-openjdk
sudo usermod -aG kvm $USER
```

Log out/in after group update.

In Android Studio:

1. **More Actions → SDK Manager**: install Android SDK Platform + SDK Platform-Tools.
2. **SDK Tools** tab: install **Android Emulator** + required command-line tools.
3. **Device Manager**: create an AVD (e.g., Pixel + recent API image).
4. Start emulator and verify `adb devices` shows it.

### 10.7 Launch Emulator from CLI (Optional)

```shellscript
~/Android/Sdk/emulator/emulator -list-avds
~/Android/Sdk/emulator/emulator -avd <YOUR_AVD_NAME>
adb devices
```

***

## 🍎 Phase 11: Optional Isolated macOS VM (CachyOS Host)

*Use this only when you need macOS. Your primary stack remains CachyOS Host + isolated Linux server VM.*

### 11.1 Preconditions (Host)

1. Keep your host as **CachyOS** (this guide's primary architecture).
2. BIOS: VT-d enabled, UEFI mode, iGPU as primary.
3. Host packages:

```shellscript
sudo pacman -S --noconfirm qemu-full libvirt virt-manager ovmf dnsmasq bridge-utils curl wget unzip
sudo systemctl enable --now libvirtd.socket
```

1. Legal check: verify Apple licensing requirements for your environment.
2. Required resources for this phase:
   * `macos-iso-builder` (installer ISO build)
   * `OpenCore-ISO` (boot/EFI path)
   * `intel-igpu-passthru` (required Intel iGPU passthrough config)

### 11.2 Get Installer Media (No Mac required)

1. Preferred: use `macos-iso-builder` GitHub Actions to build either:
   * **Recovery ISO** (fast build), or
   * **Full Installer ISO** (larger, slower build).
2. Alternative: use `gibMacOS` to download official Apple installer packages, then prepare installer media from that payload.
3. Download artifact/media and copy to host ISO path (example):

```shellscript
sudo mkdir -p /var/lib/libvirt/images
# Example path after download:
# /var/lib/libvirt/images/macOS_Sequoia.iso
```

### 11.3 Get OpenCore ISO

1. Download release from `OpenCore-ISO` repository.
2. Place ISO on host (example):

```shellscript
# Example resulting file
# /var/lib/libvirt/images/LongQT-OpenCore.iso
```

### 11.4 Create macOS VM on CachyOS Host

Use **Cockpit** (`https://localhost:9090`) or `virt-manager`:

* VM Name: `macos-vm`
* Firmware: **OVMF (UEFI)**
* vCPU: start with `6-10`
* RAM: start with `8-12 GB`
* Disk: `80+ GB` (virtio or sata)
* Network: virtio (or e1000 for older versions)
* Attach **two CD/DVD ISOs**:
  1. `LongQT-OpenCore.iso`
  2. `macOS installer/recovery ISO`

### 11.5 First Boot + Install macOS (Interface Steps)

1. Start VM and open **Console** in Cockpit.
2. In OpenCore boot picker, choose macOS installer/recovery entry.
3. Open **Disk Utility**:
   * View → Show All Devices
   * Erase target disk as **APFS** + **GUID Partition Map**
4. Run **Install macOS** and target the APFS disk.
5. VM restarts multiple times; each reboot, pick the installer/target entry until setup completes.
6. Complete macOS first-run wizard (region, keyboard, account, privacy).

### 11.6 Make macOS Usable Daily

Inside macOS:

1. Complete desktop login and verify Finder/UI responsiveness.
2. Open **System Settings → General → Sharing** and enable **Screen Sharing** (optional for in-guest remote control).
3. From OpenCore tools, install OpenCore EFI to startup disk (so you can detach temporary ISO later).

### 11.7 Direct Monitor Output (Required)

1. Connect a monitor to the host output path used for iGPU passthrough.
2. Start `macos-vm` and select the correct monitor input.
3. Confirm you can see OpenCore boot picker and macOS desktop on the physical display.
4. Keep Cockpit console as fallback control path.

### 11.8 Required Intel iGPU Passthrough

From `intel-igpu-passthru` docs (required for this macOS path):

* i9-12900H class maps to `ADL-H_RPL-H_GOPv21_igd.rom`.
* Generic QEMU/KVM path is documented (not Proxmox-only).
* Configure the VM with the documented QEMU/KVM passthrough args and ROM mapping before treating the macOS setup as complete.

### 11.9 Remote Control from Other Places (RustDesk)

You already installed RustDesk on the CachyOS host in **Phase 6**.

1. On host, refresh and get your ID:

```shellscript
sudo systemctl restart rustdesk
rustdesk --get-id
```

1. On remote device, connect to the **host RustDesk ID**.
2. From that remote host session, manage everything:
   * Cockpit (`https://localhost:9090`)
   * `server-vm` and `macos-vm` console windows
   * local tools/terminals on CachyOS

### 11.10 Direct Laptop → macOS (RustDesk Guest)

If you want direct control of macOS (without going through host console), install RustDesk inside the macOS VM:

1. In macOS VM, download/install RustDesk from `https://rustdesk.com` (or Homebrew/cask if you prefer).
2. Open RustDesk in macOS and grant permissions when prompted:
   * **Accessibility**
   * **Screen Recording**
3. In RustDesk (macOS), copy the **guest RustDesk ID** shown in the app.
4. On your laptop RustDesk client, connect directly to that macOS guest ID.
5. Optional: in RustDesk network settings inside macOS, set ID/Relay server to your VPS relay (from Phase 3B) for a private relay path.

### 11.11 Resource Reclaim + Wake Behavior (Important)

1. **CPU reclaim:** yes — when `macos-vm` is idle, host scheduler time is naturally available to host + other VMs.
2. **RAM reclaim:** do not assume automatic reclaim from macOS guest; for guaranteed reclaim, shut down macOS VM when unused:

```shellscript
sudo virsh shutdown macos-vm
```

1. **Direct RustDesk wake from laptop:** not possible if `macos-vm` is fully powered off (guest RustDesk endpoint is offline).
2. For near-instant remote use, choose one workflow:
   * **Always-on guest workflow:** keep `macos-vm` running and disable macOS auto-sleep.
   * **On-demand workflow (recommended):** connect to host RustDesk first, start VM, then connect directly to guest RustDesk ID.

```shellscript
# Start macOS VM on host
sudo virsh start macos-vm

# Check state
sudo virsh domstate macos-vm
```

From your laptop, you can do the same over SSH to the CachyOS host:

```shellscript
# Start macOS VM remotely
ssh sandria@192.168.1.50 "sudo virsh start macos-vm"

# Check state remotely
ssh sandria@192.168.1.50 "sudo virsh domstate macos-vm"

# Shut down macOS VM when done (reclaim RAM cleanly)
ssh sandria@192.168.1.50 "sudo virsh shutdown macos-vm"
```

### 11.12 OSX-KVM: What to Apply Here

From `kholia/OSX-KVM`, the useful bits for this guide are:

1. **Baseline requirements sanity checks** (VT-x/SVM, modern QEMU, OpenCore boot flow).
2. **Troubleshooting mindset** (networking, headless operation, post-install remote access notes).
3. Keep using **OpenCore-ISO + intel-igpu-passthru** as primary implementation path here (already aligned with your stack).

Usually **not needed** here unless troubleshooting:

* `kvm.ignore_msrs=1` style host tweaks from OSX-KVM.
* Full raw `OpenCore-Boot.sh` workflow (this guide already uses Cockpit/libvirt workflow).

### 11.13 Xcode + iPhone Emulator (iOS Development)

Use Apple + simulator docs flow inside the macOS VM (Xcode components + Simulator runtimes):

1. Install **Xcode** in macOS VM (App Store or Apple Developer download).
2. Launch Xcode once and complete first-run setup, then run:

```shellscript
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
```

1. Install iPhone simulator runtime:
   * Xcode → **Settings** → **Platforms**
   * Download the required **iOS Simulator Runtime**.
2. Open simulator UI:
   * Xcode → **Open Developer Tool** → **Simulator**
   * Create/select an iPhone model in **Window → Devices and Simulators**.
3. Verify toolchain + simulator from Terminal (inside macOS VM):

```shellscript
xcodebuild -showsdks
xcrun simctl list devices
```

1. Build and run a sample iOS app target to confirm compile + boot + launch pipeline.

> macOS here is still an on-demand VM, but **iGPU passthrough is required** for this phase's target setup on your CachyOS host.

## 📝 Notes & Caveats

### Zeabur + Tunnel Compatibility

* Cloudflare Tunnel is HTTP(S)-proxy oriented and not equivalent to raw multi-port exposure.
* For Zeabur, use **VPS + Rathole** for predictable onboarding.

### Platform Fit

* **Coolify:** best default for self-hosted compose workflows.
* **Dokploy:** strong choice for Swarm and AI-assisted compose generation.
* **Zeabur:** use when you need managed K3s flow and accept VPS dependency.

### Bare Metal vs Proxmox vs Isolated VM

* Fixed VM pinning can reduce compile throughput vs host scheduling.
* Static allocations can fragment RAM for AI workloads.
* Isolated VM mode keeps Compose/Swarm/K3s network changes inside VM boundaries.

***

## 📊 Quick Reference

| Component                               | IP / Port / Access                                                                                           | Location         |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------ | ---------------- |
| **Cockpit UI**                          | `https://localhost:9090`                                                                                     | Host             |
| **Coolify UI**                          | `192.168.122.50:8000`                                                                                        | VM               |
| **SSH (Host)**                          | `192.168.1.50:22`                                                                                            | Host             |
| **SSH (VM)**                            | `192.168.122.50:22`                                                                                          | VM               |
| **RustDesk (Host Control)**             | Host: `rustdesk --get-id` / TCP+UDP `21115-21119`; use host session to control VMs via Cockpit               | Host             |
| **RustDesk (macOS Direct Control)**     | Use RustDesk ID shown inside macOS guest app                                                                 | macOS VM         |
| **macOS VM On-Demand Start**            | Host local: `sudo virsh start macos-vm`; from laptop: `ssh sandria@192.168.1.50 "sudo virsh start macos-vm"` | Host → macOS VM  |
| **Phase 12 Direct-Boot Mode (CachyOS)** | `sudo ln -sf /usr/lib/systemd/system/multi-user.target /etc/systemd/system/default.target && sudo reboot`    | Host             |
| **Phase 12 Restore GUI Mode (CachyOS)** | `sudo ln -sf /usr/lib/systemd/system/graphical.target /etc/systemd/system/default.target && sudo reboot`     | Host             |
| **Phase 12 Proxmox VM Autostart**       | `qm set <vmid> -onboot 1 && qm set <vmid> --startup "order=1,up=30,down=10"`                                 | Proxmox Host     |
| **macOS VM Console**                    | Cockpit → `macos-vm` → Console                                                                               | Host             |
| **Xcode + iOS Simulator**               | Xcode → Settings → Platforms; Xcode → Open Developer Tool → Simulator                                        | macOS VM         |
| **macOS Direct Monitor**                | Physical monitor output via passthrough                                                                      | Physical display |
| **macOS Screen Sharing**                | System Settings → General → Sharing                                                                          | macOS VM         |
| **Firefox + Core Apps**                 | `firefox`, `kitty`, `fastfetch`, `btop`                                                                      | Host             |
| **Niri/Quickshell Customization**       | `niri`, `quickshell`, `dms-shell`, `noctalia-shell`, `caelestia-shell`                                       | Host             |
| **Android Studio + Emulator**           | Android Studio → SDK Manager / Device Manager                                                                | Host             |
| **ADB / Fastboot**                      | `adb devices` / `fastboot devices`                                                                           | Host             |
| **Supabase Local Stack**                | `bun add -g supabase && supabase init && supabase start`                                                     | Host             |
| **Shared Data**                         | `/mnt/data`                                                                                                  | VM               |

### Troubleshooting

| Problem                                    | Solution                                                                                                                                               |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **"Can't connect to Coolify from Laptop"** | You can't. `192.168.122.50` is internal. Use the public domain (`coolify.yourdomain.com`) or RustDesk into the Host.                                   |
| **"VM slow"**                              | Check if virtio-balloon is active: `virsh dommemstat server-vm`                                                                                        |
| **"Zeabur Offline"**                       | Check if Rathole is running on Host: `systemctl status rathole-client`                                                                                 |
| **"Can't access macOS desktop remotely"**  | Use either host RustDesk → Cockpit Console, or direct guest RustDesk ID; inside macOS ensure Accessibility + Screen Recording permissions are granted. |
| **"macOS RustDesk ID offline"**            | Start `macos-vm` from host first (`sudo virsh start macos-vm`), wait for guest login/session, then reconnect with guest RustDesk ID.                   |

***

***

***

## 🚀 Phase 12: Direct-Boot macOS Daily Driver Mode (Additional)

*This is an additional mode after the full guide is already working. Goal: power on machine and land in macOS daily-use flow with minimal host interaction.*

**Phase 12 placeholder map:** `<macos-vmid>` = macOS VM ID, `<apps-vmid>` = app VM ID, `<apps-vm-ip>` = app VM IP, `<proxmox-ip>` = Proxmox host IP.

### Option A: CachyOS Host → macOS Daily Driver (Primary Path)

#### A.1 Reuse from earlier phases (100% same)

* Use all existing setup from **Phase 1 + Phase 2 + Phase 11** (host virtualization, macOS VM install, OpenCore, iGPU passthrough, direct monitor output, RustDesk in guest).
* Keep **Phase 6** RustDesk host path as recovery control channel.

#### A.2 One-time host tuning for direct-boot behavior

1. Ensure libvirt and VM autostart:

```shellscript
sudo systemctl enable --now libvirtd.socket
sudo virsh autostart macos-vm
sudo virsh dominfo macos-vm | grep -i Autostart
```

1. Set host default target to CLI (headless-style boot, lower overhead):

```shellscript
sudo ln -sf /usr/lib/systemd/system/multi-user.target /etc/systemd/system/default.target
sudo reboot
```

#### A.3 First boot validation (until macOS desktop appears)

1. Power on machine.
2. Wait for host boot + VM autostart.
3. Confirm monitor shows OpenCore → macOS login/desktop.
4. From another device, verify VM state:

```shellscript
ssh sandria@192.168.1.50 "sudo virsh domstate macos-vm"
```

#### A.4 Daily workflow (Option A)

1. Turn on machine → macOS should appear on monitor automatically.
2. Work in macOS as primary desktop.
3. If you need host actions from macOS, use macOS Terminal:

```shellscript
# Check VM/host quickly
ssh sandria@192.168.1.50 "sudo virsh domstate macos-vm && uptime"

# Enable CachyOS GUI mode from inside macOS (persistent default)
ssh sandria@192.168.1.50 "sudo ln -sf /usr/lib/systemd/system/graphical.target /etc/systemd/system/default.target && sudo reboot"

# Return to direct-boot headless mode (persistent default)
ssh sandria@192.168.1.50 "sudo ln -sf /usr/lib/systemd/system/multi-user.target /etc/systemd/system/default.target && sudo reboot"

# One-time GUI start without changing default target
ssh sandria@192.168.1.50 "sudo systemctl start sddm"
```

1. End of day: cleanly shut down macOS VM (or full machine):

```shellscript
ssh sandria@192.168.1.50 "sudo virsh shutdown macos-vm"
```

1. Run **A.6 Platform Continuity Checklist (Post-Boot)** for the platform you use.

#### A.5 Conky / watch status shown on monitor

* **Conky itself runs on Linux host GUI, not inside macOS guest.**
* Two practical ways for "screen when monitor wakes":
  1. **Host GUI mode:** enable graphical target and reuse Phase 7 Conky HUD directly.
  2. **macOS mode:** keep macOS full-screen Terminal showing host status via SSH loop:

```shellscript
while true; do clear; ssh sandria@192.168.1.50 "virsh domstate macos-vm; echo '---'; free -h | head -n 2; echo '---'; uptime"; sleep 3; done
```

Set this command in a macOS Terminal profile/login item if you want it to appear immediately after login.

#### A.6 Platform Continuity Checklist (Post-Boot)

Run these checks after booting into daily macOS mode on Option A.

Common precheck (all platforms):

```shellscript
ssh sandria@192.168.1.50 "sudo virsh domstate server-vm"
```

**If using Direct Docker (Native):**

```shellscript
ssh sandria@192.168.1.50 "ssh sandria@192.168.122.50 'docker ps'"
# Tunnel path check (use the one you selected in Phase 3)
ssh sandria@192.168.1.50 "systemctl status cloudflared --no-pager || systemctl status rathole-client --no-pager"
```

**If using Zeabur:**

```shellscript
ssh sandria@192.168.1.50 "systemctl status rathole-client --no-pager"
```

Then verify Zeabur dashboard:

* `https://dash.zeabur.com/servers` shows your server as **Online**.

**If using Dokploy:**

```shellscript
ssh sandria@192.168.1.50 "ssh sandria@192.168.122.50 'docker service ls'"
ssh sandria@192.168.1.50 "systemctl status cloudflared --no-pager || systemctl status rathole-client --no-pager"
```

**If using Coolify:**

```shellscript
ssh sandria@192.168.1.50 "ssh sandria@192.168.122.50 \"docker ps | grep -E 'coolify|traefik|postgres'\""
ssh sandria@192.168.1.50 "systemctl status cloudflared --no-pager || systemctl status rathole-client --no-pager"
```

### Option B: Proxmox Host → macOS Daily Driver (Alternative)

*Goal: full Proxmox path for Phase 12 where you still keep Zeabur/Direct Docker/Dokploy/Coolify alive, then run macOS daily after desktop is verified, and only then enable autostart.*

#### B.1 Stage 1 — Proxmox host bootstrap (network + base)

1. Flash Proxmox ISO to USB, boot target machine, install to NVMe.
2. During installer network step:
   * Use a stable management IP in your LAN (example: `192.168.1.50/24`).
   * Gateway = your router (example: `192.168.1.1`).
   * DNS = your resolver (example: `1.1.1.1`).
3. Verify host control channels:
   * Web UI: `https://<proxmox-ip>:8006`
   * SSH: `ssh root@<proxmox-ip>`

Optional host desktop/HUD stack:

```shellscript
apt update && apt install -y xfce4 lightdm firefox-esr virt-viewer conky-all net-tools git build-essential dkms pve-headers-$(uname -r) sysfsutils cpu-checker curl
```

Optional local user/autologin for desktop mode:

```shellscript
adduser sandria --gecos "" --disabled-password
echo "sandria:sandria" | chpasswd
usermod -aG sudo sandria
mkdir -p /etc/lightdm/lightdm.conf.d
echo -e "[Seat:*]\nautologin-user=sandria\nautologin-user-timeout=0" > /etc/lightdm/lightdm.conf.d/autologin.conf
```

#### B.2 Stage 1b — Intel iGPU split prerequisites (complete)

```shellscript
cd /root
git clone https://github.com/strongtz/i915-sriov-dkms.git
cd i915-sriov-dkms
dkms add .
dkms install -m i915-sriov-dkms -v $(cat VERSION) --force

sed -i 's/$/ intel_iommu=on i915.enable_guc=3 i915.max_vfs=7/' /etc/kernel/cmdline
proxmox-boot-tool refresh

echo "devices/pci0000:00/0000:00:02.0/sriov_numvfs = 7" > /etc/sysfs.d/i915-sriov.conf
reboot
```

After reboot:

```shellscript
lspci | grep -iE "VGA|Display"
cat /sys/devices/pci0000:00/0000:00:02.0/sriov_numvfs
```

#### B.3 Stage 2 — Build app node + tunnel/rathole path first

Create app VM (Ubuntu, equivalent to source VM105):

1. Proxmox UI → Create VM (example ID `105`):
   * OS: Ubuntu Server ISO
   * CPU: 4 cores (`host`)
   * RAM: 6 GB (ballooning off)
   * Disk: 32+ GB
   * Network: `vmbr0`
   * Start at boot: enabled
2. Install Ubuntu + OpenSSH in guest.

##### Tunnel path A — Cloudflare Tunnel (for Direct Docker/Dokploy/Coolify)

Inside app VM:

```shellscript
curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo dpkg -i cloudflared.deb
rm cloudflared.deb
sudo cloudflared service install <YOUR_TUNNEL_TOKEN>
```

Create hostnames in Cloudflare Zero Trust tunnel:

* `apps.yourdomain.com` → `http://127.0.0.1:80`
* `deploy.yourdomain.com` → `http://127.0.0.1:3000`
* `coolify.yourdomain.com` → `http://127.0.0.1:8000`

##### Tunnel path B — VPS + Rathole (required for Zeabur path)

On VPS:

```shellscript
sudo apt update && sudo apt install -y curl unzip ufw fail2ban micro
sudo ufw allow 22/tcp
sudo ufw allow 2222/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 2333/tcp
sudo ufw allow 21115:21119/tcp
sudo ufw allow 21116/udp
sudo ufw enable

wget -O rathole.zip https://github.com/rathole-org/rathole/releases/latest/download/rathole-x86_64-unknown-linux-gnu.zip
unzip rathole.zip && sudo mv rathole /usr/local/bin/ && sudo chmod +x /usr/local/bin/rathole && rm rathole.zip

sudo tee /etc/rathole_server.toml > /dev/null <<'EOF'
[server]
bind_addr = "0.0.0.0:2333"
default_token = "MY_SECRET_TOKEN"

[server.services.ssh]
bind_addr = "0.0.0.0:2222"

[server.services.http]
bind_addr = "0.0.0.0:80"

[server.services.https]
bind_addr = "0.0.0.0:443"
EOF

sudo tee /etc/systemd/system/rathole.service > /dev/null <<'EOF'
[Unit]
Description=Rathole Server
After=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
ExecStart=/usr/local/bin/rathole --server /etc/rathole_server.toml
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now rathole
```

Inside app VM:

```shellscript
wget -O rathole.zip https://github.com/rathole-org/rathole/releases/latest/download/rathole-x86_64-unknown-linux-gnu.zip
sudo apt install -y unzip
unzip rathole.zip
sudo mv rathole /usr/local/bin/
sudo chmod +x /usr/local/bin/rathole
rm rathole.zip

sudo tee /etc/rathole_client.toml > /dev/null <<'EOF'
[client]
remote_addr = "YOUR_VPS_IP:2333"
default_token = "MY_SECRET_TOKEN"

[client.services.ssh]
local_addr = "127.0.0.1:22"

[client.services.http]
local_addr = "127.0.0.1:80"

[client.services.https]
local_addr = "127.0.0.1:443"
EOF

sudo tee /etc/systemd/system/rathole.service > /dev/null <<'EOF'
[Unit]
Description=Rathole Client
After=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
ExecStart=/usr/local/bin/rathole --client /etc/rathole_client.toml

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now rathole
```

#### B.4 Stage 2b — Platform branch on app VM (choose one)

##### B.4.1 Zeabur (requires Tunnel path B)

1. Ensure Rathole `ssh` forwarding works to app VM.
2. In Zeabur dashboard:
   * `Create` → `Connect your own server`
   * IP: VPS IP
   * Port: `2222`
   * Username/password or SSH key from app VM
3. Server should show **Online**.

##### B.4.2 Direct Docker (native)

```shellscript
sudo apt update
sudo apt install -y docker.io docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
newgrp docker
docker ps
```

##### B.4.3 Dokploy

```shellscript
curl -sSL https://dokploy.com/install.sh | sh
docker info | grep -i Swarm
docker service ls
```

##### B.4.4 Coolify

```shellscript
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash
docker ps | grep -E 'coolify|traefik|postgres'
```

#### B.5 Stage 3 — Build macOS VM and verify desktop FIRST (required gate)

1. Put media into Proxmox ISO storage (`/var/lib/vz/template/iso/`):
   * OpenCore ISO
   * macOS installer/recovery ISO
2. Create macOS VM in Proxmox UI:
   * Machine `q35`, BIOS `OVMF`
   * CPU `host`, vCPU `6-10`
   * RAM `8-12 GB`, disk `80+ GB`
   * Attach both ISOs
   * Add PCI device `0000:00:02.1` (iGPU VF), PCIe enabled
3. Connect monitor to passthrough output path.
4. Boot VM and complete installer until macOS desktop/login is stable.
5. Confirm at least one reboot cycle still reaches macOS desktop.

Do **not** enable autostart yet until this stage is stable.

#### B.6 Stage 4 — Enable macOS autostart daily mode (after gate passes)

```shellscript
qm set <macos-vmid> -onboot 1
qm set <macos-vmid> --startup "order=1,up=30,down=10"
qm start <macos-vmid>
```

Rollback (disable auto daily mode):

```shellscript
qm set <macos-vmid> -onboot 0
qm set <macos-vmid> --delete startup
```

#### B.7 Daily workflow (Option B)

1. Power on machine.
2. Proxmox boots; app VM and macOS VM boot based on onboot order.
3. Land directly on macOS via monitor.
4. Runtime control from host shell:

```shellscript
qm status <macos-vmid>
qm start <macos-vmid>
qm shutdown <macos-vmid>
```

1. Use Proxmox web console fallback on display issues.

Optional kiosk note (not required path):

* If you installed host GUI, you may create a kiosk launcher for VM console/viewer convenience.
* Keep this optional; direct monitor passthrough remains the primary Phase 12 behavior.

#### B.8 Platform Continuity Checklist (Post-Boot, Option B)

Common precheck:

```shellscript
qm status <macos-vmid>
qm status <apps-vmid>
```

**If using Direct Docker (Native):**

```shellscript
ssh <apps-user>@<apps-vm-ip> "docker ps"
ssh <apps-user>@<apps-vm-ip> "systemctl status cloudflared --no-pager || systemctl status rathole --no-pager"
```

**If using Zeabur:**

```shellscript
ssh <apps-user>@<apps-vm-ip> "systemctl status rathole --no-pager"
```

Then verify:

* `https://dash.zeabur.com/servers` is **Online**.

**If using Dokploy:**

```shellscript
ssh <apps-user>@<apps-vm-ip> "docker service ls"
ssh <apps-user>@<apps-vm-ip> "systemctl status cloudflared --no-pager || systemctl status rathole --no-pager"
```

**If using Coolify:**

```shellscript
ssh <apps-user>@<apps-vm-ip> "docker ps | grep -E 'coolify|traefik|postgres'"
ssh <apps-user>@<apps-vm-ip> "systemctl status cloudflared --no-pager || systemctl status rathole --no-pager"
```

#### B.9 Conky/watch status on Option B

* **Conky runs on Linux host GUI, not inside macOS guest.**
* Two practical monitor-visible paths for Option B:
  1. **Host GUI HUD path (full Conky):**
     * Install if missing:

```shellscript
apt update && apt install -y conky-all
```

```
 - Create config (`/home/<host-user>/.config/conky/conky.conf`):
```

```lua
conky.config = {
  update_interval = 2,
  own_window = true,
  own_window_type = 'dock',
  alignment = 'top_right',
  minimum_width = 360,
  minimum_height = 220,
  double_buffer = true,
  use_xft = true,
  font = 'DejaVu Sans Mono:size=10',
  default_color = 'white',
};

conky.text = [[
Host: ${nodename}
Uptime: ${uptime}
RAM: ${mem}/${memmax} (${memperc}%)
CPU: ${cpu}%
---
macOS VM: ${execi 3 qm status <macos-vmid> 2>/dev/null | awk '{print $2}'}
Apps VM: ${execi 3 qm status <apps-vmid> 2>/dev/null | awk '{print $2}'}
Load: ${loadavg}
Time: ${time %Y-%m-%d %H:%M:%S}
]];
```

```
 - Autostart in desktop session (`/home/<host-user>/.config/autostart/conky.desktop`):
```

```ini
[Desktop Entry]
Type=Application
Name=Conky
Exec=conky -c /home/<host-user>/.config/conky/conky.conf
X-GNOME-Autostart-enabled=true
```

1. **macOS daily mode path (SSH status screen):** keep macOS Terminal full-screen with host live status:

```shellscript
while true; do clear; ssh root@<proxmox-ip> "qm status <macos-vmid>; qm status <apps-vmid>; echo '---'; free -h | head -n 2; echo '---'; uptime"; sleep 3; done
```

Set this as a macOS Terminal login command if you want status to appear immediately after login.

* Minimal fallback (no host GUI session active): use terminal watch on Proxmox host:

```shellscript
watch -n 2 "qm status <macos-vmid>; echo '---'; free -h; echo '---'; uptime"
```

#### B.10 RustDesk access paths on Option B

1. Keep two remote paths:
   * **Primary control path:** Proxmox Web UI + SSH (`https://<proxmox-ip>:8006`, `ssh root@<proxmox-ip>`).
   * **Direct macOS path:** RustDesk inside macOS guest for daily remote desktop.
2. If macOS RustDesk ID is offline, wake VM first from Proxmox host:

```shellscript
qm status <macos-vmid>
qm start <macos-vmid>
```

1. Then connect from your laptop RustDesk client to the macOS guest ID.
2. Optional private relay path (if you already built VPS relay in Phase 3B): set RustDesk ID/Relay server in macOS RustDesk settings to your VPS relay values.
3. RustDesk install/permissions reference:
   * Host-side control path: reuse **Phase 6**.
   * macOS guest install + permissions (Accessibility/Screen Recording): reuse **Phase 11.10**.

#### B.11 Backup & Recovery (Option B)

Before major changes, take VM snapshots:

```shellscript
qm snapshot <macos-vmid> pre-change-$(date +%Y%m%d-%H%M)
qm snapshot <apps-vmid> pre-change-$(date +%Y%m%d-%H%M)
```

Quick rollback:

```shellscript
qm rollback <macos-vmid> <snapshot-name>
qm rollback <apps-vmid> <snapshot-name>
```

Periodic full backups (recommended to external/NAS-capable Proxmox backup storage):

```shellscript
vzdump <macos-vmid> --mode snapshot --compress zstd --storage <backup-storage>
vzdump <apps-vmid> --mode snapshot --compress zstd --storage <backup-storage>
```

Restore from full backup archive:

```shellscript
qmrestore <backup-archive-path> <macos-vmid>
qmrestore <backup-archive-path> <apps-vmid>
```

Apps VM data archive (Docker volumes + compose/project data):

```shellscript
ssh <apps-user>@<apps-vm-ip> "sudo tar -czf /tmp/apps-data-$(date +%Y%m%d-%H%M).tgz /var/lib/docker/volumes"
```

If your app data also lives in `/opt` or `/srv`, include those paths explicitly in the tar command.

Post-recovery validation:

```shellscript
qm status <macos-vmid>
qm status <apps-vmid>
```

## 📝 Phase 12 Notes & Caveats (Specific)

* **Option A Conky behavior:** Conky runs on Linux host GUI only; in direct macOS daily mode use the macOS Terminal SSH status loop.
* **Option B gate rule:** keep macOS VM autostart disabled until desktop/login is verified across reboot.
* **Tunnel/platform coupling:** Zeabur path requires VPS + Rathole; Cloudflare Tunnel path is for Direct Docker/Dokploy/Coolify.
* **RustDesk behavior:** macOS guest RustDesk is offline until the guest is running; keep host/Proxmox control path as fallback.
* **Recovery discipline:** snapshot both `macos-vm` and app VM before passthrough/OpenCore/platform changes.

## 📊 Phase 12 Quick Reference (Specific)

| Action                            | Option A (CachyOS Host)                                                                                                                    | Option B (Proxmox Host)                                                                  |                                                                                |                                                 |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | ----------------------------------------------- |
| **Enable daily direct-boot mode** | `sudo ln -sf /usr/lib/systemd/system/multi-user.target /etc/systemd/system/default.target && sudo virsh autostart macos-vm && sudo reboot` | `qm set <macos-vmid> -onboot 1 && qm set <macos-vmid> --startup "order=1,up=30,down=10"` |                                                                                |                                                 |
| **Disable daily mode**            | `sudo ln -sf /usr/lib/systemd/system/graphical.target /etc/systemd/system/default.target && sudo reboot`                                   | `qm set <macos-vmid> -onboot 0 && qm set <macos-vmid> --delete startup`                  |                                                                                |                                                 |
| **Check macOS VM state**          | `sudo virsh domstate macos-vm`                                                                                                             | `qm status <macos-vmid>`                                                                 |                                                                                |                                                 |
| **Manual macOS VM start**         | `sudo virsh start macos-vm`                                                                                                                | `qm start <macos-vmid>`                                                                  |                                                                                |                                                 |
| **Snapshot before changes**       | `sudo virsh snapshot-create-as macos-vm pre-change-$(date +%Y%m%d-%H%M)`                                                                   | `qm snapshot <macos-vmid> pre-change-$(date +%Y%m%d-%H%M)`                               |                                                                                |                                                 |
| **Fast status screen from macOS** | \`while true; do clear; ssh sandria@192.168.1.50 "virsh domstate macos-vm; echo '---'; free -h                                             | head -n 2; echo '---'; uptime"; sleep 3; done\`                                          | \`while true; do clear; ssh root@ "qm status ; qm status ; echo '---'; free -h | head -n 2; echo '---'; uptime"; sleep 3; done\` |
| **Remote recovery path**          | Host RustDesk session → start/recover VMs                                                                                                  | Proxmox UI (`https://<proxmox-ip>:8006`) or SSH (`root@<proxmox-ip>`)                    |                                                                                |                                                 |

## 🧯 Phase 12 Troubleshooting (Specific)

| Problem                                         | Solution                                                                                                                                                                 |                       |                                                            |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------- | ---------------------------------------------------------- |
| **"Boot did not land in macOS on Option A"**    | Verify `multi-user.target` is default and `macos-vm` autostart is enabled (\`virsh dominfo macos-vm                                                                      | grep -i Autostart\`). |                                                            |
| **"Boot did not land in macOS on Option B"**    | Verify VM onboot/startup (\`qm config                                                                                                                                    | grep -E 'onboot       | startup'\`) and ensure VM itself still boots from console. |
| **"macOS RustDesk ID is offline"**              | Start macOS VM first (`virsh start macos-vm` or `qm start <macos-vmid>`), then reconnect after guest session is up.                                                      |                       |                                                            |
| **"Zeabur server shows Offline after reboot"**  | Check Rathole on the app path (`systemctl status rathole-client` on Option A host, or `ssh <apps-user>@<apps-vm-ip> "systemctl status rathole --no-pager"` on Option B). |                       |                                                            |
| **"Direct Docker/Dokploy/Coolify unreachable"** | Verify app VM/container health (`docker ps` / `docker service ls`) and tunnel service (`cloudflared` or `rathole`) for your selected path.                               |                       |                                                            |
| **"No HUD/status on monitor"**                  | Option A/Option B host GUI path: confirm Conky is running; macOS path: run the SSH status loop in full-screen Terminal.                                                  |                       |                                                            |

***
