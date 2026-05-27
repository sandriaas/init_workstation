#!/bin/bash
# Remote-apply linux-ram configs to vm_2 via SSH
# Usage: bash linux-ram-vm/remote-apply.sh
set -e
VM_IP="${VM_IP:-192.168.122.51}"
VM_USER="${VM_USER:-sandriaas}"
VM_PASS="${VM_PASS:-<YOUR_VM_PASSWORD>}"

echo "Copying apply.sh to vm_2..."
sshpass -p "$VM_PASS" scp -o StrictHostKeyChecking=no "$(dirname "$0")/apply.sh" "${VM_USER}@${VM_IP}:/tmp/apply.sh"

echo "Running on vm_2..."
sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no "${VM_USER}@${VM_IP}" "echo '${VM_PASS}' | sudo -S bash /tmp/apply.sh"
