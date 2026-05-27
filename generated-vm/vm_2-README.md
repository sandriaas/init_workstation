# vm_2 — Quick Reference

A second Ubuntu 24.04 LTS VM, mirroring `vm_1`'s cloud-image pattern.

## Identity

| Field | Value |
|-------|-------|
| Hostname | `vm-2` |
| User | `sandriaas` |
| Password | `<see local notes>` (SHA-512 hash in `vm_2.conf`) |
| OS | Ubuntu 24.04.4 LTS (Noble) |
| RAM | 6 GB |
| vCPUs | 4 |
| Disk | 32 GB qcow2 (cloud image) |
| MAC | `52:54:00:c8:2e:a7` |
| IP | `192.168.122.51` (DHCP-reserved) |
| Graphics | VNC on `127.0.0.1` (Cockpit-accessible) |
| Firmware | UEFI (OVMF) |

## Quick Commands

```bash
# SSH
ssh sandriaas@192.168.122.51    # password set by cloud-init seed (see VM_PASSWORD_HASH in vm_2.conf)

# State
sudo virsh domstate vm_2
sudo virsh net-dhcp-leases default | grep vm-2

# Lifecycle
sudo virsh start vm_2
sudo virsh shutdown vm_2
sudo virsh destroy vm_2

# View console (Cockpit)
firefox https://localhost:9090   # Virtual Machines → vm_2 → Console
```

## Files in This Directory

- `vm_2.conf` — VM definition variables (mirrors `vm_1.conf` shape)
- `vm_2-seed/user-data` — cloud-init user config (hostname, user, SSH)
- `vm_2-seed/meta-data` — cloud-init instance metadata
- `vm_2-seed/network-config` — DHCP network config
- `recreate_vm2.sh` — Recreate vm_2 from scratch (use if you need to reset)
- `ufw-virbr0-allow.sh` — Critical UFW rules for libvirt DHCP
- `vm_2-LESSONS.md` — Full debugging history and recipes

## Recreating vm_2 from Scratch

```bash
# 1. Ensure prerequisites are installed
sudo pacman -S cloud-image-utils guestfs-tools

# 2. Ensure UFW allows DHCP/DNS on virbr0 (only needed once per host)
sudo bash ufw-virbr0-allow.sh

# 3. Run the recreation script
sudo bash recreate_vm2.sh

# 4. Wait ~30-60s for first-boot cloud-init, then:
ssh sandriaas@192.168.122.51
```

## Differences from vm_1

| Aspect | vm_1 | vm_2 |
|--------|------|------|
| Hostname | `ubuntu-server` | `vm-2` |
| RAM | 4 GB | 6 GB |
| Network | Static `192.168.122.50` | DHCP reserved `192.168.122.51` |
| Graphics | None (headless) | VNC (Cockpit-accessible) |
| Autostart | yes | no |

## Memory Management

Host-style swap + sysctl tuning from `linux-ram-vm/` applied:
- 8 GB disk swap (/swapfile, pri=10)
- swappiness=60, overcommit=0, page-cluster=0

```bash
# Re-apply if VM is recreated
sudo bash linux-ram-vm/apply.sh
```

Both VMs share the same disk lineage (Ubuntu cloud image, 32 GB qcow2).
