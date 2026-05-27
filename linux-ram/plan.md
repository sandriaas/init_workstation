# Hybrid Memory Management Setup — Execution Plan

## Date: 2026-05-26
## System: CachyOS, 24GB RAM, Btrfs, 6GB libvirt VM

## Locked Decisions

| # | Decision | Choice |
|---|----------|--------|
| 1 | Swap size | **64GB** disk swap |
| 2 | zram size | **8GB** (RAM/3) |
| 3 | Overcommit | **Heuristic** (memory=0) |
| 4 | VM OOM protection | **Strict** (oom_score_adj=-900) |
| 5 | Cleanup | **54.3GB** across 5 items |
| 6 | VM duplication | **vm_1 → vm_2** via btrfs reflink |
| 7 | VM RAM | **Both 6GB** |
| 8 | vm_1 RAM apply method | **(A) Shutdown → resize → restart** |
| 9 | vm_2 identity | **(A) virt-clone defaults** |

---

## Execution Phases

### Phase 0: Pre-flight Checks
```bash
sudo virsh list --all
sudo virsh dominfo vm_1
sudo qemu-img info /var/lib/libvirt/images/vm_1.qcow2
free -h && swapon --show && df -h /
```

### Phase 1: Cleanup 54.3GB
```bash
rm -rf ~/.minipc-backup-stage-hExVxW    # 28GB
rm -rf ~/.cache/paru                     # 4.7GB
rm -rf ~/.cache/uv                       # 3.8GB
rm -rf ~/.cache/pip                      # 3.8GB
rm -rf ~/Downloads/ABDM                  # 14GB
df -h /
```

### Phase 2: VM Operations
```bash
sudo virsh shutdown vm_1 (wait up to 60s)
sudo cp --reflink=auto vm_1.qcow2 vm_2.qcow2
sudo virt-clone --original vm_1 --name vm_2 \
               --file /var/lib/libvirt/images/vm_2.qcow2 \
               --preserve-data
sudo virsh setmaxmem vm_1 6G --config
sudo virsh setmem vm_1 6G --config
sudo virsh setmaxmem vm_2 6G --config
sudo virsh setmem vm_2 6G --config
sudo virsh start vm_1
```

### Phase 3: Reconfigure zram (file only, activates on reboot)
```bash
sudo cp /etc/systemd/zram-generator.conf \
        /etc/systemd/zram-generator.conf.bak.$(date +%s)
sudo tee /etc/systemd/zram-generator.conf > /dev/null << 'EOF'
[zram0]
zram-size = ram / 3
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF
```

### Phase 4: Create 64GB Btrfs Swapfile (LIVE)
```bash
sudo btrfs filesystem mkswapfile -s 64g /swapfile
sudo swapon -p 10 /swapfile
echo "/swapfile none swap sw,pri=10 0 0" | sudo tee -a /etc/fstab
```

### Phase 5: Sysctl Tuning (LIVE)
```bash
sudo tee /etc/sysctl.d/99-hybrid-memory.conf > /dev/null << 'EOF'
# Hybrid memory: 8GB zram (pri=100) + 64GB disk (pri=10)
vm.swappiness = 60
vm.overcommit_memory = 0
vm.page-cluster = 0
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF
sudo sysctl -p /etc/sysctl.d/99-hybrid-memory.conf
```

### Phase 6: earlyoom Relaxation (LIVE)
```bash
sudo cp /etc/default/earlyoom /etc/default/earlyoom.bak.$(date +%s)
sudo tee /etc/default/earlyoom > /dev/null << 'EOF'
# earlyoom configuration
# Relaxed thresholds: kill only at <2% RAM or <5% total swap
EARLYOOM_ARGS="-m 2 -s 5 -r 3600 --avoid '(^|/)(init|systemd|Xorg|sddm|docker|containerd|podman|qemu-system|libvirtd)$' --prefer '(^|/)(electron|chrome|chromium|firefox|java|node)$'"
EOF
sudo systemctl restart earlyoom.service
```

### Phase 7: VM OOM Protection (LIVE)
```bash
sudo mkdir -p /etc/systemd/system/libvirtd.service.d
sudo tee /etc/systemd/system/libvirtd.service.d/oom-protect.conf > /dev/null << 'EOF'
[Service]
OOMScoreAdjust=-900
EOF
sudo systemctl daemon-reload
sudo systemctl restart libvirtd
```

### Phase 8: Live VM Process Protection (LIVE)
```bash
for PID in $(pgrep -f 'qemu-system'); do
    echo -900 | sudo tee /proc/$PID/oom_score_adj > /dev/null
done
```

### Phase 9: SKIPPED (no reboot)

### Phase 10: Verification
```bash
free -h && swapon --show && zramctl
sysctl vm.swappiness vm.overcommit_memory vm.page-cluster
sudo virsh list --all
sudo virsh dominfo vm_1 | grep -i memory
sudo virsh dominfo vm_2 | grep -i memory
for PID in $(pgrep -f 'qemu-system'); do
    echo "PID $PID: oom_score_adj=$(cat /proc/$PID/oom_score_adj)"
done
systemctl status earlyoom.service --no-pager | head -10
df -h /
```

---

## Rollback Procedure

```bash
# Restore zram config
sudo cp /etc/systemd/zram-generator.conf.bak.<timestamp> \
        /etc/systemd/zram-generator.conf
# Disable disk swap
sudo swapoff /swapfile
sudo sed -i '/\/swapfile/d' /etc/fstab
sudo rm /swapfile
# Restore earlyoom
sudo cp /etc/default/earlyoom.bak.<timestamp> /etc/default/earlyoom
# Remove sysctl overrides
sudo rm /etc/sysctl.d/99-hybrid-memory.conf
# Remove VM OOM protection
sudo rm /etc/systemd/system/libvirtd.service.d/oom-protect.conf
sudo systemctl daemon-reload
sudo reboot
# VM rollback
virsh undefine vm_2
rm /var/lib/libvirt/images/vm_2.qcow2
```

## Expected Final State

```
Disk:    353GB total, ~299GB used, ~54GB free (85%)
RAM:     24GB physical
zram:    92GB active (will resize to 8GB on next reboot)
swap:    64GB disk active at priority 10
Sysctl:  swappiness=60, overcommit=0
earlyoom: 2%/5% thresholds with qemu/libvirtd avoidance
libvirtd: oom_score_adj=-900
VMs:     vm_1 (6GB), vm_2 (6GB, cloned)
```
