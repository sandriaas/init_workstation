#!/usr/bin/env bash
# =============================================================================
# check.sh — Rev5.7.2 System Verification
# Run before/after any phase to verify installation state
# No root required (most checks use /sys and /proc)
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
ok()      { echo -e "  ${GREEN}✓${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}!${RESET} $*"; }
fail()    { echo -e "  ${RED}✗${RESET} $*"; }
info()    { echo -e "  ${CYAN}i${RESET} $*"; }
section() { echo -e "\n${BOLD}══ $* ══${RESET}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VM_CONF="${REPO_DIR}/configs/vm.conf"

PASS=0; WARN=0; FAIL=0
pass() { ok "$*";  PASS=$((PASS+1)); }
flag() { warn "$*"; WARN=$((WARN+1)); }
bad()  { fail "$*"; FAIL=$((FAIL+1)); }

# ─── System Info ─────────────────────────────────────────────────────────────
section "System Information"
CPU="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo unknown)"
KERNEL="$(uname -r)"
RAM="$(free -h 2>/dev/null | awk '/^Mem/{print $2}' || echo unknown)"
IGPU="$(lspci 2>/dev/null | grep -iE 'VGA|Display' | grep -i intel | head -1 | sed 's/.*: //' || true)"
DISKS="$(lsblk -d -o NAME,SIZE --noheadings 2>/dev/null | grep -v loop | awk '{printf "%s(%s) ",$1,$2}' || true)"
BOOT="$( [ -d /sys/firmware/efi ] && echo 'UEFI' || echo 'Legacy/CSM')"

echo "  CPU     : ${CPU}"
echo "  Kernel  : ${KERNEL}"
echo "  RAM     : ${RAM}"
echo "  iGPU    : ${IGPU:-not detected}"
echo "  Storage : ${DISKS}"
echo "  Boot    : ${BOOT}"

# ─── Phase 1: Host Prerequisites ─────────────────────────────────────────────
section "Phase 1 — Host Prerequisites"

# UEFI
[ -d /sys/firmware/efi ] && pass "UEFI boot mode" || bad "Legacy/CSM boot — set UEFI-only in BIOS"

# Kernel ≥ 6.8
KVER_MAJOR="$(uname -r | cut -d. -f1)"
KVER_MINOR="$(uname -r | cut -d. -f2)"
if [ "$KVER_MAJOR" -gt 6 ] || { [ "$KVER_MAJOR" -eq 6 ] && [ "$KVER_MINOR" -ge 8 ]; }; then
  pass "Kernel ${KERNEL} ≥ 6.8"
else
  bad  "Kernel ${KERNEL} < 6.8 — SR-IOV requires 6.8+"
fi

# Intel iGPU
if lspci 2>/dev/null | grep -iE 'VGA|Display' | grep -qi intel; then
  pass "Intel iGPU detected: ${IGPU:-unknown}"
else
  bad  "No Intel iGPU detected — check BIOS: Primary Display = iGPU"
fi

# IOMMU / VT-d
if ls /sys/class/iommu/ 2>/dev/null | grep -q .; then
  pass "VT-d / IOMMU active ($(ls /sys/class/iommu/ 2>/dev/null | tr '\n' ' '))"
else
  bad  "VT-d not active — enable Intel VT-d in BIOS and add intel_iommu=on to kernel args"
fi

# IOMMU kernel args
if grep -q "intel_iommu=on" /proc/cmdline 2>/dev/null; then
  pass "intel_iommu=on in cmdline"
else
  bad  "intel_iommu=on missing from /proc/cmdline"
fi
if grep -q "iommu=pt" /proc/cmdline 2>/dev/null; then
  pass "iommu=pt in cmdline"
else
  flag "iommu=pt missing from /proc/cmdline (recommended)"
fi

# Sleep disabled
if systemctl is-masked sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null | grep -q "masked"; then
  pass "System sleep masked"
else
  flag "Sleep not fully masked — server may suspend (run phase1 step 2)"
fi

# Static IP
CURRENT_IP="$(ip -4 addr show $(ip route | awk '/default/{print $5; exit}') 2>/dev/null | awk '/inet /{print $2}' | head -1 || true)"
[ -n "${CURRENT_IP:-}" ] && pass "Network IP: ${CURRENT_IP}" || flag "Could not detect network IP"

# sshd
if systemctl is-active sshd >/dev/null 2>&1 || systemctl is-active ssh >/dev/null 2>&1; then
  pass "sshd active"
else
  bad  "sshd not running"
fi
if systemctl is-enabled sshd >/dev/null 2>&1 || systemctl is-enabled ssh >/dev/null 2>&1; then
  pass "sshd enabled (starts on boot)"
else
  flag "sshd not enabled — won't start on reboot"
fi

# cloudflared
if systemctl is-active cloudflared >/dev/null 2>&1; then
  TUNNEL_HOST="$(awk '/hostname:/{print $NF; exit}' ~/.cloudflared/config.yml 2>/dev/null || echo unknown)"
  pass "cloudflared active — tunnel: ${TUNNEL_HOST}"
else
  bad  "cloudflared not running"
fi
if systemctl is-enabled cloudflared >/dev/null 2>&1; then
  pass "cloudflared enabled (auto-starts after reboot)"
else
  flag "cloudflared not enabled on boot"
fi

# docker
if systemctl is-active docker >/dev/null 2>&1; then
  pass "docker active"
else
  flag "docker not running"
fi
CURRENT_USER="${SUDO_USER:-$USER}"
if groups "$CURRENT_USER" 2>/dev/null | grep -q docker; then
  pass "User ${CURRENT_USER} in docker group"
else
  flag "User ${CURRENT_USER} NOT in docker group (active after reboot)"
fi

# libvirtd
if systemctl is-active libvirtd >/dev/null 2>&1 || systemctl is-active libvirtd.socket >/dev/null 2>&1; then
  pass "libvirtd active"
else
  flag "libvirtd not running"
fi
if groups "$CURRENT_USER" 2>/dev/null | grep -q libvirt; then
  pass "User ${CURRENT_USER} in libvirt group"
else
  flag "User ${CURRENT_USER} NOT in libvirt group"
fi

# ─── Phase 1 SR-IOV ──────────────────────────────────────────────────────────
section "SR-IOV + iGPU Passthrough"

# i915-sriov-dkms installed
DKMS_KERNEL="$(dkms status 2>/dev/null | grep "i915-sriov" | awk -F'[, ]+' '{print $2}' | head -1 || true)"
if [ -n "${DKMS_KERNEL:-}" ]; then
  pass "i915-sriov-dkms installed (built for ${DKMS_KERNEL})"
  if [ "${DKMS_KERNEL}" = "${KERNEL}" ]; then
    pass "Running on dkms-compatible kernel (${KERNEL})"
  else
    warn "Running ${KERNEL} — dkms built for ${DKMS_KERNEL}"
    # Check if default boot is correctly configured
    _limine_default="$(grep "^DEFAULT_ENTRY=" /etc/default/limine 2>/dev/null | cut -d= -f2 | tr -d '"' || true)"
    _limine_remember="$(grep "^remember_last_entry:" /boot/limine.conf 2>/dev/null | awk '{print $2}' || true)"
    if [ -n "${_limine_default}" ] && [ "${_limine_remember}" != "yes" ]; then
      flag "Boot default set (${_limine_default}) — reboot to switch to ${DKMS_KERNEL}"
    else
      flag "Boot default should be set to ${DKMS_KERNEL} (check /etc/default/limine DEFAULT_ENTRY)"
      [ "${_limine_remember}" = "yes" ] && flag "remember_last_entry=yes overrides default_entry — run: sudo sed -i 's/remember_last_entry: yes/remember_last_entry: no/' /boot/limine.conf"
    fi
  fi
else
  bad  "i915-sriov-dkms not installed — run phase1 step 6"
fi

# SR-IOV kernel args
if grep -q "i915.enable_guc=3" /proc/cmdline 2>/dev/null; then
  pass "i915.enable_guc=3 in cmdline"
else
  flag "i915.enable_guc=3 missing from cmdline"
fi
MAX_VFS="$(grep -oP 'i915\.max_vfs=\K[0-9]+' /proc/cmdline 2>/dev/null || true)"
[ -n "${MAX_VFS:-}" ] && pass "i915.max_vfs=${MAX_VFS} in cmdline" || flag "i915.max_vfs not in cmdline"
if grep -q "module_blacklist=xe" /proc/cmdline 2>/dev/null; then
  pass "module_blacklist=xe in cmdline"
else
  flag "module_blacklist=xe missing — xe driver may conflict"
fi

# VF count at boot
if [ -f /etc/tmpfiles.d/i915-set-sriov-numvfs.conf ]; then
  NUMVFS_CONF="$(grep -v '^#' /etc/tmpfiles.d/i915-set-sriov-numvfs.conf | grep sriov_numvfs | awk '{print $NF}' || true)"
  [ -n "${NUMVFS_CONF:-}" ] && pass "tmpfiles VF count = ${NUMVFS_CONF}" || flag "tmpfiles sriov_numvfs not set"
elif grep -q "sriov_numvfs" /etc/sysfs.conf 2>/dev/null; then
  pass "sysfs.conf sriov_numvfs configured"
else
  flag "VF count at boot not configured (no tmpfiles or sysfs.conf entry)"
fi

# Live VFs
LIVE_VFS="$(cat /sys/devices/pci0000:00/0000:00:02.0/sriov_numvfs 2>/dev/null || echo 0)"
if [ "${LIVE_VFS}" -gt 0 ] 2>/dev/null; then
  pass "SR-IOV VFs active: ${LIVE_VFS} VF(s) on 0000:00:02.0"
else
  flag "SR-IOV VFs not yet active (0) — reboot required"
fi

# vfio-pci module config
if [ -f /etc/modules-load.d/vfio.conf ] && grep -q "vfio-pci" /etc/modules-load.d/vfio.conf 2>/dev/null; then
  pass "vfio-pci in modules-load.d"
else
  flag "vfio-pci not in /etc/modules-load.d/"
fi

# udev rule for VF binding
if [ -f /etc/udev/rules.d/99-i915-vf-vfio.rules ]; then
  pass "VF→vfio-pci udev rule present"
else
  flag "VF udev rule missing (/etc/udev/rules.d/99-i915-vf-vfio.rules)"
fi

# GPU PCI driver usage (only meaningful when VFs are live)
if [ "${LIVE_VFS}" -gt 0 ] 2>/dev/null; then
  PF_DRIVER="$(cat /sys/devices/pci0000:00/0000:00:02.0/driver/module/drivers 2>/dev/null | grep -o 'i915\|vfio' | head -1 || true)"
  VF_DRIVER="$(cat /sys/devices/pci0000:00/0000:00:02.1/driver/module/drivers 2>/dev/null | grep -o 'vfio' | head -1 || true)"
  [ "${PF_DRIVER:-}" = "i915" ] && pass "PF (00:02.0) driver: i915 ✓" || flag "PF driver: ${PF_DRIVER:-unknown}"
  [ "${VF_DRIVER:-}" = "vfio" ] && pass "VF (00:02.1) driver: vfio-pci ✓" || flag "VF driver: ${VF_DRIVER:-unknown (reboot or VF not bound)}"
fi

# /dev/dri
if ls /dev/dri/card* /dev/dri/renderD* 2>/dev/null | grep -q .; then
  pass "/dev/dri present: $(ls /dev/dri/ 2>/dev/null | tr '\n' ' ')"
else
  flag "/dev/dri not present"
fi

# ─── Phase 2: VM ─────────────────────────────────────────────────────────────
section "Phase 2 — VM"

# vm.conf
if [ -f "$VM_CONF" ]; then
  pass "vm.conf present: ${VM_CONF}"
  source "$VM_CONF" 2>/dev/null || true
  [ -n "${VM_NAME:-}" ]     && info "VM_NAME       = ${VM_NAME}"
  [ -n "${VM_RAM_MB:-}" ]   && info "VM_RAM_MB     = ${VM_RAM_MB}"
  [ -n "${GPU_DRIVER:-}" ]  && info "GPU_DRIVER    = ${GPU_DRIVER}"
  [ -n "${GPU_VF_COUNT:-}" ] && info "GPU_VF_COUNT  = ${GPU_VF_COUNT}"
  [ -n "${VM_TUNNEL_HOST:-}" ] && info "VM_TUNNEL_HOST= ${VM_TUNNEL_HOST}"
else
  flag "vm.conf not found — run phase2.sh to create it"
fi

# ROM file
ROM_PATH="${GPU_ROM_PATH:-/usr/share/kvm/igd.rom}"
if [ -f "$ROM_PATH" ]; then
  pass "ROM file present: ${ROM_PATH}"
else
  flag "ROM file missing: ${ROM_PATH} — phase2 will download it"
fi

# VM exists in libvirt
if command -v virsh >/dev/null 2>&1; then
  VM_STATE="$(virsh domstate "${VM_NAME:-server-vm}" 2>/dev/null || echo 'not found')"
  case "$VM_STATE" in
    running)   pass "VM '${VM_NAME:-server-vm}' running" ;;
    shut\ off) flag "VM '${VM_NAME:-server-vm}' shut off" ;;
    "not found") flag "VM '${VM_NAME:-server-vm}' not created yet" ;;
    *)         flag "VM '${VM_NAME:-server-vm}' state: ${VM_STATE}" ;;
  esac
else
  flag "virsh not available"
fi

# ─── Phase 3: VM Tunnel ───────────────────────────────────────────────────────
section "Phase 3 — VM Tunnel"

if [ -n "${VM_TUNNEL_HOST:-}" ] && [ "${VM_TUNNEL_HOST}" != "vm-xxxxxxx.easyrentbali.com" ]; then
  info "VM tunnel host: ${VM_TUNNEL_HOST}"
  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes \
       "${VM_SSH_USER:-ubuntu}@${VM_SSH_HOST:-${VM_STATIC_IP:-192.168.122.50}}" true 2>/dev/null; then
    pass "VM SSH reachable at ${VM_SSH_HOST:-${VM_STATIC_IP:-}}"
  else
    flag "VM SSH not reachable (VM may not be running or phase3 not done)"
  fi
else
  flag "VM_TUNNEL_HOST not configured — run phase2+phase3"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
section "Summary"
TOTAL=$((PASS+WARN+FAIL))
echo -e "  ${GREEN}✓ ${PASS} passed${RESET}   ${YELLOW}! ${WARN} warnings${RESET}   ${RED}✗ ${FAIL} failed${RESET}   (${TOTAL} checks)"
echo ""
if [ $FAIL -gt 0 ]; then
  echo -e "  ${RED}Action required — review ✗ items above.${RESET}"
elif [ $WARN -gt 0 ]; then
  echo -e "  ${YELLOW}System mostly ready — review ! warnings above.${RESET}"
else
  echo -e "  ${GREEN}All checks passed.${RESET}"
fi
echo ""
