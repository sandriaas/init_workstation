#!/usr/bin/env bash
# =============================================================================
# dokploy-cloudflared.sh — Rev5.7.2
# Install Dokploy + wire Cloudflare tunnel for app HTTP traffic
# =============================================================================
# Steps:
#   0. Select VM conf
#   1. Ensure cloudflared installed on host
#   2. Cloudflare auth (reuses saved token/cert from phase1/phase3)
#   3. Select domain + subdomain prefix for apps
#   4. Create CF tunnel  dokploy-<vmname>
#   5. Route wildcard DNS  *.domain → tunnel
#   6. SSH into VM → install Dokploy + deploy cloudflared container on dokploy-network
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()     { echo -e "${RED}[ERR]${RESET}  $*" >&2; }
ask()     { echo -e "${YELLOW}[?]${RESET} $*"; }
confirm() { ask "$1 [Y/n]: "; read -r _r; [[ "${_r:-Y}" =~ ^[Yy]$ ]]; }
section() { echo -e "\n${BOLD}══ $* ══${RESET}"; }
step()    { echo -e "\n${BOLD}  ── $* ──${RESET}"; }

trap '_ec=$?; [ $_ec -ne 0 ] && err "Failed at line ${LINENO} (exit ${_ec})"' ERR

[ "$EUID" -ne 0 ] && { warn "Re-running with sudo..."; exec sudo bash "$0" "$@"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VM_CONF_DIR="${REPO_DIR}/generated-vm"

# =============================================================================
# Cloudflare helpers (mirrors phase3.sh)
# =============================================================================
CF_DOMAIN=""
CF_API_TOKEN_FILE=""
CF_DOMAIN_FILE=""

_cf_init_paths() {
  local home="${SUDO_USER:+$(eval echo "~$SUDO_USER")}"
  home="${home:-$HOME}"
  CF_API_TOKEN_FILE="${home}/.cloudflared/api-token"
  CF_DOMAIN_FILE="${home}/.cloudflared/minipc-domain"
}

cf_load_api_token() {
  [ -f "$CF_API_TOKEN_FILE" ] && cat "$CF_API_TOKEN_FILE" 2>/dev/null || true
}

cf_store_api_token() {
  mkdir -p "$(dirname "$CF_API_TOKEN_FILE")"
  echo "$1" > "$CF_API_TOKEN_FILE"
  chmod 600 "$CF_API_TOKEN_FILE"
}

cf_list_zones() {
  local token="${1:-}"; [ -z "$token" ] && return 1
  curl -sf -H "Authorization: Bearer $token" \
    "https://api.cloudflare.com/client/v4/zones?per_page=50&status=active" \
    | grep -oP '"name"\s*:\s*"[^"]*"' | sed 's/"name"[[:space:]]*:[[:space:]]*"//;s/"//' 2>/dev/null
}

ensure_host_cloudflared() {
  command -v cloudflared &>/dev/null && {
    ok "cloudflared: $(cloudflared --version 2>/dev/null | head -1)"; return
  }
  info "Installing cloudflared on host..."
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
    err "Cannot install cloudflared — install manually."; exit 1
  fi
  ok "cloudflared: $(cloudflared --version 2>/dev/null | head -1)"
}

cf_ensure_auth() {
  local home="${SUDO_USER:+$(eval echo "~$SUDO_USER")}"; home="${home:-$HOME}"
  local cf_user="${SUDO_USER:-$USER}"
  if [ -f "${home}/.cloudflared/cert.pem" ] || sudo -u "$cf_user" cloudflared tunnel list >/dev/null 2>&1; then
    ok "Cloudflare auth confirmed."; return
  fi
  warn "Not authenticated with Cloudflare."
  echo "  1) Browser login (recommended)"
  echo "  2) API token"
  local _stored; _stored=$(cf_load_api_token)
  [ -n "$_stored" ] && echo "  ✓ Saved token detected"
  ask "Choice [1/2]:"; read -r _auth
  if [ "${_auth:-1}" = "2" ]; then
    local _token=""
    if [ -n "$_stored" ]; then
      ask "Use saved token? [Y/n]:"; read -r _use
      [[ "${_use:-Y}" =~ ^[Yy]$ ]] && _token="$_stored"
    fi
    [ -z "$_token" ] && { ask "API token:"; read -rs _token; echo ""; }
    cf_store_api_token "$_token"
    export CLOUDFLARE_API_TOKEN="$_token"
    sudo -u "$cf_user" CLOUDFLARE_API_TOKEN="$_token" cloudflared tunnel login --no-browser 2>/dev/null || true
  else
    sudo -u "$cf_user" cloudflared login
  fi
}

cf_select_domain() {
  local token="${1:-}"
  local stored=""; [ -f "$CF_DOMAIN_FILE" ] && stored=$(cat "$CF_DOMAIN_FILE" 2>/dev/null)
  if [ -n "$token" ]; then
    local zones; zones=$(cf_list_zones "$token" || true)
    if [ -n "$zones" ]; then
      echo ""
      local i=1 zone_arr=()
      while IFS= read -r z; do
        zone_arr+=("$z")
        local m=""; [ "$z" = "$stored" ] && m=" ← current"
        printf "    %d) %s%s\n" "$i" "$z" "$m"
        (( i++ ))
      done <<< "$zones"
      echo ""
      ask "Select domain [1-${#zone_arr[@]}, default=1]:"; read -r _c
      _c="${_c:-1}"
      if [[ "$_c" =~ ^[0-9]+$ ]] && [ "$_c" -ge 1 ] && [ "$_c" -le "${#zone_arr[@]}" ]; then
        CF_DOMAIN="${zone_arr[$((_c-1))]}"
      else
        CF_DOMAIN="${zone_arr[0]}"
      fi
    else
      warn "Could not list domains."
      ask "Domain (e.g. example.com):"; read -r CF_DOMAIN
    fi
  elif [ -n "$stored" ]; then
    ask "Domain [${stored}]:"; read -r _d; CF_DOMAIN="${_d:-$stored}"
  else
    ask "Domain (e.g. example.com):"; read -r CF_DOMAIN
  fi
  ok "Domain: $CF_DOMAIN"
  mkdir -p "$(dirname "$CF_DOMAIN_FILE")"
  echo "$CF_DOMAIN" > "$CF_DOMAIN_FILE"
}

# =============================================================================
# Step 0: Select VM conf
# =============================================================================
select_conf() {
  section "Select VM"
  local confs=()
  while IFS= read -r f; do confs+=("$f"); done < <(find "$VM_CONF_DIR" -maxdepth 1 -name "*.conf" 2>/dev/null | sort)

  if [ ${#confs[@]} -eq 0 ]; then
    err "No VM confs in ${VM_CONF_DIR}. Run phase2 first."; exit 1
  elif [ ${#confs[@]} -eq 1 ]; then
    VM_CONF="${confs[0]}"
    ok "Using: $(basename "$VM_CONF")"
  else
    local i=1
    for c in "${confs[@]}"; do printf "  %d) %s\n" "$i" "$(basename "$c")"; (( i++ )); done
    ask "Select [1-${#confs[@]}, default=1]:"; read -r _c
    _c="${_c:-1}"
    VM_CONF="${confs[$((_c-1))]}"
    ok "Using: $(basename "$VM_CONF")"
  fi

  # shellcheck source=/dev/null
  source "$VM_CONF"
  VM_SSH_HOST="${VM_STATIC_IP%/*}"
  VM_SSH_USER="${VM_USER}"
}

# =============================================================================
# Step 0b: Verify VM SSH is reachable
# =============================================================================
_ssh_alive() { timeout 3 bash -c "echo >/dev/tcp/${1}/22" 2>/dev/null; }

wait_for_vm_ssh() {
  step "Step 0b: Check VM SSH (${VM_SSH_USER}@${VM_SSH_HOST})"
  ssh-keygen -R "${VM_SSH_HOST}" 2>/dev/null || true

  if _ssh_alive "$VM_SSH_HOST"; then
    ok "VM SSH reachable at ${VM_SSH_HOST}"
    return
  fi

  warn "VM SSH not reachable at ${VM_SSH_HOST}."
  echo ""
  echo "  Is the VM running?  sudo virsh start ${VM_NAME:-vm}"
  echo ""
  ask "Enter alternative IP/hostname, or press Enter to retry:"; read -r _alt
  if [ -n "$_alt" ]; then
    VM_SSH_HOST="$_alt"
    _ssh_alive "$VM_SSH_HOST" || { err "Still not reachable at ${VM_SSH_HOST}"; exit 1; }
    ok "VM SSH reachable at ${VM_SSH_HOST}"
  else
    # Poll for up to 2 min
    info "Polling SSH at ${VM_SSH_HOST} (up to 2 min)..."
    local i=0
    while [ $i -lt 24 ]; do
      _ssh_alive "$VM_SSH_HOST" && { echo ""; ok "VM SSH reachable at ${VM_SSH_HOST}"; return; }
      printf "\r  Waiting... (%d/24)  " "$i"; sleep 5; i=$((i+1))
    done
    echo ""
    err "VM not reachable after 2 min. Start it with: sudo virsh start ${VM_NAME:-vm}"
    exit 1
  fi
}

# =============================================================================
# Step 4+5: Create tunnel + route wildcard DNS
# =============================================================================
DOKPLOY_TUNNEL_ID=""
DOKPLOY_TUNNEL_NAME=""
DOKPLOY_CREDS_B64=""

setup_dokploy_tunnel() {
  local cf_user="${SUDO_USER:-$USER}"
  DOKPLOY_TUNNEL_NAME="dokploy-${VM_NAME:-server}"

  step "Step 4: CF tunnel — ${DOKPLOY_TUNNEL_NAME}"
  if ! sudo -u "$cf_user" cloudflared tunnel list 2>/dev/null | grep -q "${DOKPLOY_TUNNEL_NAME}"; then
    info "Creating tunnel '${DOKPLOY_TUNNEL_NAME}'..."
    sudo -u "$cf_user" cloudflared tunnel create "${DOKPLOY_TUNNEL_NAME}"
    ok "Tunnel created."
  else
    ok "Tunnel '${DOKPLOY_TUNNEL_NAME}' already exists."
  fi

  DOKPLOY_TUNNEL_ID=$(sudo -u "$cf_user" cloudflared tunnel list 2>/dev/null \
    | awk -v n="${DOKPLOY_TUNNEL_NAME}" '$0 ~ n {print $1}' | head -1)
  [ -z "$DOKPLOY_TUNNEL_ID" ] && { err "Could not get tunnel ID."; exit 1; }
  ok "Tunnel ID: ${DOKPLOY_TUNNEL_ID}"

  step "Step 5: Wildcard DNS — *.${CF_DOMAIN} → tunnel"
  sudo -u "$cf_user" cloudflared tunnel route dns "${DOKPLOY_TUNNEL_NAME}" "*.${CF_DOMAIN}" 2>/dev/null \
    && ok "DNS routed: *.${CF_DOMAIN}" \
    || warn "DNS route failed (record may already exist — continuing)"

  # Base64-encode credentials for VM
  local creds_home; creds_home="$(eval echo ~${cf_user})"
  local creds_file="${creds_home}/.cloudflared/${DOKPLOY_TUNNEL_ID}.json"
  if [ -f "$creds_file" ]; then
    DOKPLOY_CREDS_B64=$(base64 -w 0 "$creds_file" 2>/dev/null || base64 "$creds_file")
    ok "Credentials ready."
  else
    err "Credentials not found: ${creds_file}"; exit 1
  fi
}

# =============================================================================
# Step 6: SSH into VM — install Dokploy + deploy cloudflared container
# =============================================================================
run_vm_setup() {
  section "Step 6 — VM Setup (${VM_SSH_USER}@${VM_SSH_HOST})"

  ssh -T -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${VM_SSH_USER}@${VM_SSH_HOST}" \
    "DOKPLOY_TUNNEL_ID='${DOKPLOY_TUNNEL_ID}' \
     DOKPLOY_TUNNEL_NAME='${DOKPLOY_TUNNEL_NAME}' \
     DOKPLOY_CREDS_B64='${DOKPLOY_CREDS_B64}' \
     DOKPLOY_DOMAIN='${CF_DOMAIN}' \
     sudo -E bash -s" <<'REMOTE'
set -euo pipefail
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}  [OK]${RESET}  $*"; }
info() { echo -e "${CYAN}  [>>]${RESET}  $*"; }
warn() { echo -e "${YELLOW}  [!!]${RESET}  $*"; }
step() { echo -e "\n${BOLD}  ── $* ──${RESET}"; }

# ── Install Dokploy ───────────────────────────────────────────────────────────
step "Install Dokploy"
if docker ps 2>/dev/null | grep -q "dokploy"; then
  ok "Dokploy already running — skipping install."
else
  info "Running Dokploy installer (~2 min)..."
  curl -sSL https://dokploy.com/install.sh | sh
  ok "Dokploy installed."
fi

# ── Deploy cloudflared on dokploy-network ────────────────────────────────────
step "Deploy cloudflared app tunnel (${DOKPLOY_TUNNEL_NAME})"

# Write credentials + config
mkdir -p /etc/cloudflared-dokploy
echo "${DOKPLOY_CREDS_B64}" | base64 -d > /etc/cloudflared-dokploy/creds.json
cat > /etc/cloudflared-dokploy/config.yml <<CFCONFIG
tunnel: ${DOKPLOY_TUNNEL_ID}
credentials-file: /etc/cloudflared/creds.json
ingress:
  - hostname: "*.${DOKPLOY_DOMAIN}"
    service: http://dokploy-traefik:80
  - service: http_status:404
CFCONFIG

# Wait for Dokploy to create dokploy-network (up to 90s)
_tries=0
info "Waiting for dokploy-network..."
while [ $_tries -lt 18 ] && ! docker network ls 2>/dev/null | grep -q "dokploy-network"; do
  sleep 5; _tries=$((_tries+1))
done
docker network ls | grep -q "dokploy-network" || { warn "dokploy-network not found — Dokploy may not have started yet."; }

# Deploy container
docker rm -f cloudflared-dokploy 2>/dev/null || true
docker run -d \
  --name cloudflared-dokploy \
  --restart unless-stopped \
  --network dokploy-network \
  -v /etc/cloudflared-dokploy/creds.json:/etc/cloudflared/creds.json:ro \
  -v /etc/cloudflared-dokploy/config.yml:/etc/cloudflared/config.yml:ro \
  cloudflare/cloudflared:latest tunnel --config /etc/cloudflared/config.yml run

ok "cloudflared-dokploy running on dokploy-network"
ok "App traffic: *.${DOKPLOY_DOMAIN} → dokploy-traefik:80"
REMOTE
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║              ✓  DOKPLOY + CLOUDFLARE COMPLETE               ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "${BOLD}  ├─ Tunnel ──────────────────────────────────────────────────${RESET}"
  printf "  │  %-20s %s\n" "Name:"        "${DOKPLOY_TUNNEL_NAME}"
  printf "  │  %-20s %s\n" "ID:"          "${DOKPLOY_TUNNEL_ID}"
  printf "  │  %-20s %s\n" "Wildcard DNS:" "*.${CF_DOMAIN} → tunnel"
  echo   "  │"
  printf "  │  Traffic flow:  Internet → CF Tunnel → cloudflared (dokploy-network) → dokploy-traefik:80\n"
  echo ""
  echo -e "${BOLD}  ├─ Dokploy ──────────────────────────────────────────────────${RESET}"
  printf "  │  %-20s http://%s:3000\n" "Dashboard:"  "${VM_SSH_HOST}"
  echo   "  │"
  echo   "  │  ⚠  In Dokploy → Settings → Traefik:"
  echo   "  │     • Disable Let's Encrypt  (Cloudflare handles SSL)"
  echo   "  │     • Use 'web' entrypoint (HTTP) for app domains"
  echo   "  │"
  echo   "  │  To add an app:"
  echo   "  │     1. Deploy app in Dokploy"
  echo   "  │     2. Domains tab → add  app.${CF_DOMAIN}  (port 80, no HTTPS toggle)"
  echo   "  │     3. App is live at  https://app.${CF_DOMAIN}  via CF tunnel"
  echo ""
  echo -e "${BOLD}  └─ Cloudflare SSL/TLS ───────────────────────────────────────${RESET}"
  echo   "     In CF Dashboard → SSL/TLS: set to Full (not Flexible)"
  echo ""
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  echo -e "${BOLD}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║   Rev5.7.2 — Dokploy + Cloudflare App Tunnel Setup          ║"
  echo "║   Run after phase3 completes (VM must be running)           ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo -e "${RESET}"

  _cf_init_paths

  # Step 0: pick VM conf
  select_conf

  # Step 0b: verify VM SSH reachable
  wait_for_vm_ssh

  # Step 1: ensure cloudflared on host
  step "Step 1: Host cloudflared"
  ensure_host_cloudflared

  # Step 2: CF auth
  step "Step 2: Cloudflare auth"
  cf_ensure_auth

  # Step 3: select domain
  step "Step 3: Select domain"
  local _api_token; _api_token=$(cf_load_api_token)
  cf_select_domain "$_api_token"

  # Steps 4+5: create tunnel + route DNS
  setup_dokploy_tunnel

  # Step 6: VM — install Dokploy + deploy cloudflared container
  run_vm_setup

  print_summary
}

main "$@"
