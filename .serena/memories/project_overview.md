# minipc — Project Overview

## Purpose
Automated workstation/server setup for a CachyOS-based mini PC (Intel Alder Lake i9-12900HK).
Sets up KVM/QEMU virtual machines with Intel iGPU SR-IOV passthrough and Cloudflare SSH tunnels.

## Tech Stack
- **Language:** Bash scripts (all `.sh` files)
- **Host OS:** CachyOS (Arch-based)
- **VM OS:** Ubuntu 24.04 LTS (default)
- **Virtualization:** KVM/QEMU/libvirt
- **GPU:** Intel iGPU SR-IOV via `i915-sriov-dkms`
- **Networking:** Cloudflare Tunnel (`cloudflared`)

## Structure
```
scripts/
  phase1.sh          # Host setup (packages, IOMMU, SSH, Cloudflare tunnel)
  phase2.sh          # VM provisioning (virt-install, GPU passthrough, XML patching)
  phase3.sh          # VM internal setup (SSH, cloudflared, static IP, i915)
  phase1-client.sh   # Client SSH config for host tunnel
  phase3-client.sh   # Client SSH config for VM tunnel
  phase1-client.ps1  # Windows client for host
  phase3-client.ps1  # Windows client for VM
  phase2-client.sh   # Client utilities
  check.sh           # Verification script
configs/
  vm.conf            # Active VM configuration
  vm.conf.example    # Template
  windows-vm.conf    # Windows VM template
  macos-vm.conf      # macOS VM template
  cloudflared-config.yml  # Tunnel ingress config
  cloudflared.service     # systemd unit
  ssh-config              # SSH client config
  limine-default          # Bootloader config
generated-vm/       # Generated VM files (XML, disks)
```

## Key Commands
- `sudo bash scripts/phase1.sh` — Host setup
- `sudo bash scripts/phase2.sh` — VM provisioning
- `sudo bash scripts/phase3.sh` — VM internal setup
- `bash scripts/check.sh` — Verify setup

## Code Style
- Bash scripts with functions, color-coded output (BOLD, GREEN, RED, YELLOW, BLUE)
- Helper functions: `ok()`, `warn()`, `info()`, `step()`, `section()`
- Scripts use `set -euo pipefail` or similar error handling
- Comments use `# ──` section headers
- No formal linting/testing framework; scripts are run directly
