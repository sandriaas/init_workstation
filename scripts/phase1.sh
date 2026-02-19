#!/usr/bin/env bash
# =============================================================================
# phase1.sh — Rev5.7.2 Phase 1: CachyOS Host Setup
# Supports: CachyOS/Arch · Ubuntu/Debian · Fedora · Proxmox
# Idempotent: safely re-run; already-done steps are skipped
# =============================================================================

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
section() { echo -e "\n${BOLD}══ $* ══${RESET}"; }
ask()     { echo -e "${YELLOW}[?]${RESET} $*"; }
confirm() { ask "$1 [Y/n]: "; read -r r; [[ "${r:-Y}" =~ ^[Yy]$ ]]; }
default_if_empty() { [ -n "${1:-}" ] && echo "$1" || echo "${2:-}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VM_CONF="${REPO_DIR}/configs/vm.conf"

# ─── Detect OS ───────────────────────────────────────────────────────────────
detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
      cachyos|arch|endeavouros|manjaro)     OS=arch ;;
      ubuntu|debian|pop|linuxmint)          OS=ubuntu ;;
      fedora|rhel|centos|rocky|almalinux)   OS=fedora ;;
      proxmox*)                             OS=proxmox ;;
      *) warn "Unknown OS: $ID — defaulting to ubuntu-style"; OS=ubuntu ;;
    esac
    OS_NAME="$PRETTY_NAME"
  else
    warn "Cannot detect OS"; OS=ubuntu; OS_NAME="Unknown"
  fi
  info "Detected OS: $OS_NAME ($OS)"
}

# ─── Detect current user (not root) ──────────────────────────────────────────
detect_user() {
  CURRENT_USER="${SUDO_USER:-$USER}"
  if [ "$CURRENT_USER" = "root" ]; then
    ask "Running as root. Enter the main username to configure: "; read -r CURRENT_USER
  fi
  USER_HOME=$(eval echo "~$CURRENT_USER")
  info "Target user: $CURRENT_USER (home: $USER_HOME)"
}

# ─── System detection + requirements ─────────────────────────────────────────
detect_system() {
  SYS_CPU="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || true)"
  SYS_RAM="$(free -h 2>/dev/null | awk '/^Mem/{print $2}' || true)"
  SYS_KERNEL="$(uname -r)"
  SYS_IGPU="$(lspci 2>/dev/null | grep -iE 'VGA|Display' | grep -i intel | head -1 | sed 's/.*: //' || true)"
  SYS_DGPU="$(lspci 2>/dev/null | grep -iE 'VGA|Display' | grep -iv intel | head -1 | sed 's/.*: //' || true)"
  SYS_DISKS="$(lsblk -d -o NAME,SIZE,MODEL --noheadings 2>/dev/null | grep -v loop | awk '{printf "%s(%s) ", $1,$2}' || true)"
  SYS_BOOT_MODE="$( [ -d /sys/firmware/efi ] && echo 'UEFI ✓' || echo 'Legacy/CSM ✗ (set UEFI-only in BIOS!)')"

  # Detect Intel CPU gen from model name (rough heuristic)
  SYS_CPU_GEN=""
  if echo "$SYS_CPU" | grep -qiE 'i[3579]-12[0-9]{3}|i[3579]-1[23][0-9]{3}H'; then
    SYS_CPU_GEN="12th gen Alder Lake (Iris Xe)"
  elif echo "$SYS_CPU" | grep -qiE 'i[3579]-13[0-9]{3}'; then
    SYS_CPU_GEN="13th gen Raptor Lake"
  elif echo "$SYS_CPU" | grep -qiE 'i[3579]-14[0-9]{3}'; then
    SYS_CPU_GEN="14th gen Raptor Lake Refresh"
  elif echo "$SYS_CPU" | grep -qiE 'i[3579]-1[01][0-9]{3}'; then
    SYS_CPU_GEN="10th/11th gen (Ice/Tiger Lake)"
  fi

  if ls /sys/class/iommu/ 2>/dev/null | grep -q .; then
    SYS_VTXD="VT-d active ✓"
  else
    SYS_VTXD="VT-d not yet visible (enable in BIOS, set IOMMU kernel args)"
  fi

  section "System Information"
  echo "  CPU     : ${SYS_CPU} ${SYS_CPU_GEN:+(${SYS_CPU_GEN})}"
  echo "  RAM     : ${SYS_RAM}"
  echo "  iGPU    : ${SYS_IGPU:-not detected}"
  [ -n "${SYS_DGPU}" ] && echo "  dGPU    : ${SYS_DGPU}"
  echo "  Storage : ${SYS_DISKS}"
  echo "  Kernel  : ${SYS_KERNEL}"
  echo "  Boot    : ${SYS_BOOT_MODE}"
  echo "  IOMMU   : ${SYS_VTXD}"

  # SR-IOV kernel compatibility check
  SRIOV_DKMS_BUILT="$(dkms status 2>/dev/null | grep "i915-sriov" | awk -F'[, ]+' '{print $2}' | head -1 || true)"
  if [ -n "${SRIOV_DKMS_BUILT:-}" ]; then
    if [ "${SRIOV_DKMS_BUILT}" = "${SYS_KERNEL}" ]; then
      echo "  SR-IOV  : i915-sriov-dkms built for running kernel ✓ (${SYS_KERNEL})"
    else
      echo "  SR-IOV  : ⚠ dkms built for ${SRIOV_DKMS_BUILT} — running ${SYS_KERNEL} (excluded, will boot ${SRIOV_DKMS_BUILT} after reboot)"
    fi
  else
    echo "  SR-IOV  : i915-sriov-dkms not installed (step 6 will install)"
  fi
}

check_requirements() {
  section "Requirements Check"
  echo "  Per LongQT-sea/intel-igpu-passthru + Rev5.7.2 guide:"
  echo ""

  local ok_count=0 warn_count=0

  # UEFI boot
  if [ -d /sys/firmware/efi ]; then
    echo -e "  ${GREEN}✓${RESET} UEFI boot mode"
    ok_count=$((ok_count+1))
  else
    echo -e "  ${YELLOW}✗${RESET} Legacy/CSM boot detected — BIOS: enable UEFI-only, disable Legacy/CSM"
    warn_count=$((warn_count+1))
  fi

  # Kernel version ≥ 6.8
  KVER_MAJOR="$(uname -r | cut -d. -f1)"
  KVER_MINOR="$(uname -r | cut -d. -f2)"
  if [ "$KVER_MAJOR" -gt 6 ] || { [ "$KVER_MAJOR" -eq 6 ] && [ "$KVER_MINOR" -ge 8 ]; }; then
    echo -e "  ${GREEN}✓${RESET} Kernel $(uname -r) ≥ 6.8"
    ok_count=$((ok_count+1))
  else
    echo -e "  ${YELLOW}✗${RESET} Kernel $(uname -r) < 6.8 — SR-IOV requires kernel 6.8+"
    warn_count=$((warn_count+1))
  fi

  # Intel iGPU present
  if lspci 2>/dev/null | grep -qi 'vga\|display' | grep -qi intel 2>/dev/null; then
    echo -e "  ${GREEN}✓${RESET} Intel iGPU detected"
    ok_count=$((ok_count+1))
  elif lspci 2>/dev/null | grep -iE 'VGA|Display' | grep -qi intel; then
    echo -e "  ${GREEN}✓${RESET} Intel iGPU detected"
    ok_count=$((ok_count+1))
  else
    echo -e "  ${YELLOW}✗${RESET} No Intel iGPU detected — ensure 'Primary Display = iGPU' in BIOS"
    warn_count=$((warn_count+1))
  fi

  # VT-d / IOMMU check via sysfs (works without root, unlike dmesg)
  if ls /sys/class/iommu/ 2>/dev/null | grep -q .; then
    echo -e "  ${GREEN}✓${RESET} VT-d/IOMMU active in kernel log"
    ok_count=$((ok_count+1))
  else
    echo -e "  ${YELLOW}!${RESET} VT-d not confirmed — BIOS: enable 'Intel VT-d (Virtualization for Directed I/O)'"
    warn_count=$((warn_count+1))
  fi

  # SR-IOV kernel compatibility
  SRIOV_COMPAT_KERNEL="$(dkms status 2>/dev/null | grep "i915-sriov" | awk -F'[, ]+' '{print $2}' | head -1 || true)"
  if [ -z "${SRIOV_COMPAT_KERNEL:-}" ]; then
    echo -e "  ${CYAN}i${RESET} i915-sriov-dkms: not yet installed (step 6)"
  elif [ "${SRIOV_COMPAT_KERNEL}" = "$(uname -r)" ]; then
    echo -e "  ${GREEN}✓${RESET} i915-sriov-dkms built for running kernel ($(uname -r))"
    ok_count=$((ok_count+1))
  else
    echo -e "  ${YELLOW}!${RESET} i915-sriov-dkms built for ${SRIOV_COMPAT_KERNEL}, running $(uname -r) — step 6 will set ${SRIOV_COMPAT_KERNEL} as default boot"
    warn_count=$((warn_count+1))
  fi

  echo ""
  echo "  Required BIOS/UEFI settings:"
  echo "    • UEFI-only boot (disable Legacy/CSM)"
  echo "    • VGA OpROM = UEFI"
  echo "    • Intel VT-d (IOMMU) = Enabled"
  echo "    • Initial/Primary display = IGD / iGPU / Integrated"
  echo ""
  echo "  VM requirements (handled by phase2/3):"
  echo "    • OVMF/UEFI firmware for guest"
  echo "    • Guest headless: SSH + Cloudflare tunnel via phase3.sh"
  echo ""

  if [ "$warn_count" -gt 0 ]; then
    warn "${warn_count} requirement(s) not met — review BIOS settings before running phase2."
    confirm "Continue anyway?" || { echo "Aborted. Fix BIOS settings and re-run."; exit 0; }
  else
    ok "All requirements met."
  fi
}

# ─── Helpers ─────────────────────────────────────────────────────────────────
confirm() { ask "$1 [Y/n]: "; read -r r; [[ "${r:-Y}" =~ ^[Yy]$ ]]; }

pkg_install() {
  case $OS in
    arch)           sudo pacman -S --noconfirm --needed "$@" ;;
    ubuntu|proxmox) sudo apt-get install -y "$@" ;;
    fedora)         sudo dnf install -y "$@" ;;
  esac
}

pkg_update() {
  case $OS in
    arch)           sudo pacman -Syu --noconfirm ;;
    ubuntu|proxmox) sudo apt-get update && sudo apt-get upgrade -y ;;
    fedora)         sudo dnf upgrade -y ;;
  esac
}

get_packages() {
  case $OS in
    arch)           echo "git base-devel curl wget htop net-tools openssh docker docker-compose cloudflared sysfsutils fail2ban lm_sensors websocat micro qemu-full libvirt virt-manager cockpit cockpit-machines dnsmasq" ;;
    ubuntu|proxmox) echo "git build-essential curl wget htop net-tools openssh-server docker.io docker-compose fail2ban lm-sensors qemu-kvm libvirt-daemon-system libvirt-clients virt-manager cockpit cockpit-machines dnsmasq-base bridge-utils" ;;
    fedora)         echo "git curl wget htop net-tools openssh-server docker docker-compose fail2ban lm_sensors qemu-kvm libvirt virt-install virt-manager cockpit cockpit-machines dnsmasq bridge-utils" ;;
  esac
}

# cloudflared: separate install for non-Arch (not in default repos)
install_cloudflared() {
  if command -v cloudflared &>/dev/null; then ok "cloudflared already installed"; return; fi
  info "Installing cloudflared..."
  case $OS in
    ubuntu|proxmox)
      curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
      echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
        | sudo tee /etc/apt/sources.list.d/cloudflared.list
      sudo apt-get update && sudo apt-get install -y cloudflared ;;
    fedora)
      curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-x86_64.rpm \
        -o /tmp/cloudflared.rpm && sudo rpm -i /tmp/cloudflared.rpm ;;
  esac
}

# websocat: separate install for non-Arch
install_websocat() {
  if command -v websocat &>/dev/null; then ok "websocat already installed"; return; fi
  info "Installing websocat..."
  case $OS in
    ubuntu|proxmox|fedora)
      curl -sL https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-musl \
        -o /usr/local/bin/websocat && chmod +x /usr/local/bin/websocat
      ok "websocat installed to /usr/local/bin/websocat" ;;
  esac
}

# =============================================================================
# STEP 1: Packages & Services
# =============================================================================
step_packages() {
  section "Step 1: Packages & Services"
  confirm "Update system and install required packages?" || { info "Skipped."; return; }

  pkg_update
  pkg_install $(get_packages)
  install_cloudflared   # no-op on Arch (already in get_packages)
  install_websocat      # no-op on Arch

  # Enable core services
  sudo systemctl enable --now sshd 2>/dev/null || sudo systemctl enable --now ssh 2>/dev/null || true
  sudo systemctl enable --now docker
  sudo systemctl enable --now fail2ban
  sudo systemctl enable --now libvirtd.socket 2>/dev/null || sudo systemctl enable --now libvirtd 2>/dev/null || true
  sudo systemctl enable --now cockpit.socket 2>/dev/null || true

  # Add user to required groups (active after reboot)
  for grp in docker libvirt kvm; do
    if getent group "$grp" >/dev/null 2>&1; then
      if ! groups "$CURRENT_USER" | grep -q "\\b${grp}\\b"; then
        sudo usermod -aG "$grp" "$CURRENT_USER"
        ok "Added $CURRENT_USER to $grp group (active after reboot)"
      else
        ok "$CURRENT_USER already in $grp group"
      fi
    fi
  done

  if command -v virsh >/dev/null 2>&1; then
    sudo virsh net-autostart default >/dev/null 2>&1 || true
    sudo virsh net-start default >/dev/null 2>&1 || true
    ok "libvirt default network ensured"
  fi

  command -v sensors-detect &>/dev/null && sudo sensors-detect --auto || true
  ok "Packages and services done."
}

# =============================================================================


# =============================================================================
# STEP 2: Disable System Sleep
# =============================================================================
step_sleep() {
  section "Step 2: Disable System Sleep"

  if systemctl is-masked sleep.target &>/dev/null; then
    ok "Sleep targets already masked. Skipping."; return
  fi

  confirm "Mask all sleep/suspend targets (server should never sleep)?" || { info "Skipped."; return; }
  sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
  ok "Sleep targets masked."
}

# =============================================================================
# STEP 3: Static IP
# =============================================================================
step_static_ip() {
  section "Step 3: Static IP"

  IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
  CURRENT_IP=$(ip addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -1)
  GW=$(ip route | awk '/default/{print $3}' | head -1)

  info "Interface: $IFACE | IP: ${CURRENT_IP:-none} | Gateway: ${GW:-unknown}"

  # Skip if already static via NetworkManager
  if command -v nmcli &>/dev/null; then
    NM_CON=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | grep "$IFACE" | cut -d: -f1 | head -1)
    NM_METHOD=$(nmcli con show "$NM_CON" 2>/dev/null | awk '/ipv4.method/{print $2}')
    if [ "$NM_METHOD" = "manual" ]; then
      ok "Static IP already set on '$NM_CON'. Skipping."; return
    fi
  fi

  # Skip if already static via Netplan
  if grep -r "dhcp4: no\|dhcp4: false" /etc/netplan/ 2>/dev/null | grep -q .; then
    ok "Static IP already set via Netplan. Skipping."; return
  fi

  confirm "Configure static IP? (Current: ${CURRENT_IP:-DHCP})" || { info "Skipped."; return; }

  echo ""
  echo "  Example: static 192.168.110.90/24 | gateway 192.168.110.1 | dns 1.1.1.1,8.8.8.8"
  echo ""
  ask "Static IP (e.g. 192.168.1.50): ";           read -r STATIC_IP
  ask "Gateway (detected: ${GW:-192.168.1.1}): ";  read -r STATIC_GW
  ask "DNS comma-separated (e.g. 1.1.1.1,8.8.8.8): "; read -r STATIC_DNS
  STATIC_GW="${STATIC_GW:-$GW}"; STATIC_DNS="${STATIC_DNS:-1.1.1.1,8.8.8.8}"
  PREFIX=$(echo "$CURRENT_IP" | grep -oP '/\d+' || echo "/24")
  [[ "$STATIC_IP" == */* ]] || STATIC_IP="${STATIC_IP}${PREFIX}"

  if command -v nmcli &>/dev/null; then
    NM_CON="${NM_CON:-Wired connection 1}"
    sudo nmcli con mod "$NM_CON" ipv4.method manual ipv4.addresses "$STATIC_IP" \
      ipv4.gateway "$STATIC_GW" ipv4.dns "$(echo "$STATIC_DNS" | tr ',' ' ')"
    sudo nmcli con up "$NM_CON"
    ok "Static IP set via NetworkManager: $STATIC_IP"
  elif [ -d /etc/netplan ]; then
    sudo tee /etc/netplan/99-static.yaml > /dev/null << EOF
network:
  ethernets:
    ${IFACE}:
      dhcp4: no
      addresses: [${STATIC_IP}]
      routes:
        - to: default
          via: ${STATIC_GW}
      nameservers:
        addresses: [$(echo "$STATIC_DNS" | sed 's/,/, /g')]
  version: 2
EOF
    sudo netplan apply
    ok "Static IP set via Netplan: $STATIC_IP"
  else
    warn "No NetworkManager or Netplan found — set static IP manually."
  fi
}

# =============================================================================
# STEP 4: SSH
# =============================================================================
step_ssh() {
  section "Step 4: SSH Setup"

  if ! systemctl is-active sshd &>/dev/null && ! systemctl is-active ssh &>/dev/null; then
    warn "sshd not running — was it enabled in Step 1?"; return
  fi

  ok "sshd is active."

  # Ensure password authentication is explicitly enabled
  sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  sudo sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config
  sudo systemctl reload sshd 2>/dev/null || sudo systemctl reload ssh 2>/dev/null || true
  ok "Password authentication enabled — connect with: ssh minipc (enter your login password)"
}

# =============================================================================
# STEP 5: Cloudflare SSH Tunnel
# =============================================================================
step_cloudflare_tunnel() {
  section "Step 5: Cloudflare SSH Tunnel"

  if systemctl is-active cloudflared &>/dev/null; then
    ok "cloudflared already active. Skipping."; return
  fi

  confirm "Set up Cloudflare SSH tunnel?" || { info "Skipped."; return; }

  if ! command -v cloudflared &>/dev/null; then
    warn "cloudflared not installed — run Step 1 first."; return
  fi

  echo ""
  info "You need: a Cloudflare account with your domain already added."
  echo ""
  ask "Tunnel hostname (e.g. abc123.yourdomain.com): "; read -r TUNNEL_HOST
  ask "Tunnel name (e.g. minipc-ssh): ";               read -r TUNNEL_NAME
  echo ""
  info "Choose authentication method:"
  echo "  1) Browser login (opens browser — recommended for first time)"
  echo "  2) API token    (headless/server — token from dash.cloudflare.com/profile/api-tokens)"
  ask "Choice [1/2]: "; read -r AUTH_CHOICE

  if [ "${AUTH_CHOICE:-1}" = "2" ]; then
    ask "Cloudflare API token: "; read -rs CF_TOKEN; echo ""
    ask "Cloudflare Account ID: "; read -r CF_ACCOUNT_ID
    # Write cert using API token (cloudflared uses TUNNEL_TOKEN env or cert.pem)
    export CLOUDFLARE_TUNNEL_TOKEN="$CF_TOKEN"
    sudo -u "$CURRENT_USER" CLOUDFLARE_API_TOKEN="$CF_TOKEN" cloudflared tunnel login --no-browser 2>/dev/null \
      || { info "Falling back to token-based route DNS (no login needed for named tunnels with API token)"; }
  else
    info "Opening Cloudflare browser login..."
    sudo -u "$CURRENT_USER" cloudflared login
  fi

  # Create tunnel
  info "Creating tunnel '$TUNNEL_NAME'..."
  TUNNEL_OUTPUT=$(sudo -u "$CURRENT_USER" cloudflared tunnel create "$TUNNEL_NAME" 2>&1)
  echo "$TUNNEL_OUTPUT"
  TUNNEL_ID=$(echo "$TUNNEL_OUTPUT" | grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)

  if [ -z "$TUNNEL_ID" ]; then
    warn "Could not parse tunnel ID — check output above."; return
  fi
  info "Tunnel ID: $TUNNEL_ID"

  # Write tunnel config
  CRED_FILE="$USER_HOME/.cloudflared/${TUNNEL_ID}.json"
  mkdir -p "$USER_HOME/.cloudflared"
  cat > "$USER_HOME/.cloudflared/config.yml" << EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CRED_FILE}
ingress:
  - hostname: ${TUNNEL_HOST}
    service: ssh://localhost:22
  - service: http_status:404
EOF
  chown "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.cloudflared/config.yml"

  # Create DNS CNAME record
  info "Creating DNS CNAME: $TUNNEL_HOST → tunnel..."
  if [ "${AUTH_CHOICE:-1}" = "2" ] && [ -n "${CF_TOKEN:-}" ]; then
    # Use API to create CNAME if we have a token
    ZONE_ID=$(curl -s "https://api.cloudflare.com/client/v4/zones?name=$(echo "$TUNNEL_HOST" | rev | cut -d. -f1-2 | rev)" \
      -H "Authorization: Bearer $CF_TOKEN" | python3 -c "import json,sys; print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null || echo "")
    if [ -n "$ZONE_ID" ]; then
      sudo -u "$CURRENT_USER" cloudflared tunnel route dns "$TUNNEL_NAME" "$TUNNEL_HOST" || true
    fi
  else
    sudo -u "$CURRENT_USER" cloudflared tunnel route dns "$TUNNEL_NAME" "$TUNNEL_HOST"
  fi

  # Install systemd service
  sudo tee /etc/systemd/system/cloudflared.service > /dev/null << EOF
[Unit]
Description=Cloudflare Tunnel — ${TUNNEL_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${CURRENT_USER}
ExecStart=/usr/bin/cloudflared --no-autoupdate --config ${USER_HOME}/.cloudflared/config.yml tunnel run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload && sudo systemctl enable --now cloudflared
  ok "Cloudflare tunnel '$TUNNEL_NAME' live at $TUNNEL_HOST"

  # Save hostname for final summary
  echo "$TUNNEL_HOST" > /tmp/phase1_tunnel_host
  echo "$CURRENT_USER" > /tmp/phase1_tunnel_user
}


# =============================================================================
# STEP 6: Intel iGPU SR-IOV + IOMMU (GPU gen, dkms, kernel args, bootloader)
# =============================================================================
step_sriov_host() {
  section "Step 6: Intel iGPU SR-IOV + IOMMU"

  # Load existing vm.conf if already done
  [ -f "$VM_CONF" ] && source "$VM_CONF" 2>/dev/null || true

  # Skip only if BOTH kernel args AND dkms module are already in place
  SRIOV_ARGS_SET=false
  SRIOV_DKMS_SET=false
  { grep -q "i915.max_vfs=" /etc/default/limine 2>/dev/null || \
    grep -q "i915.max_vfs=" /etc/default/grub 2>/dev/null; } && SRIOV_ARGS_SET=true
  { pacman -Q i915-sriov-dkms >/dev/null 2>&1 || \
    dpkg -s i915-sriov-dkms >/dev/null 2>&1 || \
    rpm -q akmod-i915-sriov >/dev/null 2>&1 || \
    dkms status 2>/dev/null | grep -q "i915.sriov\|i915-sriov"; } && SRIOV_DKMS_SET=true

  if $SRIOV_ARGS_SET && $SRIOV_DKMS_SET; then
    ok "SR-IOV kernel args + i915-sriov-dkms already in place. Skipping."
    return
  fi
  if $SRIOV_ARGS_SET && ! $SRIOV_DKMS_SET; then
    warn "Kernel args already set but i915-sriov-dkms is NOT installed — continuing to install dkms."
  fi

  confirm "Set up Intel iGPU SR-IOV (needed for GPU passthrough to VM)?" || { info "Skipped."; return; }

  echo "Select Intel CPU generation:"
  echo "  1   Sandy Bridge     (2nd)          Core i3/5/7 2xxx"
  echo "  2   Ivy Bridge       (3rd)          Core i3/5/7 3xxx"
  echo "  3   Haswell/BDW      (4th/5th)      Core i3/5/7/9 4xxx-5xxx"
  echo "  4   Skylake->CML     (6-10th)       Core i3/5/7/9 6xxx-10xxx"
  echo "  5   Coffee/Comet     (8-10th)       Core i3/5/7/9 8xxx-10xxx"
  echo "  6   Gemini Lake                     Pentium/Celeron J/N 4xxx/5xxx"
  echo "  7   Ice Lake mobile  (10th)         Core i3/5/7 10xxG1/G4/G7"
  echo "  8   Rocket/Tiger/Alder/Raptor       Core i3/5/7/9 11xxx-14xxx (desktop/mainstream)"
  echo "  9   Alder/Raptor Lake H/P/U mobile  Core i3/5/7/9 12xxx-14xxx H/P/U  <- i9-12900H"
  echo " 10   Jasper Lake                     Pentium/Celeron N 4xxx/5xxx/6xxx"
  echo " 11   Alder Lake-N / Twin Lake        N-series"
  echo " 12   Arrow/Meteor Lake               Core Ultra (i915)"
  echo " 13   Lunar Lake                      Core Ultra 2xx (i915)"
  ask "Selection [9]: "; read -r GPU_GEN
  GPU_GEN="$(default_if_empty "$GPU_GEN" "9")"
  ask "How many VFs? [7]: "; read -r GPU_VF_COUNT
  GPU_VF_COUNT="$(default_if_empty "$GPU_VF_COUNT" "7")"

  case "$GPU_GEN" in
    1)  GPU_DRIVER="i915"; GPU_ROM_FILE="SNB_GOPv2_igd.rom";               GPU_IGD_LPC="no"  ;;
    2)  GPU_DRIVER="i915"; GPU_ROM_FILE="IVB_GOPv3_igd.rom";               GPU_IGD_LPC="no"  ;;
    3)  GPU_DRIVER="i915"; GPU_ROM_FILE="HSW_BDW_GOPv5_igd.rom";           GPU_IGD_LPC="no"  ;;
    4)  GPU_DRIVER="i915"; GPU_ROM_FILE="SKL_CML_GOPv9_igd.rom";           GPU_IGD_LPC="no"  ;;
    5)  GPU_DRIVER="i915"; GPU_ROM_FILE="CFL_CML_GOPv9.1_igd.rom";         GPU_IGD_LPC="no"  ;;
    6)  GPU_DRIVER="i915"; GPU_ROM_FILE="GLK_GOPv13_igd.rom";              GPU_IGD_LPC="no"  ;;
    7)  GPU_DRIVER="i915"; GPU_ROM_FILE="ICL_GOPv14_igd.rom";              GPU_IGD_LPC="yes" ;;
    8)  GPU_DRIVER="i915"; GPU_ROM_FILE="RKL_TGL_ADL_RPL_GOPv17_igd.rom";  GPU_IGD_LPC="yes" ;;
    9)  GPU_DRIVER="i915"; GPU_ROM_FILE="ADL-H_RPL-H_GOPv21_igd.rom";      GPU_IGD_LPC="yes" ;;
    10) GPU_DRIVER="i915"; GPU_ROM_FILE="JSL_GOPv18_igd.rom";              GPU_IGD_LPC="no"  ;;
    11) GPU_DRIVER="i915"; GPU_ROM_FILE="ADL-N_TWL_GOPv21_igd.rom";        GPU_IGD_LPC="yes" ;;
    12) GPU_DRIVER="i915"; GPU_ROM_FILE="ARL_MTL_GOPv22_igd.rom";          GPU_IGD_LPC="yes" ;;
    13) GPU_DRIVER="i915"; GPU_ROM_FILE="LNL_GOPv2X_igd.rom";              GPU_IGD_LPC="yes" ;;
    *)  GPU_DRIVER="i915"; GPU_ROM_FILE="ADL-H_RPL-H_GOPv21_igd.rom";      GPU_IGD_LPC="yes" ;;
  esac
  GPU_ROM_URL="https://github.com/LongQT-sea/intel-igpu-passthru/releases/download/v0.1/${GPU_ROM_FILE}"
  KERNEL_GPU_ARGS="i915.enable_guc=3 i915.max_vfs=${GPU_VF_COUNT} module_blacklist=xe"

  # Write GPU vars to vm.conf so phase2 picks them up without re-asking
  mkdir -p "${REPO_DIR}/configs"
  if [ -f "$VM_CONF" ]; then
    # Update existing fields
    sed -i "s|^GPU_GEN=.*|GPU_GEN=\"${GPU_GEN}\"|"                 "$VM_CONF"
    sed -i "s|^GPU_VF_COUNT=.*|GPU_VF_COUNT=\"${GPU_VF_COUNT}\"|"  "$VM_CONF"
    sed -i "s|^GPU_DRIVER=.*|GPU_DRIVER=\"${GPU_DRIVER}\"|"        "$VM_CONF"
    sed -i "s|^GPU_ROM_FILE=.*|GPU_ROM_FILE=\"${GPU_ROM_FILE}\"|"   "$VM_CONF"
    sed -i "s|^GPU_ROM_URL=.*|GPU_ROM_URL=\"${GPU_ROM_URL}\"|"      "$VM_CONF"
    sed -i "s|^GPU_IGD_LPC=.*|GPU_IGD_LPC=\"${GPU_IGD_LPC}\"|"     "$VM_CONF"
    sed -i "s|^KERNEL_GPU_ARGS=.*|KERNEL_GPU_ARGS=\"${KERNEL_GPU_ARGS}\"|" "$VM_CONF"
  else
    # Create minimal vm.conf with GPU section only
    cat > "$VM_CONF" <<EOF
# vm.conf — generated by phase1.sh (GPU section only; phase2 fills the rest)
GPU_GEN="${GPU_GEN}"
GPU_VF_COUNT="${GPU_VF_COUNT}"
GPU_DRIVER="${GPU_DRIVER}"
GPU_ROM_FILE="${GPU_ROM_FILE}"
GPU_ROM_URL="${GPU_ROM_URL}"
GPU_ROM_PATH="\${HOME}/igd.rom"
GPU_IGD_LPC="${GPU_IGD_LPC}"
GPU_PASSTHROUGH="yes"
KERNEL_GPU_ARGS="${KERNEL_GPU_ARGS}"
EOF
  fi
  ok "GPU config saved to vm.conf"

  # 1. Install i915-sriov-dkms (module must exist before kernel args reference it)
  info "Installing i915-sriov-dkms on host..."
  case "$OS" in
    arch)
      if command -v paru >/dev/null 2>&1; then
        sudo -u "$CURRENT_USER" paru -S --noconfirm --needed i915-sriov-dkms || warn "AUR install failed; install i915-sriov-dkms manually."
      else
        warn "paru not found. Install i915-sriov-dkms from AUR manually."
      fi
      ;;
    fedora)
      sudo dnf -y copr enable matte23/akmods || warn "Could not enable COPR"
      sudo dnf install -y akmod-i915-sriov || warn "Could not install akmod-i915-sriov"
      sudo akmods --force || true; sudo depmod -a || true
      ;;
    ubuntu|proxmox)
      if ! dpkg -s i915-sriov-dkms >/dev/null 2>&1; then
        local_url="$(curl -fsSL https://api.github.com/repos/strongtz/i915-sriov-dkms/releases/latest \
          | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(a["browser_download_url"] for a in d["assets"] if a["name"].endswith("_amd64.deb")))' 2>/dev/null || true)"
        if [ -n "${local_url:-}" ]; then
          curl -fL "$local_url" -o /tmp/i915-sriov-dkms_latest_amd64.deb
          sudo dpkg -i /tmp/i915-sriov-dkms_latest_amd64.deb || sudo apt-get install -f -y
        else
          warn "Could not resolve i915-sriov-dkms .deb URL; install manually."
        fi
      fi
      ;;
  esac

  # Check if dkms built for running kernel — if excluded, set compatible kernel as default boot
  RUNNING_KERNEL="$(uname -r)"
  if ! dkms status 2>/dev/null | grep -q "i915-sriov.*${RUNNING_KERNEL}"; then
    # Find a kernel the module DID build for
    COMPAT_KERNEL="$(dkms status 2>/dev/null | grep "i915-sriov" | awk -F'[, ]+' '{print $2}' | head -1)"
    if [ -n "${COMPAT_KERNEL:-}" ]; then
      warn "i915-sriov-dkms is NOT built for running kernel (${RUNNING_KERNEL})."
      warn "It is built for: ${COMPAT_KERNEL} — SR-IOV requires booting that kernel."
      warn "The system will be configured to boot ${COMPAT_KERNEL} by default."
      if [ -f /etc/default/limine ]; then
        # Derive Limine entry name from kernel version: strip distro suffix after last '-'
        # e.g. 6.18.12-2-cachyos-lts → linux-cachyos-lts; fallback to *lts if name contains lts
        if echo "$COMPAT_KERNEL" | grep -qi "lts"; then
          LIMINE_ENTRY="*lts"
        else
          # Use kernel package name by stripping version prefix
          LIMINE_ENTRY="*$(echo "$COMPAT_KERNEL" | sed 's/^[0-9.-]*-[0-9]*-//')"
        fi
        if ! grep -q "^DEFAULT_ENTRY=" /etc/default/limine 2>/dev/null; then
          echo "DEFAULT_ENTRY=\"${LIMINE_ENTRY}\"" | sudo tee -a /etc/default/limine >/dev/null
        else
          sudo sed -i "s|^DEFAULT_ENTRY=.*|DEFAULT_ENTRY=\"${LIMINE_ENTRY}\"|" /etc/default/limine
        fi
        sudo limine-update
        ok "Limine default boot set to: ${LIMINE_ENTRY} (kernel ${COMPAT_KERNEL})."
      elif [ -f /etc/default/grub ]; then
        # GRUB: set GRUB_DEFAULT to the exact menuentry matching the compat kernel
        # Find the menuentry index by grepping grub.cfg for the kernel version
        GRUB_CFG="/boot/grub/grub.cfg"
        [ -f /boot/grub2/grub.cfg ] && GRUB_CFG="/boot/grub2/grub.cfg"
        GRUB_IDX="$(grep -n "menuentry\|linux.*${COMPAT_KERNEL}" "$GRUB_CFG" 2>/dev/null \
          | grep "linux.*${COMPAT_KERNEL}" | head -1 | cut -d: -f1 || true)"
        if [ -n "${GRUB_IDX:-}" ]; then
          sudo sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"${COMPAT_KERNEL}\"|" /etc/default/grub
          case "$OS" in
            arch)           sudo grub-mkconfig -o /boot/grub/grub.cfg ;;
            ubuntu|proxmox) sudo update-grub ;;
            fedora)         sudo grub2-mkconfig -o /boot/grub2/grub.cfg ;;
          esac
          ok "GRUB default boot set to kernel: ${COMPAT_KERNEL}."
        else
          warn "Could not auto-set GRUB default — set GRUB_DEFAULT manually to: ${COMPAT_KERNEL}"
        fi
      elif [ -d /boot/loader/entries ]; then
        # systemd-boot: set the default entry to the matching .conf file
        SD_ENTRY="$(grep -rl "${COMPAT_KERNEL}" /boot/loader/entries/ 2>/dev/null | head -1 | xargs basename 2>/dev/null || true)"
        if [ -n "${SD_ENTRY:-}" ]; then
          sudo sed -i "s|^default .*|default ${SD_ENTRY}|" /boot/loader/loader.conf 2>/dev/null || \
            echo "default ${SD_ENTRY}" | sudo tee /boot/loader/loader.conf >/dev/null
          ok "systemd-boot default set to: ${SD_ENTRY}"
        else
          warn "Could not auto-set systemd-boot default — set 'default' in /boot/loader/loader.conf manually."
        fi
      else
        warn "Unknown bootloader — manually set default kernel to: ${COMPAT_KERNEL}"
      fi
      warn "⚠  SR-IOV NOTE: After reboot you will run ${COMPAT_KERNEL}. SR-IOV will be active."
      warn "   i915-sriov-dkms BUILD_EXCLUSIVE_KERNEL excludes kernel ${RUNNING_KERNEL}."
      warn "   See: https://github.com/strongtz/i915-sriov-dkms for supported kernel range."
    else
      warn "i915-sriov-dkms built for no kernel yet — check 'dkms status' after reboot."
    fi
  fi
  echo "vfio-pci" | sudo tee /etc/modules-load.d/vfio.conf >/dev/null
  DEVICE_ID="$(cat /sys/devices/pci0000:00/0000:00:02.0/device 2>/dev/null | sed 's/^0x//' || echo "a7a0")"
  sudo tee /etc/udev/rules.d/99-i915-vf-vfio.rules >/dev/null <<EOF
ACTION=="add", SUBSYSTEM=="pci", KERNEL=="0000:00:02.[1-7]", ATTR{vendor}=="0x8086", ATTR{device}=="0x${DEVICE_ID}", DRIVER!="vfio-pci", RUN+="/bin/sh -c 'echo \$kernel > /sys/bus/pci/devices/\$kernel/driver/unbind; echo vfio-pci > /sys/bus/pci/devices/\$kernel/driver_override; modprobe vfio-pci; echo \$kernel > /sys/bus/pci/drivers/vfio-pci/bind'"
EOF

  # 3. Enable VF creation at boot via sysfs/tmpfiles
  if [ -f /etc/tmpfiles.d/i915-set-sriov-numvfs.conf ]; then
    sudo sed -i "s|^#*w /sys/devices/pci0000:00/0000:00:02.0/sriov_numvfs.*|w /sys/devices/pci0000:00/0000:00:02.0/sriov_numvfs - - - - ${GPU_VF_COUNT}|" \
      /etc/tmpfiles.d/i915-set-sriov-numvfs.conf
  else
    if ! grep -q "sriov_numvfs" /etc/sysfs.conf 2>/dev/null; then
      echo "devices/pci0000:00/0000:00:02.0/sriov_numvfs = ${GPU_VF_COUNT}" | sudo tee -a /etc/sysfs.conf >/dev/null
    fi
  fi

  # 4. Rebuild initramfs (includes new dkms module + vfio)
  case "$OS" in
    arch)           sudo mkinitcpio -P || true ;;
    ubuntu|proxmox) sudo update-initramfs -u || true ;;
    fedora)         sudo dracut --force || true ;;
  esac

  # 5. Patch kernel args + regenerate bootloader (after initramfs is ready)
  if [ -f /etc/default/limine ]; then
    if ! grep -q "${GPU_DRIVER}.max_vfs=" /etc/default/limine 2>/dev/null; then
      sudo sed -i "s/\\(KERNEL_CMDLINE\\[[^]]*\\]+=\"[^\"]*\\)\"/\\1 ${KERNEL_GPU_ARGS}\"/g" /etc/default/limine
    fi
    sudo limine-update
    ok "Limine updated with SR-IOV args."
  elif [ -f /etc/default/grub ]; then
    if ! grep -q "${GPU_DRIVER}.max_vfs=" /etc/default/grub 2>/dev/null; then
      sudo sed -i "s/\\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\\)\"/\\1 ${KERNEL_GPU_ARGS}\"/" /etc/default/grub
    fi
    case "$OS" in
      arch)           sudo grub-mkconfig -o /boot/grub/grub.cfg ;;
      ubuntu|proxmox) sudo update-grub ;;
      fedora)         sudo grub2-mkconfig -o /boot/grub2/grub.cfg ;;
    esac
    ok "GRUB updated with SR-IOV args."
  fi

  ok "SR-IOV host setup done. VFs will be active after reboot."
}


print_final_summary() {
  # Try temp file first (written by step_cloudflare_tunnel if it ran this session)
  TUNNEL_HOST_SAVED=""
  [ -f /tmp/phase1_tunnel_host ] && TUNNEL_HOST_SAVED=$(cat /tmp/phase1_tunnel_host)

  # Fallback: parse from existing cloudflared config.yml
  if [ -z "$TUNNEL_HOST_SAVED" ]; then
    for cfg in "$USER_HOME/.cloudflared/config.yml" /etc/cloudflared/config.yml; do
      if [ -f "$cfg" ]; then
        TUNNEL_HOST_SAVED="$(awk '/hostname:/{print $NF; exit}' "$cfg" 2>/dev/null || true)"
        [ -n "$TUNNEL_HOST_SAVED" ] && break
      fi
    done
  fi

  TUNNEL_HOST_SAVED="${TUNNEL_HOST_SAVED:-YOUR_TUNNEL_HOST}"
  TUN_USER="${CURRENT_USER}"

  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║              PHASE 1 COMPLETE                               ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "${BOLD}Tunnel:${RESET} ${TUNNEL_HOST_SAVED}  ${BOLD}User:${RESET} ${TUN_USER}"
  echo ""
  echo -e "${BOLD}── On each client device (phone, laptop, etc.) ──${RESET}"
  echo ""
  echo -e "  bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase1-client.sh)"
  echo ""
  echo -e "  Then: ${GREEN}ssh minipc${RESET}"
  echo ""
  echo -e "${YELLOW}⚠  REBOOT REQUIRED to activate: IOMMU + SR-IOV + docker/libvirt groups${RESET}"
  echo ""
  echo -e "${BOLD}  Auto-start on boot (no login required):${RESET}"
  echo "    sshd      — enabled (systemd, starts before login)"
  echo "    cloudflared — enabled, After=network-online.target (auto-reconnects tunnel)"
  echo "    → After sudo reboot, SSH from phone reconnects automatically once network is up."
  echo ""
  echo "  After reboot verify:"
  echo "    cat /proc/cmdline | grep iommu           # → intel_iommu=on iommu=pt"
  echo "    cat /proc/cmdline | grep i915            # → i915.enable_guc=3 i915.max_vfs=7"
  echo "    lspci -nnk -s 00:02 | grep 'driver in use'  # → i915 on PF, vfio-pci on VFs"
  echo "    ls /dev/dri/                             # → card0/renderD128 (no VF render nodes yet)"
  echo "    docker run --rm hello-world"
  echo "    systemctl status cloudflared"
  echo ""
  rm -f /tmp/phase1_tunnel_host /tmp/phase1_tunnel_user
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  echo -e "${BOLD}"
  echo "╔══════════════════════════════════════════════╗"
  echo "║   Rev5.7.2 — Phase 1: Host Setup            ║"
  echo "║   CachyOS · Ubuntu · Fedora · Proxmox       ║"
  echo "╚══════════════════════════════════════════════╝"
  echo -e "${RESET}"

  # Re-run with sudo if not root
  [ "$EUID" -ne 0 ] && { warn "Re-running with sudo..."; exec sudo bash "$0" "$@"; }

  detect_os
  detect_user
  detect_system
  check_requirements

  echo ""
  info "Steps: packages → sleep → static IP → SSH → Cloudflare tunnel → iGPU SR-IOV+IOMMU"
  confirm "Proceed with Phase 1 setup?" || { echo "Aborted."; exit 0; }

  step_packages
  step_sleep
  step_static_ip
  step_ssh
  step_cloudflare_tunnel
  step_sriov_host
  print_final_summary
}

main "$@"
