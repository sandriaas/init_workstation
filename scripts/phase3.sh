#!/usr/bin/env bash
# =============================================================================
# phase3.sh — Rev5.7.2 Phase 3: VM Install Wait + Internal Configuration
# =============================================================================
# Steps:
#   0. Select VM conf (generated-vm/*.conf)
#   1. Ensure VM is running; attach console for Ubuntu installer if needed
#   2. Wait until VM is reachable via SSH (poll with timeout)
#   3. Install packages inside VM (apt/dnf/pacman)
#   4. Configure SSH (enable sshd, fail2ban, PasswordAuthentication)
#   5. Set static IP via netplan
#   6. Mount virtiofs shared folder
#   7. Install i915-sriov-dkms in guest (required for SR-IOV VF inside VM)
#   8. Install cloudflared + set up Cloudflare tunnel
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()     { echo -e "${RED}[ERR]${RESET}  $*" >&2; }
section() { echo -e "\n${BOLD}══ $* ══${RESET}"; }
ask()     { echo -e "${YELLOW}[?]${RESET} $*"; }
confirm() { ask "$1 [Y/n]: "; read -r _r; [[ "${_r:-Y}" =~ ^[Yy]$ ]]; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VM_CONF_DIR="${REPO_DIR}/generated-vm"
_STATE="${VM_CONF_DIR}/.state"

# =============================================================================
# Snapper snapshot helpers
# =============================================================================
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

# =============================================================================
# Step 0: Select VM conf
# =============================================================================
select_conf() {
  section "Select VM Configuration"

  # Load last state
  [ -f "$_STATE" ] && source "$_STATE" 2>/dev/null || true

  mapfile -t EXISTING < <(ls "${VM_CONF_DIR}"/*.conf 2>/dev/null || true)

  if [ ${#EXISTING[@]} -eq 0 ]; then
    err "No VM conf files found in ${VM_CONF_DIR}/"
    err "Run scripts/phase2.sh first to create a VM configuration."
    exit 1
  fi

  local default_idx=1
  echo ""
  local i=1
  for f in "${EXISTING[@]}"; do
    local nm; nm="$(basename "$f" .conf)"
    local mark=""
    if [ "${f}" = "${LAST_VM_CONF:-}" ]; then
      mark=" ${YELLOW}← last used${RESET}"
      default_idx=$i
    fi
    echo -e "    $i) $nm  (${f})${mark}"
    (( i++ ))
  done
  echo ""
  ask "Select configuration [1-$((i-1)), default=${default_idx}]: "; read -r _sel
  _sel="${_sel:-$default_idx}"

  if [[ "$_sel" =~ ^[0-9]+$ ]] && [ "$_sel" -ge 1 ] && [ "$_sel" -lt "$i" ]; then
    VM_CONF="${EXISTING[$(( _sel - 1 ))]}"
  else
    VM_CONF="${EXISTING[$(( default_idx - 1 ))]}"
  fi

  [ -f "$VM_CONF" ] || { err "Missing ${VM_CONF}"; exit 1; }
  # shellcheck disable=SC1090
  source "$VM_CONF"

  VM_CONF_DIR="$(dirname "$VM_CONF")"
  ok "Using conf: $VM_CONF"
  info "VM: ${VM_NAME}  •  ${VM_VCPUS} vCPU  •  ${VM_RAM_MB} MB RAM  •  ${VM_STATIC_IP}"
}

# =============================================================================
# Step 1: Ensure VM is defined + running
# =============================================================================
ensure_vm_running() {
  section "Step 1 — Start VM"

  if ! virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    err "VM '${VM_NAME}' not yet defined. Run scripts/phase2.sh first."
    exit 1
  fi

  local state; state="$(virsh domstate "$VM_NAME" 2>/dev/null || echo unknown)"
  info "VM '${VM_NAME}' state: ${state}"

  if [ "$state" = "running" ]; then
    ok "VM is running."
  else
    confirm "Start VM '${VM_NAME}' now?" && virsh start "$VM_NAME"
    sleep 2
    state="$(virsh domstate "$VM_NAME" 2>/dev/null || echo unknown)"
    [ "$state" = "running" ] && ok "VM started." || { err "Failed to start VM."; exit 1; }
  fi

  if [ "${VM_AUTOINSTALL:-yes}" = "yes" ]; then
    info "Ubuntu autoinstall is running inside the VM (~10-15 min total)."
    info "Optional — watch progress: sudo virsh console ${VM_NAME}  (exit: Ctrl+])"
  else
    # Manual install — check if already SSH-reachable (install may already be done)
    local vm_ip; vm_ip="$(_resolve_vm_ip)"
    if _ssh_alive "$vm_ip" 2>/dev/null; then
      ok "VM SSH already reachable — Ubuntu installation complete."
      VM_SSH_HOST="$vm_ip"
      return
    fi
    echo ""
    echo -e "${YELLOW}  Ubuntu installer is running. Complete it via the console:${RESET}"
    echo -e "    ${BOLD}sudo virsh console ${VM_NAME}${RESET}   (exit: Ctrl+])"
    echo ""
    echo "  Steps: language → network (DHCP) → disk (default) → user=${VM_USER} → OpenSSH=YES → Done"
    echo ""
    confirm "Press Y once Ubuntu installation is complete and VM has rebooted" || exit 0
  fi
}

# =============================================================================
# Step 2: Wait for SSH
# =============================================================================
_resolve_vm_ip() {
  # Try static IP first, fall back to DHCP lease from virsh
  if ping -c 1 -W 1 "${VM_STATIC_IP%/*}" >/dev/null 2>&1; then
    echo "${VM_STATIC_IP%/*}"; return
  fi
  local dhcp; dhcp="$(virsh domifaddr "$VM_NAME" 2>/dev/null \
    | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -1)"
  echo "${dhcp:-${VM_STATIC_IP%/*}}"
}

_ssh_alive() {
  local host="$1"
  ssh -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=3 \
      -o BatchMode=yes \
      "${VM_SSH_USER}@${host}" true 2>/dev/null
}

wait_for_ssh() {
  section "Step 2 — Wait for VM SSH"

  VM_SSH_HOST="$(_resolve_vm_ip)"
  # Autoinstall takes ~10-15 min; manual install confirmed before this call
  local max=180  # 15 min (180 x 5s)
  [ "${VM_AUTOINSTALL:-yes}" != "yes" ] && max=60

  info "Polling SSH at ${VM_SSH_USER}@${VM_SSH_HOST} (up to $(( max * 5 / 60 )) min)..."

  local attempts=0
  while [ $attempts -lt $max ]; do
    if _ssh_alive "$VM_SSH_HOST"; then
      echo ""
      ok "VM SSH reachable at ${VM_SSH_HOST}"
      return
    fi
    (( attempts++ ))
    if (( attempts % 12 == 0 )); then
      local elapsed=$(( attempts * 5 / 60 ))
      local vm_state; vm_state="$(virsh domstate "$VM_NAME" 2>/dev/null || echo unknown)"
      printf "\r  [%d min] VM state: %-12s  waiting for SSH...    " "$elapsed" "$vm_state"
    else
      printf "\r  Waiting... (%d/%d)    " "$attempts" "$max"
    fi
    sleep 5
  done
  echo ""
  err "VM SSH not reachable after $(( max * 5 / 60 )) minutes."
  ask "Enter VM IP/hostname manually (or press Enter to retry once more): "; read -r _manual
  if [ -n "$_manual" ]; then
    VM_SSH_HOST="$_manual"
    _ssh_alive "$VM_SSH_HOST" || { err "Still not reachable at ${VM_SSH_HOST}"; exit 1; }
    ok "VM SSH reachable at ${VM_SSH_HOST}"
  else
    wait_for_ssh  # recurse once
  fi
}


# =============================================================================
# Step 3–8: Remote configuration (runs inside VM via SSH)
# =============================================================================
run_remote_setup() {
  section "Remote VM Configuration (${VM_SSH_USER}@${VM_SSH_HOST})"
  info "Steps: packages → SSH config → static IP → shared folder → i915-sriov-dkms → cloudflared tunnel"
  echo ""

  ssh -tt -o StrictHostKeyChecking=accept-new "${VM_SSH_USER}@${VM_SSH_HOST}" \
    "VM_NAME='${VM_NAME}' \
     VM_AUTOINSTALL='${VM_AUTOINSTALL:-yes}' \
     VM_TUNNEL_HOST='${VM_TUNNEL_HOST}' \
     VM_TUNNEL_NAME='${VM_TUNNEL_NAME}' \
     VM_STATIC_IP='${VM_STATIC_IP}' \
     VM_GATEWAY='${VM_GATEWAY}' \
     VM_DNS='${VM_DNS}' \
     SHARED_TAG='${SHARED_TAG}' \
     sudo -E bash -s" <<'REMOTE'
set -euo pipefail
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}  [OK]${RESET}  $*"; }
info() { echo -e "${CYAN}  [>>]${RESET}  $*"; }
warn() { echo -e "${YELLOW}  [!!]${RESET}  $*"; }
step() { echo -e "\n${BOLD}  ── $* ──${RESET}"; }

# Detect OS
[ -f /etc/os-release ] && . /etc/os-release || ID=ubuntu

# ── Step 3: Install packages ────────────────────────────────────────────────
step "Step 3: Install base packages"
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget openssh-server fail2ban net-tools \
    dkms "linux-headers-$(uname -r)" build-essential
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y curl wget openssh-server fail2ban net-tools \
    dkms "kernel-devel-$(uname -r)"
elif command -v pacman >/dev/null 2>&1; then
  pacman -Syu --noconfirm --needed curl wget openssh fail2ban net-tools dkms linux-headers
fi
ok "Packages installed."

# ── Step 4: SSH + fail2ban ──────────────────────────────────────────────────
step "Step 4: Configure SSH + fail2ban"
systemctl enable --now sshd 2>/dev/null || systemctl enable --now ssh 2>/dev/null || true
systemctl enable --now fail2ban 2>/dev/null || true
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config
systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
ok "SSH enabled. fail2ban enabled."

# ── Step 5: Static IP via netplan ───────────────────────────────────────────
step "Step 5: Set static IP (${VM_STATIC_IP})"
IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)"
if [ -d /etc/netplan ] && ! grep -rq "dhcp4: no\|dhcp4: false" /etc/netplan/ 2>/dev/null; then
  cat > /etc/netplan/99-static.yaml <<EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: no
      addresses: [${VM_STATIC_IP}]
      routes:
        - to: default
          via: ${VM_GATEWAY}
      nameservers:
        addresses: [$(echo "${VM_DNS}" | sed 's/,/, /g')]
EOF
  netplan apply || true
  ok "Static IP set: ${VM_STATIC_IP} via ${VM_GATEWAY}"
else
  ok "Static IP already configured — skipping."
fi

# ── Step 6: virtiofs shared folder ─────────────────────────────────────────
step "Step 6: Mount shared folder (${SHARED_TAG})"
mkdir -p "/mnt/${SHARED_TAG}"
if ! grep -q "${SHARED_TAG}" /etc/fstab; then
  echo "${SHARED_TAG} /mnt/${SHARED_TAG} virtiofs defaults,_netdev 0 0" >> /etc/fstab
  ok "Added ${SHARED_TAG} to /etc/fstab"
fi
mount -a 2>/dev/null || warn "virtiofs mount failed — will succeed after host reboot."

# ── Step 7: i915-sriov-dkms in guest ───────────────────────────────────────
step "Step 7: Install i915-sriov-dkms in guest"
if command -v apt-get >/dev/null 2>&1; then
  SRIOV_DEB_URL="$(curl -fsSL https://api.github.com/repos/strongtz/i915-sriov-dkms/releases/latest \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(a["browser_download_url"] for a in d["assets"] if a["name"].endswith("_amd64.deb")))' 2>/dev/null || true)"
  if [ -n "${SRIOV_DEB_URL:-}" ]; then
    curl -fL "$SRIOV_DEB_URL" -o /tmp/i915-sriov-dkms.deb
    dpkg -i /tmp/i915-sriov-dkms.deb || DEBIAN_FRONTEND=noninteractive apt-get install -f -y
    ok "i915-sriov-dkms installed."
  else
    warn "Could not fetch i915-sriov-dkms .deb — install manually:"
    warn "  https://github.com/strongtz/i915-sriov-dkms/releases"
  fi
elif command -v pacman >/dev/null 2>&1 && command -v paru >/dev/null 2>&1; then
  paru -S --noconfirm --needed i915-sriov-dkms
  ok "i915-sriov-dkms installed."
else
  warn "Unsupported package manager — install i915-sriov-dkms manually."
fi

# ── Step 8: cloudflared + tunnel ───────────────────────────────────────────
step "Step 8: Install cloudflared"
if ! command -v cloudflared >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] \
https://pkg.cloudflare.com/cloudflared $(. /etc/os-release; echo "${VERSION_CODENAME:-jammy}") main" \
      | tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
    apt-get update -qq && apt-get install -y cloudflared
  elif command -v dnf >/dev/null 2>&1; then
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-x86_64.rpm \
      -o /tmp/cloudflared.rpm && rpm -i /tmp/cloudflared.rpm || true
  elif command -v pacman >/dev/null 2>&1; then
    pacman -S --noconfirm --needed cloudflared
  fi
fi
ok "cloudflared installed: $(cloudflared --version 2>/dev/null | head -1)"

step "Step 8b: Set up Cloudflare tunnel (VM: ${VM_TUNNEL_NAME} → ${VM_TUNNEL_HOST})"
echo ""
echo "  Tunnel: ${VM_TUNNEL_NAME}"
echo "  Host:   ${VM_TUNNEL_HOST}"
echo ""
echo "  Choose tunnel install method:"
echo "    1) Token-based  (paste token from Cloudflare dashboard — recommended)"
echo "    2) Browser login  (cloudflared login — opens browser URL)"
read -r -p "  Choice [1/2, default=1]: " CHOICE
CHOICE="${CHOICE:-1}"

if [ "$CHOICE" = "2" ]; then
  cloudflared login
  cloudflared tunnel create "${VM_TUNNEL_NAME}" 2>/dev/null || true
  cloudflared tunnel route dns "${VM_TUNNEL_NAME}" "${VM_TUNNEL_HOST}" 2>/dev/null || true
  mkdir -p /root/.cloudflared
  TUNNEL_ID="$(cloudflared tunnel list 2>/dev/null | awk -v n="${VM_TUNNEL_NAME}" '$2==n{print $1; exit}')"
  if [ -n "${TUNNEL_ID:-}" ]; then
    cat > /root/.cloudflared/config.yml <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /root/.cloudflared/${TUNNEL_ID}.json
ingress:
  - hostname: ${VM_TUNNEL_HOST}
    service: ssh://localhost:22
  - service: http_status:404
EOF
    cloudflared service install
    ok "Tunnel configured: ${VM_TUNNEL_HOST}"
  else
    warn "Could not find tunnel ID for '${VM_TUNNEL_NAME}' — configure manually."
  fi
else
  read -r -p "  Paste Tunnel Token: " TUNNEL_TOKEN
  if [ -n "${TUNNEL_TOKEN:-}" ]; then
    cloudflared service install "$TUNNEL_TOKEN"
    ok "Tunnel installed via token."
  else
    warn "No token provided — skipping tunnel install."
  fi
fi

systemctl enable --now cloudflared 2>/dev/null || true

echo ""
ok "VM internal configuration complete."
REMOTE
}

# =============================================================================
# Write confirmed tunnel info back to vm.conf
# =============================================================================
update_vm_conf() {
  [ -f "$VM_CONF" ] || return
  sed -i "s|^VM_TUNNEL_HOST=.*|VM_TUNNEL_HOST=\"${VM_TUNNEL_HOST}\"|" "$VM_CONF"
  sed -i "s|^VM_TUNNEL_NAME=.*|VM_TUNNEL_NAME=\"${VM_TUNNEL_NAME}\"|" "$VM_CONF"
  ok "vm.conf updated: VM_TUNNEL_HOST=${VM_TUNNEL_HOST}"
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
  local vm_ip; vm_ip="${VM_SSH_HOST:-${VM_STATIC_IP%/*}}"
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║                    PHASE 3 COMPLETE ✓                       ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "${BOLD}  ── VM ─────────────────────────────────────────────────────${RESET}"
  printf "  %-18s %s\n" "Name:"        "$VM_NAME"
  printf "  %-18s %s\n" "User:"        "$VM_SSH_USER"
  printf "  %-18s %s\n" "IP:"          "$vm_ip"
  printf "  %-18s %s\n" "Tunnel:"      "$VM_TUNNEL_HOST"
  echo ""
  echo -e "${BOLD}  ── Steps completed ────────────────────────────────────────${RESET}"
  echo "  3. Packages installed     (curl wget openssh fail2ban dkms linux-headers)"
  echo "  4. SSH configured         (sshd enabled, fail2ban enabled)"
  echo "  5. Static IP set          (${VM_STATIC_IP} via ${VM_GATEWAY})"
  echo "  6. Shared folder mounted  (/mnt/${SHARED_TAG})"
  echo "  7. i915-sriov-dkms        (installed in guest)"
  echo "  8. cloudflared            (tunnel: ${VM_TUNNEL_HOST})"
  echo ""
  echo -e "${BOLD}  ── Connect from anywhere ───────────────────────────────────${RESET}"
  echo "  Direct (LAN):   ssh ${VM_SSH_USER}@${vm_ip}"
  echo "  Via tunnel:     ssh ${VM_SSH_USER}@${VM_TUNNEL_HOST}"
  echo ""
  echo -e "${BOLD}  ── Client setup (phone/laptop) ─────────────────────────────${RESET}"
  echo "  bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase2-client.sh)"
  echo ""
  echo -e "${BOLD}  ── Verify ───────────────────────────────────────────────────${RESET}"
  echo "  bash scripts/check.sh"
  echo ""
  _snap_summary
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  echo -e "${BOLD}"
  echo "╔══════════════════════════════════════════════╗"
  echo "║   Rev5.7.2 — Phase 3: VM Internal Setup     ║"
  echo "║   Steps: conf → installer → SSH → config    ║"
  echo "╚══════════════════════════════════════════════╝"
  echo -e "${RESET}"

  [ "$EUID" -ne 0 ] && { warn "Re-running with sudo..."; exec sudo bash "$0" "$@"; }

  # Step 0: pick conf
  select_conf
  VM_STATIC_IP_ADDR="${VM_STATIC_IP%/*}"
  VM_SSH_HOST="$VM_STATIC_IP_ADDR"
  VM_SSH_USER="${VM_USER}"

  _snap_pre "phase3 vm internal setup start"

  # Step 1: ensure VM running + Ubuntu installer complete
  ensure_vm_running

  # Step 2: poll SSH until reachable
  wait_for_ssh

  # Steps 3–8: configure VM internals over SSH
  run_remote_setup

  # Write tunnel info back to conf
  update_vm_conf

  # Mark phase3 done in .state
  [ -f "$_STATE" ] && sed -i 's/PHASE3_DONE=.*/PHASE3_DONE="yes"/' "$_STATE" || true

  _snap_post "phase3 vm internal setup complete"
  print_summary
}

main "$@"
