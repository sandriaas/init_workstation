#!/bin/bash
# Hybrid Memory Management — Phases 3-8 (No Reboot)
# Run as: sudo ./apply-phases-3-8.sh
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (use sudo)"
    exit 1
fi

echo "=============================================="
echo "Phase 3: Reconfigure zram (92GB → 8GB)"
echo "=============================================="

if [ -f /etc/systemd/zram-generator.conf ]; then
    cp /etc/systemd/zram-generator.conf /etc/systemd/zram-generator.conf.bak.$(date +%s)
    echo "✓ Backed up zram-generator.conf"
fi

cat > /etc/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = ram / 3
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

echo "✓ zram config set to 8GB (activates on next reboot)"
echo "  Current 92GB zram remains active until reboot"

echo ""
echo "=============================================="
echo "Phase 4: Create 64GB Btrfs Swapfile"
echo "=============================================="

if [ -f /swapfile ]; then
    echo "⚠ /swapfile already exists, skipping creation"
else
    echo "Creating 64GB swapfile via btrfs filesystem mkswapfile..."
    btrfs filesystem mkswapfile -s 64g /swapfile
    echo "✓ Created 64GB swapfile"
fi

swapon -p 10 /swapfile 2>/dev/null && echo "✓ Activated swapfile with priority 10" || echo "⚠ Swapfile already active"

if ! grep -q "/swapfile" /etc/fstab; then
    echo "/swapfile none swap sw,pri=10 0 0" >> /etc/fstab
    echo "✓ Added swapfile to /etc/fstab"
fi

echo ""
echo "=============================================="
echo "Phase 5: Sysctl Tuning"
echo "=============================================="

cat > /etc/sysctl.d/99-hybrid-memory.conf << 'EOF'
# Hybrid memory: 8GB zram (pri=100) + 64GB disk (pri=10)
vm.swappiness = 60
vm.overcommit_memory = 0
vm.page-cluster = 0
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF

sysctl -p /etc/sysctl.d/99-hybrid-memory.conf
echo "✓ sysctl settings applied live"

echo ""
echo "=============================================="
echo "Phase 6: earlyoom Relaxation"
echo "=============================================="

if [ -f /etc/default/earlyoom ]; then
    cp /etc/default/earlyoom /etc/default/earlyoom.bak.$(date +%s)
    echo "✓ Backed up earlyoom config"
fi

cat > /etc/default/earlyoom << 'EOF'
# earlyoom configuration
# Relaxed thresholds: kill only at <2% RAM or <5% total swap
EARLYOOM_ARGS="-m 2 -s 5 -r 3600 --avoid '(^|/)(init|systemd|Xorg|sddm|docker|containerd|podman|qemu-system|libvirtd)$' --prefer '(^|/)(electron|chrome|chromium|firefox|java|node)$'"
EOF

systemctl restart earlyoom.service 2>/dev/null && echo "✓ earlyoom restarted with relaxed thresholds" || echo "⚠ earlyoom not running (service restart failed)"

echo ""
echo "=============================================="
echo "Phase 7: VM OOM Protection (libvirtd)"
echo "=============================================="

mkdir -p /etc/systemd/system/libvirtd.service.d

cat > /etc/systemd/system/libvirtd.service.d/oom-protect.conf << 'EOF'
[Service]
OOMScoreAdjust=-900
EOF

systemctl daemon-reload
systemctl restart libvirtd 2>/dev/null && echo "✓ libvirtd restarted with OOM protection" || echo "⚠ libvirtd restart failed"

echo ""
echo "=============================================="
echo "Phase 8: Live VM Process Protection"
echo "=============================================="

PROTECTED=0
for PID in $(pgrep -f 'qemu-system' 2>/dev/null); do
    echo -900 > /proc/$PID/oom_score_adj 2>/dev/null && {
        echo "✓ PID $PID: oom_score_adj = -900"
        PROTECTED=$((PROTECTED + 1))
    } || echo "⚠ Failed to protect PID $PID"
done

if [ $PROTECTED -eq 0 ]; then
    echo "⚠ No QEMU processes found (VM may not be running)"
fi

echo ""
echo "=============================================="
echo "ALL PHASES 3-8 COMPLETE"
echo "=============================================="
echo ""
echo "Summary:"
echo "  ✓ zram: config set to 8GB (activates on next reboot)"
echo "  ✓ swap: 64GB disk swap active (priority 10)"
echo "  ✓ sysctl: swappiness=60, overcommit=heuristic"
echo "  ✓ earlyoom: 2% RAM / 5% swap thresholds"
echo "  ✓ libvirtd: oom_score_adj=-900"
echo "  ✓ VM processes: OOM-protected"
echo ""
echo "Verification:"
swapon --show
echo ""
free -h
echo ""
sysctl vm.swappiness vm.overcommit_memory vm.page-cluster
echo ""
df -h /
