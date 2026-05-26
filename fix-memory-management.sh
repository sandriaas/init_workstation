#!/bin/bash
set -euo pipefail

echo "=== Windows-like Memory Management Configuration ==="
echo "This script will:"
echo "  1. Disable zram (92GB compressed swap)"
echo "  2. Create 16GB disk-backed swap file"
echo "  3. Configure strict memory overcommit"
echo "  4. Relax earlyoom thresholds to 2%/5%"
echo ""
read -p "Press Enter to continue or Ctrl+C to abort..."

# Phase 1: Disable zram
echo ""
echo "=== Phase 1: Disabling zram ==="
sudo swapoff /dev/zram0 || true
sudo systemctl stop systemd-zram-setup@zram0.service || true
sudo systemctl mask systemd-zram-setup@zram0.service

# Disable zram-generator config
if [ -f /etc/systemd/zram-generator.conf ]; then
    echo "Backing up /etc/systemd/zram-generator.conf to /etc/systemd/zram-generator.conf.bak"
    sudo cp /etc/systemd/zram-generator.conf /etc/systemd/zram-generator.conf.bak
    echo "Disabling zram in /etc/systemd/zram-generator.conf"
    sudo tee /etc/systemd/zram-generator.conf > /dev/null <<'EOF'
# zram disabled - using disk-backed swap instead
# Original config backed up to zram-generator.conf.bak
EOF
fi

echo "✓ zram disabled"

# Phase 2: Create disk-backed swap
echo ""
echo "=== Phase 2: Creating 16GB disk swap ==="

if [ -f /swapfile ]; then
    echo "⚠ /swapfile already exists. Checking if it's active..."
    if swapon --show | grep -q /swapfile; then
        echo "✓ /swapfile already active, skipping creation"
    else
        echo "Activating existing /swapfile..."
        sudo swapon /swapfile
        echo "✓ /swapfile activated"
    fi
else
    echo "Creating 16GB swap file at /swapfile..."
    sudo fallocate -l 16G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo "✓ 16GB swap file created and activated"
fi

# Add to fstab if not already present
if ! grep -q "^/swapfile" /etc/fstab; then
    echo "Adding /swapfile to /etc/fstab..."
    echo "/swapfile none swap defaults 0 0" | sudo tee -a /etc/fstab
    echo "✓ /swapfile added to /etc/fstab"
else
    echo "✓ /swapfile already in /etc/fstab"
fi

# Phase 3: Configure strict memory overcommit
echo ""
echo "=== Phase 3: Configuring strict memory overcommit ==="

sudo tee /etc/sysctl.d/99-windows-like-memory.conf > /dev/null <<'EOF'
# Windows-like memory management configuration
# Created: $(date)

# Strict overcommit accounting - prevent phantom allocations
# CommitLimit = (RAM * overcommit_ratio / 100) + swap
vm.overcommit_memory = 2
vm.overcommit_ratio = 80

# Balanced swappiness for disk-backed swap
vm.swappiness = 60

# OOM killer tuning - prefer killing high-memory processes
vm.oom_kill_allocating_task = 0
vm.panic_on_oom = 0
EOF

echo "✓ Created /etc/sysctl.d/99-windows-like-memory.conf"

# Apply sysctl settings
sudo sysctl --system
echo "✓ Applied sysctl settings"

# Phase 4: Relax earlyoom thresholds
echo ""
echo "=== Phase 4: Relaxing earlyoom thresholds ==="

if [ -f /etc/default/earlyoom ]; then
    echo "Backing up /etc/default/earlyoom to /etc/default/earlyoom.bak"
    sudo cp /etc/default/earlyoom /etc/default/earlyoom.bak
    
    # Update thresholds from -m 4 -s 10 to -m 2 -s 5
    sudo sed -i 's/-m [0-9]\+/-m 2/g' /etc/default/earlyoom
    sudo sed -i 's/-s [0-9]\+/-s 5/g' /etc/default/earlyoom
    
    echo "✓ Updated earlyoom thresholds to -m 2 -s 5"
    echo "  (kills only when <2% RAM or <5% swap remaining)"
    
    # Restart earlyoom to apply changes
    sudo systemctl restart earlyoom
    echo "✓ Restarted earlyoom service"
else
    echo "⚠ /etc/default/earlyoom not found, skipping"
fi

# Phase 5: Verification
echo ""
echo "=== Phase 5: Current Configuration ==="
echo ""
echo "Active swap devices:"
swapon --show
echo ""
echo "Memory overcommit settings:"
echo "  vm.overcommit_memory = $(cat /proc/sys/vm/overcommit_memory)"
echo "  vm.overcommit_ratio = $(cat /proc/sys/vm/overcommit_ratio)"
echo "  vm.swappiness = $(cat /proc/sys/vm/swappiness)"
echo ""
echo "CommitLimit calculation:"
grep -E "CommitLimit|Committed_AS" /proc/meminfo
echo ""
echo "earlyoom status:"
systemctl status earlyoom --no-pager | head -n 10 || echo "earlyoom not running"

echo ""
echo "=== Configuration Complete ==="
echo ""
echo "⚠ IMPORTANT: You must REBOOT for all changes to take full effect"
echo "  (especially zram removal and overcommit settings)"
echo ""
echo "After reboot, verify with:"
echo "  swapon --show  # Should show only /swapfile, no zram0"
echo "  cat /proc/sys/vm/overcommit_memory  # Should be 2"
echo "  free -h  # Check swap usage"
echo ""
read -p "Reboot now? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Rebooting in 5 seconds... (Ctrl+C to cancel)"
    sleep 5
    sudo reboot
else
    echo "Reboot cancelled. Remember to reboot manually later!"
fi
