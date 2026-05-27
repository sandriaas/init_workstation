# linux-ram-vm — Memory Management for Ubuntu VMs (6GB)

Scaled-down version of `linux-ram/` configs for use inside VMs.
No zram, no earlyoom — those are handled by the host.

## Files

| File | Target | Purpose |
|------|--------|---------|
| `99-linux-ram.conf` | `/etc/sysctl.d/` | swappiness=60, heuristic overcommit, page-cluster=0 |
| `fstab-swap-line` | `/etc/fstab` (append) | Persist /swapfile at priority 10 |
| `apply.sh` | Run inside VM as root | Creates 8GB swapfile + applies sysctl |
| `remote-apply.sh` | Run from host | SSH + scp apply.sh to vm_2 then execute |

## Quick Apply

```bash
# From host (auto-pushes to vm_2 via SSH):
VM_PASS='737576A$tound' bash linux-ram-vm/remote-apply.sh

# Or inside the VM directly:
sudo bash linux-ram-vm/apply.sh
```

## Config Summary

```
                         BEFORE         AFTER
                         ──────         ─────
Swap:                    none           8GB disk (pri=10)
swappiness:              60             60 (unchanged)
overcommit_memory:       1 (always)     0 (heuristic)
page-cluster:            default        0
dirty_ratio:             default        10
dirty_background_ratio:  default        5
```

## Why No zram / earlyoom?

- **zram**: Pointless inside a VM — the RAM is already virtualized. Host's
  zram already compresses cold VM pages. Adding zram inside the VM adds
  compression-on-compression overhead with no benefit.
- **earlyoom**: Host's earlyoom already protects QEMU/libvirtd via
  `--avoid '(^|/)(qemu-system|libvirtd)$'`. No need for OOM killer inside the VM.
- **OOMScoreAdjust**: Host's libvirtd drop-in already sets -900 for all
  QEMU PIDs.

## Diff from Host `linux-ram/`

| Aspect | Host (linux-ram) | VM (linux-ram-vm) |
|--------|-----------------|-------------------|
| RAM | 24 GB | 6 GB |
| zram | 8 GB (ram/3) | none |
| Disk swap | 64 GB btrfs | 8 GB ext4 fallocate |
| earlyoom | 2%/5% with VM protect | none |
| oom_score_adj | -900 for libvirtd | none (host handles) |
| Sysctl | identical | identical |
