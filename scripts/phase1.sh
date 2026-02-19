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
# STEP 2: IOMMU — Intel VT-d (KVM passthrough)
# =============================================================================
step_iommu() {
  section "Step 2: IOMMU Kernel Parameters"
  IOMMU_ARGS="intel_iommu=on iommu=pt i915.enable_guc=3 i915.max_vfs=7 module_blacklist=xe"

  # Skip only if full parameter set is active in running kernel
  if grep -q "intel_iommu=on" /proc/cmdline 2>/dev/null && grep -q "i915.max_vfs=" /proc/cmdline 2>/dev/null; then
    ok "IOMMU + SR-IOV args already active in running kernel. Skipping."; return
  fi

  confirm "Enable IOMMU + Intel SR-IOV args in bootloader?" || { info "Skipped."; return; }

  if [ -f /etc/default/limine ]; then
    info "Bootloader: Limine (CachyOS)"
    # Skip sed if already patched — prevents double-patch on re-run
    if grep -q "i915.max_vfs=" /etc/default/limine; then
      ok "Already patched in /etc/default/limine — regenerating bootloader only..."
    else
      sudo cp /etc/default/limine /etc/default/limine.bak
      # Patch ALL KERNEL_CMDLINE entries (default + any named kernels e.g. lts, zen, hardened)
      sudo sed -i "s/\\(KERNEL_CMDLINE\\[[^]]*\\]+=\"[^\"]*\\)\"/\\1 ${IOMMU_ARGS}\"/g" /etc/default/limine
    fi
    sudo limine-install
    ok "Limine updated — applied to all kernel entries. Active after reboot."

  elif [ -f /etc/default/grub ]; then
    info "Bootloader: GRUB"
    if grep -q "i915.max_vfs=" /etc/default/grub; then
      ok "Already patched in /etc/default/grub — regenerating only..."
    else
      sudo cp /etc/default/grub /etc/default/grub.bak
      sudo sed -i "s/\\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\\)\"/\\1 ${IOMMU_ARGS}\"/" /etc/default/grub
    fi
    case $OS in
      arch)           sudo grub-mkconfig -o /boot/grub/grub.cfg ;;
      ubuntu|proxmox) sudo update-grub ;;
      fedora)         sudo grub2-mkconfig -o /boot/grub2/grub.cfg ;;
    esac
    ok "GRUB updated. Active after reboot."

  elif [ -d /boot/loader/entries ]; then
    # Patch all entry .conf files in /boot/loader/entries/
    info "Bootloader: systemd-boot — patching all entries..."
    for entry in /boot/loader/entries/*.conf; do
      if grep -q "i915.max_vfs=" "$entry" 2>/dev/null; then
        ok "Already patched: $entry"
      else
         sudo sed -i "s/\\(options.*\\)/\\1 ${IOMMU_ARGS}/" "$entry"
        ok "Patched: $entry"
      fi
    done

  else
    warn "Unknown bootloader — add '${IOMMU_ARGS}' to kernel cmdline manually."
  fi

  info "Verify after reboot: cat /proc/cmdline | grep iommu"
}

# =============================================================================
# STEP 3: Disable System Sleep
# =============================================================================
step_sleep() {
  section "Step 3: Disable System Sleep"

  if systemctl is-masked sleep.target &>/dev/null; then
    ok "Sleep targets already masked. Skipping."; return
  fi

  confirm "Mask all sleep/suspend targets (server should never sleep)?" || { info "Skipped."; return; }
  sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
  ok "Sleep targets masked."
}

# =============================================================================
# STEP 4: Static IP
# =============================================================================
step_static_ip() {
  section "Step 4: Static IP"

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
# STEP 5: SSH Hardening
# =============================================================================
step_ssh() {
  section "Step 5: SSH Setup"

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
# STEP 6: Cloudflare SSH Tunnel
# =============================================================================
step_cloudflare_tunnel() {
  section "Step 6: Cloudflare SSH Tunnel"

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
After=network.target

[Service]
Type=simple
User=${CURRENT_USER}
ExecStart=/usr/bin/cloudflared --no-autoupdate --config ${USER_HOME}/.cloudflared/config.yml tunnel run
Restart=on-failure
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
# FINAL SUMMARY — how to connect from phone + every OS
# =============================================================================
print_final_summary() {
  TUNNEL_HOST_SAVED=""
  [ -f /tmp/phase1_tunnel_host ] && TUNNEL_HOST_SAVED=$(cat /tmp/phase1_tunnel_host)
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
  echo -e "${YELLOW}⚠  REBOOT REQUIRED to activate: IOMMU + docker group${RESET}"
  echo ""
  echo "  After reboot verify:"
  echo "    cat /proc/cmdline | grep iommu"
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

  echo ""
  info "Steps: packages → IOMMU → sleep → static IP → SSH → Cloudflare tunnel"
  confirm "Proceed with Phase 1 setup?" || { echo "Aborted."; exit 0; }

  step_packages
  step_iommu
  step_sleep
  step_static_ip
  step_ssh
  step_cloudflare_tunnel
  print_final_summary
}

main "$@"
