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
VM_CONF_DIR="${REPO_DIR}/generated-vm"
VM_CONF="$(ls "${VM_CONF_DIR}"/*.conf 2>/dev/null | head -1 || echo "${VM_CONF_DIR}/server-vm.conf")"
VM_CONF_LOADED="no"
VM_GPU_PASSTHROUGH="yes"
if [ -f "$VM_CONF" ]; then
  # shellcheck disable=SC1090
  set +u
  source "$VM_CONF" 2>/dev/null || true
  set -u
  VM_CONF_LOADED="yes"
  VM_GPU_PASSTHROUGH="${GPU_PASSTHROUGH:-yes}"
fi

PASS=0; WARN=0; FAIL=0
pass() { ok "$*";  PASS=$((PASS+1)); }
flag() { warn "$*"; WARN=$((WARN+1)); }
bad()  { fail "$*"; FAIL=$((FAIL+1)); }

PROFILE="full"
if [ "${1:-}" = "--profile" ]; then
  PROFILE="${2:-full}"
  shift 2
fi

find_cloudflared_config() {
  local candidate
  for candidate in "${HOME}/.cloudflared/config.yml" "/etc/cloudflared/config.yml"; do
    [ -f "$candidate" ] && { echo "$candidate"; return 0; }
  done
  return 1
}

find_it01_hostname_file() {
  local candidate
  for candidate in "/etc/cloudflared/it01-hostname" "${HOME}/.cloudflared/it01-hostname"; do
    [ -r "$candidate" ] && { echo "$candidate"; return 0; }
  done
  return 1
}

run_host_ssh_profile() {
  local tunnel_host="" hostname_file="" resolved_hosts="" ssh_state="" ssh_enabled=""

  section "Host SSH Profile"

  ssh_state="$(systemctl is-active sshd 2>/dev/null || systemctl is-active ssh 2>/dev/null || true)"
  ssh_enabled="$(systemctl is-enabled sshd 2>/dev/null || systemctl is-enabled ssh 2>/dev/null || true)"
  [ "${ssh_state}" = "active" ] && pass "sshd active" || bad "sshd not running"
  [ "${ssh_enabled}" = "enabled" ] && pass "sshd enabled on boot" || flag "sshd not enabled on boot"

  if systemctl is-active it01-cloudflared.service >/dev/null 2>&1; then
    pass "it01-cloudflared.service active"
  else
    bad "it01-cloudflared.service not running"
  fi
  if systemctl is-enabled it01-cloudflared.service >/dev/null 2>&1; then
    pass "it01-cloudflared.service enabled on boot"
  else
    flag "it01-cloudflared.service not enabled on boot"
  fi

  if [ -f /etc/cloudflared/it01.env ]; then
    pass "Tunnel token env present: /etc/cloudflared/it01.env"
  else
    bad "Tunnel token env missing: /etc/cloudflared/it01.env"
  fi

  hostname_file="$(find_it01_hostname_file || true)"
  if [ -n "${hostname_file}" ]; then
    pass "Hostname file present: ${hostname_file}"
    tunnel_host="$(cat "${hostname_file}" 2>/dev/null || true)"
  else
    bad "Hostname file missing for it01 host tunnel"
  fi

  if [ -n "${tunnel_host}" ]; then
    pass "Host SSH alias: it01 -> ${tunnel_host}"
    resolved_hosts="$(getent ahosts "${tunnel_host}" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd ', ' -)"
    if [ -n "${resolved_hosts}" ]; then
      pass "DNS resolves: ${tunnel_host} -> ${resolved_hosts}"
    else
      bad "DNS not propagated for ${tunnel_host}"
    fi

    if command -v websocat >/dev/null 2>&1; then
      if timeout 10 websocat -E --binary - "wss://${tunnel_host}" </dev/null >/dev/null 2>&1; then
        pass "websocat handshake succeeded for ${tunnel_host}"
      else
        bad "websocat handshake failed for ${tunnel_host}"
      fi
    else
      flag "websocat not installed locally — skipping tunnel handshake"
    fi
  else
    bad "Host SSH tunnel hostname not configured"
  fi

  section "Summary"
  echo -e "  ${GREEN}✓ ${PASS} passed${RESET}   ${YELLOW}! ${WARN} warnings${RESET}   ${RED}✗ ${FAIL} failed${RESET}"
  [ "${FAIL}" -eq 0 ] || echo -e "\n  ${RED}Action required — review ✗ items above.${RESET}"
  exit "${FAIL}"
}

[ "${PROFILE}" = "host-ssh" ] && run_host_ssh_profile

extract_ssh_tunnel_host() {
  local cfg="$1"
  awk '
    $1 == "-" && $2 == "hostname:" { host=$3 }
    $1 == "service:" && $2 ~ /^ssh:\/\// { print host; exit }
  ' "$cfg" 2>/dev/null
}

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
# Note: 'systemctl is-masked' exit code is unreliable on some systemd versions;
# use 'show --property=LoadState' instead.
ALL_MASKED=true
for _unit in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
  _state="$(systemctl show "$_unit" --property=LoadState 2>/dev/null | cut -d= -f2)"
  [ "$_state" = "masked" ] || { ALL_MASKED=false; break; }
done
$ALL_MASKED && pass "System sleep masked" || flag "Sleep not fully masked — server may suspend (run phase1 step 2)"

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

TUNNEL_CFG="$(find_cloudflared_config || true)"
TUNNEL_HOST=""
[ -n "${TUNNEL_CFG:-}" ] && TUNNEL_HOST="$(extract_ssh_tunnel_host "$TUNNEL_CFG" || true)"

# cloudflared
if systemctl is-active cloudflared >/dev/null 2>&1; then
  if [ -n "${TUNNEL_HOST:-}" ]; then
    pass "cloudflared active — SSH tunnel: ${TUNNEL_HOST}"
  else
    bad  "cloudflared active but SSH tunnel hostname missing from config"
  fi
else
  bad  "cloudflared not running"
fi
if systemctl is-enabled cloudflared >/dev/null 2>&1; then
  pass "cloudflared enabled (auto-starts after reboot)"
else
  flag "cloudflared not enabled on boot"
fi

section "Host Tunnel"
if [ -n "${TUNNEL_CFG:-}" ]; then
  pass "cloudflared config present: ${TUNNEL_CFG}"
else
  bad "cloudflared config not found in ~/.cloudflared/config.yml or /etc/cloudflared/config.yml"
fi

if [ -n "${TUNNEL_HOST:-}" ]; then
  pass "Host SSH alias: it01 → ${TUNNEL_HOST}"
  CNAME_TARGET="$(dig +short CNAME "${TUNNEL_HOST}" 2>/dev/null | head -1 | sed 's/\.$//')"
  if [ -n "${CNAME_TARGET:-}" ]; then
    pass "DNS CNAME resolves: ${TUNNEL_HOST} → ${CNAME_TARGET}"
  else
    bad "DNS CNAME missing or not propagated for ${TUNNEL_HOST}"
  fi

  if command -v websocat >/dev/null 2>&1; then
    if timeout 10 websocat -E --binary - "wss://${TUNNEL_HOST}" </dev/null >/dev/null 2>&1; then
      pass "websocat handshake succeeded for ${TUNNEL_HOST}"
    else
      bad "websocat handshake failed for ${TUNNEL_HOST}"
    fi
  else
    flag "websocat not installed locally — skipping tunnel handshake"
  fi
else
  bad "Host SSH tunnel hostname not configured"
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

if [ "${VM_GPU_PASSTHROUGH}" = "yes" ]; then
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
    PF_DRIVER="$(basename "$(readlink /sys/bus/pci/devices/0000:00:02.0/driver 2>/dev/null)" 2>/dev/null || true)"
    VF_DRIVER="$(basename "$(readlink /sys/bus/pci/devices/0000:00:02.1/driver 2>/dev/null)" 2>/dev/null || true)"
    [ "${PF_DRIVER:-}" = "i915" ]    && pass "PF (00:02.0) driver: i915 ✓"           || flag "PF driver: ${PF_DRIVER:-unknown}"
    [ "${VF_DRIVER:-}" = "vfio-pci" ] && pass "VF (00:02.1) driver: vfio-pci ✓"      || flag "VF driver: ${VF_DRIVER:-unknown (reboot or VF not bound)}"
  fi

  # /dev/dri
  if ls /dev/dri/card* /dev/dri/renderD* 2>/dev/null | grep -q .; then
    pass "/dev/dri present: $(ls /dev/dri/ 2>/dev/null | tr '\n' ' ')"
  else
    flag "/dev/dri not present"
  fi
else
  pass "GPU passthrough disabled in vm.conf — skipping SR-IOV enforcement checks"
fi

# ─── Phase 2: VM ─────────────────────────────────────────────────────────────
section "Phase 2 — VM"

# vm.conf
if [ -f "$VM_CONF" ]; then
  pass "vm.conf present: ${VM_CONF}"
  if [ "${VM_CONF_LOADED}" != "yes" ]; then
    # shellcheck disable=SC1090
    set +u
    source "$VM_CONF" 2>/dev/null || true
    set -u
  fi
  [ -n "${VM_NAME:-}" ]     && info "VM_NAME       = ${VM_NAME}"
  [ -n "${VM_RAM_MB:-}" ]   && info "VM_RAM_MB     = ${VM_RAM_MB}"
  [ -n "${GPU_PASSTHROUGH:-}" ] && info "GPU_PASSTHROUGH = ${GPU_PASSTHROUGH}"
  [ -n "${GPU_DRIVER:-}" ]  && info "GPU_DRIVER    = ${GPU_DRIVER}"
  [ -n "${GPU_VF_COUNT:-}" ] && info "GPU_VF_COUNT  = ${GPU_VF_COUNT}"
  [ -n "${VM_TUNNEL_HOST:-}" ] && info "VM_TUNNEL_HOST= ${VM_TUNNEL_HOST}"
else
  flag "vm.conf not found — run phase2.sh to create it"
fi

# ROM file
ROM_PATH="${GPU_ROM_PATH:-/usr/share/kvm/igd.rom}"
if [ "${GPU_PASSTHROUGH:-${VM_GPU_PASSTHROUGH}}" = "yes" ]; then
  if [ -f "$ROM_PATH" ]; then
    pass "ROM file present: ${ROM_PATH}"
  else
    flag "ROM file missing: ${ROM_PATH} — phase2 will download it"
  fi
else
  info "GPU passthrough disabled — ROM file check skipped"
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
  HOSTDEV_PRESENT="no"
  if virsh dumpxml "${VM_NAME:-server-vm}" 2>/dev/null | grep -q "<hostdev mode='subsystem' type='pci'>\\|<hostdev mode='subsystem' type='pci' managed='yes'>"; then
    HOSTDEV_PRESENT="yes"
  fi
  if [ "${GPU_PASSTHROUGH:-${VM_GPU_PASSTHROUGH}}" = "yes" ]; then
    [ "${HOSTDEV_PRESENT}" = "yes" ] && pass "VM hostdev passthrough XML present" || bad "GPU passthrough enabled in vm.conf but no hostdev in VM XML"
  else
    [ "${HOSTDEV_PRESENT}" = "no" ] && pass "VM hostdev passthrough XML absent (expected no-GPU mode)" || flag "No-GPU mode set but hostdev still present in VM XML"
  fi
else
  flag "virsh not available"
fi

# ─── Phase 3: VM Tunnel ───────────────────────────────────────────────────────
section "Phase 3 — VM Tunnel"

if [ -n "${VM_TUNNEL_HOST:-}" ] && [ "${VM_TUNNEL_HOST}" != "vm-xxxxxxx.easyrentbali.com" ]; then
  info "VM tunnel host: ${VM_TUNNEL_HOST}"
  VM_SSH_TARGET="${VM_SSH_HOST:-${VM_STATIC_IP%/*}}"
  if timeout 3 bash -c "echo >/dev/tcp/${VM_SSH_TARGET}/22" 2>/dev/null; then
    pass "VM SSH port reachable at ${VM_SSH_TARGET}:22"
  else
    flag "VM SSH not reachable (VM may not be running or phase3 not done)"
  fi
else
  flag "VM_TUNNEL_HOST not configured — run phase2+phase3"
fi

# ─── Phase State ─────────────────────────────────────────────────────────────
section "Phase Progress"
STATE_FILE="${REPO_DIR}/generated-vm/.state"
if [ -f "$STATE_FILE" ]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE" 2>/dev/null || true
  [ "${PHASE1_DONE:-no}" = "yes" ] && pass "Phase 1 complete" || flag "Phase 1 not complete — run scripts/phase1.sh"
  [ "${PHASE2_DONE:-no}" = "yes" ] && pass "Phase 2 complete  (last VM: ${LAST_VM_NAME:-unknown})" || flag "Phase 2 not complete — run scripts/phase2.sh"
  [ "${PHASE3_DONE:-no}" = "yes" ] && pass "Phase 3 complete" || flag "Phase 3 not complete — run scripts/phase3.sh"
  [ -n "${LAST_VM_CONF:-}" ] && info "Last vm.conf: ${LAST_VM_CONF}"
else
  flag "No state file found — run scripts/phase1.sh first"
fi


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
