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

# Error trap — show file:line on unexpected exit
trap '_ec=$?; [ $_ec -ne 0 ] && err "Script failed at line ${LINENO} (exit code ${_ec}) in ${FUNCNAME[0]:-main}()" >&2' ERR
section() {
  local conf_hint=""
  [ -n "${VM_CONF:-}" ] && [ -f "${VM_CONF}" ] && \
    conf_hint="  ${CYAN}[$(basename "${VM_CONF}")]${RESET}"
  echo -e "\n${BOLD}══ $* ══${RESET}${conf_hint}"
}
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
  section "Select VM to Configure"

  [ -f "$_STATE" ] && source "$_STATE" 2>/dev/null || true

  # ── Installed VMs from virsh ───────────────────────────────────────────────
  local -a VM_NAMES=() VM_STATES=()
  while IFS= read -r line; do
    local name state
    name="$(echo "$line" | awk '{print $2}')"
    state="$(echo "$line" | awk '{$1=$2=""; print $0}' | xargs || true)"
    [ -z "$name" ] || [ "$name" = "Name" ] && continue
    VM_NAMES+=("$name"); VM_STATES+=("$state")
  done < <(virsh list --all 2>/dev/null | tail -n +3 || true)

  # ── Available conf files ───────────────────────────────────────────────────
  local -a EXISTING=()
  mapfile -t EXISTING < <(ls "${VM_CONF_DIR}"/*.conf 2>/dev/null || true)

  if [ ${#VM_NAMES[@]} -eq 0 ] && [ ${#EXISTING[@]} -eq 0 ]; then
    err "No VMs found in virsh and no conf files in ${VM_CONF_DIR}/"
    err "Run scripts/phase2.sh first to create a VM."
    exit 1
  fi

  echo ""
  echo -e "${BOLD}  ── Installed VMs ───────────────────────────────────────────────${RESET}"
  local idx=1
  local -a CHOICES=()   # maps choice number → vm_name
  local -a CONF_MAP=()  # maps choice number → conf file (may be empty)
  local default_idx=1

  if [ ${#VM_NAMES[@]} -gt 0 ]; then
    local v=0
    for name in "${VM_NAMES[@]}"; do
      local state="${VM_STATES[$v]:-}"
      local conf_file=""
      # Find matching conf file
      if [ ${#EXISTING[@]} -gt 0 ]; then
        for f in "${EXISTING[@]}"; do
          local fn; fn="$(basename "$f" .conf)"
          [ "$fn" = "$name" ] && { conf_file="$f"; break; }
        done
      fi
      local conf_hint=""; [ -n "$conf_file" ] && conf_hint="  ${CYAN}[conf: $(basename "$conf_file")]${RESET}"
      local mark=""
      [ "${name}" = "${LAST_VM_NAME:-}" ] && { mark=" ${YELLOW}← last used${RESET}"; default_idx=$idx; }
      echo -e "    ${BOLD}${idx})${RESET} ${name}  (${state})${conf_hint}${mark}"
      CHOICES+=("$name"); CONF_MAP+=("$conf_file")
      (( idx++ )) || true; (( v++ )) || true
    done
  fi

  # Conf files with no matching virsh VM
  if [ ${#EXISTING[@]} -gt 0 ]; then
    for f in "${EXISTING[@]}"; do
      local fn; fn="$(basename "$f" .conf)"
      local already=0
      if [ ${#VM_NAMES[@]} -gt 0 ]; then
        for name in "${VM_NAMES[@]}"; do [ "$name" = "$fn" ] && already=1; done
      fi
      if [ $already -eq 0 ]; then
        echo -e "    ${BOLD}${idx})${RESET} ${fn}  ${YELLOW}(conf only — not yet installed)${RESET}"
        CHOICES+=("$fn"); CONF_MAP+=("$f")
        (( idx++ )) || true
      fi
    done
  fi

  echo ""
  ask "Select VM to configure [1-$((idx-1)), default=${default_idx}]: "; read -r _sel
  _sel="${_sel:-$default_idx}"

  if ! [[ "$_sel" =~ ^[0-9]+$ ]] || [ "$_sel" -lt 1 ] || [ "$_sel" -ge "$idx" ]; then
    _sel="$default_idx"
  fi

  local chosen_name="${CHOICES[$(( _sel - 1 ))]}"
  VM_CONF="${CONF_MAP[$(( _sel - 1 ))]}"

  if [ -z "$VM_CONF" ] || [ ! -f "$VM_CONF" ]; then
    # Try to find any conf matching by name
    VM_CONF="${VM_CONF_DIR}/${chosen_name}.conf"
    if [ ! -f "$VM_CONF" ]; then
      err "No conf file for '${chosen_name}'. Run phase2 first or place conf at ${VM_CONF}"
      exit 1
    fi
  fi

  # Temporarily disable nounset — conf file contains SHA-512 hash with $6$ literal
  set +u
  # shellcheck disable=SC1090
  source "$VM_CONF"
  set -u
  VM_CONF_DIR="$(dirname "$VM_CONF")"
  ok "Selected VM: ${VM_NAME}  (conf: $(basename "$VM_CONF"))"
  info "${VM_VCPUS} vCPU  •  $(( VM_RAM_MB / 1024 )) GB RAM  •  ${VM_STATIC_IP%/*}  •  tunnel: ${VM_TUNNEL_HOST:-not set}"
}

# =============================================================================
# Step 1: Ensure VM is defined + running
# =============================================================================
ensure_vm_running() {
  section "Step 1 — Start VM"

  if ! virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    warn "VM '${VM_NAME}' is not yet created in libvirt."
    echo ""
    echo -e "  ${BOLD}Phase 2${RESET} must run first to create and install the VM."
    echo -e "  The existing conf (${CYAN}$(basename "$VM_CONF")${RESET}) will be reused automatically."
    echo ""
    echo "  1) Run phase2 now  (recommended)"
    echo "  2) Exit — I'll run phase2 manually"
    ask "Choice [1/2, default=1]: "; read -r _p2choice
    if [ "${_p2choice:-1}" != "2" ]; then
      info "Launching phase2 with conf: $(basename "$VM_CONF")..."
      # Write LAST_VM_CONF to state so phase2 pre-selects this conf
      local _state="${VM_CONF_DIR}/.state"
      mkdir -p "$VM_CONF_DIR"
      if [ -f "$_state" ]; then
        sed -i "s|^LAST_VM_CONF=.*|LAST_VM_CONF=\"${VM_CONF}\"|" "$_state"
        sed -i "s|^LAST_VM_NAME=.*|LAST_VM_NAME=\"${VM_NAME}\"|" "$_state"
      else
        printf 'LAST_VM_CONF="%s"\nLAST_VM_NAME="%s"\n' "$VM_CONF" "$VM_NAME" > "$_state"
      fi
      local _phase2="${BASH_SOURCE[0]%/*}/phase2.sh"
      if [ ! -f "$_phase2" ]; then
        err "phase2.sh not found at ${_phase2}"
        exit 1
      fi
      exec sudo bash "$_phase2"
    else
      err "VM '${VM_NAME}' not yet defined."
      echo "  Run:  sudo bash scripts/phase2.sh"
      exit 1
    fi
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
    info "Ubuntu autoinstall runs silently (~10-15 min). SSH poll will catch it when done."
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
    | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -1 || true)"
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

  # If phase2 already confirmed SSH, use that IP and do a quick check
  [ -f "$_STATE" ] && source "$_STATE" 2>/dev/null || true
  if [ -n "${VM_SSH_IP:-}" ]; then
    if _ssh_alive "$VM_SSH_IP"; then
      VM_SSH_HOST="$VM_SSH_IP"
      ok "VM SSH confirmed (phase2 verified): ${VM_SSH_HOST}"
      return
    fi
  fi

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
    (( attempts++ )) || true
    if [ $(( attempts % 12 )) -eq 0 ]; then
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
    wait_for_ssh
  fi
}


# =============================================================================
# Step 3–8: Remote configuration (runs inside VM via SSH)
# =============================================================================
run_remote_setup() {
  section "Remote VM Configuration (${VM_SSH_USER}@${VM_SSH_HOST})"
  info "Steps: packages → SSH config → static IP → shared folder → i915-sriov-dkms → cloudflared tunnel"
  echo ""

  # Ensure VM has internet via libvirt NAT (UFW may block FORWARD)
  sudo ufw route allow in on virbr0 out on virbr0 >/dev/null 2>&1 || true
  sudo ufw route allow in on virbr0 >/dev/null 2>&1 || true
  sudo ufw route allow out on virbr0 >/dev/null 2>&1 || true
  # Also ensure iptables masquerade for libvirt NAT (in case it got flushed)
  sudo iptables -t nat -C POSTROUTING -s 192.168.122.0/24 ! -d 192.168.122.0/24 -j MASQUERADE 2>/dev/null \
    || sudo iptables -t nat -A POSTROUTING -s 192.168.122.0/24 ! -d 192.168.122.0/24 -j MASQUERADE 2>/dev/null || true

  # Prompt for tunnel token on HOST (before SSH — no TTY inside remote heredoc)
  local VM_TUNNEL_TOKEN="${VM_TUNNEL_TOKEN:-}"
  if [ -z "$VM_TUNNEL_TOKEN" ]; then
    echo ""
    echo "  ── Cloudflare Tunnel Token ────────────────────────────────"
    echo "  Get from: dash.cloudflare.com → Zero Trust → Networks → Tunnels"
    echo "  Select tunnel '${VM_TUNNEL_NAME}' → Configure → Install connector → token"
    echo ""
    read -r -p "  Paste tunnel token (Enter to skip): " VM_TUNNEL_TOKEN
    echo ""
  fi

  ssh -T -o StrictHostKeyChecking=accept-new "${VM_SSH_USER}@${VM_SSH_HOST}" \
    "VM_NAME='${VM_NAME}' \
     VM_AUTOINSTALL='${VM_AUTOINSTALL:-yes}' \
     VM_TUNNEL_HOST='${VM_TUNNEL_HOST}' \
     VM_TUNNEL_NAME='${VM_TUNNEL_NAME}' \
     VM_TUNNEL_TOKEN='${VM_TUNNEL_TOKEN}' \
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
  apt-get update
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
systemctl enable --now sshd || systemctl enable --now ssh || true
systemctl enable --now fail2ban || true
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config
systemctl reload sshd || systemctl reload ssh || true
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
mount -a || warn "virtiofs mount failed — will succeed after host reboot."

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
    apt-get update && apt-get install -y cloudflared
  elif command -v dnf >/dev/null 2>&1; then
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-x86_64.rpm \
      -o /tmp/cloudflared.rpm && rpm -i /tmp/cloudflared.rpm || true
  elif command -v pacman >/dev/null 2>&1; then
    pacman -S --noconfirm --needed cloudflared
  fi
fi
ok "cloudflared installed: $(cloudflared --version 2>/dev/null | head -1)"

step "Step 8b: Set up Cloudflare tunnel (VM: ${VM_TUNNEL_NAME} → ${VM_TUNNEL_HOST})"
echo "  Tunnel: ${VM_TUNNEL_NAME}  →  ${VM_TUNNEL_HOST}"

if [ -n "${VM_TUNNEL_TOKEN:-}" ]; then
  cloudflared service install "$VM_TUNNEL_TOKEN"
  ok "Tunnel installed via token."
else
  warn "No tunnel token provided — run phase3 again with token to activate tunnel."
  warn "  Get token: dash.cloudflare.com → Zero Trust → Networks → Tunnels → ${VM_TUNNEL_NAME} → Configure"
fi

systemctl enable --now cloudflared || true

echo ""
ok "VM internal configuration complete."
REMOTE
}

# =============================================================================
# Test cloudflared websocat SSH tunnel from host → VM
# =============================================================================
CF_TUNNEL_RESULT="not tested"
test_cf_tunnel() {
  [ -n "${VM_TUNNEL_HOST:-}" ] || { CF_TUNNEL_RESULT="no VM_TUNNEL_HOST configured"; return; }
  info "Testing cloudflared WebSocket SSH tunnel → ${VM_TUNNEL_HOST}..."

  # Ensure websocat available on host
  if ! command -v websocat &>/dev/null; then
    warn "websocat not found on host — installing..."
    curl -sL https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-musl \
      -o /usr/local/bin/websocat && chmod +x /usr/local/bin/websocat 2>/dev/null || true
  fi

  if ! command -v websocat &>/dev/null; then
    CF_TUNNEL_RESULT="websocat not available — install manually"
    return
  fi

  # Give cloudflared ~30s to come up after install
  local attempts=0
  while [ $attempts -lt 6 ]; do
    if ssh \
         -o StrictHostKeyChecking=accept-new \
         -o ConnectTimeout=8 \
         -o BatchMode=yes \
         -o ProxyCommand="websocat -E --binary - wss://%h" \
         "${VM_SSH_USER}@${VM_TUNNEL_HOST}" true 2>/dev/null; then
      CF_TUNNEL_RESULT="✓  working"
      ok "Cloudflared SSH tunnel test passed: ssh ${VM_SSH_USER}@${VM_TUNNEL_HOST}"
      return
    fi
    (( attempts++ )) || true
    sleep 5
  done
  CF_TUNNEL_RESULT="not reachable yet (tunnel may need a minute to propagate DNS)"
  warn "Cloudflared SSH tunnel not reachable yet — try again in 1-2 min:"
  warn "  ssh -o ProxyCommand='websocat -E --binary - wss://%h' ${VM_SSH_USER}@${VM_TUNNEL_HOST}"
}
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
  local HOST_IP; HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║                    PHASE 3 COMPLETE ✓                       ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "${BOLD}  ── VM Configuration ──────────────────────────────────────${RESET}"
  printf "  %-18s %s\n" "Name:"        "$VM_NAME"
  printf "  %-18s %s\n" "Hostname:"    "$VM_HOSTNAME"
  printf "  %-18s %s\n" "User:"        "$VM_SSH_USER"
  printf "  %-18s %s vCPU  /  %s MB RAM\n" "Resources:" "$VM_VCPUS" "$VM_RAM_MB"
  printf "  %-18s %s  (%s GB,  %s)\n"  "Disk:" "$VM_DISK_PATH" "$VM_DISK_GB" "$VM_DISK_FORMAT"
  printf "  %-18s %s  (machine=%s, firmware=%s)\n" "Machine:" "$VM_CPU_MODEL" "$VM_MACHINE_TYPE" "$VM_FIRMWARE"
  printf "  %-18s %s\n" "OS Variant:"  "$VM_OS_VARIANT"
  echo ""
  echo -e "${BOLD}  ── Network ─────────────────────────────────────────────────${RESET}"
  printf "  %-18s %s  (physical LAN)\n"       "Host IP:"  "$HOST_IP"
  printf "  %-18s %s  (libvirt NAT)\n"        "VM IP:"    "$vm_ip"
  printf "  %-18s %s / %s\n"                  "Gateway:"  "$VM_GATEWAY" "$VM_DNS"
  printf "  %-18s %s → %s\n"                  "Shared:"   "$SHARED_DIR" "$SHARED_TAG"
  echo ""
  echo -e "${BOLD}  ── GPU Passthrough ─────────────────────────────────────────${RESET}"
  printf "  %-18s %s  (driver: %s, gen %s)\n" "GPU:"      "$GPU_PCI_ID" "$GPU_DRIVER" "$GPU_GEN"
  printf "  %-18s %s  (x-igd-lpc=%s)\n"       "VF count:" "$GPU_VF_COUNT" "$GPU_IGD_LPC"
  printf "  %-18s %s\n"                        "ROM:"      "${GPU_ROM_PATH}"
  echo ""
  echo -e "${BOLD}  ── Cloudflare Tunnels ───────────────────────────────────────${RESET}"
  printf "  %-20s %s\n" "Host hostname:"  "${HOST_TUNNEL_HOST}"
  [ -n "${HOST_TUNNEL_NAME:-}" ] && printf "  %-20s %s\n" "Host tunnel name:" "${HOST_TUNNEL_NAME}"
  [ -n "${HOST_TUNNEL_ID:-}" ]   && printf "  %-20s %s\n" "Host tunnel ID:"   "${HOST_TUNNEL_ID}"
  printf "  %-20s %s\n" "Host connect:"   "ssh ${VM_SSH_USER}@${HOST_TUNNEL_HOST}"
  echo ""
  printf "  %-20s %s\n" "VM hostname:"    "${VM_TUNNEL_HOST}"
  printf "  %-20s %s\n" "VM tunnel name:" "${VM_TUNNEL_NAME}"
  printf "  %-20s %s\n" "VM connect:"     "ssh ${VM_SSH_USER}@${VM_TUNNEL_HOST}"
  echo ""
  echo -e "${BOLD}  ── Steps Completed ─────────────────────────────────────────${RESET}"
  echo "  3. Packages installed     (curl wget openssh fail2ban dkms linux-headers)"
  echo "  4. SSH configured         (sshd + fail2ban enabled, PasswordAuth yes)"
  echo "  5. Static IP set          (${VM_STATIC_IP} via ${VM_GATEWAY})"
  echo "  6. Shared folder mounted  (/mnt/${SHARED_TAG})"
  echo "  7. i915-sriov-dkms        (installed in guest)"
  echo "  8. cloudflared            (host: ${HOST_TUNNEL_HOST} → VM: ${VM_TUNNEL_HOST})"
  echo ""
  echo -e "${BOLD}  ── VM Status ────────────────────────────────────────────────${RESET}"
  virsh list --all 2>/dev/null | sed 's/^/  /' || true
  echo ""
  echo -e "${BOLD}  ── SSH Access ───────────────────────────────────────────────${RESET}"
  printf "  %-24s %s\n" "Direct (LAN):"        "ssh ${VM_SSH_USER}@${vm_ip}"
  printf "  %-24s %s\n" "Via host tunnel:"      "ssh ${VM_SSH_USER}@${HOST_TUNNEL_HOST}"
  printf "  %-24s %s\n" "VM tunnel status:"     "${CF_TUNNEL_RESULT:-not tested}"
  printf "  %-24s %s\n" "Via VM tunnel:"        "ssh ${VM_SSH_USER}@${VM_TUNNEL_HOST}"
  printf "  %-24s %s\n" "Via VM tunnel (raw):"  "ssh -o ProxyCommand='websocat -E --binary - wss://%h' ${VM_SSH_USER}@${VM_TUNNEL_HOST}"
  echo ""
  echo -e "${BOLD}  ── Files ───────────────────────────────────────────────────${RESET}"
  printf "  %-18s %s\n" "VM conf:" "$VM_CONF"
  printf "  %-18s %s\n" "State:"   "${VM_CONF_DIR}/.state"
  echo ""
  echo -e "${BOLD}  ── Network Diagram ─────────────────────────────────────────${RESET}"
  echo "  Internet ──cloudflare──▶ Host ($HOST_IP / ${HOST_TUNNEL_HOST})"
  echo "                               └──virbr0 NAT──▶ VM ($vm_ip / ${VM_TUNNEL_HOST})"
  echo ""
  echo -e "${BOLD}  ── Client setup (phone/laptop) ─────────────────────────────${RESET}"
  echo "  # Install VM client (sets up 'ssh ${VM_NAME}'):"
  echo "  bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase3-client.sh)"
  echo "  # Windows:"
  echo "  irm https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase3-client.ps1 | iex"
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

  # Steps 3–8: configure VM internals over SSH — skip if already done
  local _cf_running; _cf_running="$(ssh -T -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=5 -o BatchMode=yes "${VM_SSH_USER}@${VM_SSH_HOST}" \
    "systemctl is-active cloudflared 2>/dev/null || echo inactive" 2>/dev/null || echo inactive)"
  if [ "$_cf_running" = "active" ]; then
    ok "VM already configured (cloudflared active) — skipping remote setup."
  else
    run_remote_setup
  fi

  # Write tunnel info back to conf
  update_vm_conf

  # Test cloudflared websocat SSH tunnel
  test_cf_tunnel

  # Mark phase3 done in .state
  [ -f "$_STATE" ] && sed -i 's/PHASE3_DONE=.*/PHASE3_DONE="yes"/' "$_STATE" || true

  _snap_post "phase3 vm internal setup complete"
  print_summary
}

main "$@"
