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

cf_fetch_zone_id() {
  local token="${1:-}" domain="${2:-}"
  [ -z "$token" ] || [ -z "$domain" ] && return 1
  curl -sf -H "Authorization: Bearer $token" \
    "https://api.cloudflare.com/client/v4/zones?name=${domain}&status=active" \
    | grep -oP '"id":"[a-f0-9]+"' | head -1 | cut -d'"' -f4
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
  echo ""
  echo "  1) Browser login"
  echo "  2) API token  ← recommended (one token for tunnels + DNS auto-sync)"
  echo ""
  echo "  For option 2, create a token at:"
  echo "    https://dash.cloudflare.com/profile/api-tokens"
  echo "  Required permissions:"
  echo "    • Account > Cloudflare Tunnel > Edit"
  echo "    • Zone > Zone > Read"
  echo "    • Zone > DNS > Edit"
  echo ""
  local _stored; _stored=$(cf_load_api_token)
  [ -n "$_stored" ] && echo "  ✓ Saved token detected"
  ask "Choice [1/2]:"; read -r _auth
  if [ "${_auth:-1}" = "2" ]; then
    local _token=""
    if [ -n "$_stored" ]; then
      ask "Use saved token? [Y/n]:"; read -r _use
      [[ "${_use:-Y}" =~ ^[Yy]$ ]] && _token="$_stored"
    fi
    [ -z "$_token" ] && { ask "API token:"; read -r _token; echo ""; }
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
        i=$((i+1))
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
    for c in "${confs[@]}"; do printf "  %d) %s\n" "$i" "$(basename "$c")"; i=$((i+1)); done
    ask "Select [1-${#confs[@]}, default=1]:"; read -r _c
    _c="${_c:-1}"
    VM_CONF="${confs[$((_c-1))]}"
    ok "Using: $(basename "$VM_CONF")"
  fi

  # shellcheck source=/dev/null
  # Temporarily disable nounset — conf file contains SHA-512 hash with $6$ literal
  set +u
  source "$VM_CONF"
  set -u
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
DOKPLOY_SUBDOMAINS=""   # space-separated, e.g. "dokploy app1 shop"
DOKPLOY_CF_ZONE_ID=""
DOKPLOY_CF_API_TOKEN=""

setup_dokploy_tunnel() {
  local cf_user="${SUDO_USER:-$USER}"
  DOKPLOY_TUNNEL_NAME="dokploy-${VM_NAME:-server}"

  step "Step 4: CF tunnel — ${DOKPLOY_TUNNEL_NAME}"

  # Show existing tunnels + confirm name
  echo ""
  echo -e "  ${BOLD}Existing Cloudflare Tunnels:${RESET}"
  local _tlist
  _tlist=$(sudo -u "$cf_user" cloudflared tunnel list 2>/dev/null | tail -n +2) || true
  if [ -n "$_tlist" ]; then
    while IFS= read -r _tl; do
      local _tid _tname _mk=""
      _tid=$(awk '{print $1}' <<< "$_tl")
      _tname=$(awk '{print $2}' <<< "$_tl")
      [ "$_tname" = "${DOKPLOY_TUNNEL_NAME}" ] && _mk=" ← will use this"
      printf "    • %-36s  %s%s\n" "$_tid" "$_tname" "$_mk"
    done <<< "$_tlist"
  else
    echo "    (no tunnels yet)"
  fi
  echo ""
  ask "  Tunnel name [${DOKPLOY_TUNNEL_NAME}]:"; read -r _tn
  DOKPLOY_TUNNEL_NAME="${_tn:-$DOKPLOY_TUNNEL_NAME}"

  # Dashboard subdomain
  echo ""
  ask "  Dashboard subdomain [dokploy]:"; read -r _dash
  local _dash_sub="${_dash:-dokploy}"
  DOKPLOY_SUBDOMAINS="${_dash_sub}"

  # Wildcard DNS explanation + confirm
  echo ""
  echo -e "  ${BOLD}Routing plan:${RESET}"
  echo "    ${_dash_sub}.${CF_DOMAIN}  →  Dokploy dashboard (:3000)"
  echo "    *.${CF_DOMAIN}            →  Dokploy Traefik (:80)  [all apps]"
  echo ""
  echo "  Note: CF wildcard CNAME only affects subdomains with NO existing DNS"
  echo "  record. Your existing A/CNAME records are not touched."
  confirm "  Proceed?" || { info "Aborted by user."; exit 0; }
  echo ""

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

  step "Step 5: DNS routes"
  local _expected_target="${DOKPLOY_TUNNEL_ID}.cfargotunnel.com"

  # Helper: check if existing CNAME points to the correct tunnel
  _check_dns_cname() {
    local _host="$1"
    local _current; _current=$(dig +short CNAME "${_host}" 2>/dev/null | head -1 | sed 's/\.$//')
    if [ -n "$_current" ] && [ "$_current" != "$_expected_target" ]; then
      warn "DNS '${_host}' exists but points to WRONG tunnel:"
      warn "  Current:  ${_current}"
      warn "  Expected: ${_expected_target}"
      warn "  ⚠  Manually update this CNAME in Cloudflare Dashboard!"
      return 1
    fi
    return 0
  }

  # Dashboard: specific record
  if sudo -u "$cf_user" cloudflared tunnel route dns "${DOKPLOY_TUNNEL_NAME}" "${_dash_sub}.${CF_DOMAIN}" 2>/dev/null; then
    ok "DNS: ${_dash_sub}.${CF_DOMAIN}"
  else
    _check_dns_cname "${_dash_sub}.${CF_DOMAIN}" \
      || warn "DNS route exists but points to wrong tunnel — update manually."
  fi
  # Wildcard: all app subdomains → Traefik
  if sudo -u "$cf_user" cloudflared tunnel route dns "${DOKPLOY_TUNNEL_NAME}" "*.${CF_DOMAIN}" 2>/dev/null; then
    ok "DNS: *.${CF_DOMAIN}"
  else
    _check_dns_cname "*.${CF_DOMAIN}" \
      || warn "Wildcard DNS points to wrong tunnel — update manually."
  fi

  # Base64-encode credentials for VM
  local creds_home; creds_home="$(eval echo ~${cf_user})"
  local creds_file="${creds_home}/.cloudflared/${DOKPLOY_TUNNEL_ID}.json"
  if [ -f "$creds_file" ]; then
    DOKPLOY_CREDS_B64=$(base64 -w 0 "$creds_file" 2>/dev/null || base64 "$creds_file")
    ok "Credentials ready."
  else
    err "Credentials not found: ${creds_file}"; exit 1
  fi

  # Fetch CF Zone ID for DNS sync watcher
  local _api_token; _api_token=$(cf_load_api_token)
  DOKPLOY_CF_ZONE_ID=""
  DOKPLOY_CF_API_TOKEN=""
  if [ -n "$_api_token" ]; then
    DOKPLOY_CF_ZONE_ID=$(cf_fetch_zone_id "$_api_token" "$CF_DOMAIN" || true)
    [ -n "$DOKPLOY_CF_ZONE_ID" ] && DOKPLOY_CF_API_TOKEN="$_api_token"
  fi
  if [ -z "$DOKPLOY_CF_ZONE_ID" ]; then
    echo ""
    warn "DNS auto-sync needs a CF API token (Tunnel:Edit + Zone:Read + DNS:Edit)."
    echo "  https://dash.cloudflare.com/profile/api-tokens"
    echo ""
    ask "  CF API token (or Enter to skip):"; read -r _tok; echo ""
    if [ -n "$_tok" ]; then
      DOKPLOY_CF_ZONE_ID=$(cf_fetch_zone_id "$_tok" "$CF_DOMAIN" || true)
      if [ -n "$DOKPLOY_CF_ZONE_ID" ]; then
        DOKPLOY_CF_API_TOKEN="$_tok"
        cf_store_api_token "$_tok"
        ok "CF Zone ID: ${DOKPLOY_CF_ZONE_ID}"
      else
        warn "Could not fetch Zone ID — check token permissions. DNS auto-sync disabled."
      fi
    else
      warn "Skipping DNS auto-sync — use 'add-domain' subcommand for manual CNAME creation."
    fi
  else
    ok "CF Zone ID: ${DOKPLOY_CF_ZONE_ID}"
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
     DOKPLOY_SUBDOMAINS='${DOKPLOY_SUBDOMAINS}' \
     DOKPLOY_CF_ZONE_ID='${DOKPLOY_CF_ZONE_ID}' \
     DOKPLOY_CF_API_TOKEN='${DOKPLOY_CF_API_TOKEN}' \
     sudo -E bash -s" <<'REMOTE'
set -euo pipefail
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}  [OK]${RESET}  $*"; }
info() { echo -e "${CYAN}  [>>]${RESET}  $*"; }
warn() { echo -e "${YELLOW}  [!!]${RESET}  $*"; }
step() { echo -e "\n${BOLD}  ── $* ──${RESET}"; }

# ── Save CF API token on VM ───────────────────────────────────────────────────
if [ -n "${DOKPLOY_CF_API_TOKEN}" ]; then
  mkdir -p /root/.cloudflared
  echo "${DOKPLOY_CF_API_TOKEN}" > /root/.cloudflared/api-token
  chmod 600 /root/.cloudflared/api-token
  # Also save for the login user if different
  _vm_user=$(logname 2>/dev/null || echo "")
  if [ -n "$_vm_user" ] && [ "$_vm_user" != "root" ] && id "$_vm_user" &>/dev/null; then
    _vm_home=$(eval echo "~$_vm_user")
    mkdir -p "${_vm_home}/.cloudflared"
    echo "${DOKPLOY_CF_API_TOKEN}" > "${_vm_home}/.cloudflared/api-token"
    chmod 600 "${_vm_home}/.cloudflared/api-token"
    chown "$_vm_user:$_vm_user" "${_vm_home}/.cloudflared/api-token"
  fi
  ok "CF API token saved on VM."
fi

# ── Install Docker (if missing) + Docker 29 fix ──────────────────────────────
step "Docker install + Docker 29 compat"
if command -v docker &>/dev/null; then
  ok "Docker already installed: $(docker --version)"
else
  info "Installing docker.io ..."
  if command -v apt-get &>/dev/null; then
    apt-get update -qq && apt-get install -y docker.io docker-compose
  elif command -v dnf &>/dev/null; then
    dnf install -y docker docker-compose
  elif command -v pacman &>/dev/null; then
    pacman -Syu --noconfirm --needed docker docker-compose
  else
    warn "Unknown package manager — skipping docker install"; fi
  systemctl enable --now docker || true
  ok "Docker installed."
fi
_dropin="/etc/systemd/system/docker.service.d/min-api-version.conf"
if grep -qs "DOCKER_MIN_API_VERSION" "$_dropin" 2>/dev/null; then
  ok "DOCKER_MIN_API_VERSION drop-in already present — skipping."
else
  mkdir -p /etc/systemd/system/docker.service.d
  printf '[Service]\nEnvironment="DOCKER_MIN_API_VERSION=1.24"\n' > "$_dropin"
  systemctl daemon-reload
  systemctl restart docker || true
  ok "Docker 29 compat drop-in applied."
fi

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

# Write credentials + config — everything via Traefik (official Dokploy pattern)
mkdir -p /etc/cloudflared-dokploy
echo "${DOKPLOY_CREDS_B64}" | base64 -d > /etc/cloudflared-dokploy/creds.json
_dash_sub="${DOKPLOY_SUBDOMAINS%% *}"
cat > /etc/cloudflared-dokploy/config.yml <<CFCONFIG
tunnel: ${DOKPLOY_TUNNEL_ID}
credentials-file: /etc/cloudflared/creds.json
ingress:
  - hostname: "${_dash_sub}.${DOKPLOY_DOMAIN}"
    service: http://localhost:3000
  - hostname: "*.${DOKPLOY_DOMAIN}"
    service: http://localhost:80
  - service: http_status:404
CFCONFIG
ok "cloudflared config: ${_dash_sub}.${DOKPLOY_DOMAIN} → :3000, *.${DOKPLOY_DOMAIN} → :80"

# Deploy container with host networking — avoids Docker Swarm DNS issues
# localhost:80 = dokploy-traefik (port mapped to 0.0.0.0:80 on VM host)
docker rm -f cloudflared-dokploy 2>/dev/null || true
docker run -d \
  --name cloudflared-dokploy \
  --restart unless-stopped \
  --network host \
  -v /etc/cloudflared-dokploy/creds.json:/etc/cloudflared/creds.json:ro \
  -v /etc/cloudflared-dokploy/config.yml:/etc/cloudflared/config.yml:ro \
  cloudflare/cloudflared:latest tunnel --config /etc/cloudflared/config.yml run

ok "cloudflared-dokploy running (host network → localhost:80)"
ok "App traffic: *.${DOKPLOY_DOMAIN} → Traefik:80"

# ── DNS auto-sync watcher ─────────────────────────────────────────────────────
step "DNS auto-sync service"
if [ -z "${DOKPLOY_CF_ZONE_ID}" ] || [ -z "${DOKPLOY_CF_API_TOKEN}" ]; then
  warn "CF Zone ID or API token not set — skipping DNS auto-sync."
  warn "Run: sudo bash scripts/dokploy-cloudflared.sh add-domain <subdomain>"
else
  mkdir -p /etc/dokploy-dns-sync /var/lib/dokploy-dns-sync

  # Config
  cat > /etc/dokploy-dns-sync/config.env <<DNSCONF
CF_API_TOKEN=${DOKPLOY_CF_API_TOKEN}
CF_ZONE_ID=${DOKPLOY_CF_ZONE_ID}
CF_DOMAIN=${DOKPLOY_DOMAIN}
TUNNEL_ID=${DOKPLOY_TUNNEL_ID}
DNSCONF
  chmod 600 /etc/dokploy-dns-sync/config.env

  # Watcher script
  cat > /usr/local/bin/dokploy-dns-sync <<'WATCHER'
#!/usr/bin/env bash
# Auto-create CF DNS CNAMEs for new Dokploy app hostnames
set -uo pipefail
source /etc/dokploy-dns-sync/config.env
TUNNEL_TARGET="${TUNNEL_ID}.cfargotunnel.com"
STATE_DIR="/var/lib/dokploy-dns-sync"
mkdir -p "$STATE_DIR"

_cf_cname_exists() {
  curl -sf -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?name=${1}&type=CNAME" \
    | grep -q '"count":0' && return 1 || return 0
}

_cf_create_cname() {
  curl -sf -X POST \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"CNAME\",\"name\":\"${1}\",\"content\":\"${TUNNEL_TARGET}\",\"proxied\":true}" \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
    | grep -q '"success":true'
}

_get_traefik_hostnames() {
  docker ps -q 2>/dev/null | while read -r cid; do
    docker inspect "$cid" 2>/dev/null \
      | grep -oP 'Host\(`[^`]+`\)' \
      | grep -oP '[^`(Host]+' | grep '\.'
  done | sort -u
}

while true; do
  while IFS= read -r host; do
    [[ "$host" != *".${CF_DOMAIN}" ]] && continue
    state_file="${STATE_DIR}/${host//\//_}"
    [ -f "$state_file" ] && continue
    if _cf_cname_exists "$host"; then
      touch "$state_file"
      echo "[$(date -Iseconds)] Already exists: $host"
      continue
    fi
    if _cf_create_cname "$host"; then
      touch "$state_file"
      echo "[$(date -Iseconds)] Created CNAME: $host → $TUNNEL_TARGET"
    else
      echo "[$(date -Iseconds)] WARN: Failed to create CNAME: $host" >&2
    fi
  done < <(_get_traefik_hostnames 2>/dev/null || true)
  sleep 30
done
WATCHER
  chmod +x /usr/local/bin/dokploy-dns-sync

  # Systemd service
  cat > /etc/systemd/system/dokploy-dns-sync.service <<SVCEOF
[Unit]
Description=Dokploy DNS Auto-Sync — auto-create CF CNAMEs for new app domains
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/dokploy-dns-sync
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF
  systemctl daemon-reload
  systemctl enable --now dokploy-dns-sync
  ok "dokploy-dns-sync service installed and running."
  ok "New app domains will get CF CNAMEs automatically within 30s."
fi
REMOTE
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
  local _dash="${DOKPLOY_SUBDOMAINS%% *}"
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║              ✓  DOKPLOY + CLOUDFLARE COMPLETE               ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "${BOLD}  ├─ Tunnel ──────────────────────────────────────────────────${RESET}"
  printf "  │  %-20s %s\n" "Tunnel:"  "${DOKPLOY_TUNNEL_NAME}"
  printf "  │  %-20s %s\n" "ID:"      "${DOKPLOY_TUNNEL_ID}"
  printf "  │  %-20s %s\n" "DNS:"     "*.${CF_DOMAIN} → dokploy-traefik:80"
  echo   "  │  Flow: Internet → CF Tunnel → cloudflared → Traefik → apps"
  echo ""
  echo -e "${BOLD}  ├─ Dokploy ──────────────────────────────────────────────────${RESET}"
  printf "  │  %-20s http://%s:3000  (LAN only until step below)\n" "Access now:" "${VM_SSH_HOST}"
  echo   "  │"
  echo -e "  │  ${BOLD}⚠  Required first-time setup (via LAN):${RESET}"
  echo   "  │"
  echo   "  │  1. Open http://${VM_SSH_HOST}:3000 → Settings → General"
  printf "  │     Server Domain → set to:  %s.%s\n" "${_dash}" "${CF_DOMAIN}"
  echo   "  │     (Traefik will then proxy the dashboard)"
  echo   "  │"
  echo   "  │  2. Settings → Traefik:"
  echo   "  │     • Disable Let's Encrypt  (Cloudflare handles SSL)"
  echo   "  │     • Entrypoint: web (HTTP port 80)"
  echo   "  │"
  echo   "  │  After that, dashboard reachable at:"
  printf "  │     https://%s.%s\n" "${_dash}" "${CF_DOMAIN}"
  echo   "  │"
  echo   "  │  To add an app:"
  echo   "  │     Deploy in Dokploy → Domains tab → app.${CF_DOMAIN} (port 80, no HTTPS)"
  echo   "  │     Traefik routes it automatically — no cloudflared changes needed"
  echo ""
  echo -e "${BOLD}  └─ Cloudflare SSL/TLS ───────────────────────────────────────${RESET}"
  echo   "     CF Dashboard → SSL/TLS → set to Full (not Flexible)"
  echo ""
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  # Subcommand dispatch
  case "${1:-}" in
    add-domain)
      shift
      echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
      echo -e "${BOLD}║   Rev5.7.2 — Add App Domain → CF Tunnel                     ║${RESET}"
      echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
      cmd_add_domain "${1:-}"
      exit 0
      ;;
  esac
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗"
  echo "║   Rev5.7.2 — Dokploy + Cloudflare App Tunnel Setup          ║"
  echo "║   Run after phase3 completes (VM must be running)           ║"
  echo -e "╚══════════════════════════════════════════════════════════════╝${RESET}"

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

# =============================================================================
# Subcommand: add-domain <subdomain> — create CNAME for a new app
# Usage: sudo bash dokploy-cloudflared.sh add-domain n8n-test-dokploy
# =============================================================================
cmd_add_domain() {
  local _sub="${1:-}"
  _cf_init_paths

  # Load saved domain
  local _domain=""
  [ -f "$CF_DOMAIN_FILE" ] && _domain=$(cat "$CF_DOMAIN_FILE" 2>/dev/null)
  if [ -z "$_domain" ]; then
    ask "Domain (e.g. easyrentbali.com):"; read -r _domain
  fi

  # Load saved tunnel name from any VM conf
  local _tunnel=""
  local _conf
  for _conf in "${REPO_DIR}/generated-vm/"*.conf; do
    [ -f "$_conf" ] || continue
    set +u; source "$_conf"; set -u
    [ -n "${DOKPLOY_TUNNEL_NAME:-}" ] && { _tunnel="$DOKPLOY_TUNNEL_NAME"; break; }
  done
  if [ -z "$_tunnel" ]; then
    local cf_user="${SUDO_USER:-$USER}"
    echo ""
    echo -e "  ${BOLD}Existing Tunnels:${RESET}"
    sudo -u "$cf_user" cloudflared tunnel list 2>/dev/null | tail -n +2 | while IFS= read -r _tl; do
      printf "    • %-36s  %s\n" "$(awk '{print $1}' <<< "$_tl")" "$(awk '{print $2}' <<< "$_tl")"
    done
    echo ""
    ask "Tunnel name:"; read -r _tunnel
  fi

  # Prompt for subdomain if not given
  if [ -z "$_sub" ]; then
    ask "Subdomain to add (e.g. n8n, myapp, shop):"; read -r _sub
  fi
  local _fqdn="${_sub}.${_domain}"

  local cf_user="${SUDO_USER:-$USER}"
  local _tunnel_id
  _tunnel_id=$(sudo -u "$cf_user" cloudflared tunnel list 2>/dev/null \
    | awk -v n="${_tunnel}" '$0 ~ n {print $1}' | head -1)
  [ -z "$_tunnel_id" ] && { err "Tunnel '${_tunnel}' not found."; exit 1; }
  local _expected_target="${_tunnel_id}.cfargotunnel.com"

  echo ""
  echo -e "  ${BOLD}Will create:${RESET}"
  echo "    CNAME  ${_fqdn}  →  ${_expected_target}"
  echo ""
  confirm "  Proceed?" || { info "Aborted."; exit 0; }

  if sudo -u "$cf_user" cloudflared tunnel route dns "${_tunnel}" "${_fqdn}" 2>/dev/null; then
    ok "CNAME created: ${_fqdn} → tunnel"
    ok "https://${_fqdn} is ready (once app is deployed in Dokploy)"
  else
    # Check if wrong tunnel
    local _current; _current=$(dig +short CNAME "${_fqdn}" 2>/dev/null | head -1 | sed 's/\.$//')
    if [ -n "$_current" ] && [ "$_current" = "$_expected_target" ]; then
      ok "CNAME already correct: ${_fqdn} → tunnel"
    elif [ -n "$_current" ]; then
      warn "CNAME exists but points to wrong target:"
      warn "  Current:  ${_current}"
      warn "  Expected: ${_expected_target}"
      warn "  Update manually in CF Dashboard."
    else
      err "Failed to create CNAME for ${_fqdn}."
    fi
  fi
}

main "$@"
