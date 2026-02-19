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
  section "Step 0: VM Resources"
  TOTAL_THREADS="$(nproc)"
  TOTAL_RAM_GB="$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)"

  VM_NAME_DEFAULT="server-vm"
  VM_USER_DEFAULT="$CURRENT_USER"
  VM_HOSTNAME_DEFAULT="ubuntu-server"
  VM_VCPUS_DEFAULT="14"
  VM_RAM_GB_DEFAULT="8"
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
  section "Step 1: VM Disk Location"
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
  section "Step 2: Ubuntu ISO"
  VM_OS_VARIANT="ubuntu24.04"
  VM_ISO_URL="https://releases.ubuntu.com/24.04.3/ubuntu-24.04.3-live-server-amd64.iso"
  VM_ISO_PATH_DEFAULT="${USER_HOME}/iso/ubuntu-24.04.3-live-server-amd64.iso"
  mkdir -p "${USER_HOME}/iso"

  echo "  1) Download now (Ubuntu 24.04 server ISO)"
  echo "  2) I already have ISO path"
  echo "  3) Enter a custom destination path"
  ask "Choice [1/2/3]: "; read -r ISO_CHOICE

  case "${ISO_CHOICE:-1}" in
    1)
      VM_ISO_PATH="$VM_ISO_PATH_DEFAULT"
      if [ ! -f "$VM_ISO_PATH" ]; then
        info "Downloading Ubuntu ISO to $VM_ISO_PATH"
        curl -fL "$VM_ISO_URL" -o "$VM_ISO_PATH"
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
        info "Downloading Ubuntu ISO to $VM_ISO_PATH"
        curl -fL "$VM_ISO_URL" -o "$VM_ISO_PATH"
      fi
      ;;
    *)
      VM_ISO_PATH="$VM_ISO_PATH_DEFAULT"
      ;;
  esac
}

prompt_network_and_share() {
  section "Step 3: Network + Shared Dir"
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
  section "Step 4: Intel iGPU SR-IOV"
  echo "Select Intel CPU generation:"
  echo "  1  Sandy Bridge (2nd)"
  echo "  2  Ivy Bridge (3rd)"
  echo "  3  Haswell/Broadwell (4th/5th)"
  echo "  4  Skylake -> Comet Lake (6th-10th)"
  echo "  5  Coffee/Comet (8th-10th)"
  echo "  6  Gemini Lake"
  echo "  7  Ice Lake mobile (10th)"
  echo "  8  Rocket/Tiger/Alder/Raptor (11th-14th)  <- i9-12900H Intel Iris Xe"
  echo "  9  Meteor/Lunar Lake (xe driver path)"
  ask "Selection [8]: "; read -r GPU_GEN
  GPU_GEN="$(default_if_empty "$GPU_GEN" "8")"

  ask "Enable GPU passthrough SR-IOV? [Y/n]: "; read -r GPU_PASS_CHOICE
  if [[ "${GPU_PASS_CHOICE:-Y}" =~ ^[Nn]$ ]]; then
    GPU_PASSTHROUGH="no"
  else
    GPU_PASSTHROUGH="yes"
  fi

  ask "How many VFs? [7]: "; read -r GPU_VF_COUNT
  GPU_VF_COUNT="$(default_if_empty "$GPU_VF_COUNT" "7")"

  case "$GPU_GEN" in
    9)
      GPU_DRIVER="xe"
      GPU_ROM="N/A"
      KERNEL_GPU_ARGS="xe.max_vfs=${GPU_VF_COUNT} module_blacklist=i915"
      ;;
    *)
      GPU_DRIVER="i915"
      GPU_ROM="RKL_TGL_ADL_RPL_GOPv17_igd.rom"
      KERNEL_GPU_ARGS="i915.enable_guc=3 i915.max_vfs=${GPU_VF_COUNT} module_blacklist=xe"
      ;;
  esac

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

prompt_tunnel() {
  section "Step 5: Tunnel Domain"
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
GPU_ROM="${GPU_ROM}"

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
  [ "${GPU_PASSTHROUGH}" = "yes" ] || return 0
  section "Host SR-IOV Setup (${GPU_DRIVER})"

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
    sudo limine-install || true
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
    sudo virt-install \
      --name "$VM_NAME" \
      --memory "$VM_RAM_MB" \
      --vcpus "$VM_VCPUS" \
      --cpu host-passthrough \
      --disk "path=${VM_DISK_PATH},size=${VM_DISK_GB},format=qcow2,bus=virtio" \
      --os-variant "$VM_OS_VARIANT" \
      --network network=default,model=virtio \
      --graphics none \
      --console pty,target_type=serial \
      --cdrom "$VM_ISO_PATH" \
      --noautoconsole
    ok "VM created. Complete Ubuntu installer if prompted via console."
  fi

  TMP_VIRTIOFS_XML="/tmp/${VM_NAME}-virtiofs.xml"
  cat > "$TMP_VIRTIOFS_XML" <<EOF
<filesystem type='mount' accessmode='passthrough'>
  <driver type='virtiofs'/>
  <source dir='${SHARED_DIR}'/>
  <target dir='${SHARED_TAG}'/>
</filesystem>
EOF
  sudo virsh attach-device "$VM_NAME" "$TMP_VIRTIOFS_XML" --config >/dev/null 2>&1 || true

  if [ "$GPU_PASSTHROUGH" = "yes" ]; then
    VF_PCI="${GPU_PCI_ID%.*}.1"
    TMP_VF_XML="/tmp/${VM_NAME}-vf.xml"
    cat > "$TMP_VF_XML" <<EOF
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x${VF_PCI:0:4}' bus='0x${VF_PCI:5:2}' slot='0x${VF_PCI:8:2}' function='0x${VF_PCI:11:1}'/>
  </source>
</hostdev>
EOF
    sudo virsh attach-device "$VM_NAME" "$TMP_VF_XML" --config >/dev/null 2>&1 || warn "Could not attach VF ${VF_PCI} yet."
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

  confirm "Proceed with Phase 2 setup?" || exit 0
  prompt_resource_and_vm_basics
  prompt_disk_path
  prompt_iso
  prompt_network_and_share
  prompt_gpu
  prompt_tunnel
  write_vm_conf
  install_sriov_host
  create_vm
  print_summary
}

main "$@"
