#!/usr/bin/env bash
# =============================================================================
# cockpit-cloudflared.sh — Rev5.7.2
# Standalone Cloudflare tunnel for host Cockpit + SSH access
# =============================================================================
# Steps:
#   1. Ensure cloudflared installed on host
#   2. Cloudflare auth (reuses saved cert/token from phase1)
#   3. Select domain
#   4. Create/reuse CF tunnel + configure hostnames
#   5. Route DNS CNAMEs (with wrong-tunnel detection)
#   6. Install systemd service + start tunnel
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
step()    { echo -e "\n${BOLD}  ── $* ──${RESET}"; }

trap '_ec=$?; [ $_ec -ne 0 ] && err "Failed at line ${LINENO} (exit ${_ec})"' ERR

[ "$EUID" -ne 0 ] && { warn "Re-running with sudo..."; exec sudo bash "$0" "$@"; }

CURRENT_USER="${SUDO_USER:-$USER}"
USER_HOME="$(eval echo "~$CURRENT_USER")"

# =============================================================================
# Cloudflare helpers
# =============================================================================
CF_DOMAIN=""
CF_API_TOKEN_FILE="${USER_HOME}/.cloudflared/api-token"
CF_DOMAIN_FILE="${USER_HOME}/.cloudflared/minipc-domain"

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

# =============================================================================
# Step 1: Ensure cloudflared installed
# =============================================================================
ensure_cloudflared() {
  step "Step 1: Host cloudflared"
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

# =============================================================================
# Step 2: Cloudflare auth
# =============================================================================
cf_ensure_auth() {
  step "Step 2: Cloudflare auth"
  if [ -f "${USER_HOME}/.cloudflared/cert.pem" ] || sudo -u "$CURRENT_USER" cloudflared tunnel list >/dev/null 2>&1; then
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
    sudo -u "$CURRENT_USER" CLOUDFLARE_API_TOKEN="$_token" cloudflared tunnel login --no-browser 2>/dev/null || true
  else
    sudo -u "$CURRENT_USER" cloudflared login
  fi
}

# =============================================================================
# Step 3: Select domain
# =============================================================================
cf_select_domain() {
  step "Step 3: Select domain"
  local token; token=$(cf_load_api_token)
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
# Step 4: Create/reuse tunnel + configure hostnames
# =============================================================================
TUNNEL_NAME=""
TUNNEL_ID=""
TUNNEL_HOST=""
COCKPIT_HOST=""

setup_tunnel() {
  step "Step 4: CF tunnel"
  TUNNEL_NAME="minipc-ssh"

  # Show existing tunnels
  echo ""
  echo -e "  ${BOLD}Existing Cloudflare Tunnels:${RESET}"
  local _tlist
  _tlist=$(sudo -u "$CURRENT_USER" cloudflared tunnel list 2>/dev/null | tail -n +2) || true
  if [ -n "$_tlist" ]; then
    while IFS= read -r _tl; do
      local _tid _tname _mk=""
      _tid=$(awk '{print $1}' <<< "$_tl")
      _tname=$(awk '{print $2}' <<< "$_tl")
      [ "$_tname" = "${TUNNEL_NAME}" ] && _mk=" ← will use this"
      printf "    • %-36s  %s%s\n" "$_tid" "$_tname" "$_mk"
    done <<< "$_tlist"
  else
    echo "    (no tunnels yet)"
  fi

  echo ""
  ask "  Tunnel name [${TUNNEL_NAME}]:"; read -r _tn
  TUNNEL_NAME="${_tn:-$TUNNEL_NAME}"

  # Hostnames
  local _ssh_default="${CURRENT_USER}.${CF_DOMAIN}"
  local _cockpit_default="cockpit.${CF_DOMAIN}"

  # Check existing config for current values
  local _existing_cfg="${USER_HOME}/.cloudflared/config.yml"
  if [ -f "$_existing_cfg" ]; then
    local _cur_ssh _cur_cockpit
    _cur_ssh=$(awk '/service: ssh/{found=1} found && /hostname:/{print $NF; exit}' "$_existing_cfg" 2>/dev/null || true)
    _cur_cockpit=$(awk '/localhost:9090/{found=1} found && /hostname:/{print $NF}' "$_existing_cfg" 2>/dev/null \
      || awk '/hostname:/{h=$NF} /localhost:9090/{print h}' "$_existing_cfg" 2>/dev/null || true)
    [ -n "$_cur_ssh" ] && _ssh_default="$_cur_ssh"
    [ -n "$_cur_cockpit" ] && _cockpit_default="$_cur_cockpit"
  fi

  echo ""
  ask "  SSH hostname [${_ssh_default}]:"; read -r _sh
  TUNNEL_HOST="${_sh:-$_ssh_default}"
  ask "  Cockpit hostname [${_cockpit_default}]:"; read -r _ch
  COCKPIT_HOST="${_ch:-$_cockpit_default}"

  # Routing plan + confirm
  echo ""
  echo -e "  ${BOLD}Routing plan:${RESET}"
  echo "    ${TUNNEL_HOST}   →  SSH (:22)"
  echo "    ${COCKPIT_HOST}  →  Cockpit (:9090)"
  echo ""
  confirm "  Proceed?" || { info "Aborted by user."; exit 0; }

  # Create/reuse tunnel
  if ! sudo -u "$CURRENT_USER" cloudflared tunnel list 2>/dev/null | grep -q "${TUNNEL_NAME}"; then
    info "Creating tunnel '${TUNNEL_NAME}'..."
    sudo -u "$CURRENT_USER" cloudflared tunnel create "${TUNNEL_NAME}"
    ok "Tunnel created."
  else
    ok "Tunnel '${TUNNEL_NAME}' already exists."
  fi

  TUNNEL_ID=$(sudo -u "$CURRENT_USER" cloudflared tunnel list 2>/dev/null \
    | awk -v n="${TUNNEL_NAME}" '$0 ~ n {print $1}' | head -1)
  [ -z "$TUNNEL_ID" ] && { err "Could not get tunnel ID."; exit 1; }
  ok "Tunnel ID: ${TUNNEL_ID}"

  # Write config
  local CRED_FILE="${USER_HOME}/.cloudflared/${TUNNEL_ID}.json"
  cat > "${USER_HOME}/.cloudflared/config.yml" << EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CRED_FILE}
ingress:
  - hostname: ${TUNNEL_HOST}
    service: ssh://localhost:22
  - hostname: ${COCKPIT_HOST}
    service: http://localhost:9090
  - service: http_status:404
EOF
  chown "$CURRENT_USER:$CURRENT_USER" "${USER_HOME}/.cloudflared/config.yml"
  ok "Config written: ${USER_HOME}/.cloudflared/config.yml"
}

# =============================================================================
# Step 5: Route DNS CNAMEs (with wrong-tunnel detection)
# =============================================================================
route_dns() {
  step "Step 5: DNS routes"
  local _expected_target="${TUNNEL_ID}.cfargotunnel.com"

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

  # SSH hostname
  if sudo -u "$CURRENT_USER" cloudflared tunnel route dns "${TUNNEL_NAME}" "${TUNNEL_HOST}" 2>/dev/null; then
    ok "DNS: ${TUNNEL_HOST}"
  else
    _check_dns_cname "${TUNNEL_HOST}" \
      || warn "DNS route exists but points to wrong tunnel — update manually."
  fi

  # Cockpit hostname
  if sudo -u "$CURRENT_USER" cloudflared tunnel route dns "${TUNNEL_NAME}" "${COCKPIT_HOST}" 2>/dev/null; then
    ok "DNS: ${COCKPIT_HOST}"
  else
    _check_dns_cname "${COCKPIT_HOST}" \
      || warn "DNS route exists but points to wrong tunnel — update manually."
  fi
}

# =============================================================================
# Step 6: Install systemd service
# =============================================================================
install_service() {
  step "Step 6: Systemd service"

  tee /etc/systemd/system/cloudflared.service > /dev/null << EOF
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

  systemctl daemon-reload
  systemctl enable --now cloudflared
  ok "cloudflared service enabled and started."
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
  local host_ip; host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║          ✓  COCKPIT + SSH TUNNEL COMPLETE                   ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"

  echo ""
  echo -e "${BOLD}  ┌─ SSH Access ───────────────────────────────────────────────${RESET}"
  printf "  │  %-18s %s\n" "LAN:"        "ssh ${CURRENT_USER}@${host_ip}"
  printf "  │  %-18s %s\n" "Via tunnel:" "ssh ${CURRENT_USER}@${TUNNEL_HOST}"

  echo ""
  echo -e "${BOLD}  ├─ Cockpit Web UI ──────────────────────────────────────────${RESET}"
  printf "  │  %-18s %s\n" "LAN:"        "http://${host_ip}:9090"
  printf "  │  %-18s %s\n" "Via tunnel:" "https://${COCKPIT_HOST}"
  printf "  │  %-18s %s\n" "Status:"     "$(systemctl is-active cockpit.socket 2>/dev/null || echo unknown)"

  echo ""
  echo -e "${BOLD}  ├─ Tunnel ─────────────────────────────────────────────────${RESET}"
  printf "  │  %-18s %s\n" "Name:"   "${TUNNEL_NAME}"
  printf "  │  %-18s %s\n" "ID:"     "${TUNNEL_ID}"
  printf "  │  %-18s %s\n" "Status:" "$(systemctl is-active cloudflared 2>/dev/null || echo unknown)"

  echo ""
  echo -e "${BOLD}  └─ Cloudflare SSL/TLS ───────────────────────────────────────${RESET}"
  echo   "     CF Dashboard → SSL/TLS → set to Full (not Flexible)"
  echo ""
}

# =============================================================================
# Main
# =============================================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   Rev5.7.2 — Cockpit + SSH Cloudflare Tunnel Setup          ║${RESET}"
echo -e "${BOLD}║   Standalone script — run on the host machine               ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""

ensure_cloudflared
cf_ensure_auth
cf_select_domain
setup_tunnel
route_dns
install_service
print_summary
