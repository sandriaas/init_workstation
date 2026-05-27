#!/bin/bash
# Apply linux-ram memory configs to a VM (~6GB RAM, Ubuntu 24.04+)
# Creates 8GB disk swap + sysctl tuning (no zram, no earlyoom — host handles these)
#
# Usage: ssh into VM and run as root, or pipe via ssh:
#   ssh user@vm 'sudo bash -s' < linux-ram-vm/apply.sh
# Or copy to VM and run:
#   scp linux-ram-vm/apply.sh user@vm:/tmp/ && ssh user@vm 'sudo bash /tmp/apply.sh'

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Error: must run as root"
    exit 1
fi

echo "=== Create 8GB swapfile ==="
if [ -f /swapfile ]; then
    echo "/swapfile already exists, skipping creation"
else
    fallocate -l 8G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon -p 10 /swapfile
fi

grep -q /swapfile /etc/fstab || echo "/swapfile none swap sw,pri=10 0 0" >> /etc/fstab
echo "✓ swapfile 8GB active"

echo ""
echo "=== Sysctl tuning ==="
cat > /etc/sysctl.d/99-linux-ram.conf << 'EOF'
vm.swappiness = 60
vm.overcommit_memory = 0
vm.page-cluster = 0
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF
sysctl -p /etc/sysctl.d/99-linux-ram.conf
echo "✓ sysctl applied"

echo ""
echo "=== Verify ==="
swapon --show
free -h
sysctl vm.swappiness vm.overcommit_memory vm.page-cluster vm.dirty_ratio vm.dirty_background_ratio
