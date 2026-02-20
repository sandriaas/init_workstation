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
#   7. i915 guest driver check (host-only DKMS not needed in VM)
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

# ─── Cloudflare helpers ──────────────────────────────────────────────────────
BLUE='\033[0;34m'
CF_API_TOKEN_FILE=""
CF_DOMAIN_FILE=""
CF_DOMAIN=""

_cf_init_paths() {
  local home="${SUDO_USER:+$(eval echo "~$SUDO_USER")}"
  home="${home:-$HOME}"
  CF_API_TOKEN_FILE="${home}/.cloudflared/api-token"
  CF_DOMAIN_FILE="${home}/.cloudflared/minipc-domain"
}

ensure_host_cloudflared() {
  if command -v cloudflared &>/dev/null; then
    ok "cloudflared installed: $(cloudflared --version 2>/dev/null | head -1)"
    return
  fi
  info "cloudflared not installed on host. Installing..."
  if command -v pacman &>/dev/null; then
    pacman -S --noconfirm --needed cloudflared
  elif command -v apt-get &>/dev/null; then
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
      | tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
    apt-get update && apt-get install -y cloudflared
  elif command -v dnf &>/dev/null; then
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-x86_64.rpm \
      -o /tmp/cloudflared.rpm && rpm -i /tmp/cloudflared.rpm
  else
    err "Cannot install cloudflared — unknown package manager. Install manually."
    exit 1
  fi
  ok "cloudflared installed: $(cloudflared --version 2>/dev/null | head -1)"
}

cf_list_zones() {
  local token="${1:-}"
  [ -z "$token" ] && return 1
  curl -sf -H "Authorization: Bearer $token" \
    "https://api.cloudflare.com/client/v4/zones?per_page=50&status=active" \
    | grep -oP '"name"\s*:\s*"[^"]*"' | sed 's/"name"[[:space:]]*:[[:space:]]*"//;s/"//' 2>/dev/null
}

cf_load_api_token() {
  [ -f "$CF_API_TOKEN_FILE" ] && cat "$CF_API_TOKEN_FILE" 2>/dev/null || true
}

cf_store_api_token() {
  local token="$1" home
  home="$(dirname "$CF_API_TOKEN_FILE")"
  mkdir -p "$home"
  echo "$token" > "$CF_API_TOKEN_FILE"
  chmod 600 "$CF_API_TOKEN_FILE"
}

cf_ensure_auth() {
  local home="${SUDO_USER:+$(eval echo "~$SUDO_USER")}"
  home="${home:-$HOME}"
  local cf_user="${SUDO_USER:-$USER}"

  if [ -f "${home}/.cloudflared/cert.pem" ] || cloudflared tunnel list >/dev/null 2>&1; then
    ok "Host cloudflared authenticated."
    return
  fi

  warn "Host cloudflared not authenticated."
  info "Choose authentication method:"
  echo "  1) Browser login (opens browser — recommended)"
  echo "  2) API token    (headless/server)"
  local _stored; _stored=$(cf_load_api_token)
  [ -n "$_stored" ] && echo "  ✓ Saved API token detected"
  ask "Choice [1/2]: "; read -r _auth

  if [ "${_auth:-1}" = "2" ]; then
    local _token=""
    if [ -n "$_stored" ]; then
      ask "Use saved API token? [Y/n]: "; read -r _use
      [[ "${_use:-Y}" =~ ^[Yy]$ ]] && _token="$_stored"
    fi
    if [ -z "$_token" ]; then
      ask "Cloudflare API token: "; read -rs _token; echo ""
    fi
    cf_store_api_token "$_token"
    export CLOUDFLARE_API_TOKEN="$_token"
    sudo -u "$cf_user" CLOUDFLARE_API_TOKEN="$_token" cloudflared tunnel login --no-browser 2>/dev/null \
      || info "Falling back to token-based route DNS"
  else
    info "Opening Cloudflare browser login..."
    sudo -u "$cf_user" cloudflared login
  fi
}

cf_select_domain() {
  local token="${1:-}"
  local stored_domain=""
  [ -f "$CF_DOMAIN_FILE" ] && stored_domain=$(cat "$CF_DOMAIN_FILE" 2>/dev/null)

  if [ -n "$token" ]; then
    info "Fetching domains from your Cloudflare account..."
    local zones
    zones=$(cf_list_zones "$token" || true)
    if [ -n "$zones" ]; then
      echo ""
      echo "  Available domains:"
      local i=1 zone_arr=()
      while IFS= read -r z; do
        zone_arr+=("$z")
        local marker=""
        [ "$z" = "$stored_domain" ] && marker=" ← current"
        printf "    %d) %s%s\n" "$i" "$z" "$marker"
        (( i++ ))
      done <<< "$zones"
      echo ""
      ask "Select domain [1-${#zone_arr[@]}, default=1]: "; read -r _choice
      _choice="${_choice:-1}"
      if [[ "$_choice" =~ ^[0-9]+$ ]] && [ "$_choice" -ge 1 ] && [ "$_choice" -le "${#zone_arr[@]}" ]; then
        CF_DOMAIN="${zone_arr[$((_choice-1))]}"
      else
        warn "Invalid choice, using first domain."
        CF_DOMAIN="${zone_arr[0]}"
      fi
    else
      warn "Could not list domains via API."
      _cf_domain_fallback "$stored_domain"
    fi
  else
    _cf_domain_fallback "$stored_domain"
  fi
  ok "Selected domain: $CF_DOMAIN"
  mkdir -p "$(dirname "$CF_DOMAIN_FILE")"
  echo "$CF_DOMAIN" > "$CF_DOMAIN_FILE"
}

_cf_domain_fallback() {
  local stored="${1:-}"
  if [ -n "$stored" ]; then
    ask "Domain [${stored}]: "; read -r _d
    CF_DOMAIN="${_d:-$stored}"
  else
    # Try to detect from HOST_TUNNEL_DOMAIN or existing config
    local _detected="${HOST_TUNNEL_DOMAIN:-}"
    if [ -z "$_detected" ]; then
      ask "Your Cloudflare domain (e.g. example.com): "; read -r CF_DOMAIN
    else
      ask "Domain [${_detected}]: "; read -r _d
      CF_DOMAIN="${_d:-$_detected}"
    fi
  fi
}

KEEP_VM_TUNNEL="no"
cf_detect_vm_tunnel() {
  KEEP_VM_TUNNEL="no"

  # Can't check VM cloudflared status without SSH keys (password-only auth).
  # Instead, check if we have a VM_TUNNEL_HOST in the conf already.
  if [ -n "${VM_TUNNEL_HOST:-}" ] && [ "${VM_TUNNEL_HOST}" != "not set" ]; then
    echo ""
    echo -e "${GREEN}  ✓ VM tunnel configured: ${VM_TUNNEL_HOST}${RESET}"
    echo ""
    ask "Keep existing tunnel hostname? [Y/n]: "; read -r _keep
    if [[ "${_keep:-Y}" =~ ^[Yy]$ ]]; then
      KEEP_VM_TUNNEL="yes"
      return
    fi
  fi
}

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
  timeout 3 bash -c "echo >/dev/tcp/${host}/22" 2>/dev/null
}

wait_for_ssh() {
  section "Step 2 — Wait for VM SSH"

  # Clear stale known_hosts — VM may have been recreated with new host keys
  ssh-keygen -R "${VM_STATIC_IP%/*}" 2>/dev/null || true

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
  info "Steps: packages → SSH config → static IP → shared folder → i915 check → cloudflared tunnel"
  echo ""

  # Ensure VM has internet via libvirt NAT (UFW may block FORWARD)
  sudo ufw route allow in on virbr0 out on virbr0 >/dev/null 2>&1 || true
  sudo ufw route allow in on virbr0 >/dev/null 2>&1 || true
  sudo ufw route allow out on virbr0 >/dev/null 2>&1 || true
  sudo iptables -t nat -C POSTROUTING -s 192.168.122.0/24 ! -d 192.168.122.0/24 -j MASQUERADE 2>/dev/null \
    || sudo iptables -t nat -A POSTROUTING -s 192.168.122.0/24 ! -d 192.168.122.0/24 -j MASQUERADE 2>/dev/null || true

  ssh -T -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${VM_SSH_USER}@${VM_SSH_HOST}" \
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
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget openssh-server fail2ban docker.io docker-compose
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y curl wget openssh-server fail2ban docker docker-compose
elif command -v pacman >/dev/null 2>&1; then
  pacman -Syu --noconfirm --needed curl wget openssh fail2ban docker docker-compose
fi
ok "Packages installed."

# ── Docker 29 compat: DOCKER_MIN_API_VERSION drop-in ────────────────────────
# Docker 29 raised min API version (1.24→1.44), breaking Traefik/Coolify.
# Apply the officially documented drop-in so any Traefik version works.
step "Step 3b: Docker 29 / Traefik compat fix"
_dropin="/etc/systemd/system/docker.service.d/min-api-version.conf"
if grep -qs "DOCKER_MIN_API_VERSION" "$_dropin" 2>/dev/null; then
  ok "DOCKER_MIN_API_VERSION drop-in already present — skipping."
else
  mkdir -p /etc/systemd/system/docker.service.d
  cat > "$_dropin" <<'DROPIN'
[Service]
Environment="DOCKER_MIN_API_VERSION=1.24"
DROPIN
  systemctl enable --now docker || true
  systemctl daemon-reload
  systemctl restart docker || true
  ok "Docker min-api-version drop-in applied (Docker 29 / Traefik compat fix)."
fi

# ── Step 4: SSH + fail2ban ──────────────────────────────────────────────────
step "Step 4: Configure SSH + fail2ban"
if grep -q "^PasswordAuthentication yes" /etc/ssh/sshd_config 2>/dev/null \
   && systemctl is-active --quiet sshd 2>/dev/null; then
  ok "SSH already configured — skipping."
else
  systemctl enable --now sshd || systemctl enable --now ssh || true
  systemctl enable --now fail2ban || true
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config
  systemctl reload sshd || systemctl reload ssh || true
  ok "SSH enabled. fail2ban enabled."
fi

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

# ── Step 7: i915 guest driver check ────────────────────────────────────────
step "Step 7: i915 SR-IOV guest driver"
# i915-sriov-dkms is HOST-only (creates VFs). VM uses built-in i915 driver.
# Ubuntu 24.04 kernel 6.8+ handles SR-IOV VF passthrough natively.
if lsmod 2>/dev/null | grep -q "^i915"; then
  ok "i915 driver loaded — SR-IOV VF will work when attached."
else
  warn "i915 not loaded — will load automatically when GPU VF is attached."
fi

# ── Step 8: cloudflared + tunnel ───────────────────────────────────────────
step "Step 8: Install cloudflared"
# NOTE: We now automate the token retrieval from the host, so we just install and start with the token passed in VM_TUNNEL_TOKEN

# 1. Install cloudflared (using same logic but simplified since we know it's Ubuntu/Debian in VM usually)
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

step "Step 8b: Configure Cloudflare Tunnel (VM: ${VM_TUNNEL_NAME})"

if [ -n "${VM_TUNNEL_TOKEN:-}" ]; then
  info "Configuring tunnel with provided token..."
  cloudflared service uninstall 2>/dev/null || true
  cloudflared service install "$VM_TUNNEL_TOKEN"
  systemctl enable --now cloudflared || true
  ok "Tunnel installed via token."
else
  # Service already installed — just make sure it's running
  systemctl enable --now cloudflared 2>/dev/null || true
  warn "No tunnel token provided — run phase3 again with token to activate tunnel."
fi

echo ""
ok "VM internal configuration complete."
REMOTE
}

# =============================================================================
# Test cloudflared tunnel via websocat SSH (same method as phase1/phase3 client)
# ProxyCommand: websocat -E --binary - wss://%h
# =============================================================================
CF_TUNNEL_RESULT="not tested"
test_cf_tunnel() {
  [ -n "${VM_TUNNEL_HOST:-}" ] || { CF_TUNNEL_RESULT="no VM_TUNNEL_HOST configured"; return; }
  info "Testing SSH tunnel → ${VM_TUNNEL_HOST} (via websocat)..."

  if ! command -v websocat &>/dev/null; then
    CF_TUNNEL_RESULT="websocat not found (run phase1 to install)"
    warn "$CF_TUNNEL_RESULT"; return
  fi

  local attempts=0
  while [ $attempts -lt 6 ]; do
    if command -v websocat >/dev/null 2>&1 && \
       timeout 10 websocat -E --binary - "wss://${VM_TUNNEL_HOST}" </dev/null >/dev/null 2>&1; then
      CF_TUNNEL_RESULT="✓  working"
      ok "Tunnel SSH working:  ssh ${VM_SSH_USER}@${VM_TUNNEL_HOST}"
      return
    fi
    (( attempts++ )) || true
    [ $attempts -lt 6 ] && { info "Not reachable yet (${attempts}/6) — waiting 10s..."; sleep 10; }
  done

  CF_TUNNEL_RESULT="not reachable yet (DNS may still propagate)"
  warn "Tunnel SSH not reachable yet. Check in VM:"
  warn "  sudo systemctl status cloudflared"
  warn "  sudo journalctl -u cloudflared -n 20"
  warn "Manual connect (after reachable):"
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
  local vm_ip="${VM_SSH_HOST:-${VM_STATIC_IP%/*}}"
  local HOST_IP; HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  local VM_STATE; VM_STATE="$(virsh domstate "${VM_NAME:-}" 2>/dev/null || echo unknown)"
  local cf_status; cf_status="$(systemctl is-active cloudflared 2>/dev/null || echo inactive)"

  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║                  ✓  PHASE 3 COMPLETE                        ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"

  # ── VM ──────────────────────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}  ┌─ VM ────────────────────────────────────────────────────────${RESET}"
  printf "  │  %-16s %s  (%s)\n"  "Name:"        "${VM_NAME:-?}" "${VM_HOSTNAME:-?}"
  printf "  │  %-16s %s\n"        "User:"        "${VM_SSH_USER:-${VM_USER:-?}}"
  printf "  │  %-16s %s vCPU  •  %s MB RAM  •  %s GB disk\n" \
                                  "Resources:"   "${VM_VCPUS:-?}" "${VM_RAM_MB:-?}" "${VM_DISK_GB:-?}"
  printf "  │  %-16s %s  •  machine=%s  •  %s\n" \
                                  "CPU / Type:"  "${VM_CPU_MODEL:-?}" "${VM_MACHINE_TYPE:-?}" "${VM_OS_VARIANT:-?}"
  printf "  │  %-16s %s  •  firmware=%s\n" \
                                  "Disk:"        "${VM_DISK_PATH:-?}" "${VM_FIRMWARE:-uefi}"
  printf "  │  %-16s "            "State:"
  if [ "$VM_STATE" = "running" ]; then
    echo -e "${GREEN}${VM_STATE}${RESET}"
  else
    echo -e "${YELLOW}${VM_STATE}${RESET}"
  fi

  # ── Network ─────────────────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}  ├─ Network ──────────────────────────────────────────────────${RESET}"
  printf "  │  %-16s %s  (LAN)\n"                    "Host IP:"     "${HOST_IP:-?}"
  printf "  │  %-16s %s  (libvirt NAT)\n"            "VM IP:"       "$vm_ip"
  printf "  │  %-16s %s  /  %s\n"                    "Gateway/DNS:" "${VM_GATEWAY:-?}" "${VM_DNS:-?}"
  printf "  │  %-16s %s → %s  (virtiofs)\n"          "Shared:"      "${SHARED_DIR:-none}" "${SHARED_TAG:-none}"
  printf "  │  %-16s %s  (${VM_STATIC_IP:-?})\n"     "Static IP:"   "$vm_ip"
  echo   "  │"
  echo   "  │  Internet ──cloudflare──▶ host (${HOST_IP:-?})"
  echo   "  │                └──virbr0──▶ vm ($vm_ip)"

  # ── GPU ─────────────────────────────────────────────────────────────────────
  if [ "${GPU_PASSTHROUGH:-no}" = "yes" ]; then
    echo ""
    echo -e "${BOLD}  ├─ GPU Passthrough ──────────────────────────────────────────${RESET}"
    printf "  │  %-16s %s  (driver=%s, gen%s, VFs=%s)\n" \
                               "GPU:"        "${GPU_PCI_ID:-?}" "${GPU_DRIVER:-?}" "${GPU_GEN:-?}" "${GPU_VF_COUNT:-?}"
    printf "  │  %-16s %s\n"   "ROM:"        "${GPU_ROM_PATH:-none}"
    printf "  │  %-16s %s\n"   "IGD LPC:"    "${GPU_IGD_LPC:-no}"
  fi

  # ── Cloudflare Tunnels ──────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}  ├─ Cloudflare Tunnels ───────────────────────────────────────${RESET}"
  printf "  │  %-16s %s\n"  "Host tunnel:"    "ssh ${VM_SSH_USER:-${VM_USER:-?}}@${HOST_TUNNEL_HOST:-not set}"
  [ -n "${HOST_TUNNEL_ID:-}" ] && \
    printf "  │  %-16s %s\n" "Tunnel ID:"     "${HOST_TUNNEL_ID}"
  printf "  │  %-16s "       "Host CF status:"
  if [ "$cf_status" = "active" ]; then
    echo -e "${GREEN}active${RESET}"
  else
    echo -e "${YELLOW}${cf_status}${RESET}"
  fi
  echo   "  │"
  printf "  │  %-16s %s\n"  "VM hostname:"    "${VM_TUNNEL_HOST:-not set}"
  printf "  │  %-16s %s\n"  "VM tunnel name:" "${VM_TUNNEL_NAME:-not set}"
  printf "  │  %-16s "       "VM tunnel test:"
  if [[ "${CF_TUNNEL_RESULT:-}" == *"working"* ]]; then
    echo -e "${GREEN}${CF_TUNNEL_RESULT}${RESET}"
  else
    echo -e "${YELLOW}${CF_TUNNEL_RESULT:-not tested}${RESET}"
  fi

  # ── SSH Access ──────────────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}  ├─ SSH Access ───────────────────────────────────────────────${RESET}"
  printf "  │  %-16s %s\n"  "Direct (LAN):"   "ssh ${VM_SSH_USER:-${VM_USER:-?}}@${vm_ip}"
  printf "  │  %-16s %s\n"  "Via host tunnel:" "ssh ${VM_SSH_USER:-${VM_USER:-?}}@${HOST_TUNNEL_HOST:-?}"
  printf "  │  %-16s %s\n"  "Via VM tunnel:"   "ssh -o ProxyCommand='websocat -E --binary - wss://%h' ${VM_SSH_USER:-${VM_USER:-?}}@${VM_TUNNEL_HOST:-?}"
  printf "  │  %-16s %s\n"  "Console:"         "sudo virsh console ${VM_NAME:-?}  (Ctrl+] to exit)"

  # ── Steps Completed ─────────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}  ├─ Steps Completed ──────────────────────────────────────────${RESET}"
  echo "  │  ✓  3. Packages        (curl wget openssh fail2ban docker docker-compose + Docker 29 compat)"
  echo "  │  ✓  4. SSH configured  (sshd + fail2ban, PasswordAuth yes)"
  echo "  │  ✓  5. Static IP       (${VM_STATIC_IP:-?} via ${VM_GATEWAY:-?})"
  echo "  │  ✓  6. Shared folder   (/mnt/${SHARED_TAG:-hostshare})"
  echo "  │  ✓  7. i915 driver     (built-in, no DKMS needed in VM)"
  echo "  │  ✓  8. cloudflared     (automated: host tunnel → VM token → autostart)"

  # ── Files ────────────────────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}  ├─ Files ────────────────────────────────────────────────────${RESET}"
  printf "  │  %-16s %s\n"  "VM conf:"    "${VM_CONF:-?}"
  printf "  │  %-16s %s\n"  "State:"      "${VM_CONF_DIR}/.state"

  # ── Client Setup ─────────────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}  ├─ Client Setup (phone/laptop) ────────────────────────────────${RESET}"
  echo   "  │  # Add VM SSH config (run on each client):"
  echo   "  │  printf 'Host ${VM_NAME:-vm}\\n  HostName ${VM_TUNNEL_HOST:-?}\\n  ProxyCommand websocat -E --binary - wss://%%h\\n  User ${VM_SSH_USER:-${VM_USER:-?}}\\n' >> ~/.ssh/config"
  echo   "  │"
  echo   "  │  # Then connect with:"
  echo   "  │  ssh ${VM_NAME:-vm}"
  echo   "  │"
  echo   "  │  # Or run full client setup script:"
  echo   "  │  bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase1-client.sh)"

  # ── Next Steps ───────────────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}  └─ Next Steps ───────────────────────────────────────────────${RESET}"
  echo   "     Verify:"
  echo   "       bash scripts/check.sh"
  echo   "     VM console:"
  echo   "       sudo virsh console ${VM_NAME:-?}"
  echo   "     VM management:"
  echo   "       sudo virsh start/stop/destroy ${VM_NAME:-?}"
  echo   "     Next: run scripts/dokploy-cloudflared.sh to install Dokploy + CF app tunnel"
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

  # ── Automated Cloudflare Tunnel Setup ──
  echo ""
  echo -e "${BOLD}── Step 8b: Cloudflare Tunnel Automation ──${RESET}"

  # Init CF paths
  _cf_init_paths

  # 0. Ensure cloudflared is installed on host
  ensure_host_cloudflared

  # 1. Detect existing cloudflared in VM (uses global KEEP_VM_TUNNEL)
  cf_detect_vm_tunnel "$VM_SSH_USER" "$VM_SSH_HOST"

  if [ "$KEEP_VM_TUNNEL" = "yes" ]; then
    ok "Keeping existing VM tunnel: ${VM_TUNNEL_HOST}"
    sed -i "s|^VM_TUNNEL_HOST=.*|VM_TUNNEL_HOST=\"${VM_TUNNEL_HOST}\"|" "$VM_CONF" 2>/dev/null || true
    # Still run remote setup to ensure everything is up to date
    export VM_TUNNEL_HOST
    update_vm_conf
    test_cf_tunnel
    [ -f "$_STATE" ] && sed -i 's/PHASE3_DONE=.*/PHASE3_DONE="yes"/' "$_STATE" || true
    _snap_post "phase3 vm internal setup complete"
    print_summary
    return
  fi

  # 2. Ensure host cloudflared auth
  cf_ensure_auth

  # 3. Select domain + subdomain
  local _api_token; _api_token=$(cf_load_api_token)
  cf_select_domain "$_api_token"
  local cf_user="${SUDO_USER:-$USER}"

  # Show existing tunnels
  echo -e "\n${BOLD}── Existing Cloudflare Tunnels ──────────────────────────${RESET}"
  local _tlist
  _tlist=$(sudo -u "$cf_user" cloudflared tunnel list 2>/dev/null | tail -n +2) || true
  if [ -n "$_tlist" ]; then
    while IFS= read -r _tl; do
      local _tid _tname _mk=""
      _tid=$(awk '{print $1}' <<< "$_tl")
      _tname=$(awk '{print $2}' <<< "$_tl")
      [ "$_tname" = "${VM_TUNNEL_NAME}" ] && _mk=" ← this VM (${VM_NAME})"
      printf "    • %-36s  %s%s\n" "$_tid" "$_tname" "$_mk"
    done <<< "$_tlist"
  else
    echo "    (no tunnels yet)"
  fi
  echo ""

  # Subdomain prompt — sensible default
  local _cur_sub="${VM_TUNNEL_HOST%%.*}"
  { [ "$_cur_sub" = "not set" ] || [ -z "$_cur_sub" ]; } && _cur_sub="${VM_NAME:-vm}-ssh"
  echo "  Domain:   ${CF_DOMAIN}"
  echo "  Tunnel:   ${VM_TUNNEL_NAME}"
  [ -n "${VM_TUNNEL_HOST:-}" ] && [ "${VM_TUNNEL_HOST}" != "not set" ] && \
    echo "  Current:  ${VM_TUNNEL_HOST}"
  ask "  Subdomain [${_cur_sub}]:"; read -r _input_sub
  local _final_sub="${_input_sub:-${_cur_sub}}"
  VM_TUNNEL_HOST="${_final_sub}.${CF_DOMAIN}"
  echo ""
  echo -e "  ${BOLD}Will configure:${RESET}  ${VM_TUNNEL_HOST}  →  tunnel '${VM_TUNNEL_NAME}'"
  confirm "  Proceed?" || { info "Aborted by user."; exit 0; }
  sed -i "s|^VM_TUNNEL_HOST=.*|VM_TUNNEL_HOST=\"${VM_TUNNEL_HOST}\"|" "$VM_CONF" 2>/dev/null || true
  ok "VM Tunnel Host: ${VM_TUNNEL_HOST}"

  # 4. Create/Get Tunnel on Host
  info "Checking tunnel '${VM_TUNNEL_NAME}'..."
  if ! sudo -u "$cf_user" cloudflared tunnel list 2>/dev/null | grep -q "${VM_TUNNEL_NAME}"; then
      info "Creating tunnel '${VM_TUNNEL_NAME}'..."
      if ! sudo -u "$cf_user" cloudflared tunnel create "${VM_TUNNEL_NAME}"; then
           err "Failed to create tunnel."
           exit 1
      fi
      ok "Tunnel created."
  else
      ok "Tunnel '${VM_TUNNEL_NAME}' already exists."
  fi

  # 5. Get Tunnel Token
  info "Fetching tunnel token..."
  local VM_TUNNEL_TOKEN
  VM_TUNNEL_TOKEN=$(sudo -u "$cf_user" cloudflared tunnel token "${VM_TUNNEL_NAME}" 2>/dev/null)
  if [[ -z "$VM_TUNNEL_TOKEN" ]]; then
      err "Failed to get tunnel token."
      exit 1
  fi
  ok "Token retrieved."

  # Get tunnel ID for DNS verification
  local VM_TUNNEL_ID
  VM_TUNNEL_ID=$(sudo -u "$cf_user" cloudflared tunnel list 2>/dev/null \
    | awk -v n="${VM_TUNNEL_NAME}" '$0 ~ n {print $1}' | head -1)

  # 6. Route DNS (CNAME)
  local _expected_target="${VM_TUNNEL_ID}.cfargotunnel.com"
  info "Routing DNS: ${VM_TUNNEL_HOST} → Tunnel..."
  if sudo -u "$cf_user" cloudflared tunnel route dns "${VM_TUNNEL_NAME}" "${VM_TUNNEL_HOST}" 2>/dev/null; then
       ok "DNS route established: ${VM_TUNNEL_HOST}"
  else
       # Check if existing CNAME points to the wrong tunnel
       local _current; _current=$(dig +short CNAME "${VM_TUNNEL_HOST}" 2>/dev/null | head -1 | sed 's/\.$//')
       if [ -n "$_current" ] && [ "$_current" != "$_expected_target" ]; then
         warn "DNS '${VM_TUNNEL_HOST}' exists but points to WRONG tunnel:"
         warn "  Current:  ${_current}"
         warn "  Expected: ${_expected_target}"
         warn "  ⚠  Update this CNAME in Cloudflare Dashboard!"
       else
         warn "DNS route failed. Check if domain '${CF_DOMAIN}' is in your Cloudflare account."
       fi
  fi

  # Export for remote setup
  export VM_TUNNEL_HOST VM_TUNNEL_TOKEN

  # Steps 3–8: configure VM internals over SSH
  # With password-only auth, we can't silently probe VM state,
  # so always run the full remote setup (idempotent).
  run_remote_setup

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
