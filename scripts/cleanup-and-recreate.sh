#!/bin/bash
# =============================================================================
# cleanup-and-recreate.sh — Remove vm_1 + Recreate vm_2 + Update CF tunnel
# =============================================================================
# Usage: sudo bash scripts/cleanup-and-recreate.sh
#
# What it does:
#   Phase 1: Destroy vm_1 and remove its disk + seed ISO
#   Phase 2: Recreate vm_2 from Ubuntu cloud image (cloud-init seed pattern)
#   Phase 3: Update Cloudflare tunnel config for vm_2-minipc-local
#   Phase 4: Verify everything works
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'
info()  { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()   { echo -e "${RED}[ERR]${RESET}  $*" >&2; }
step()  { echo -e "\n${BOLD}  ── $* ──${RESET}"; }

trap '_ec=$?; [ $_ec -ne 0 ] && err "Failed at line ${LINENO} (exit ${_ec})"' ERR

if [ "$EUID" -ne 0 ]; then
    err "Must run as root. Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi

# ── Config ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
GENERATED_VM="${REPO_DIR}/generated-vm"
VM2_SEED_DIR="${GENERATED_VM}/vm_2-seed"
SEED_ISO="/var/lib/libvirt/images/vm_2-seed.iso"
VM2_DISK="/var/lib/libvirt/images/vm_2.qcow2"
CLOUD_IMG="${VM_CLOUD_IMG_PATH:-/home/sandriaas/iso/noble-server-cloudimg-amd64.img}"
DISK_GB="${VM_DISK_GB:-32}"
RAM_MB="${VM_RAM_MB:-6144}"
VCPUS="${VM_VCPUS:-4}"
TUNNEL_HOSTNAME="vm_2-minipc-local"
CF_DOMAIN="easyrentbali.com"
CF_CONFIG="${HOME}/.cloudflared/config.yml"
CF_CONFIG_REPO="${REPO_DIR}/configs/cloudflared-config.yml"

# ── Preflight ───────────────────────────────────────────────────────────────
step "Preflight checks"

[ -f "$CLOUD_IMG" ] && ok "Cloud image: $CLOUD_IMG" || { err "Cloud image not found: $CLOUD_IMG"; exit 1; }
command -v cloud-localds &>/dev/null && ok "cloud-localds installed" || { err "Install: pacman -S cloud-image-utils"; exit 1; }
command -v virsh &>/dev/null && ok "virsh installed" || { err "Install: pacman -S libvirt"; exit 1; }
command -v virt-install &>/dev/null && ok "virt-install installed" || { err "Install: pacman -S virt-install"; exit 1; }

OVMF_CODE=$(ls /usr/share/edk2/x64/OVMF_CODE*.fd 2>/dev/null | head -1)
OVMF_VARS=$(ls /usr/share/edk2/x64/OVMF_VARS*.fd 2>/dev/null | head -1)
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ] && ok "OVMF firmware found" || { err "OVMF not found. Install: pacman -S edk2-ovmf"; exit 1; }

# Check libvirt running
systemctl is-active --quiet libvirtd && ok "libvirtd running" || { warn "Starting libvirtd..."; systemctl start libvirtd; }

# Check default network active
virsh net-info default 2>/dev/null | grep -q "Active: yes" && ok "Default network active" || {
    warn "Activating default network..."
    virsh net-start default 2>/dev/null || true
    ok "Default network started"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 1: Remove vm_1
# ═══════════════════════════════════════════════════════════════════════════════
step "Phase 1: Remove vm_1"

# Destroy if running
if virsh domstate vm_1 &>/dev/null; then
    info "Stopping vm_1..."
    virsh destroy vm_1 2>/dev/null || true
    sleep 1
    ok "vm_1 stopped"
else
    ok "vm_1 not running"
fi

# Undefine from libvirt
if virsh dominfo vm_1 &>/dev/null; then
    info "Undefining vm_1 from libvirt..."
    virsh undefine vm_1 --nvram 2>/dev/null || virsh undefine vm_1 2>/dev/null || true
    ok "vm_1 undefined"
else
    ok "vm_1 not defined in libvirt"
fi

# Remove disk
if [ -f "/var/lib/libvirt/images/vm_1.qcow2" ]; then
    info "Removing vm_1 disk (32GB)..."
    rm -f /var/lib/libvirt/images/vm_1.qcow2
    ok "vm_1 disk removed"
else
    ok "vm_1 disk not found (already clean)"
fi

# Remove seed ISO
if [ -f "/var/lib/libvirt/images/vm_1-seed.iso" ]; then
    info "Removing vm_1 seed ISO..."
    rm -f /var/lib/libvirt/images/vm_1-seed.iso
    ok "vm_1 seed ISO removed"
else
    ok "vm_1 seed ISO not found (already clean)"
fi

# Config files kept in repo (per user request)
ok "vm_1 config files kept in ${GENERATED_VM}/"

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 2: Recreate vm_2 from cloud image
# ═══════════════════════════════════════════════════════════════════════════════
step "Phase 2: Recreate vm_2 from cloud image"

# Stop existing vm_2
if virsh domstate vm_2 &>/dev/null; then
    info "Stopping existing vm_2..."
    virsh destroy vm_2 2>/dev/null || true
    sleep 1
fi
virsh undefine vm_2 --nvram 2>/dev/null || virsh undefine vm_2 2>/dev/null || true
ok "Existing vm_2 removed"

# Build seed ISO
info "Building cloud-init seed ISO..."
cloud-localds --network-config="${VM2_SEED_DIR}/network-config" \
    "$SEED_ISO" \
    "${VM2_SEED_DIR}/user-data" \
    "${VM2_SEED_DIR}/meta-data"
chown libvirt-qemu:libvirt-qemu "$SEED_ISO"
ok "Seed ISO built: $SEED_ISO"

# Create disk from cloud image
info "Creating vm_2 disk from cloud image (${DISK_GB}GB)..."
rm -f "$VM2_DISK"
qemu-img convert -O qcow2 "$CLOUD_IMG" "$VM2_DISK"
qemu-img resize "$VM2_DISK" "${DISK_GB}G"
chmod 644 "$VM2_DISK"
chown libvirt-qemu:libvirt-qemu "$VM2_DISK"
qemu-img info "$VM2_DISK" | head -5
ok "Disk created: $VM2_DISK"

# virt-install
info "Running virt-install..."
virt-install \
    --name vm_2 \
    --memory "$RAM_MB" \
    --vcpus "$VCPUS" \
    --cpu host-passthrough \
    --machine q35 \
    --boot "loader=${OVMF_CODE},loader.readonly=yes,loader.type=pflash,nvram.template=${OVMF_VARS}" \
    --disk "path=${VM2_DISK},format=qcow2,bus=virtio" \
    --disk "path=${SEED_ISO},device=cdrom,bus=sata" \
    --os-variant ubuntu24.04 \
    --network "network=default,model=virtio" \
    --graphics vnc,listen=127.0.0.1 \
    --video virtio \
    --serial pty \
    --import \
    --noautoconsole
ok "vm_2 created and booting"

# DHCP reservation
info "Setting DHCP reservation (192.168.122.51)..."
sleep 2
VM_MAC=$(virsh domiflist vm_2 | awk '/^ / && /network/ {print $NF}' | head -1)
info "vm_2 MAC: $VM_MAC"
virsh net-update default add ip-dhcp-host \
    "<host mac='${VM_MAC}' ip='192.168.122.51'/>" \
    --live --config 2>/dev/null \
    && ok "DHCP reservation: ${VM_MAC} -> 192.168.122.51" \
    || warn "Reservation may already exist"

# OOM protection
info "Applying OOM protection..."
for PID in $(pgrep -f 'qemu-system'); do
    echo -900 > /proc/$PID/oom_score_adj 2>/dev/null && ok "  PID $PID: oom_score_adj=-900"
done

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 3: Update Cloudflare tunnel for vm_2
# ═══════════════════════════════════════════════════════════════════════════════
step "Phase 3: Update Cloudflare tunnel"

# Update repo config
info "Updating ${CF_CONFIG_REPO}..."
if [ -f "$CF_CONFIG_REPO" ]; then
    # Check if vm_2-minipc-local already in config
    if grep -q "vm_2-minipc-local" "$CF_CONFIG_REPO"; then
        ok "vm_2-minipc-local already in repo config"
    else
        # Insert before the catch-all http_status:404 line
        sed -i '/service: http_status:404/i\  - hostname: vm_2-minipc-local.'"${CF_DOMAIN}"'\n    service: ssh://192.168.122.51:22' "$CF_CONFIG_REPO"
        ok "Added vm_2-minipc-local to repo config"
    fi
    cat "$CF_CONFIG_REPO"
else
    warn "Repo cloudflared config not found at $CF_CONFIG_REPO"
fi

# Update live config
info "Updating live Cloudflare config..."
if [ -f "$CF_CONFIG" ]; then
    if grep -q "vm_2-minipc-local" "$CF_CONFIG"; then
        ok "vm_2-minipc-local already in live config"
    else
        sed -i '/service: http_status:404/i\  - hostname: vm_2-minipc-local.'"${CF_DOMAIN}"'\n    service: ssh://192.168.122.51:22' "$CF_CONFIG"
        ok "Added vm_2-minipc-local to live config"
    fi
else
    warn "Live Cloudflare config not found at $CF_CONFIG"
    warn "Copy repo config: sudo cp $CF_CONFIG_REPO $CF_CONFIG"
fi

# Route DNS
info "Routing DNS for ${TUNNEL_HOSTNAME}.${CF_DOMAIN}..."
TUNNEL_NAME="minipc-ssh"
if command -v cloudflared &>/dev/null; then
    sudo -u "${SUDO_USER:-$USER}" cloudflared tunnel route dns "${TUNNEL_NAME}" "${TUNNEL_HOSTNAME}.${CF_DOMAIN}" 2>/dev/null \
        && ok "DNS routed: ${TUNNEL_HOSTNAME}.${CF_DOMAIN}" \
        || warn "DNS route may already exist or tunnel not configured"
else
    warn "cloudflared not found — route DNS manually"
fi

# Restart cloudflared
info "Restarting cloudflared service..."
if systemctl is-active --quiet cloudflared; then
    systemctl restart cloudflared
    ok "cloudflared restarted"
else
    warn "cloudflared service not running — start manually"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 4: Verify
# ═══════════════════════════════════════════════════════════════════════════════
step "Phase 4: Verify"

info "Waiting for vm_2 cloud-init (30-60s)..."
for i in $(seq 1 12); do
    sleep 5
    if ping -c 1 -W 2 192.168.122.51 &>/dev/null; then
        ok "vm_2 is reachable at 192.168.122.51"
        break
    fi
    info "  Waiting... (${i}/12)"
done

echo ""
echo -e "${BOLD}  ── VM State ──${RESET}"
virsh domstate vm_2 2>/dev/null || echo "vm_2 not running"
echo ""
echo -e "${BOLD}  ── DHCP Leases ──${RESET}"
virsh net-dhcp-leases default 2>/dev/null | grep -E "vm-2|vm_2" || echo "No lease yet"
echo ""
echo -e "${BOLD}  ── SSH Test ──${RESET}"
if ping -c 1 -W 2 192.168.122.51 &>/dev/null; then
    info "Try: ssh sandriaas@192.168.122.51"
    info "Try: ssh sandriaas@vm_2-minipc-local.${CF_DOMAIN}"
else
    warn "vm_2 not reachable yet — cloud-init may still be running"
    info "Wait 30s and try: ping 192.168.122.51"
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║          ✓  CLEANUP AND RECREATE COMPLETE                    ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  vm_1: ${GREEN}removed${RESET} (disk + seed deleted, config kept)"
echo -e "  vm_2: ${GREEN}recreated${RESET} from cloud image at 192.168.122.51"
echo -e "  SSH:  ${GREEN}vm_2-minipc-local.${CF_DOMAIN}${RESET} -> vm_2"
echo ""
