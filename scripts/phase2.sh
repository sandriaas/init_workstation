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
VM_CONF="${REPO_DIR}/configs/vm.conf"

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
  local cfg host
  for cfg in "$USER_HOME/.cloudflared/config.yml" "${REPO_DIR}/configs/cloudflared-config.yml"; do
    if [ -f "$cfg" ]; then
      host="$(awk '/hostname:/{print $2; exit}' "$cfg")"
      if [ -n "${host:-}" ]; then
        HOST_TUNNEL_HOST="$host"
        HOST_TUNNEL_DOMAIN="${host#*.}"
        return
      fi
    fi
  done
  HOST_TUNNEL_HOST=""
  HOST_TUNNEL_DOMAIN="easyrentbali.com"
}

prompt_resource_and_vm_basics() {
  section "Step 1: VM Resources (RAM + CPU)"
  TOTAL_THREADS="$(nproc)"
  TOTAL_RAM_GB="$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)"

  VM_NAME_DEFAULT="server-vm"
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

  VM_NAME="$(default_if_empty "$VM_NAME" "$VM_NAME_DEFAULT")"
  VM_USER="$(default_if_empty "$VM_USER" "$VM_USER_DEFAULT")"
  VM_HOSTNAME="$(default_if_empty "$VM_HOSTNAME" "$VM_HOSTNAME_DEFAULT")"
  VM_VCPUS="$(default_if_empty "$VM_VCPUS" "$VM_VCPUS_DEFAULT")"
  VM_RAM_GB="$(default_if_empty "$VM_RAM_GB" "$VM_RAM_GB_DEFAULT")"
  VM_DISK_GB="$(default_if_empty "$VM_DISK_GB" "$VM_DISK_GB_DEFAULT")"

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
  VM_ISO_PATH_DEFAULT="${USER_HOME}/iso/ubuntu-24.04.3-live-server-amd64.iso"
  mkdir -p "${USER_HOME}/iso"

  echo "  1) Download now (Ubuntu 24.04 server ISO)"
  echo "  2) I already have ISO path"
  echo "  3) Enter a custom destination path"
  ask "Choice [1/2/3]: "; read -r ISO_CHOICE

  _download_iso() {
    local dest="$1"
    info "Downloading Ubuntu ISO to $dest"
    info "(supports resume — safe to Ctrl+C and rerun)"
    # Try wget first (handles redirects + resume cleanly), fall back to curl
    if command -v wget &>/dev/null; then
      wget --continue --show-progress --tries=5 --timeout=30 \
           -O "$dest" "$VM_ISO_URL"
    else
      curl -L --retry 5 --retry-delay 5 --retry-connrefused \
           -C - --progress-bar \
           -o "$dest" "$VM_ISO_URL"
    fi
  }

  case "${ISO_CHOICE:-1}" in
    1)
      VM_ISO_PATH="$VM_ISO_PATH_DEFAULT"
      if [ ! -f "$VM_ISO_PATH" ]; then
        _download_iso "$VM_ISO_PATH"
      else
        ok "ISO already exists: $VM_ISO_PATH"
      fi
      ;;
    2)
      ask "Existing ISO path: "; read -r VM_ISO_PATH
      [ -f "$VM_ISO_PATH" ] || { warn "ISO not found: $VM_ISO_PATH"; exit 1; }
      ;;
    3)
      ask "Destination ISO path: "; read -r VM_ISO_PATH
      if [ ! -f "$VM_ISO_PATH" ]; then
        _download_iso "$VM_ISO_PATH"
      fi
      ;;
    *)
      VM_ISO_PATH="$VM_ISO_PATH_DEFAULT"
      ;;
  esac
}

prompt_network_and_share() {
  section "Step 4: Network + Shared Folder"
  VM_STATIC_IP_DEFAULT="192.168.122.50/24"
  VM_GATEWAY_DEFAULT="192.168.122.1"
  VM_DNS_DEFAULT="1.1.1.1,8.8.8.8"
  SHARED_DIR_DEFAULT="${USER_HOME}/server-data"
  SHARED_TAG_DEFAULT="hostshare"

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
  echo "  1) Download now (auto curl from LongQT-sea/intel-igpu-passthru)"
  echo "  2) I already have the ROM file — specify path"
  ask "Choice [1/2]: "; read -r ROM_CHOICE

  case "${ROM_CHOICE:-1}" in
    2)
      ask "Path to ROM file: "; read -r USER_ROM_PATH
      if [ ! -f "$USER_ROM_PATH" ]; then
        warn "ROM file not found: $USER_ROM_PATH"; exit 1
      fi
      sudo mkdir -p /usr/share/kvm
      sudo cp "$USER_ROM_PATH" "$GPU_ROM_DEST"
      ;;
    *)
      if [ ! -f "$GPU_ROM_DEST" ]; then
        info "Downloading ${GPU_ROM_FILE} to ${GPU_ROM_DEST}..."
        sudo mkdir -p /usr/share/kvm
        sudo curl -fL "$GPU_ROM_URL" -o "$GPU_ROM_DEST"
      else
        ok "ROM already present: $GPU_ROM_DEST"
      fi
      ;;
  esac
  ok "ROM ready at ${GPU_ROM_DEST}"
}

prompt_tunnel() {
  section "Step 6: VM Tunnel Domain"
  detect_host_tunnel
  if [ -n "$HOST_TUNNEL_HOST" ]; then
    info "Detected host tunnel: ${HOST_TUNNEL_HOST}"
    echo "  1) Use detected domain: ${HOST_TUNNEL_DOMAIN}"
    echo "  2) Use another domain"
    ask "Choice [1/2]: "; read -r DOMAIN_CHOICE
    if [ "${DOMAIN_CHOICE:-1}" = "2" ]; then
      ask "Enter domain (e.g. example.com): "; read -r HOST_TUNNEL_DOMAIN
      ask "Enter host tunnel host (phase1 host): "; read -r HOST_TUNNEL_HOST
    fi
  else
    ask "No host tunnel detected. Enter domain (e.g. easyrentbali.com): "; read -r HOST_TUNNEL_DOMAIN
    HOST_TUNNEL_DOMAIN="$(default_if_empty "$HOST_TUNNEL_DOMAIN" "easyrentbali.com")"
    ask "Enter host tunnel host (phase1 host): "; read -r HOST_TUNNEL_HOST
  fi

  VM_TUNNEL_NAME_DEFAULT="${VM_NAME}-ssh"
  VM_TUNNEL_HOST_DEFAULT="vm-$(tr -dc a-z0-9 </dev/urandom | head -c 8).${HOST_TUNNEL_DOMAIN}"
  ask "VM tunnel name [${VM_TUNNEL_NAME_DEFAULT}]: "; read -r VM_TUNNEL_NAME
  ask "VM tunnel host [${VM_TUNNEL_HOST_DEFAULT}]: "; read -r VM_TUNNEL_HOST
  VM_TUNNEL_NAME="$(default_if_empty "$VM_TUNNEL_NAME" "$VM_TUNNEL_NAME_DEFAULT")"
  VM_TUNNEL_HOST="$(default_if_empty "$VM_TUNNEL_HOST" "$VM_TUNNEL_HOST_DEFAULT")"
}

write_vm_conf() {
  section "Writing configs/vm.conf"
  mkdir -p "${REPO_DIR}/configs"
  cat > "$VM_CONF" <<EOF
# Generated by scripts/phase2.sh
VM_NAME="${VM_NAME}"
VM_HOSTNAME="${VM_HOSTNAME}"
VM_USER="${VM_USER}"

VM_RAM_MB="${VM_RAM_MB}"
VM_VCPUS="${VM_VCPUS}"
VM_DISK_GB="${VM_DISK_GB}"
VM_DISK_PATH="${VM_DISK_PATH}"

VM_OS_VARIANT="${VM_OS_VARIANT}"
VM_ISO_PATH="${VM_ISO_PATH}"
VM_ISO_URL="${VM_ISO_URL}"

VM_STATIC_IP="${VM_STATIC_IP}"
VM_GATEWAY="${VM_GATEWAY}"
VM_DNS="${VM_DNS}"

SHARED_DIR="${SHARED_DIR}"
SHARED_TAG="${SHARED_TAG}"

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

HOST_TUNNEL_DOMAIN="${HOST_TUNNEL_DOMAIN}"
HOST_TUNNEL_HOST="${HOST_TUNNEL_HOST}"
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
    # Machine type must be pc (i440fx) for legacy IGD passthrough — NOT q35
    # OVMF/UEFI required per LongQT-sea/intel-igpu-passthru guide
    sudo virt-install \
      --name "$VM_NAME" \
      --memory "$VM_RAM_MB" \
      --vcpus "$VM_VCPUS" \
      --cpu host-passthrough \
      --machine pc \
      --boot uefi \
      --disk "path=${VM_DISK_PATH},size=${VM_DISK_GB},format=qcow2,bus=virtio" \
      --os-variant "$VM_OS_VARIANT" \
      --network network=default,model=virtio \
      --graphics none \
      --video none \
      --console pty,target_type=serial \
      --cdrom "$VM_ISO_PATH" \
      --noautoconsole
    ok "VM created. Complete Ubuntu installer via: sudo virsh console ${VM_NAME}"
  fi

  # virtiofs shared storage
  TMP_VIRTIOFS_XML="/tmp/${VM_NAME}-virtiofs.xml"
  cat > "$TMP_VIRTIOFS_XML" <<EOF
<filesystem type='mount' accessmode='passthrough'>
  <driver type='virtiofs'/>
  <source dir='${SHARED_DIR}'/>
  <target dir='${SHARED_TAG}'/>
</filesystem>
EOF
  sudo virsh attach-device "$VM_NAME" "$TMP_VIRTIOFS_XML" --config >/dev/null 2>&1 || true

  # GPU SR-IOV VF passthrough with ROM + x-igd-lpc (per LongQT-sea/intel-igpu-passthru)
  if [ "${GPU_PASSTHROUGH:-no}" = "yes" ] && [ -f "${GPU_ROM_PATH:-/usr/share/kvm/igd.rom}" ]; then
    # NEVER pass the PF (00:02.0) — only VF (00:02.1)
    # Parse VF PCI address from PF: 0000:00:02.0 → 0000:00:02.1
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

    # x-igd-lpc required for Ice Lake / Rocket Lake / Tiger Lake / Alder Lake and newer
    if [ "${GPU_IGD_LPC:-no}" = "yes" ]; then
      TMP_QEMU_XML="/tmp/${VM_NAME}-qemu-args.xml"
      cat > "$TMP_QEMU_XML" <<EOF
<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <qemu:commandline>
    <qemu:arg value='-set'/>
    <qemu:arg value='device.hostpci0.x-igd-lpc=on'/>
  </qemu:commandline>
</domain>
EOF
      # Merge qemu:commandline into existing VM XML
      EXISTING_XML="$(sudo virsh dumpxml "$VM_NAME")"
      if echo "$EXISTING_XML" | grep -q "qemu:commandline"; then
        ok "qemu:commandline already present in VM XML."
      else
        # virt-xml can append qemu args; fallback: instruct user
        if command -v virt-xml >/dev/null 2>&1; then
          sudo virt-xml "$VM_NAME" --edit --qemu-commandline='-set device.hostpci0.x-igd-lpc=on' 2>/dev/null \
            || warn "Could not auto-add x-igd-lpc arg. Add manually: virsh edit ${VM_NAME}"
        else
          warn "Add x-igd-lpc manually to VM XML (required for Alder Lake+):"
          warn "  sudo virsh edit ${VM_NAME}"
          warn "  Add inside <domain>:"
          warn "    <qemu:commandline><qemu:arg value='-set'/><qemu:arg value='device.hostpci0.x-igd-lpc=on'/></qemu:commandline>"
        fi
      fi
    fi
  elif [ "${GPU_PASSTHROUGH:-no}" = "yes" ]; then
    warn "ROM file not found at ${GPU_ROM_PATH:-/usr/share/kvm/igd.rom} — skipping GPU passthrough."
  fi

  sudo virsh autostart "$VM_NAME"
  ok "VM autostart enabled."
}

print_summary() {
  source_vm_conf
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║                    PHASE 2 COMPLETE                          ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo "VM Name:        $VM_NAME"
  echo "Disk:           $VM_DISK_PATH (${VM_DISK_GB}GB)"
  echo "vCPU/RAM:       ${VM_VCPUS} vCPU / ${VM_RAM_MB} MB"
  echo "VM Static IP:   $VM_STATIC_IP"
  echo "Shared Dir:     $SHARED_DIR -> $SHARED_TAG"
  echo "GPU Mode:       $GPU_DRIVER (${GPU_PASSTHROUGH})"
  echo "Host Tunnel:    ${HOST_TUNNEL_HOST:-not-set}"
  echo "VM Tunnel Host: $VM_TUNNEL_HOST"
  echo ""
  echo "Next:"
  echo "  1) Finish Ubuntu install if not done yet."
  echo "  2) Run Phase 3:"
  echo "     bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase3.sh)"
  echo ""
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
  prompt_resource_and_vm_basics
  prompt_disk_path
  prompt_iso
  prompt_network_and_share
  prompt_gpu
  prompt_rom
  prompt_tunnel
  write_vm_conf
  install_sriov_host
  create_vm
  print_summary
}

main "$@"
