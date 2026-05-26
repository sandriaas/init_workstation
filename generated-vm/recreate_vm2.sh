#!/bin/bash
# Recreate vm_2 from cloud image (mirrors vm_1 pattern)
# Creates an empty 32GB disk from Ubuntu cloud image, attaches seed ISO, boots in ~30s.
#
# Prerequisites:
#   - cloud-image-utils (cloud-localds)
#   - guestfs-tools (virt-customize, optional)
#   - Ubuntu noble cloud image at /home/sandriaas/iso/noble-server-cloudimg-amd64.img
#   - virt-install
#   - libvirt running with default network active
#
# Usage: sudo bash recreate_vm2.sh

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
SEED_DIR="${SCRIPT_DIR}/vm_2-seed"
SEED_ISO="/var/lib/libvirt/images/vm_2-seed.iso"
DISK="/var/lib/libvirt/images/vm_2.qcow2"
CLOUD_IMG="${VM_CLOUD_IMG_PATH:-/home/sandriaas/iso/noble-server-cloudimg-amd64.img}"
DISK_GB="${VM_DISK_GB:-32}"
RAM_MB="${VM_RAM_MB:-6144}"
VCPUS="${VM_VCPUS:-4}"

if [ "$EUID" -ne 0 ]; then
    echo "Error: must run as root"
    exit 1
fi

# Find OVMF UEFI firmware
OVMF_CODE=$(ls /usr/share/edk2/x64/OVMF_CODE*.fd 2>/dev/null | head -1)
OVMF_VARS=$(ls /usr/share/edk2/x64/OVMF_VARS*.fd 2>/dev/null | head -1)
if [ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS" ]; then
    echo "Error: OVMF firmware not found. Install: pacman -S edk2-ovmf"
    exit 1
fi

echo "=== Stop and undefine existing vm_2 ==="
virsh destroy vm_2 2>/dev/null || true
sleep 1
virsh undefine vm_2 --nvram 2>/dev/null || virsh undefine vm_2 2>/dev/null || true

echo "=== Build seed ISO from $SEED_DIR ==="
cloud-localds --network-config="${SEED_DIR}/network-config" \
    "$SEED_ISO" \
    "${SEED_DIR}/user-data" \
    "${SEED_DIR}/meta-data"
chown libvirt-qemu:libvirt-qemu "$SEED_ISO"
ls -lah "$SEED_ISO"

echo "=== Create vm_2 disk from cloud image (${DISK_GB}GB) ==="
rm -f "$DISK"
qemu-img convert -O qcow2 "$CLOUD_IMG" "$DISK"
qemu-img resize "$DISK" "${DISK_GB}G"
chmod 644 "$DISK"
chown libvirt-qemu:libvirt-qemu "$DISK"
qemu-img info "$DISK" | head -5

echo "=== virt-install vm_2 ==="
virt-install \
    --name vm_2 \
    --memory "$RAM_MB" \
    --vcpus "$VCPUS" \
    --cpu host-passthrough \
    --machine q35 \
    --boot "loader=${OVMF_CODE},loader.readonly=yes,loader.type=pflash,nvram.template=${OVMF_VARS}" \
    --disk "path=${DISK},format=qcow2,bus=virtio" \
    --disk "path=${SEED_ISO},device=cdrom,bus=sata" \
    --os-variant ubuntu24.04 \
    --network "network=default,model=virtio" \
    --graphics vnc,listen=127.0.0.1 \
    --video virtio \
    --serial pty \
    --import \
    --noautoconsole

echo "=== Apply DHCP reservation (192.168.122.51) ==="
VM_MAC=$(virsh domiflist vm_2 | awk '/^ / && /network/ {print $NF}' | head -1)
echo "vm_2 MAC: $VM_MAC"
virsh net-update default add ip-dhcp-host \
    "<host mac='${VM_MAC}' ip='192.168.122.51'/>" \
    --live --config 2>/dev/null \
    && echo "✓ DHCP reservation: ${VM_MAC} → 192.168.122.51" \
    || echo "(reservation may already exist)"

echo ""
echo "=== Apply OOM protection ==="
for PID in $(pgrep -f 'qemu-system'); do
    echo -900 > /proc/$PID/oom_score_adj 2>/dev/null && echo "  PID $PID: oom_score_adj=-900"
done

echo ""
echo "=== Done. vm_2 should be reachable at 192.168.122.51 in ~30-60s ==="
echo ""
echo "Verify:"
echo "  ping 192.168.122.51"
echo "  ssh sandriaas@192.168.122.51   # password from cloud-init seed (vm_2.conf)"
echo "  virsh net-dhcp-leases default"
