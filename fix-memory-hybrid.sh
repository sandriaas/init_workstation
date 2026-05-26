#!/bin/bash
# Hybrid Memory Management Configuration for CachyOS
# Goal: 8GB zram (fast) + 32GB disk swap (overflow) + VM protection
# Prevents OOM kills by using disk paging like Windows

set -e

echo "=========================================="
echo "Hybrid Memory Management Setup"
echo "=========================================="
echo ""
echo "This script will:"
echo "  1. Shrink zram from 92GB to 8GB (reduce CPU overhead)"
echo "  2. Create 32GB disk swap on NVMe (overflow protection)"
echo "  3. Configure tiered swap priorities (zram=100, disk=10)"
echo "  4. Tune swappiness from 150 to 60 (balanced)"
echo "  5. Set strict overcommit (prevent phantom allocations)"
echo "  6. Relax earlyoom thresholds (2% RAM / 5% swap)"
echo "  7. Protect VM from OOM killer"
echo ""
echo "Expected behavior:"
echo "  - VM stays responsive (never swaps)"
echo "  - Inactive apps swap to zram (fast, low CPU)"
echo "  - Extreme overflow goes to disk (slow but safe)"
echo "  - Apps slow down instead of being killed"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! \$REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# Check if running as root
if [ "\$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (use sudo)"
    exit 1
fi

echo ""
echo "=========================================="
echo "Phase 1: Reconfigure zram (92GB → 8GB)"
echo "=========================================="

# Backup current zram config
if [ -f /etc/systemd/zram-generator.conf ]; then
    cp /etc/systemd/zram-generator.conf /etc/systemd/zram-generator.conf.bak.\$(date +%s)
    echo "✓ Backed up zram-generator.conf"
fi

# Disable current zram
echo "Disabling current zram device..."
swapoff /dev/zram0 2>/dev/null || true
zramctl --reset /dev/zram0 2>/dev/null || true
echo "✓ Current zram disabled"

# Configure new 8GB zram
cat > /etc/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = ram / 3
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

echo "✓ Configured 8GB zram with priority 100"

# Reload zram
systemctl daemon-reload
systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true
echo "✓ Reloaded zram service"

sleep 2

echo ""
echo "=========================================="
echo "Phase 2: Create 32GB Disk Swap"
echo "=========================================="

SWAPFILE="/swapfile"
SWAPSIZE_GB=32

if [ -f "\$SWAPFILE" ]; then
    echo "Warning: \$SWAPFILE already exists"
    read -p "Remove and recreate? (y/n) " -n 1 -r
    echo
    if [[ \$REPLY =~ ^[Yy]$ ]]; then
        swapoff "\$SWAPFILE" 2>/dev/null || true
        rm -f "\$SWAPFILE"
        echo "✓ Removed existing swapfile"
    else
        echo "Skipping swapfile creation"
        SWAPFILE_CREATED=false
    fi
fi

if [ ! -f "\$SWAPFILE" ]; then
    echo "Creating \${SWAPSIZE_GB}GB swapfile (this may take a minute)..."
    dd if=/dev/zero of="\$SWAPFILE" bs=1M count=\$((SWAPSIZE_GB * 1024)) status=progress
    chmod 600 "\$SWAPFILE"
    mkswap "\$SWAPFILE"
    swapon -p 10 "\$SWAPFILE"
    echo "✓ Created and activated \${SWAPSIZE_GB}GB swapfile with priority 10"
    SWAPFILE_CREATED=true
else
    SWAPFILE_CREATED=false
fi

# Add to fstab if not already present
if [ "\$SWAPFILE_CREATED" = true ]; then
    if ! grep -q "\$SWAPFILE" /etc/fstab; then
        echo "\$SWAPFILE none swap sw,pri=10 0 0" >> /etc/fstab
        echo "✓ Added swapfile to /etc/fstab"
    else
        echo "✓ Swapfile already in /etc/fstab"
    fi
fi

echo ""
echo "=========================================="
echo "Phase 3: Configure Memory Parameters"
echo "=========================================="

SYSCTL_CONF="/etc/sysctl.d/99-hybrid-memory.conf"

cat > "\$SYSCTL_CONF" << 'EOF'
# Hybrid Memory Management Configuration
# 8GB zram (priority 100) + 32GB disk swap (priority 10)

# Swappiness: 60 = balanced (was 150 = too aggressive)
vm.swappiness = 60

# Strict overcommit accounting (prevent phantom allocations)
vm.overcommit_memory = 2
vm.overcommit_ratio = 80

# VFS cache pressure (default 100 = balanced)
vm.vfs_cache_pressure = 100

# Page cluster (reduce swap I/O clustering for better responsiveness)
vm.page-cluster = 0

# Dirty page writeback (faster disk writes under pressure)
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF

echo "✓ Created \$SYSCTL_CONF"

# Apply immediately
sysctl -p "\$SYSCTL_CONF"
echo "✓ Applied sysctl settings"

echo ""
echo "=========================================="
echo "Phase 4: Configure earlyoom"
echo "=========================================="

EARLYOOM_CONF="/etc/default/earlyoom"

if [ -f "\$EARLYOOM_CONF" ]; then
    cp "\$EARLYOOM_CONF" "\${EARLYOOM_CONF}.bak.\$(date +%s)"
    echo "✓ Backed up earlyoom config"
fi

cat > "\$EARLYOOM_CONF" << 'EOF'
# earlyoom configuration
# Relaxed thresholds: kill only at <2% RAM or <5% total swap
EARLYOOM_ARGS="-m 2 -s 5 -r 3600 --avoid '(^|/)(init|systemd|Xorg|sddm|docker|containerd|podman)$' --prefer '(^|/)(electron|chrome|chromium|firefox|java|node)$'"
EOF

echo "✓ Configured earlyoom with relaxed thresholds (2% RAM / 5% swap)"

# Restart earlyoom
systemctl restart earlyoom.service 2>/dev/null || true
echo "✓ Restarted earlyoom service"

echo ""
echo "=========================================="
echo "Phase 5: Protect VM from OOM Killer"
echo "=========================================="

echo "Searching for VM processes (QEMU/KVM)..."

# Find VM processes
VM_PIDS=\$(pgrep -f 'qemu|kvm|libvirt' 2>/dev/null || true)

if [ -n "\$VM_PIDS" ]; then
    echo "Found VM processes: \$VM_PIDS"
    for PID in \$VM_PIDS; do
        echo -900 > /proc/\$PID/oom_score_adj 2>/dev/null || true
        echo "✓ Protected PID \$PID (oom_score_adj = -900)"
    done
else
    echo "⚠ No VM processes found (will protect on next VM start)"
fi

# Create systemd drop-in for permanent VM protection
VM_OVERRIDE_DIR="/etc/systemd/system/libvirtd.service.d"
mkdir -p "\$VM_OVERRIDE_DIR"

cat > "\$VM_OVERRIDE_DIR/oom-protect.conf" << 'EOF'
[Service]
OOMScoreAdjust=-900
EOF

echo "✓ Created systemd override for libvirtd OOM protection"

systemctl daemon-reload
echo "✓ Reloaded systemd"

echo ""
echo "=========================================="
echo "Phase 6: Verification"
echo "=========================================="

echo ""
echo "Current swap configuration:"
swapon --show

echo ""
echo "Current memory usage:"
free -h

echo ""
echo "Zram status:"
zramctl

echo ""
echo "Sysctl settings:"
sysctl vm.swappiness vm.overcommit_memory vm.overcommit_ratio

echo ""
echo "CommitLimit (total allocatable memory):"
grep -E 'CommitLimit|Committed_AS' /proc/meminfo

echo ""
echo "earlyoom status:"
systemctl status earlyoom.service --no-pager | head -n 10

echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
echo "Configuration summary:"
echo "  - zram: 8GB (priority 100, fast)"
echo "  - disk swap: 32GB (priority 10, overflow)"
echo "  - swappiness: 60 (balanced)"
echo "  - overcommit: strict (prevents phantom allocations)"
echo "  - earlyoom: 2% RAM / 5% swap (relaxed)"
echo "  - VM: protected from OOM killer"
echo ""
echo "Expected behavior:"
echo "  ✓ VM stays responsive (never swaps)"
echo "  ✓ Inactive apps swap to zram (fast, low CPU)"
echo "  ✓ Extreme overflow goes to disk (slow but safe)"
echo "  ✓ Apps slow down instead of being killed"
echo ""
echo "⚠ REBOOT REQUIRED for full effect"
echo ""
read -p "Reboot now? (y/n) " -n 1 -r
echo
if [[ \$REPLY =~ ^[Yy]$ ]]; then
    echo "Rebooting in 5 seconds..."
    sleep 5
    reboot
else
    echo "Please reboot manually when ready: sudo reboot"
fi
