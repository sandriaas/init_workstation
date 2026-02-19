#!/usr/bin/env bash
# =============================================================================
# phase2.sh — Rev5.7.2 Phase 2: KVM VM Provision (Host Side)
# Supports: CachyOS/Arch · Ubuntu/Debian · Fedora · Proxmox
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
section() { echo -e "\n${BOLD}══ $* ══${RESET}"; }
ask()     { echo -e "${YELLOW}[?]${RESET} $*"; }
confirm() { ask "$1 [Y/n]: "; read -r r; [[ "${r:-Y}" =~ ^[Yy]$ ]]; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VM_CONF_DIR="${REPO_DIR}/generated-vm"
# Default — updated to generated-vm/${VM_NAME}.conf after VM_NAME is known
VM_CONF="${VM_CONF_DIR}/server-vm.conf"

detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}" in
      cachyos|arch|endeavouros|manjaro)     OS=arch ;;
      ubuntu|debian|pop|linuxmint)          OS=ubuntu ;;
      fedora|rhel|centos|rocky|almalinux)   OS=fedora ;;
      proxmox*)                             OS=proxmox ;;
      *)                                    OS=ubuntu ;;
    esac
    OS_NAME="${PRETTY_NAME:-$ID}"
  else
    OS=ubuntu
    OS_NAME="Unknown"
  fi
  info "Detected OS: $OS_NAME ($OS)"
}

detect_user() {
  CURRENT_USER="${SUDO_USER:-$USER}"
  if [ "$CURRENT_USER" = "root" ]; then
    ask "Enter the main username to configure: "; read -r CURRENT_USER
  fi
  USER_HOME="$(eval echo "~${CURRENT_USER}")"
  info "Target user: $CURRENT_USER ($USER_HOME)"
}

detect_system() {
  SYS_CPU="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || true)"
  SYS_RAM_TOTAL="$(free -h 2>/dev/null | awk '/^Mem/{print $2}' || true)"
  SYS_RAM_MB="$(free -m 2>/dev/null | awk '/^Mem/{print $2}' || true)"
  SYS_KERNEL="$(uname -r)"
  SYS_IGPU="$(lspci 2>/dev/null | grep -iE 'VGA|Display' | grep -i intel | head -1 | sed 's/.*: //' || true)"
  SYS_DGPU="$(lspci 2>/dev/null | grep -iE 'VGA|Display' | grep -iv intel | head -1 | sed 's/.*: //' || true)"
  SYS_DISKS="$(lsblk -d -o NAME,SIZE,MODEL --noheadings 2>/dev/null | grep -v loop | awk '{printf "%s(%s) ", $1,$2}' || true)"
  SYS_BOOT_MODE="$( [ -d /sys/firmware/efi ] && echo 'UEFI ✓' || echo 'Legacy/CSM ✗')"
  SYS_NCPU="$(nproc 2>/dev/null || echo '?')"

  # Detect Intel CPU gen from model name
  SYS_CPU_GEN=""
  if echo "$SYS_CPU" | grep -qiE 'i[3579]-12[0-9]{3}'; then
    SYS_CPU_GEN="12th gen Alder Lake"
  elif echo "$SYS_CPU" | grep -qiE 'i[3579]-13[0-9]{3}'; then
    SYS_CPU_GEN="13th gen Raptor Lake"
  elif echo "$SYS_CPU" | grep -qiE 'i[3579]-14[0-9]{3}'; then
    SYS_CPU_GEN="14th gen Raptor Lake Refresh"
  fi

  if ls /sys/class/iommu/ 2>/dev/null | grep -q .; then
    SYS_VTXD="VT-d active ✓"
  else
    SYS_VTXD="VT-d: set kernel args + BIOS"
  fi

  section "System Information"
  echo "  CPU     : ${SYS_CPU} ${SYS_CPU_GEN:+(${SYS_CPU_GEN})}"
  echo "  Cores   : ${SYS_NCPU} logical CPUs"
  echo "  RAM     : ${SYS_RAM_TOTAL} total"
  echo "  iGPU    : ${SYS_IGPU:-not detected}"
  [ -n "${SYS_DGPU}" ] && echo "  dGPU    : ${SYS_DGPU}"
  echo "  Storage : ${SYS_DISKS}"
  echo "  Kernel  : ${SYS_KERNEL}"
  echo "  Boot    : ${SYS_BOOT_MODE}"
  echo "  IOMMU   : ${SYS_VTXD}"
  echo ""

  # Suggest sensible VM defaults based on actual hardware
  SUGGESTED_VM_RAM_MB=$(( SYS_RAM_MB * 60 / 100 ))
  SUGGESTED_VM_VCPUS=$(( SYS_NCPU * 3 / 4 ))
  [ "$SUGGESTED_VM_VCPUS" -lt 2 ] && SUGGESTED_VM_VCPUS=2
  info "Suggested VM RAM: ~${SUGGESTED_VM_RAM_MB}MB (60% of ${SYS_RAM_TOTAL}) — VM CPUs: ~${SUGGESTED_VM_VCPUS} (75% of ${SYS_NCPU})"
  echo ""
}

check_requirements() {
  section "Requirements Check"
  echo "  Per LongQT-sea/intel-igpu-passthru guide:"
  echo ""

  local warn_count=0

  # UEFI
  if [ -d /sys/firmware/efi ]; then
    echo -e "  ${GREEN}✓${RESET} UEFI boot mode"
  else
    echo -e "  ${YELLOW}✗${RESET} Legacy/CSM boot — BIOS: enable UEFI-only, disable Legacy/CSM"
    warn_count=$((warn_count+1))
  fi

  # Kernel ≥ 6.8
  KVER_MAJOR="$(uname -r | cut -d. -f1)"
  KVER_MINOR="$(uname -r | cut -d. -f2)"
  if [ "$KVER_MAJOR" -gt 6 ] || { [ "$KVER_MAJOR" -eq 6 ] && [ "$KVER_MINOR" -ge 8 ]; }; then
    echo -e "  ${GREEN}✓${RESET} Kernel $(uname -r) ≥ 6.8"
  else
    echo -e "  ${YELLOW}✗${RESET} Kernel $(uname -r) < 6.8 — SR-IOV requires kernel 6.8+"
    warn_count=$((warn_count+1))
  fi

  # Intel iGPU present
  if lspci 2>/dev/null | grep -iE 'VGA|Display' | grep -qi intel; then
    echo -e "  ${GREEN}✓${RESET} Intel iGPU detected"
  else
    echo -e "  ${YELLOW}✗${RESET} No Intel iGPU — BIOS: set Primary Display = iGPU / Integrated"
    warn_count=$((warn_count+1))
  fi

  # VT-d check via sysfs (works without root, unlike dmesg)
  if ls /sys/class/iommu/ 2>/dev/null | grep -q .; then
    echo -e "  ${GREEN}✓${RESET} VT-d/IOMMU active"
  else
    echo -e "  ${YELLOW}!${RESET} VT-d not confirmed — BIOS: enable Intel VT-d"
    warn_count=$((warn_count+1))
  fi

  # VFs available (SR-IOV already configured by phase1)
  if [ -d /sys/class/drm ] && ls /sys/bus/pci/devices/0000:00:02.0/virtfn* >/dev/null 2>&1; then
    VF_COUNT="$(ls /sys/bus/pci/devices/0000:00:02.0/virtfn* 2>/dev/null | wc -l)"
    echo -e "  ${GREEN}✓${RESET} SR-IOV VFs active: ${VF_COUNT} VF(s) on 0000:00:02.0"
  else
    echo -e "  ${YELLOW}!${RESET} SR-IOV VFs not yet active — run phase1 (step 6) + reboot first"
  fi

  echo ""
  echo "  Required BIOS/UEFI settings (set before running):"
  echo "    • UEFI-only boot (disable Legacy/CSM)    • VGA OpROM = UEFI"
  echo "    • Intel VT-d = Enabled                   • Primary display = iGPU/Integrated"
  echo ""
  echo "  VM (phase2/3 will handle): OVMF firmware · headless · SSH+tunnel via phase3"
  echo ""

  if [ "$warn_count" -gt 0 ]; then
    warn "${warn_count} requirement(s) not confirmed — review before proceeding."
    confirm "Continue anyway?" || { echo "Aborted."; exit 0; }
  else
    ok "All requirements met."
  fi
}

default_if_empty() {
  local v="${1:-}" d="${2:-}"
  [ -n "$v" ] && echo "$v" || echo "$d"
}

detect_host_tunnel() {
  HOST_TUNNEL_HOST=""
  HOST_TUNNEL_DOMAIN=""
  HOST_TUNNEL_NAME=""
  HOST_TUNNEL_ID=""

  # Parse a specific YAML key's value from cloudflared config files.
  # Handles both '  key: value' and '  - key: value' formats via $NF.
  _cf_val() {
    local key="$1"; shift
    grep -h "${key}:" "$@" 2>/dev/null \
      | awk -v k="${key}:" '{for(i=1;i<=NF;i++) if($i==k){print $(i+1); exit}}' \
      | head -1
  }
  # hostname lines use $NF (last field) because value has no sub-keys after it
  _cf_hostname() {
    grep -h "hostname:" "$@" 2>/dev/null \
      | awk '{v=$NF} v!="" && v!~/^\*/ {print v; exit}'
  }

  local cfg
  # Primary: ~/.cloudflared/config.yml (written by phase1)
  for cfg in "$USER_HOME/.cloudflared/config.yml" "/etc/cloudflared/config.yml"; do
    [ -f "$cfg" ] || continue
    local h; h="$(_cf_hostname "$cfg")"
    [ -n "${h:-}" ] || continue
    HOST_TUNNEL_HOST="$h"
    HOST_TUNNEL_DOMAIN="${h#*.}"
    HOST_TUNNEL_ID="$(_cf_val "tunnel" "$cfg")"
    # Tunnel name: read from credentials JSON if we have the ID
    if [ -n "${HOST_TUNNEL_ID:-}" ]; then
      local cred="$USER_HOME/.cloudflared/${HOST_TUNNEL_ID}.json"
      [ -f "$cred" ] && \
        HOST_TUNNEL_NAME="$(python3 -c "import json,sys; d=json.load(open('$cred')); print(d.get('TunnelName',''))" 2>/dev/null || true)"
    fi
    return
  done

  # Fallback: scan all yml files in ~/.cloudflared/
  local h; h="$(_cf_hostname "$USER_HOME"/.cloudflared/*.yml 2>/dev/null || true)"
  if [ -n "${h:-}" ]; then
    HOST_TUNNEL_HOST="$h"
    HOST_TUNNEL_DOMAIN="${h#*.}"
  fi

  # Fallback: systemd ExecStart config arg
  local svc_cfg; svc_cfg="$(systemctl cat cloudflared 2>/dev/null \
    | grep -oP '(?<=--config )\S+' | head -1 || true)"
  if [ -n "${svc_cfg:-}" ] && [ -f "$svc_cfg" ]; then
    local h2; h2="$(_cf_hostname "$svc_cfg")"
    [ -n "${h2:-}" ] && HOST_TUNNEL_HOST="$h2" && HOST_TUNNEL_DOMAIN="${h2#*.}"
  fi
}

prompt_resource_and_vm_basics() {
  section "Step 1: VM Resources (RAM + CPU)"
  TOTAL_THREADS="$(nproc)"
  TOTAL_RAM_GB="$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)"

  # Default VM name: vm_N where N = next available number
  local _existing_count; _existing_count="$(virsh list --all --name 2>/dev/null | grep -c "^vm_" || echo 0)"
  VM_NAME_DEFAULT="vm_$(( _existing_count + 1 ))"
  VM_USER_DEFAULT="$CURRENT_USER"
  VM_HOSTNAME_DEFAULT="ubuntu-server"
  VM_VCPUS_DEFAULT="${SUGGESTED_VM_VCPUS:-14}"
  VM_RAM_GB_DEFAULT="$(( ${SUGGESTED_VM_RAM_MB:-8192} / 1024 ))"
  [ "$VM_RAM_GB_DEFAULT" -lt 4 ] && VM_RAM_GB_DEFAULT=4
  VM_DISK_GB_DEFAULT="32"

  VM_VCPUS_MAX=$(( TOTAL_THREADS > 2 ? TOTAL_THREADS - 2 : TOTAL_THREADS ))
  [ "$VM_VCPUS_MAX" -lt 2 ] && VM_VCPUS_MAX=2
  [ "$VM_VCPUS_DEFAULT" -gt "$VM_VCPUS_MAX" ] && VM_VCPUS_DEFAULT="$VM_VCPUS_MAX"

  info "Detected: ${TOTAL_THREADS} CPU threads, ${TOTAL_RAM_GB} GB RAM"
  ask "VM name [${VM_NAME_DEFAULT}]: "; read -r VM_NAME
  ask "VM user [${VM_USER_DEFAULT}]: "; read -r VM_USER
  ask "VM hostname [${VM_HOSTNAME_DEFAULT}]: "; read -r VM_HOSTNAME
  ask "Total vCPUs for VM? [min 2, max ${VM_VCPUS_MAX}, default ${VM_VCPUS_DEFAULT}]: "; read -r VM_VCPUS
  ask "RAM (GB) for VM? [total: ${TOTAL_RAM_GB}, default ${VM_RAM_GB_DEFAULT}]: "; read -r VM_RAM_GB
  ask "Disk size (GB)? [${VM_DISK_GB_DEFAULT}]: "; read -r VM_DISK_GB
  # VM user password for autoinstall (stored as SHA-512 hash only)
  ask "VM user password (for Ubuntu autoinstall): "; read -rs VM_PASSWORD_PLAIN; echo ""
  VM_PASSWORD_PLAIN="${VM_PASSWORD_PLAIN:-changeme123}"
  VM_PASSWORD_HASH="$(openssl passwd -6 "${VM_PASSWORD_PLAIN}" 2>/dev/null \
    || python3 -c "import crypt,sys; print(crypt.crypt(sys.argv[1],crypt.mksalt(crypt.METHOD_SHA512)))" "${VM_PASSWORD_PLAIN}" 2>/dev/null \
    || echo "\$6\$invalid")"
  unset VM_PASSWORD_PLAIN

  VM_NAME="$(default_if_empty "$VM_NAME" "$VM_NAME_DEFAULT")"
  VM_USER="$(default_if_empty "$VM_USER" "$VM_USER_DEFAULT")"
  VM_HOSTNAME="$(default_if_empty "$VM_HOSTNAME" "$VM_HOSTNAME_DEFAULT")"
  VM_VCPUS="$(default_if_empty "$VM_VCPUS" "$VM_VCPUS_DEFAULT")"
  VM_RAM_GB="$(default_if_empty "$VM_RAM_GB" "$VM_RAM_GB_DEFAULT")"
  VM_DISK_GB="$(default_if_empty "$VM_DISK_GB" "$VM_DISK_GB_DEFAULT")"
  # Update VM_CONF path now that VM_NAME is known
  VM_CONF="${VM_CONF_DIR}/${VM_NAME}.conf"

  VM_RAM_MB="$(( VM_RAM_GB * 1024 ))"
}

prompt_disk_path() {
  section "Step 2: VM Disk Location"
  echo "  1) /var/lib/libvirt/images/  (default libvirt)"
  echo "  2) /var/lib/qemu/            (QEMU directory)"
  echo "  3) Enter custom directory"
  ask "Choice [1/2/3]: "; read -r DISK_CHOICE
  case "${DISK_CHOICE:-1}" in
    1) VM_DISK_DIR="/var/lib/libvirt/images" ;;
    2) VM_DISK_DIR="/var/lib/qemu" ;;
    3) ask "Custom VM disk directory: "; read -r VM_DISK_DIR ;;
    *) VM_DISK_DIR="/var/lib/libvirt/images" ;;
  esac
  VM_DISK_PATH="${VM_DISK_DIR%/}/${VM_NAME}.qcow2"
}

prompt_iso() {
  section "Step 3: Ubuntu ISO"
  VM_OS_VARIANT="ubuntu24.04"
  VM_ISO_URL="https://releases.ubuntu.com/24.04.3/ubuntu-24.04.3-live-server-amd64.iso"
  VM_ISO_SHA256_URL="https://releases.ubuntu.com/24.04.3/SHA256SUMS"
  VM_ISO_PATH_DEFAULT="${USER_HOME}/iso/ubuntu-24.04.3-live-server-amd64.iso"
  mkdir -p "${USER_HOME}/iso"

  echo "  1) Download now (Ubuntu 24.04 server ISO)"
  echo "  2) I already have ISO path"
  echo "  3) Enter a custom destination path"
  ask "Choice [1/2/3]: "; read -r ISO_CHOICE

  _iso_sha256_expected() {
    curl -fsSL "$VM_ISO_SHA256_URL" 2>/dev/null \
      | grep "$(basename "$VM_ISO_URL")" | awk '{print $1}' | head -1
  }

  _verify_iso() {
    local dest="$1"
    info "Verifying ISO checksum..."
    local expected; expected="$(_iso_sha256_expected)"
    if [ -z "${expected:-}" ]; then
      warn "Could not fetch SHA256SUMS — skipping verification"
      return 0
    fi
    local actual; actual="$(sha256sum "$dest" | awk '{print $1}')"
    if [ "$actual" = "$expected" ]; then
      ok "ISO checksum verified ✓"
    else
      warn "ISO checksum MISMATCH — file may be incomplete or corrupted"
      warn "  Expected: $expected"
      warn "  Actual:   $actual"
      warn "Removing bad file and re-downloading..."
      rm -f "$dest"
      return 1
    fi
  }

  _download_iso() {
    local dest="$1"
    info "Downloading Ubuntu ISO to $dest"
    info "(supports resume — safe to Ctrl+C and rerun)"
    if command -v wget &>/dev/null; then
      wget --continue --show-progress --tries=5 --timeout=30 \
           -O "$dest" "$VM_ISO_URL"
    else
      curl -L --retry 5 --retry-delay 5 --retry-connrefused \
           -C - --progress-bar \
           -o "$dest" "$VM_ISO_URL"
    fi
  }

  _ensure_iso() {
    local dest="$1"
    if [ -f "$dest" ]; then
      info "Found existing ISO: $dest"
    else
      _download_iso "$dest"
    fi
    # Always verify checksum — catches incomplete/corrupt downloads
    if ! _verify_iso "$dest"; then
      _download_iso "$dest"
      _verify_iso "$dest" || { warn "ISO still invalid after re-download. Check your connection."; exit 1; }
    fi
  }

  case "${ISO_CHOICE:-1}" in
    1)
      VM_ISO_PATH="$VM_ISO_PATH_DEFAULT"
      _ensure_iso "$VM_ISO_PATH"
      ;;
    2)
      ask "Existing ISO path: "; read -r VM_ISO_PATH
      [ -f "$VM_ISO_PATH" ] || { warn "ISO not found: $VM_ISO_PATH"; exit 1; }
      _verify_iso "$VM_ISO_PATH" || { warn "Existing ISO failed checksum."; exit 1; }
      ;;
    3)
      ask "Destination ISO path: "; read -r VM_ISO_PATH
      _ensure_iso "$VM_ISO_PATH"
      ;;
    *)
      VM_ISO_PATH="$VM_ISO_PATH_DEFAULT"
      ;;
  esac
}

prompt_network_and_share() {
  section "Step 4: Network + Shared Folder"

  # Auto-detect libvirt default network gateway/subnet
  _VIRT_GW="$(sudo virsh net-dumpxml default 2>/dev/null \
    | grep -oP "ip address='\K[^']+" | head -1 || true)"
  if [ -n "${_VIRT_GW:-}" ]; then
    # Suggest .50 in the same subnet as the gateway (e.g. 192.168.122.1 → 192.168.122.50)
    _VIRT_PREFIX="${_VIRT_GW%.*}"
    VM_STATIC_IP_DEFAULT="${_VIRT_PREFIX}.50/24"
    VM_GATEWAY_DEFAULT="${_VIRT_GW}"
  else
    VM_STATIC_IP_DEFAULT="192.168.122.50/24"
    VM_GATEWAY_DEFAULT="192.168.122.1"
  fi
  VM_DNS_DEFAULT="1.1.1.1,8.8.8.8"
  SHARED_DIR_DEFAULT="${USER_HOME}/server-data"
  SHARED_TAG_DEFAULT="hostshare"

  info "Host LAN IP: $(hostname -I 2>/dev/null | awk '{print $1}') — VM will be on libvirt NAT (${VM_GATEWAY_DEFAULT%.*}.x)"
  ask "VM static IP/CIDR [${VM_STATIC_IP_DEFAULT}]: "; read -r VM_STATIC_IP
  ask "VM gateway [${VM_GATEWAY_DEFAULT}]: "; read -r VM_GATEWAY
  ask "VM DNS (comma-separated) [${VM_DNS_DEFAULT}]: "; read -r VM_DNS
  ask "Host shared directory for virtiofs [${SHARED_DIR_DEFAULT}]: "; read -r SHARED_DIR
  ask "virtiofs mount tag in VM [${SHARED_TAG_DEFAULT}]: "; read -r SHARED_TAG

  VM_STATIC_IP="$(default_if_empty "$VM_STATIC_IP" "$VM_STATIC_IP_DEFAULT")"
  VM_GATEWAY="$(default_if_empty "$VM_GATEWAY" "$VM_GATEWAY_DEFAULT")"
  VM_DNS="$(default_if_empty "$VM_DNS" "$VM_DNS_DEFAULT")"
  SHARED_DIR="$(default_if_empty "$SHARED_DIR" "$SHARED_DIR_DEFAULT")"
  SHARED_TAG="$(default_if_empty "$SHARED_TAG" "$SHARED_TAG_DEFAULT")"
}

prompt_gpu() {
  section "Step 5: Intel iGPU — Gen + ROM"
  echo "Select Intel CPU generation:"
  echo "  1   Sandy Bridge     (2nd)          Core i3/5/7 2xxx"
  echo "  2   Ivy Bridge       (3rd)          Core i3/5/7 3xxx"
  echo "  3   Haswell/BDW      (4th/5th)      Core i3/5/7 4xxx-5xxx"
  echo "  4   Skylake->CML     (6-10th)       Core i3/5/7/9 6xxx-10xxx"
  echo "  5   Coffee/Comet     (8-10th)       Core i3/5/7/9 8xxx-10xxx"
  echo "  6   Gemini Lake                     Pentium/Celeron J/N 4xxx/5xxx"
  echo "  7   Ice Lake mobile  (10th)         Core i3/5/7 10xxG1/G4/G7"
  echo "  8   Rocket/Tiger/Alder/Raptor       Core i3/5/7/9 11xxx-14xxx (desktop/mainstream)"
  echo "  9   Alder/Raptor Lake H/P/U mobile  Core i3/5/7/9 12xxx-14xxx H/P/U  <- i9-12900H (Intel Iris Xe)"
  echo " 10   Jasper Lake                     Pentium/Celeron N 4xxx/5xxx/6xxx"
  echo " 11   Alder Lake-N / Twin Lake        N-series"
  echo " 12   Arrow/Meteor Lake               Core Ultra (i915 — xe unsupported for MTL)"
  echo " 13   Lunar Lake                      Core Ultra 2xx (i915 — xe unsupported for LNL)"
  ask "Selection [9]: "; read -r GPU_GEN
  GPU_GEN="$(default_if_empty "$GPU_GEN" "9")"

  ask "Enable GPU passthrough SR-IOV? [Y/n]: "; read -r GPU_PASS_CHOICE
  if [[ "${GPU_PASS_CHOICE:-Y}" =~ ^[Nn]$ ]]; then
    GPU_PASSTHROUGH="no"
  else
    GPU_PASSTHROUGH="yes"
  fi

  ask "How many VFs? [7]: "; read -r GPU_VF_COUNT
  GPU_VF_COUNT="$(default_if_empty "$GPU_VF_COUNT" "7")"

  # Set ROM file, driver, kernel args, and whether x-igd-lpc is needed
  # x-igd-lpc required for Ice Lake, Rocket Lake, Tiger Lake, Alder Lake and newer
  case "$GPU_GEN" in
    1)  GPU_DRIVER="i915"; GPU_ROM_FILE="SNB_GOPv2_igd.rom";            GPU_IGD_LPC="no"  ;;
    2)  GPU_DRIVER="i915"; GPU_ROM_FILE="IVB_GOPv3_igd.rom";            GPU_IGD_LPC="no"  ;;
    3)  GPU_DRIVER="i915"; GPU_ROM_FILE="HSW_BDW_GOPv5_igd.rom";        GPU_IGD_LPC="no"  ;;
    4)  GPU_DRIVER="i915"; GPU_ROM_FILE="SKL_CML_GOPv9_igd.rom";        GPU_IGD_LPC="no"  ;;
    5)  GPU_DRIVER="i915"; GPU_ROM_FILE="CFL_CML_GOPv9.1_igd.rom";      GPU_IGD_LPC="no"  ;;
    6)  GPU_DRIVER="i915"; GPU_ROM_FILE="GLK_GOPv13_igd.rom";           GPU_IGD_LPC="no"  ;;
    7)  GPU_DRIVER="i915"; GPU_ROM_FILE="ICL_GOPv14_igd.rom";           GPU_IGD_LPC="yes" ;;
    8)  GPU_DRIVER="i915"; GPU_ROM_FILE="RKL_TGL_ADL_RPL_GOPv17_igd.rom"; GPU_IGD_LPC="yes" ;;
    9)  GPU_DRIVER="i915"; GPU_ROM_FILE="ADL-H_RPL-H_GOPv21_igd.rom";  GPU_IGD_LPC="yes" ;;
    10) GPU_DRIVER="i915"; GPU_ROM_FILE="JSL_GOPv18_igd.rom";           GPU_IGD_LPC="no"  ;;
    11) GPU_DRIVER="i915"; GPU_ROM_FILE="ADL-N_TWL_GOPv21_igd.rom";    GPU_IGD_LPC="yes" ;;
    12) GPU_DRIVER="i915"; GPU_ROM_FILE="ARL_MTL_GOPv22_igd.rom";       GPU_IGD_LPC="yes" ;;
    13) GPU_DRIVER="i915"; GPU_ROM_FILE="LNL_GOPv2X_igd.rom";           GPU_IGD_LPC="yes" ;;
    *)  GPU_DRIVER="i915"; GPU_ROM_FILE="ADL-H_RPL-H_GOPv21_igd.rom";  GPU_IGD_LPC="yes" ;;
  esac
  GPU_ROM_URL="https://github.com/LongQT-sea/intel-igpu-passthru/releases/download/v0.1/${GPU_ROM_FILE}"

  if [ "$GPU_DRIVER" = "xe" ]; then
    # xe.force_probe required: value = output of: cat /sys/devices/pci0000:00/0000:00:02.0/device
    XE_PROBE_ID="$(cat /sys/devices/pci0000:00/0000:00:02.0/device 2>/dev/null | sed 's/^0x//' || true)"
    XE_PROBE_ID="${XE_PROBE_ID:-$(ask "Enter device ID for xe.force_probe (cat /sys/devices/pci0000:00/0000:00:02.0/device | sed s/0x//): "; read -r _p; echo "$_p")}"
    KERNEL_GPU_ARGS="xe.max_vfs=${GPU_VF_COUNT} xe.force_probe=${XE_PROBE_ID} module_blacklist=i915"
  else
    KERNEL_GPU_ARGS="i915.enable_guc=3 i915.max_vfs=${GPU_VF_COUNT} module_blacklist=xe"
  fi

  # QEMU legacy-mode restriction warning (QEMU 10.1+ restricts to SNB→CML per LongQT-sea guide fn[4])
  QEMU_VER="$(qemu-system-x86_64 --version 2>/dev/null | awk '/QEMU emulator/{print $4}' | cut -d. -f1,2 || true)"
  QEMU_MAJOR="$(echo "${QEMU_VER:-0.0}" | cut -d. -f1)"
  QEMU_MINOR="$(echo "${QEMU_VER:-0.0}" | cut -d. -f2)"
  if { [ "$QEMU_MAJOR" -gt 10 ] || { [ "$QEMU_MAJOR" -eq 10 ] && [ "$QEMU_MINOR" -ge 1 ]; }; } \
     && [ "${GPU_IGD_LPC:-no}" = "yes" ]; then
    warn "QEMU ${QEMU_VER} detected. QEMU 10.1+ restricts legacy IGD mode to Sandy Bridge → Comet Lake."
    warn "Alder Lake / Raptor Lake may require UPT mode instead of legacy mode."
    warn "See: https://github.com/LongQT-sea/intel-igpu-passthru (footnote 4)"
    warn "If passthrough fails, try removing --machine pc and switching to UPT mode."
  fi

  GPU_PCI_ID_DETECTED="$(lspci -Dnn | awk '/VGA compatible controller|Display controller/ && /Intel/{print $1; exit}')"
  GPU_PCI_ID_DETECTED="$(default_if_empty "$GPU_PCI_ID_DETECTED" "0000:00:02.0")"
  info "Detected iGPU PCI: ${GPU_PCI_ID_DETECTED}"
  ask "Use this PCI ID? [Y/n]: "; read -r USE_DETECTED
  if [[ "${USE_DETECTED:-Y}" =~ ^[Nn]$ ]]; then
    ask "Enter GPU PCI ID (e.g. 0000:00:02.0): "; read -r GPU_PCI_ID
  else
    GPU_PCI_ID="$GPU_PCI_ID_DETECTED"
  fi
}

prompt_rom() {
  [ "${GPU_PASSTHROUGH:-yes}" = "yes" ] || return 0
  section "Step 5b: iGPU ROM File (OpROM/VBIOS)"
  GPU_ROM_DEST="/usr/share/kvm/igd.rom"
  info "ROM for your generation: ${GPU_ROM_FILE}"
  info "  Source: ${GPU_ROM_URL}"
  echo ""
  echo "  1) Download now (from LongQT-sea/intel-igpu-passthru)"
  echo "  2) I already have the ROM file — specify path"
  ask "Choice [1/2]: "; read -r ROM_CHOICE

  _verify_rom() {
    local dest="$1"
    [ -f "$dest" ] || { warn "ROM not found: $dest"; return 1; }
    local size; size="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
    if [ "$size" -lt 10240 ]; then   # < 10 KB = incomplete / corrupt
      warn "ROM file too small (${size} bytes) — incomplete or corrupt"
      sudo rm -f "$dest"
      return 1
    fi
    ok "ROM file OK ✓  ($(( size / 1024 )) KB)"
  }

  _download_rom() {
    local dest="$1"
    info "Downloading ${GPU_ROM_FILE} → ${dest}"
    info "(supports resume — safe to Ctrl+C and rerun)"
    sudo mkdir -p "$(dirname "$dest")"
    if command -v wget &>/dev/null; then
      sudo wget --continue --show-progress --tries=5 --timeout=30 \
           -O "$dest" "$GPU_ROM_URL"
    else
      sudo curl -L --retry 5 --retry-delay 5 --retry-connrefused \
           -C - --progress-bar \
           -o "$dest" "$GPU_ROM_URL"
    fi
  }

  _ensure_rom() {
    local dest="$1"
    if [ -f "$dest" ]; then
      info "Found existing ROM: $dest"
    else
      _download_rom "$dest"
    fi
    # Always verify — catches incomplete downloads
    if ! _verify_rom "$dest"; then
      _download_rom "$dest"
      _verify_rom "$dest" || { warn "ROM still invalid after re-download. Check your connection."; exit 1; }
    fi
  }

  case "${ROM_CHOICE:-1}" in
    2)
      ask "Path to ROM file: "; read -r USER_ROM_PATH
      [ -f "$USER_ROM_PATH" ] || { warn "ROM file not found: $USER_ROM_PATH"; exit 1; }
      sudo mkdir -p /usr/share/kvm
      sudo cp "$USER_ROM_PATH" "$GPU_ROM_DEST"
      _verify_rom "$GPU_ROM_DEST" || { warn "Copied ROM appears invalid."; exit 1; }
      ;;
    *)
      _ensure_rom "$GPU_ROM_DEST"
      ;;
  esac
  ok "ROM ready at ${GPU_ROM_DEST}"
}

prompt_tunnel() {
  section "Step 6: Cloudflare Tunnels"
  detect_host_tunnel

  if [ -n "${HOST_TUNNEL_HOST:-}" ]; then
    echo ""
    echo -e "${GREEN}  ✓ Host tunnel detected:${RESET}"
    printf "    %-16s %s\n" "Hostname:"  "$HOST_TUNNEL_HOST"
    printf "    %-16s %s\n" "Domain:"    "$HOST_TUNNEL_DOMAIN"
    [ -n "${HOST_TUNNEL_NAME:-}" ] && printf "    %-16s %s\n" "Tunnel name:" "$HOST_TUNNEL_NAME"
    [ -n "${HOST_TUNNEL_ID:-}" ]   && printf "    %-16s %s\n" "Tunnel ID:"   "$HOST_TUNNEL_ID"
    echo ""
    echo "    SSH from anywhere:  ssh ${CURRENT_USER}@${HOST_TUNNEL_HOST}"
    echo ""
    echo "  1) Use detected domain: ${HOST_TUNNEL_DOMAIN}  (recommended)"
    echo "  2) Use another domain"
    ask "Choice [1/2]: "; read -r DOMAIN_CHOICE
    if [ "${DOMAIN_CHOICE:-1}" = "2" ]; then
      ask "Enter domain (e.g. example.com): "; read -r HOST_TUNNEL_DOMAIN
      ask "Enter host tunnel hostname: "; read -r HOST_TUNNEL_HOST
    fi
  else
    warn "No host tunnel detected from cloudflared config."
    ask "Enter domain (e.g. easyrentbali.com): "; read -r _dom
    HOST_TUNNEL_DOMAIN="$(default_if_empty "$_dom" "easyrentbali.com")"
    ask "Enter host tunnel hostname (e.g. abc123.${HOST_TUNNEL_DOMAIN}): "; read -r HOST_TUNNEL_HOST
  fi

  echo ""
  VM_TUNNEL_NAME_DEFAULT="${VM_NAME}-ssh"
  VM_TUNNEL_HOST_DEFAULT="vm-$(tr -dc a-z0-9 </dev/urandom | head -c 8).${HOST_TUNNEL_DOMAIN}"
  echo -e "  VM tunnel will be a ${YELLOW}new${RESET} tunnel on the same domain."
  ask "VM tunnel name [${VM_TUNNEL_NAME_DEFAULT}]: "; read -r VM_TUNNEL_NAME
  ask "VM tunnel hostname [${VM_TUNNEL_HOST_DEFAULT}]: "; read -r VM_TUNNEL_HOST
  VM_TUNNEL_NAME="$(default_if_empty "$VM_TUNNEL_NAME" "$VM_TUNNEL_NAME_DEFAULT")"
  VM_TUNNEL_HOST="$(default_if_empty "$VM_TUNNEL_HOST" "$VM_TUNNEL_HOST_DEFAULT")"
  echo ""
  echo -e "  ${BOLD}Tunnel plan:${RESET}"
  printf "    %-20s %s\n" "Host SSH tunnel:" "${HOST_TUNNEL_HOST}"
  printf "    %-20s %s  (created by phase 3)\n" "VM SSH tunnel:"   "${VM_TUNNEL_HOST}"
}

write_vm_conf() {
  section "Writing generated-vm/${VM_NAME}.conf"
  mkdir -p "${VM_CONF_DIR}"
  cat > "$VM_CONF" <<EOF
# Generated by scripts/phase2.sh — mirrors Cockpit/virt-install VM definition

# ── Identity ──────────────────────────────────────────────────────────────────
VM_NAME="${VM_NAME}"
VM_HOSTNAME="${VM_HOSTNAME}"
VM_USER="${VM_USER}"
# SHA-512 hash of VM user password (used by Ubuntu autoinstall — never store plaintext)
VM_PASSWORD_HASH="${VM_PASSWORD_HASH:-}"

# ── Machine / Firmware ────────────────────────────────────────────────────────
# machine: pc (i440fx) required for legacy IGD passthrough; q35 for everything else
VM_MACHINE_TYPE="${VM_MACHINE_TYPE:-pc}"
# firmware: uefi (OVMF) or bios
VM_FIRMWARE="${VM_FIRMWARE:-uefi}"
# cpu: host-passthrough exposes all host CPU features to guest
VM_CPU_MODEL="${VM_CPU_MODEL:-host-passthrough}"

# ── Resources ─────────────────────────────────────────────────────────────────
VM_RAM_MB="${VM_RAM_MB}"
VM_VCPUS="${VM_VCPUS}"

# ── Disk ──────────────────────────────────────────────────────────────────────
VM_DISK_GB="${VM_DISK_GB}"
VM_DISK_PATH="${VM_DISK_PATH}"
VM_DISK_FORMAT="${VM_DISK_FORMAT:-qcow2}"
VM_DISK_BUS="${VM_DISK_BUS:-virtio}"

# ── OS ────────────────────────────────────────────────────────────────────────
VM_OS_VARIANT="${VM_OS_VARIANT}"
VM_ISO_PATH="${VM_ISO_PATH}"
VM_ISO_URL="${VM_ISO_URL}"
VM_ISO_SHA256_URL="${VM_ISO_SHA256_URL}"
VM_BOOT_ORDER="${VM_BOOT_ORDER:-hd,cdrom}"
# Autoinstall: yes = cloud-init autoinstall (fully unattended), no = manual
VM_AUTOINSTALL="${VM_AUTOINSTALL:-yes}"
VM_SEED_ISO="${VM_SEED_ISO:-${VM_CONF_DIR}/${VM_NAME}-seed.iso}"

# ── Network ───────────────────────────────────────────────────────────────────
VM_NET_TYPE="${VM_NET_TYPE:-network}"
VM_NET_SOURCE="${VM_NET_SOURCE:-default}"
VM_NET_MODEL="${VM_NET_MODEL:-virtio}"
VM_STATIC_IP="${VM_STATIC_IP}"
VM_GATEWAY="${VM_GATEWAY}"
VM_DNS="${VM_DNS}"
VM_SSH_PORT="${VM_SSH_PORT:-22}"

# ── Display / Console ─────────────────────────────────────────────────────────
# Headless passthrough: no graphics, no video, serial console only
VM_GRAPHICS="${VM_GRAPHICS:-none}"
VM_VIDEO="${VM_VIDEO:-none}"
VM_CONSOLE="${VM_CONSOLE:-pty,target_type=serial}"

# ── Features ──────────────────────────────────────────────────────────────────
VM_FEATURES="${VM_FEATURES:-acpi,apic}"
VM_CLOCK="${VM_CLOCK:-utc}"
VM_AUTOSTART="${VM_AUTOSTART:-yes}"

# ── Shared Storage ────────────────────────────────────────────────────────────
SHARED_DIR="${SHARED_DIR}"
SHARED_TAG="${SHARED_TAG}"

# ── GPU / SR-IOV Passthrough ──────────────────────────────────────────────────
GPU_PASSTHROUGH="${GPU_PASSTHROUGH}"
GPU_GEN="${GPU_GEN}"
GPU_PCI_ID="${GPU_PCI_ID}"
GPU_VF_COUNT="${GPU_VF_COUNT}"
GPU_DRIVER="${GPU_DRIVER}"
GPU_ROM_FILE="${GPU_ROM_FILE}"
GPU_ROM_URL="${GPU_ROM_URL}"
GPU_ROM_PATH="${GPU_ROM_DEST:-/usr/share/kvm/igd.rom}"
GPU_IGD_LPC="${GPU_IGD_LPC}"
KERNEL_GPU_ARGS="${KERNEL_GPU_ARGS}"

# ── Cloudflare Tunnel ─────────────────────────────────────────────────────────
HOST_TUNNEL_DOMAIN="${HOST_TUNNEL_DOMAIN}"
HOST_TUNNEL_HOST="${HOST_TUNNEL_HOST}"
HOST_TUNNEL_NAME="${HOST_TUNNEL_NAME:-}"
HOST_TUNNEL_ID="${HOST_TUNNEL_ID:-}"
VM_TUNNEL_NAME="${VM_TUNNEL_NAME}"
VM_TUNNEL_HOST="${VM_TUNNEL_HOST}"
EOF
  chown "${CURRENT_USER}:${CURRENT_USER}" "$VM_CONF"
  ok "Saved: $VM_CONF"
}

source_vm_conf() {
  # shellcheck disable=SC1090
  source "$VM_CONF"
}

install_sriov_host() {
  [ "${GPU_PASSTHROUGH:-yes}" = "yes" ] || return 0
  source_vm_conf  # ensure all vm.conf vars (incl. KERNEL_GPU_ARGS) are loaded
  section "Host SR-IOV Setup (${GPU_DRIVER})"

  # Skip only if BOTH kernel args AND dkms module are already in place (phase1 ran step 6)
  SRIOV_ARGS_SET=false
  SRIOV_DKMS_SET=false
  { grep -q "${GPU_DRIVER}.max_vfs=" /etc/default/limine 2>/dev/null || \
    grep -q "${GPU_DRIVER}.max_vfs=" /etc/default/grub 2>/dev/null; } && SRIOV_ARGS_SET=true
  { pacman -Q i915-sriov-dkms >/dev/null 2>&1 || \
    dpkg -s i915-sriov-dkms >/dev/null 2>&1 || \
    rpm -q akmod-i915-sriov >/dev/null 2>&1 || \
    dkms status 2>/dev/null | grep -q "i915.sriov\|i915-sriov"; } && SRIOV_DKMS_SET=true

  if $SRIOV_ARGS_SET && $SRIOV_DKMS_SET; then
    ok "SR-IOV kernel args + i915-sriov-dkms already present (set by phase1). Skipping."
    return
  fi
  if $SRIOV_ARGS_SET && ! $SRIOV_DKMS_SET; then
    warn "Kernel args already set but i915-sriov-dkms not installed — continuing to install dkms."
  fi

  # Guide warning: remove disable_vga=1 if present (breaks IGD passthrough)
  if grep -qr 'disable_vga=1' /etc/modprobe.d/ /etc/default/grub /etc/default/limine 2>/dev/null; then
    warn "Found 'disable_vga=1' in your config — this BREAKS iGPU passthrough!"
    warn "Removing it now (per LongQT-sea/intel-igpu-passthru requirements)..."
    sudo find /etc/modprobe.d/ -type f -exec sudo sed -i 's/disable_vga=1//g' {} + 2>/dev/null || true
    sudo sed -i 's/disable_vga=1//g' /etc/default/grub /etc/default/limine 2>/dev/null || true
  fi

  case "$OS" in
    arch)
      if command -v paru >/dev/null 2>&1; then
        sudo -u "$CURRENT_USER" paru -S --noconfirm --needed i915-sriov-dkms || warn "AUR install failed; continue manually if needed."
      else
        warn "paru not found. Install i915-sriov-dkms manually."
      fi
      ;;
    fedora)
      sudo dnf -y copr enable matte23/akmods || warn "Could not enable COPR matte23/akmods"
      sudo dnf install -y akmod-i915-sriov || warn "Could not install akmod-i915-sriov"
      sudo akmods --force || true
      sudo depmod -a || true
      sudo dracut --force || true
      ;;
    ubuntu|proxmox)
      if ! dpkg -s i915-sriov-dkms >/dev/null 2>&1; then
        local_url="$(curl -fsSL https://api.github.com/repos/strongtz/i915-sriov-dkms/releases/latest | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(a["browser_download_url"] for a in d["assets"] if a["name"].endswith("_amd64.deb")))' 2>/dev/null || true)"
        if [ -n "${local_url:-}" ]; then
          curl -fL "$local_url" -o /tmp/i915-sriov-dkms_latest_amd64.deb
          sudo dpkg -i /tmp/i915-sriov-dkms_latest_amd64.deb || sudo apt-get install -f -y
        else
          warn "Could not resolve latest i915-sriov .deb URL; install manually."
        fi
      fi
      ;;
  esac

  FULL_KERNEL_ARGS="intel_iommu=on iommu=pt ${KERNEL_GPU_ARGS}"
  if [ -f /etc/default/limine ]; then
    if ! grep -q "${GPU_DRIVER}.max_vfs=${GPU_VF_COUNT}" /etc/default/limine 2>/dev/null; then
      sudo sed -i "s/\\(KERNEL_CMDLINE\\[[^]]*\\]+=\"[^\"]*\\)\"/\\1 ${FULL_KERNEL_ARGS}\"/g" /etc/default/limine
    fi
    sudo limine-update
  elif [ -f /etc/default/grub ]; then
    if ! grep -q "${GPU_DRIVER}.max_vfs=${GPU_VF_COUNT}" /etc/default/grub 2>/dev/null; then
      sudo sed -i "s/\\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\\)\"/\\1 ${FULL_KERNEL_ARGS}\"/" /etc/default/grub
    fi
    case "$OS" in
      arch)           sudo grub-mkconfig -o /boot/grub/grub.cfg ;;
      ubuntu|proxmox) sudo update-grub ;;
      fedora)         sudo grub2-mkconfig -o /boot/grub2/grub.cfg ;;
    esac
  fi

  if [ -f /etc/tmpfiles.d/i915-set-sriov-numvfs.conf ]; then
    sudo sed -i "s|^#*w /sys/devices/pci0000:00/0000:00:02.0/sriov_numvfs.*|w /sys/devices/pci0000:00/0000:00:02.0/sriov_numvfs - - - - ${GPU_VF_COUNT}|" /etc/tmpfiles.d/i915-set-sriov-numvfs.conf
  else
    if ! grep -q "sriov_numvfs" /etc/sysfs.conf 2>/dev/null; then
      echo "devices/pci0000:00/0000:00:02.0/sriov_numvfs = ${GPU_VF_COUNT}" | sudo tee -a /etc/sysfs.conf >/dev/null
    fi
  fi

  echo "vfio-pci" | sudo tee /etc/modules-load.d/vfio.conf >/dev/null
  DEVICE_ID="$(cat /sys/devices/pci0000:00/0000:00:02.0/device 2>/dev/null | sed 's/^0x//')"
  [ -n "${DEVICE_ID:-}" ] || DEVICE_ID="a7a0"
  sudo tee /etc/udev/rules.d/99-i915-vf-vfio.rules >/dev/null <<EOF
ACTION=="add", SUBSYSTEM=="pci", KERNEL=="0000:00:02.[1-7]", ATTR{vendor}=="0x8086", ATTR{device}=="0x${DEVICE_ID}", DRIVER!="vfio-pci", RUN+="/bin/sh -c 'echo \$kernel > /sys/bus/pci/devices/\$kernel/driver/unbind; echo vfio-pci > /sys/bus/pci/devices/\$kernel/driver_override; modprobe vfio-pci; echo \$kernel > /sys/bus/pci/drivers/vfio-pci/bind'"
EOF

  case "$OS" in
    arch)           sudo mkinitcpio -P || true ;;
    ubuntu|proxmox) sudo update-initramfs -u || true ;;
    fedora)         sudo dracut --force || true ;;
  esac
  warn "Kernel args/SR-IOV host config updated. Reboot host before VF attach if VFs are not visible yet."
}

# =============================================================================
# Ubuntu autoinstall helpers
# =============================================================================

# Generate cloud-init user-data (autoinstall format) + empty meta-data
# Written to ${VM_CONF_DIR}/${VM_NAME}-seed/user-data
generate_autoinstall() {
  source_vm_conf
  local seed_dir="${VM_CONF_DIR}/${VM_NAME}-seed"
  mkdir -p "$seed_dir"

  info "Generating Ubuntu autoinstall user-data → ${seed_dir}/user-data"

  local pw_hash="${VM_PASSWORD_HASH:-}"
  if [ -z "$pw_hash" ]; then
    warn "VM_PASSWORD_HASH not set — using default password 'changeme123'. Change after first login!"
    pw_hash="$(openssl passwd -6 'changeme123' 2>/dev/null || echo '\$6\$invalid')"
  fi

  cat > "${seed_dir}/user-data" <<EOF
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: ${VM_HOSTNAME}
    username: ${VM_USER}
    password: '${pw_hash}'
  ssh:
    install-server: true
    allow-pw: true
    authorized-keys: []
  storage:
    layout:
      name: lvm
  packages:
    - openssh-server
    - curl
    - wget
    - net-tools
  late-commands:
    - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /target/etc/ssh/sshd_config
  user-data:
    disable_root: false
EOF

  # meta-data must exist (can be empty for nocloud)
  : > "${seed_dir}/meta-data"

  ok "Autoinstall user-data written to ${seed_dir}/user-data"
}

# Create seed ISO (labeled 'cidata') from user-data + meta-data
create_seed_iso() {
  source_vm_conf
  local seed_dir="${VM_CONF_DIR}/${VM_NAME}-seed"
  local seed_iso="${VM_CONF_DIR}/${VM_NAME}-seed.iso"

  [ -f "${seed_dir}/user-data" ] || { warn "user-data missing — run generate_autoinstall first"; return 1; }

  # Ensure xorriso available (install if not)
  if ! command -v xorriso &>/dev/null; then
    info "Installing xorriso for seed ISO creation..."
    case "$OS" in
      arch)    sudo pacman -S --noconfirm --needed xorriso ;;
      ubuntu)  sudo apt-get install -y xorriso ;;
      fedora)  sudo dnf install -y xorriso ;;
      proxmox) sudo apt-get install -y xorriso ;;
    esac
  fi

  info "Creating seed ISO → ${seed_iso}"
  xorriso -as mkisofs \
    -output "${seed_iso}" \
    -volid "cidata" \
    -joliet -rock \
    "${seed_dir}/" 2>/dev/null
  ok "Seed ISO created: ${seed_iso}"
  # Update VM_CONF with the seed ISO path
  sed -i "s|^VM_SEED_ISO=.*|VM_SEED_ISO=\"${seed_iso}\"|" "$VM_CONF" || true
}

create_vm() {
  section "Create VM"
  source_vm_conf

  sudo mkdir -p "$(dirname "$VM_DISK_PATH")" "$SHARED_DIR"
  sudo chown -R "${CURRENT_USER}:${CURRENT_USER}" "$SHARED_DIR"
  sudo virsh net-autostart default >/dev/null 2>&1 || true
  sudo virsh net-start default >/dev/null 2>&1 || true

  if sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    ok "VM '${VM_NAME}' already exists. Skipping virt-install."
  else
    # ── Generate autoinstall seed if enabled ──────────────────────────────────
    local extra_args="" seed_disk_arg=""
    if [ "${VM_AUTOINSTALL:-yes}" = "yes" ]; then
      generate_autoinstall
      create_seed_iso
      source_vm_conf  # reload to pick up VM_SEED_ISO
      seed_disk_arg="--disk path=${VM_SEED_ISO},device=cdrom,readonly=on,format=raw"
      # Ubuntu 24.04 server: kernel/initrd live at casper/ in the ISO
      # autoinstall + ds=nocloud picks up seed ISO labeled 'cidata'
      extra_args="autoinstall ds=nocloud;s=/cidata/ console=ttyS0,115200n8 quiet ---"
      info "Ubuntu autoinstall enabled — installation will run unattended (~10-15 min)"
    fi

    # Machine type must be pc (i440fx) for legacy IGD passthrough — NOT q35
    # --location extracts kernel/initrd from ISO for extra-args injection
    # shellcheck disable=SC2086
    sudo virt-install \
      --name "$VM_NAME" \
      --memory "$VM_RAM_MB" \
      --vcpus "$VM_VCPUS" \
      --cpu "${VM_CPU_MODEL:-host-passthrough}" \
      --machine "${VM_MACHINE_TYPE:-pc}" \
      --boot "${VM_FIRMWARE:-uefi}" \
      --disk "path=${VM_DISK_PATH},size=${VM_DISK_GB},format=${VM_DISK_FORMAT:-qcow2},bus=${VM_DISK_BUS:-virtio}" \
      --os-variant "$VM_OS_VARIANT" \
      --network "network=${VM_NET_SOURCE:-default},model=${VM_NET_MODEL:-virtio}" \
      --graphics "${VM_GRAPHICS:-none}" \
      --video "${VM_VIDEO:-none}" \
      --console "${VM_CONSOLE:-pty,target_type=serial}" \
      --location "${VM_ISO_PATH},kernel=casper/vmlinuz,initrd=casper/initrd" \
      ${seed_disk_arg} \
      ${extra_args:+--extra-args "$extra_args"} \
      --noautoconsole

    if [ "${VM_AUTOINSTALL:-yes}" = "yes" ]; then
      ok "VM created with autoinstall. Ubuntu is installing unattended."
      info "Monitor progress:  sudo virsh console ${VM_NAME}  (exit: Ctrl+])"
      info "Phase 3 will wait for SSH automatically once installation completes."
    else
      ok "VM created. Complete Ubuntu installer via: sudo virsh console ${VM_NAME}"
    fi
  fi

  # ── virtiofs shared storage ────────────────────────────────────────────────
  TMP_VIRTIOFS_XML="/tmp/${VM_NAME}-virtiofs.xml"
  cat > "$TMP_VIRTIOFS_XML" <<EOF
<filesystem type='mount' accessmode='passthrough'>
  <driver type='virtiofs'/>
  <source dir='${SHARED_DIR}'/>
  <target dir='${SHARED_TAG}'/>
</filesystem>
EOF
  sudo virsh attach-device "$VM_NAME" "$TMP_VIRTIOFS_XML" --config >/dev/null 2>&1 || true

  # ── GPU SR-IOV VF passthrough ──────────────────────────────────────────────
  if [ "${GPU_PASSTHROUGH:-no}" = "yes" ] && [ -f "${GPU_ROM_PATH:-/usr/share/kvm/igd.rom}" ]; then
    # NEVER pass the PF (00:02.0) — only VF (00:02.1)
    PF_DOMAIN="${GPU_PCI_ID%%:*}"
    PF_BUS="${GPU_PCI_ID#*:}"; PF_BUS="${PF_BUS%%:*}"
    PF_SLOT_FN="${GPU_PCI_ID##*:}"; PF_SLOT="${PF_SLOT_FN%%.*}"
    VF_FUNCTION="1"

    TMP_VF_XML="/tmp/${VM_NAME}-vf.xml"
    cat > "$TMP_VF_XML" <<EOF
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x${PF_DOMAIN}' bus='0x${PF_BUS}' slot='0x${PF_SLOT}' function='0x${VF_FUNCTION}'/>
  </source>
  <rom file='${GPU_ROM_PATH}'/>
  <alias name='hostpci0'/>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x0'/>
</hostdev>
EOF
    sudo virsh attach-device "$VM_NAME" "$TMP_VF_XML" --config >/dev/null 2>&1 \
      || warn "Could not attach VF yet — reboot host first if SR-IOV VFs are not visible."

    if [ "${GPU_IGD_LPC:-no}" = "yes" ]; then
      if command -v virt-xml >/dev/null 2>&1; then
        sudo virt-xml "$VM_NAME" --edit --qemu-commandline='-set device.hostpci0.x-igd-lpc=on' 2>/dev/null \
          || warn "Could not auto-add x-igd-lpc. Add manually: virsh edit ${VM_NAME}"
      else
        warn "Add x-igd-lpc manually (required for Alder Lake+):"
        warn "  sudo virsh edit ${VM_NAME}"
        warn "  Add: <qemu:commandline><qemu:arg value='-set'/><qemu:arg value='device.hostpci0.x-igd-lpc=on'/></qemu:commandline>"
      fi
    fi
  elif [ "${GPU_PASSTHROUGH:-no}" = "yes" ]; then
    warn "ROM file not found at ${GPU_ROM_PATH:-/usr/share/kvm/igd.rom} — skipping GPU passthrough."
  fi

  sudo virsh autostart "$VM_NAME"
  ok "VM autostart enabled."
}

write_state() {
  local state="${VM_CONF_DIR}/.state"
  mkdir -p "$VM_CONF_DIR"
  cat > "$state" <<EOF
# Auto-generated by phase scripts — do not edit manually
LAST_VM_CONF="${VM_CONF}"
LAST_VM_NAME="${VM_NAME}"
PHASE1_DONE="yes"
PHASE2_DONE="yes"
PHASE3_DONE="no"
EOF
  chown "${CURRENT_USER}:${CURRENT_USER}" "$state"
}

# Quick non-blocking SSH test — just checks TCP port 22 reachable (no auth needed)
VM_SSH_RESULT="not tested"
VM_SSH_IP=""
test_vm_ssh() {
  section "Confirming VM SSH (waiting for Ubuntu install to complete)"
  source_vm_conf

  local vm_ip="${VM_STATIC_IP%/*}"
  local max=180  # up to 15 min for autoinstall
  [ "${VM_AUTOINSTALL:-yes}" != "yes" ] && max=12  # 1 min if manual (already confirmed)

  info "Polling SSH at ${VM_USER}@${vm_ip} (up to $(( max * 5 / 60 )) min)..."
  if [ "${VM_AUTOINSTALL:-yes}" = "yes" ]; then
    info "Optional — watch progress: sudo virsh console ${VM_NAME}  (exit: Ctrl+])"
  fi

  local attempts=0
  while [ $attempts -lt $max ]; do
    # Prefer DHCP IP until static is assigned
    local cur_ip="$vm_ip"
    local dhcp; dhcp="$(virsh domifaddr "$VM_NAME" 2>/dev/null \
      | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1 || true)"
    [ -n "${dhcp:-}" ] && cur_ip="$dhcp"

    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 -o BatchMode=yes \
           "${VM_USER}@${cur_ip}" true 2>/dev/null; then
      echo ""
      VM_SSH_IP="$cur_ip"
      VM_SSH_RESULT="✓  ${VM_USER}@${cur_ip}"
      ok "VM SSH confirmed: ssh ${VM_USER}@${cur_ip}"
      # Save confirmed IP to state
      local state="${VM_CONF_DIR}/.state"
      [ -f "$state" ] && sed -i "s|^VM_SSH_IP=.*||" "$state" || true
      echo "VM_SSH_IP=\"${cur_ip}\"" >> "$state"
      return
    fi
    (( attempts++ ))
    if (( attempts % 12 == 0 )); then
      local elapsed=$(( attempts * 5 / 60 ))
      local vm_state; vm_state="$(virsh domstate "$VM_NAME" 2>/dev/null || echo unknown)"
      printf "\r  [%d min] VM state: %-12s  waiting for SSH...    " "$elapsed" "$vm_state"
    else
      printf "\r  Waiting for SSH... (%d/%d)    " "$attempts" "$max"
    fi
    sleep 5
  done
  echo ""
  VM_SSH_IP="$vm_ip"
  VM_SSH_RESULT="not yet reachable (check with: virsh console ${VM_NAME})"
  warn "VM SSH not confirmed after $(( max * 5 / 60 )) min — Phase 3 will retry automatically."
}

print_summary() {
  source_vm_conf
  local HOST_IP; HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  local VM_IP; VM_IP="${VM_STATIC_IP%/*}"

  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║                    PHASE 2 COMPLETE ✓                       ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "${BOLD}  ── VM Configuration ──────────────────────────────────────${RESET}"
  printf "  %-18s %s\n" "Name:"        "$VM_NAME"
  printf "  %-18s %s\n" "Hostname:"    "$VM_HOSTNAME"
  printf "  %-18s %s\n" "User:"        "$VM_USER"
  printf "  %-18s %s vCPU  /  %s MB RAM\n" "Resources:" "$VM_VCPUS" "$VM_RAM_MB"
  printf "  %-18s %s  (%s GB,  %s)\n"  "Disk:" "$VM_DISK_PATH" "$VM_DISK_GB" "$VM_DISK_FORMAT"
  printf "  %-18s %s  (machine=%s, firmware=%s)\n" "Machine:" "$VM_CPU_MODEL" "$VM_MACHINE_TYPE" "$VM_FIRMWARE"
  printf "  %-18s %s\n" "OS Variant:"  "$VM_OS_VARIANT"
  echo ""
  echo -e "${BOLD}  ── Network ─────────────────────────────────────────────────${RESET}"
  printf "  %-18s %s  (physical LAN)\n"       "Host IP:"    "$HOST_IP"
  printf "  %-18s %s  (libvirt NAT)\n"        "VM IP:"      "$VM_IP"
  printf "  %-18s %s → %s\n"                  "Shared:"     "$SHARED_DIR" "$SHARED_TAG"
  echo ""
  echo -e "${BOLD}  ── GPU Passthrough ─────────────────────────────────────────${RESET}"
  printf "  %-18s %s  (driver: %s, gen %s)\n" "GPU:"        "$GPU_PCI_ID" "$GPU_DRIVER" "$GPU_GEN"
  printf "  %-18s %s  (x-igd-lpc=%s)\n"       "VF count:"   "$GPU_VF_COUNT" "$GPU_IGD_LPC"
  printf "  %-18s %s\n"                        "ROM:"        "${GPU_ROM_PATH}"
  echo ""
  echo -e "${BOLD}  ── Cloudflare Tunnels ───────────────────────────────────────${RESET}"
  printf "  %-20s %s\n" "Host hostname:"   "${HOST_TUNNEL_HOST}"
  [ -n "${HOST_TUNNEL_NAME:-}" ] && printf "  %-20s %s\n" "Host tunnel name:" "${HOST_TUNNEL_NAME}"
  [ -n "${HOST_TUNNEL_ID:-}" ]   && printf "  %-20s %s\n" "Host tunnel ID:"   "${HOST_TUNNEL_ID}"
  printf "  %-20s %s\n" "Host connect:"    "ssh ${CURRENT_USER}@${HOST_TUNNEL_HOST}"
  echo ""
  printf "  %-20s %s\n" "VM hostname:"     "${VM_TUNNEL_HOST}"
  printf "  %-20s %s\n" "VM tunnel name:"  "${VM_TUNNEL_NAME}"
  printf "  %-20s %s\n" "VM connect:"      "ssh ${VM_USER}@${VM_TUNNEL_HOST}  (after phase 3)"
  echo ""
  echo -e "${BOLD}  ── Files ───────────────────────────────────────────────────${RESET}"
  printf "  %-18s %s\n" "VM conf:"       "$VM_CONF"
  printf "  %-18s %s\n" "State:"         "${VM_CONF_DIR}/.state"
  [ -f "${VM_CONF_DIR}/${VM_NAME}-seed.iso" ] && \
    printf "  %-18s %s\n" "Seed ISO:"    "${VM_CONF_DIR}/${VM_NAME}-seed.iso"
  echo ""
  echo -e "${BOLD}  ── Network Diagram ─────────────────────────────────────────${RESET}"
  echo "  Internet ──cloudflare──▶ Host ($HOST_IP)"
  echo "                               └──virbr0 NAT──▶ VM ($VM_IP)"
  echo "                                    VM tunnel: ${VM_TUNNEL_HOST}"
  echo ""
  echo -e "${BOLD}  ── VM Status ────────────────────────────────────────────────${RESET}"
  virsh list --all 2>/dev/null | sed 's/^/  /' || true
  echo ""
  echo -e "${BOLD}  ── SSH Access ───────────────────────────────────────────────${RESET}"
  printf "  %-20s %s\n" "SSH status:"   "${VM_SSH_RESULT:-not tested}"
  printf "  %-20s %s\n" "Direct (LAN):" "ssh ${VM_USER}@${VM_SSH_IP:-${VM_STATIC_IP%/*}}"
  echo ""
  echo -e "${BOLD}  ── SSH Access ───────────────────────────────────────────────${RESET}"
  printf "  %-20s %s\n" "SSH status:"  "${VM_SSH_RESULT:-not tested}"
  printf "  %-20s %s\n" "Direct (LAN):" "ssh ${VM_USER}@${VM_SSH_IP:-$VM_IP}"
  printf "  %-20s %s\n" "Via tunnel:"   "ssh ${VM_USER}@${VM_TUNNEL_HOST}  (after phase 3)"
  printf "  %-20s %s\n" "Console:"      "sudo virsh console ${VM_NAME}  (Ctrl+] to exit)"
  echo ""
  echo -e "${YELLOW}  ── Next Steps ───────────────────────────────────────────────${RESET}"
  if [ "${VM_AUTOINSTALL:-yes}" = "yes" ]; then
    echo "  Ubuntu is installing AUTOMATICALLY (unattended, ~10-15 min)."
    echo "  Optional — watch progress:  sudo virsh console ${VM_NAME}  (exit: Ctrl+])"
    echo ""
    echo "  Run Phase 3 when ready (it will wait for SSH automatically):"
  else
    echo "  1. Complete Ubuntu installer:"
    echo "       sudo virsh console ${VM_NAME}"
    echo ""
    echo "  2. Run Phase 3 after Ubuntu finishes:"
  fi
  echo "       sudo bash scripts/phase3.sh"
  echo "     or:"
  echo "       bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase3.sh)"
  echo ""
  echo "  Verify with:"
  echo "       bash scripts/check.sh"
  echo ""
  _snap_summary
}

# Snapper snapshot helper
SNAP_PRE_NUM=""
_snap_pre() {
  local desc="$1"
  if command -v snapper &>/dev/null && snapper list-configs 2>/dev/null | grep -q "^root"; then
    SNAP_PRE_NUM="$(snapper -c root create --type pre --cleanup-algorithm number \
      --print-number --description "$desc" 2>/dev/null || true)"
    [ -n "$SNAP_PRE_NUM" ] && ok "Snapper pre-snapshot #${SNAP_PRE_NUM}: ${desc}" \
                           || warn "Snapper available but snapshot failed"
  fi
}
_snap_post() {
  local desc="$1"
  if command -v snapper &>/dev/null && [ -n "${SNAP_PRE_NUM:-}" ]; then
    local post_num
    post_num="$(snapper -c root create --type post --pre-number "$SNAP_PRE_NUM" \
      --cleanup-algorithm number --print-number --description "$desc" 2>/dev/null || true)"
    [ -n "$post_num" ] && ok "Snapper post-snapshot #${post_num} (paired with #${SNAP_PRE_NUM})" \
                       || warn "Snapper post-snapshot failed"
    SNAP_POST_NUM="$post_num"
  fi
}
_snap_summary() {
  if [ -n "${SNAP_PRE_NUM:-}" ]; then
    echo -e "${BOLD}  ── Snapshots ────────────────────────────────────────────────${RESET}"
    echo "  Pre  : #${SNAP_PRE_NUM}"
    [ -n "${SNAP_POST_NUM:-}" ] && echo "  Post : #${SNAP_POST_NUM}"
    echo "  View : snapper list"
    echo "  Undo : snapper undochange ${SNAP_PRE_NUM}..${SNAP_POST_NUM:-${SNAP_PRE_NUM}}"
    echo ""
  fi
}

select_or_create_conf() {
  local state="${VM_CONF_DIR}/.state"
  # Load last state if present
  [ -f "$state" ] && source "$state" 2>/dev/null || true

  mapfile -t EXISTING < <(ls "${VM_CONF_DIR}"/*.conf 2>/dev/null || true)
  [ ${#EXISTING[@]} -eq 0 ] && return  # No existing confs — go straight to prompts

  echo ""
  echo -e "${BOLD}  Existing VM configurations:${RESET}"
  local i=1
  for f in "${EXISTING[@]}"; do
    local nm; nm="$(basename "$f" .conf)"
    local mark=""; [ "${f}" = "${LAST_VM_CONF:-}" ] && mark=" ${YELLOW}← last used${RESET}"
    echo -e "    $i) $nm  (${f})${mark}"
    (( i++ ))
  done
  echo "    $i) Create new VM"
  echo ""
  ask "Select configuration [1-$i, default=$i]: "; read -r _sel
  _sel="$(default_if_empty "$_sel" "$i")"

  if [ "$_sel" -ge 1 ] && [ "$_sel" -lt "$i" ] 2>/dev/null; then
    VM_CONF="${EXISTING[$(( _sel - 1 ))]}"
    source_vm_conf
    VM_CONF_DIR="$(dirname "$VM_CONF")"
    # Update VM_CONF path after loading VM_NAME
    VM_CONF="${VM_CONF_DIR}/${VM_NAME}.conf"
    info "Loaded: $VM_CONF"
    echo "  1) Use existing config as-is  (skip prompts)"
    echo "  2) Edit config  (re-run all prompts with existing values as defaults)"
    ask "Choice [1/2]: "; read -r _edit
    if [ "${_edit:-1}" = "1" ]; then
      SKIP_PROMPTS="yes"
    fi
  fi
}

main() {
  echo -e "${BOLD}"
  echo "╔══════════════════════════════════════════════╗"
  echo "║   Rev5.7.2 — Phase 2: VM Provision          ║"
  echo "║   CachyOS · Ubuntu · Fedora · Proxmox       ║"
  echo "╚══════════════════════════════════════════════╝"
  echo -e "${RESET}"

  [ "$EUID" -ne 0 ] && { warn "Re-running with sudo..."; exec sudo bash "$0" "$@"; }
  detect_os
  detect_user
  detect_system
  check_requirements

  confirm "Proceed with Phase 2 VM setup?" || exit 0

  SKIP_PROMPTS="no"
  select_or_create_conf

  _snap_pre "phase2 vm provision start"

  if [ "${SKIP_PROMPTS:-no}" = "no" ]; then
    prompt_resource_and_vm_basics
    prompt_disk_path
    prompt_iso
    prompt_network_and_share
    prompt_gpu
    prompt_rom
    prompt_tunnel
    write_vm_conf
  else
    ok "Using existing config: $VM_CONF"
  fi

  install_sriov_host
  create_vm
  write_state
  test_vm_ssh
  _snap_post "phase2 vm provision complete"
  print_summary
}

main "$@"
