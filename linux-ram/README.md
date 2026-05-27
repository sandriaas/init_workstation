# linux-ram — Hybrid Memory Management for CachyOS (24GB + VMs)

Config files and scripts to prevent OOM kills by using tiered swap
(8GB zram + 64GB disk). Apps slow down instead of being killed.

## Files

| File | Type | Purpose |
|------|------|---------|
| `zram-generator.conf` | config → `/etc/systemd/zram-generator.conf` | Shrink zram from RAM*4 to RAM/3 (8GB on 24GB system) |
| `99-hybrid-memory.conf` | config → `/etc/sysctl.d/` | swappiness=60, heuristic overcommit, page-cluster=0 |
| `earlyoom` | config → `/etc/default/earlyoom` | Kill at <2% RAM or <5% swap, protect qemu/libvirt |
| `oom-protect.conf` | drop-in → `/etc/systemd/system/libvirtd.service.d/` | OOMScoreAdjust=-900 for libvirtd |
| `apply-phases-3-8.sh` | script | Applies all configs + creates 64GB btrfs swapfile |
| `fix-memory-hybrid.sh` | script | Older full script (interactive, includes reboot prompt) |
| `fix-memory-management.sh` | script | Original diagnostic+fix script |

## Quick Apply

```bash
# Install configs and create 64GB swapfile (needs sudo, no reboot)
sudo bash linux-ram/apply-phases-3-8.sh

# Reboot later to activate zram resize 92GB→8GB
sudo reboot
```

## What Each Config Does

```
BEFORE                          AFTER
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
zram:  92GB (ram*4)             zram:  8GB (ram/3)
swap:  none (disk)              swap:  64GB disk (pri=10)
swappiness: 150                 swappiness: 60
overcommit: heuristic (0)       overcommit: same
page-cluster: default            page-cluster: 0 (less I/O burst)
earlyoom: 4% RAM / 10% swap     earlyoom: 2% RAM / 5% swap
VM protected: no                VM protected: oom_score_adj=-900
```

## Behavior

- **VM (6GB)**: locked in RAM, never killed or swapped
- **Active apps**: stay in RAM (swappiness=60, less aggressive than 150)
- **Inactive pages**: swap to 8GB zram (fast compression, low CPU)
- **Cold pages**: overflow to 64GB disk swap (slow but safe)
- **Total virtual memory**: 24GB RAM + 8GB zram + 64GB disk = 96GB

## Verification

```bash
swapon --show                    # zram pri=100 + /swapfile pri=10
free -h                          # RAM+swap totals
sysctl vm.swappiness             # should be 60
sysctl vm.overcommit_memory      # should be 0 (heuristic)
cat /proc/$(pgrep qemu)/oom_score_adj  # should be -900
df -h /                          # check disk space
```

## Rollback

```bash
# Restore original zram config
sudo cp /etc/systemd/zram-generator.conf.bak.* /etc/systemd/zram-generator.conf
# Disable disk swap
sudo swapoff /swapfile && sudo sed -i '/\/swapfile/d' /etc/fstab && sudo rm /swapfile
# Remove sysctl drop-in
sudo rm /etc/sysctl.d/99-hybrid-memory.conf
# Restore earlyoom
sudo cp /etc/default/earlyoom.bak.* /etc/default/earlyoom
sudo systemctl restart earlyoom
# Remove OOM protection
sudo rm /etc/systemd/system/libvirtd.service.d/oom-protect.conf
sudo systemctl daemon-reload
```
