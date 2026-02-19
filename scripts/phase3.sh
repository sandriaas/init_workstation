#!/usr/bin/env bash
# =============================================================================
# phase3.sh — Rev5.7.2 Phase 3: Configure VM Internals (from host via SSH)
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

[ -f "$VM_CONF" ] || { echo "Missing ${VM_CONF}. Run scripts/phase2.sh first."; exit 1; }
# shellcheck disable=SC1090
source "$VM_CONF"

VM_STATIC_IP_ADDR="${VM_STATIC_IP%/*}"
VM_SSH_HOST="$VM_STATIC_IP_ADDR"
VM_SSH_USER="${VM_USER}"

detect_vm_ip() {
  if ping -c 1 -W 1 "$VM_STATIC_IP_ADDR" >/dev/null 2>&1; then
    VM_SSH_HOST="$VM_STATIC_IP_ADDR"
    return
  fi
  DHCP_IP="$(sudo virsh domifaddr "$VM_NAME" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -1)"
  if [ -n "${DHCP_IP:-}" ]; then
    VM_SSH_HOST="$DHCP_IP"
  fi
}

prompt_target() {
  section "Target VM SSH"
  detect_vm_ip
  info "VM from config: ${VM_NAME}"
  ask "VM SSH user [${VM_SSH_USER}]: "; read -r IN_USER
  ask "VM SSH host/IP [${VM_SSH_HOST}]: "; read -r IN_HOST
  VM_SSH_USER="${IN_USER:-$VM_SSH_USER}"
  VM_SSH_HOST="${IN_HOST:-$VM_SSH_HOST}"
}

run_remote_setup() {
  section "Configuring VM over SSH (${VM_SSH_USER}@${VM_SSH_HOST})"
  ssh -tt -o StrictHostKeyChecking=accept-new "${VM_SSH_USER}@${VM_SSH_HOST}" \
    "VM_TUNNEL_HOST='${VM_TUNNEL_HOST}' VM_TUNNEL_NAME='${VM_TUNNEL_NAME}' VM_STATIC_IP='${VM_STATIC_IP}' VM_GATEWAY='${VM_GATEWAY}' VM_DNS='${VM_DNS}' SHARED_TAG='${SHARED_TAG}' sudo -E bash -s" <<'REMOTE'
set -euo pipefail

if [ -f /etc/os-release ]; then
  . /etc/os-release
else
  ID=ubuntu
fi

if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  apt-get install -y curl wget openssh-server fail2ban net-tools cloud-init
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y curl wget openssh-server fail2ban net-tools
elif command -v pacman >/dev/null 2>&1; then
  pacman -Syu --noconfirm --needed curl wget openssh fail2ban net-tools
fi

if ! command -v cloudflared >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(. /etc/os-release; echo ${VERSION_CODENAME:-jammy}) main" \
      | tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
    apt-get update && apt-get install -y cloudflared
  elif command -v dnf >/dev/null 2>&1; then
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-x86_64.rpm -o /tmp/cloudflared.rpm
    rpm -i /tmp/cloudflared.rpm || true
  elif command -v pacman >/dev/null 2>&1; then
    pacman -S --noconfirm --needed cloudflared
  fi
fi

if ! command -v websocat >/dev/null 2>&1; then
  curl -sL https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-musl \
    -o /usr/local/bin/websocat
  chmod +x /usr/local/bin/websocat
fi

systemctl enable --now sshd 2>/dev/null || systemctl enable --now ssh 2>/dev/null || true
systemctl enable --now fail2ban || true

sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config
systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true

IFACE="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)"
if [ -d /etc/netplan ] && ! grep -r "dhcp4: no\|dhcp4: false" /etc/netplan/ >/dev/null 2>&1; then
  cat > /etc/netplan/99-static.yaml <<EOF
network:
  ethernets:
    ${IFACE}:
      dhcp4: no
      addresses: [${VM_STATIC_IP}]
      routes:
        - to: default
          via: ${VM_GATEWAY}
      nameservers:
        addresses: [$(echo "${VM_DNS}" | sed 's/,/, /g')]
  version: 2
EOF
  netplan apply || true
fi

mkdir -p /mnt/"${SHARED_TAG}"
if ! grep -q "${SHARED_TAG}" /etc/fstab; then
  echo "${SHARED_TAG} /mnt/${SHARED_TAG} virtiofs defaults,_netdev 0 0" >> /etc/fstab
fi
mount -a || true

echo ""
echo "Cloudflare tunnel setup for VM (${VM_TUNNEL_NAME} / ${VM_TUNNEL_HOST})"
echo "1) Browser login (cloudflared login)"
echo "2) Token-based install (cloudflared service install <TOKEN>)"
read -r -p "Choice [1/2]: " CHOICE
if [ "${CHOICE:-1}" = "2" ]; then
  read -r -p "Paste Tunnel Token: " TUNNEL_TOKEN
  cloudflared service install "$TUNNEL_TOKEN"
else
  cloudflared login
  cloudflared tunnel create "${VM_TUNNEL_NAME}" || true
  cloudflared tunnel route dns "${VM_TUNNEL_NAME}" "${VM_TUNNEL_HOST}" || true
  mkdir -p /root/.cloudflared
  TUNNEL_ID="$(cloudflared tunnel list | awk -v n="${VM_TUNNEL_NAME}" '$2==n{print $1; exit}')"
  cat > /root/.cloudflared/config.yml <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /root/.cloudflared/${TUNNEL_ID}.json
ingress:
  - hostname: ${VM_TUNNEL_HOST}
    service: ssh://localhost:22
  - service: http_status:404
EOF
  cloudflared service install
fi
systemctl enable --now cloudflared || true

echo ""
echo "VM setup done."
REMOTE
}

print_summary() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║                    PHASE 3 COMPLETE                          ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo "VM SSH target: ${VM_SSH_USER}@${VM_SSH_HOST}"
  echo "VM tunnel:     ${VM_TUNNEL_HOST}"
  echo ""
  echo "Client setup command:"
  echo "  bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase2-client.sh)"
  echo ""
}

main() {
  echo -e "${BOLD}"
  echo "╔══════════════════════════════════════════════╗"
  echo "║   Rev5.7.2 — Phase 3: VM Internal Setup     ║"
  echo "╚══════════════════════════════════════════════╝"
  echo -e "${RESET}"
  confirm "Proceed with VM internal setup now?" || exit 0
  prompt_target
  run_remote_setup
  print_summary
}

main "$@"
