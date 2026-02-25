#!/usr/bin/env bash
# =============================================================================
# phase1-cloudflared.sh — Rev5.7.2 Cloudflare tunnel for local host services
# Exposes: Cockpit, Netdata, and Bun dev ports via a dedicated CF tunnel
# Idempotent: safely re-run; already-done steps are skipped
# =============================================================================
# Services (default):
#   9090  → Cockpit
#   19999 → Netdata
#   3000  → Bun dev
#   3001  → Bun dev
#   3002  → Bun dev
#   5174  → Bun dev (Vite)
#
# Usage:
#   sudo bash scripts/phase1-cloudflared.sh            # full setup
#   sudo bash scripts/phase1-cloudflared.sh add-port 8080   # add a new port
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

trap '_ec=$?; [ $_ec -ne 0 ] && err "Failed at line ${LINENO} (exit ${_ec}) in ${FUNCNAME[0]:-main}()"' ERR

[ "$EUID" -ne 0 ] && { warn "Re-running with sudo..."; exec sudo bash "$0" "$@"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────
TUNNEL_NAME_DEFAULT="minipc-local"
HOSTNAME_PREFIX_DEFAULT="minipc-local"
# Services: "port:label"
LOCAL_SERVICES=(
  "9090:cockpit"
  "19999:netdata"
  "3000:dev-3000"
  "3001:dev-3001"
  "3002:dev-3002"
  "5174:dev-5174"
)

# ─── User / path detection ────────────────────────────────────────────────────
CURRENT_USER="${SUDO_USER:-$USER}"
if [ "$CURRENT_USER" = "root" ]; then
  ask "Running as root. Enter the main username: "; read -r CURRENT_USER
fi
USER_HOME=$(eval echo "~$CURRENT_USER")

CF_DOMAIN=""
CF_API_TOKEN_FILE="${USER_HOME}/.cloudflared/api-token"
CF_DOMAIN_FILE="${USER_HOME}/.cloudflared/minipc-domain"

# ─── Cloudflare helpers ──────────────────────────────────────────────────────
cf_list_zones() {
  local token="${1:-}"
  [ -z "$token" ] && return 1
  curl -sf -H "Authorization: Bearer $token" \
    "https://api.cloudflare.com/client/v4/zones?per_page=50&status=active" \
    | grep -oP '"name"\s*:\s*"[^"]*"' | sed 's/"name"[[:space:]]*:[[:space:]]*"//;s/"//' 2>/dev/null
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
      if [ -n "$stored_domain" ]; then
        ask "Domain [${stored_domain}]: "; read -r _d
        CF_DOMAIN="${_d:-$stored_domain}"
      else
        ask "Your Cloudflare domain (e.g. example.com): "; read -r CF_DOMAIN
      fi
    fi
  else
    if [ -n "$stored_domain" ]; then
      ask "Domain [${stored_domain}]: "; read -r _d
      CF_DOMAIN="${_d:-$stored_domain}"
    else
      ask "Your Cloudflare domain (e.g. example.com): "; read -r CF_DOMAIN
    fi
  fi
  ok "Selected domain: $CF_DOMAIN"
  mkdir -p "$USER_HOME/.cloudflared"
  echo "$CF_DOMAIN" > "$CF_DOMAIN_FILE"
  chown "$CURRENT_USER:$CURRENT_USER" "$CF_DOMAIN_FILE"
}

cf_store_api_token() {
  local token="$1"
  mkdir -p "$USER_HOME/.cloudflared"
  echo "$token" > "$CF_API_TOKEN_FILE"
  chmod 600 "$CF_API_TOKEN_FILE"
  chown "$CURRENT_USER:$CURRENT_USER" "$CF_API_TOKEN_FILE"
}

cf_load_api_token() {
  [ -f "$CF_API_TOKEN_FILE" ] && cat "$CF_API_TOKEN_FILE" 2>/dev/null || true
}

ensure_host_cloudflared() {
  if command -v cloudflared &>/dev/null; then
    ok "cloudflared $(cloudflared --version 2>&1 | head -1)"
    return
  fi
  err "cloudflared not installed — run phase1.sh first or install manually."
  exit 1
}

cf_ensure_auth() {
  local cf_home="$USER_HOME"
  # Already authed if cert.pem exists or tunnel list works
  if [ -f "${cf_home}/.cloudflared/cert.pem" ] || \
     sudo -u "$CURRENT_USER" cloudflared tunnel list &>/dev/null; then
    ok "cloudflared already authenticated."
  else
    echo ""
    info "Choose authentication method:"
    echo "  1) Browser login (opens browser)"
    echo "  2) API token    (headless — token from dash.cloudflare.com/profile/api-tokens)"
    local _stored; _stored=$(cf_load_api_token)
    [ -n "$_stored" ] && echo "  ✓ Saved API token detected"
    ask "Choice [1/2]: "; read -r _auth_choice

    if [ "${_auth_choice:-1}" = "2" ]; then
      local _token=""
      if [ -n "$_stored" ]; then
        ask "Use saved API token? [Y/n]: "; read -r _use_saved
        [[ "${_use_saved:-Y}" =~ ^[Yy]$ ]] && _token="$_stored"
      fi
      if [ -z "$_token" ]; then
        ask "Cloudflare API token: "; read -rs _token; echo ""
      fi
      cf_store_api_token "$_token"
      export CLOUDFLARE_API_TOKEN="$_token"
      sudo -u "$CURRENT_USER" CLOUDFLARE_API_TOKEN="$_token" cloudflared tunnel login --no-browser 2>/dev/null \
        || info "Falling back to token-based route DNS"
    else
      info "Opening Cloudflare browser login..."
      sudo -u "$CURRENT_USER" cloudflared login
    fi
  fi

  # ── Always ensure API token is saved (needed for DNS API calls) ──
  cf_ensure_api_token
}

cf_ensure_api_token() {
  local _token; _token=$(cf_load_api_token)
  if [ -n "$_token" ]; then
    ok "CF API token: saved ✓"
    return
  fi
  echo ""
  warn "Cloudflare API token is required for creating DNS records."
  info "Get one at: https://dash.cloudflare.com/profile/api-tokens"
  info "Permissions needed: Zone:DNS:Edit"
  ask "Cloudflare API token: "; read -rs _token; echo ""
  if [ -z "$_token" ]; then
    warn "No token provided — DNS record creation may fail."
    return
  fi
  cf_store_api_token "$_token"
  ok "CF API token saved."
}

# ─── Cloudflare API: zone + CNAME helpers ─────────────────────────────────────
# cloudflared tunnel route dns can't override wildcard CNAMEs, so we use the
# Cloudflare API directly — specific records always take priority over wildcards.
cf_fetch_zone_id() {
  local token="$1" domain="$2"
  [ -z "$token" ] || [ -z "$domain" ] && return 1
  curl -sf -H "Authorization: Bearer $token" \
    "https://api.cloudflare.com/client/v4/zones?name=${domain}&status=active" \
    | grep -oP '"id"\s*:\s*"\K[^"]+' | head -1
}

_cf_api_create_cname() {
  local token="$1" zone_id="$2" hostname="$3" target="$4"
  # Check if record already exists
  local existing
  existing=$(curl -sf -H "Authorization: Bearer $token" \
    "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${hostname}&type=CNAME" 2>/dev/null)

  local record_id
  record_id=$(echo "$existing" | grep -oP '"id"\s*:\s*"\K[^"]+' | head -1 || true)
  local existing_content
  existing_content=$(echo "$existing" | grep -oP '"content"\s*:\s*"\K[^"]+' | head -1 || true)

  if [ -n "$record_id" ]; then
    if [ "$existing_content" = "$target" ]; then
      ok "CNAME already correct: ${hostname}"
      return 0
    fi
    # Update existing record to point to correct tunnel
    info "Updating CNAME: ${hostname} → ${target}"
    curl -sf -X PUT \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${target}\",\"proxied\":true}" \
      "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
      | grep -q '"success":true' && ok "Updated CNAME: ${hostname}" && return 0
    warn "Failed to update CNAME: ${hostname}"
    return 1
  fi

  # Create new record
  info "Creating CNAME: ${hostname} → ${target}"
  curl -sf -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${target}\",\"proxied\":true}" \
    "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
    | grep -q '"success":true' && ok "Created CNAME: ${hostname}" && return 0
  warn "Failed to create CNAME: ${hostname}"
  return 1
}

# =============================================================================
# Main setup
# =============================================================================
setup_local_tunnel() {
  section "Local Services Tunnel Setup"

  # ── Tunnel name ──
  ask "Tunnel name [${TUNNEL_NAME_DEFAULT}]: "; read -r TUNNEL_NAME
  TUNNEL_NAME="${TUNNEL_NAME:-$TUNNEL_NAME_DEFAULT}"

  # ── Hostname prefix ──
  ask "Hostname prefix [${HOSTNAME_PREFIX_DEFAULT}]: "; read -r HOSTNAME_PREFIX
  HOSTNAME_PREFIX="${HOSTNAME_PREFIX:-$HOSTNAME_PREFIX_DEFAULT}"

  # ── Show routing plan ──
  echo ""
  info "Routing plan for tunnel '${TUNNEL_NAME}':"
  echo ""
  printf "  %-35s → %s\n" "HOSTNAME" "SERVICE"
  echo "  ─────────────────────────────────────────────────────"
  for svc in "${LOCAL_SERVICES[@]}"; do
    local port="${svc%%:*}" label="${svc#*:}"
    printf "  %-35s → %s\n" "${port}-${HOSTNAME_PREFIX}.${CF_DOMAIN}" "http://localhost:${port} (${label})"
  done
  echo ""
  info "Dev-port tunnels (3000–5174) will show a connection error when no server is running — that's normal."
  echo ""
  confirm "Create tunnel and DNS routes?" || { info "Aborted."; return; }

  # ── Check for existing service ──
  if systemctl is-active "cloudflared-${TUNNEL_NAME}" &>/dev/null; then
    ok "cloudflared-${TUNNEL_NAME} already active."
    confirm "Re-configure and restart?" || { info "Skipped."; return; }
  fi

  # ── Create tunnel (if not exists) ──
  step "Creating tunnel '${TUNNEL_NAME}'"
  local TUNNEL_ID=""
  # Check if tunnel already exists
  TUNNEL_ID=$(sudo -u "$CURRENT_USER" cloudflared tunnel list 2>/dev/null \
    | awk -v n="${TUNNEL_NAME}" '$2 == n {print $1}' | head -1 || true)

  if [ -n "$TUNNEL_ID" ]; then
    ok "Tunnel '${TUNNEL_NAME}' already exists (${TUNNEL_ID})"
  else
    local _output
    _output=$(sudo -u "$CURRENT_USER" cloudflared tunnel create "${TUNNEL_NAME}" 2>&1)
    echo "$_output"
    TUNNEL_ID=$(echo "$_output" | grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 || true)
    if [ -z "$TUNNEL_ID" ]; then
      err "Could not parse tunnel ID — check output above."
      return 1
    fi
    ok "Created tunnel: ${TUNNEL_NAME} (${TUNNEL_ID})"
  fi

  # ── Write config ──
  step "Writing tunnel config"
  local CONFIG_FILE="${USER_HOME}/.cloudflared/config-${TUNNEL_NAME}.yml"
  local CRED_FILE="${USER_HOME}/.cloudflared/${TUNNEL_ID}.json"
  mkdir -p "$USER_HOME/.cloudflared"

  {
    echo "tunnel: ${TUNNEL_ID}"
    echo "credentials-file: ${CRED_FILE}"
    echo ""
    echo "ingress:"
    for svc in "${LOCAL_SERVICES[@]}"; do
      local port="${svc%%:*}"
      local hostname="${port}-${HOSTNAME_PREFIX}.${CF_DOMAIN}"
      echo "  - hostname: ${hostname}"
      echo "    service: http://localhost:${port}"
    done
    echo "  - service: http_status:404"
  } > "$CONFIG_FILE"
  chown "$CURRENT_USER:$CURRENT_USER" "$CONFIG_FILE"
  ok "Config: ${CONFIG_FILE}"

  # ── DNS CNAMEs (via CF API — cloudflared route dns can't override wildcards) ──
  step "Creating DNS CNAME records"
  local TUNNEL_TARGET="${TUNNEL_ID}.cfargotunnel.com"
  local _api_token; _api_token=$(cf_load_api_token)
  local _zone_id=""

  if [ -n "$_api_token" ]; then
    _zone_id=$(cf_fetch_zone_id "$_api_token" "$CF_DOMAIN" || true)
  fi

  if [ -n "$_zone_id" ] && [ -n "$_api_token" ]; then
    for svc in "${LOCAL_SERVICES[@]}"; do
      local port="${svc%%:*}"
      local hostname="${port}-${HOSTNAME_PREFIX}.${CF_DOMAIN}"
      _cf_api_create_cname "$_api_token" "$_zone_id" "$hostname" "$TUNNEL_TARGET" || true
    done
  else
    warn "No CF API token or zone ID — falling back to cloudflared route dns"
    warn "(This won't work if a wildcard *.${CF_DOMAIN} exists)"
    for svc in "${LOCAL_SERVICES[@]}"; do
      local port="${svc%%:*}"
      local hostname="${port}-${HOSTNAME_PREFIX}.${CF_DOMAIN}"
      sudo -u "$CURRENT_USER" cloudflared tunnel route dns "${TUNNEL_NAME}" "${hostname}" 2>/dev/null \
        && ok "CNAME: ${hostname}" \
        || warn "Route DNS failed for ${hostname} — may already exist"
    done
  fi

  # ── Systemd service ──
  step "Installing systemd service"
  local SERVICE_NAME="cloudflared-${TUNNEL_NAME}"
  sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" > /dev/null << EOF
[Unit]
Description=Cloudflare Tunnel — ${TUNNEL_NAME} (local services)
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=15
Type=notify
User=${CURRENT_USER}
ExecStart=/usr/bin/cloudflared --no-autoupdate --config ${CONFIG_FILE} tunnel run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now "${SERVICE_NAME}"
  ok "${SERVICE_NAME} service installed and running."

  # ── Cockpit reverse-proxy config ──
  # Cockpit needs to know it's behind a TLS-terminating proxy, otherwise its
  # CSP headers use http:// / ws:// which browsers block as mixed content.
  local _cockpit_hostname=""
  for svc in "${LOCAL_SERVICES[@]}"; do
    local port="${svc%%:*}"
    [ "$port" = "9090" ] && { _cockpit_hostname="${port}-${HOSTNAME_PREFIX}.${CF_DOMAIN}"; break; }
  done
  if [ -n "$_cockpit_hostname" ] && command -v cockpit-bridge &>/dev/null; then
    step "Configuring Cockpit for reverse proxy"
    printf '[WebService]\nOrigins = https://%s wss://%s\nProtocolHeader = X-Forwarded-Proto\nForwardedForHeader = X-Forwarded-For\n' \
      "${_cockpit_hostname}" "${_cockpit_hostname}" \
      | sudo tee /etc/cockpit/cockpit.conf > /dev/null
    sudo systemctl restart cockpit.socket 2>/dev/null || true
    ok "Cockpit configured: Origins = https://${_cockpit_hostname}"
  fi
}

# =============================================================================
# Subcommand: add-port <port> [label]
# =============================================================================
cmd_add_port() {
  local port="${1:-}"
  local label="${2:-port-${port}}"

  if [ -z "$port" ]; then
    err "Usage: $0 add-port <port> [label]"
    exit 1
  fi

  # Load saved domain
  if [ -f "$CF_DOMAIN_FILE" ]; then
    CF_DOMAIN=$(cat "$CF_DOMAIN_FILE" 2>/dev/null)
  fi
  if [ -z "$CF_DOMAIN" ]; then
    ask "Your Cloudflare domain (e.g. example.com): "; read -r CF_DOMAIN
  fi

  # Detect tunnel name from existing config files
  local TUNNEL_NAME=""
  local CONFIG_FILE=""
  for f in "$USER_HOME"/.cloudflared/config-*.yml; do
    [ -f "$f" ] || continue
    CONFIG_FILE="$f"
    TUNNEL_NAME=$(basename "$f" | sed 's/^config-//;s/\.yml$//')
    break
  done
  if [ -z "$TUNNEL_NAME" ]; then
    ask "Tunnel name [${TUNNEL_NAME_DEFAULT}]: "; read -r TUNNEL_NAME
    TUNNEL_NAME="${TUNNEL_NAME:-$TUNNEL_NAME_DEFAULT}"
    CONFIG_FILE="${USER_HOME}/.cloudflared/config-${TUNNEL_NAME}.yml"
  fi

  if [ ! -f "$CONFIG_FILE" ]; then
    err "Config file not found: ${CONFIG_FILE}"
    err "Run the full setup first: sudo bash $0"
    exit 1
  fi

  # Detect prefix from existing config
  local HOSTNAME_PREFIX
  HOSTNAME_PREFIX=$(grep -oP '\d+-\K[^.]+' "$CONFIG_FILE" | head -1 || echo "$HOSTNAME_PREFIX_DEFAULT")

  local hostname="${port}-${HOSTNAME_PREFIX}.${CF_DOMAIN}"
  info "Adding: ${hostname} → http://localhost:${port}"

  # Get tunnel ID
  local TUNNEL_ID
  TUNNEL_ID=$(sudo -u "$CURRENT_USER" cloudflared tunnel list 2>/dev/null \
    | awk -v n="${TUNNEL_NAME}" '$2 == n {print $1}' | head -1 || true)
  if [ -z "$TUNNEL_ID" ]; then
    err "Tunnel '${TUNNEL_NAME}' not found."
    exit 1
  fi

  # Check if already in config
  if grep -q "localhost:${port}" "$CONFIG_FILE" 2>/dev/null; then
    ok "Port ${port} already in config — skipping."
  else
    # Insert new ingress rule before the final catch-all
    sed -i "/^  - service: http_status:404/i\\  - hostname: ${hostname}\\n    service: http://localhost:${port}" "$CONFIG_FILE"
    ok "Added to config: ${hostname}"
  fi

  # Create DNS CNAME
  local TUNNEL_TARGET="${TUNNEL_ID}.cfargotunnel.com"
  local _api_token; _api_token=$(cf_load_api_token)
  local _zone_id=""
  [ -n "$_api_token" ] && _zone_id=$(cf_fetch_zone_id "$_api_token" "$CF_DOMAIN" || true)

  if [ -n "$_zone_id" ] && [ -n "$_api_token" ]; then
    _cf_api_create_cname "$_api_token" "$_zone_id" "$hostname" "$TUNNEL_TARGET" || true
  else
    sudo -u "$CURRENT_USER" cloudflared tunnel route dns "${TUNNEL_NAME}" "${hostname}" 2>/dev/null \
      && ok "CNAME: ${hostname}" \
      || warn "Route DNS failed for ${hostname} — use CF Dashboard to create CNAME manually"
  fi

  # Restart service
  local SERVICE_NAME="cloudflared-${TUNNEL_NAME}"
  if systemctl is-active "$SERVICE_NAME" &>/dev/null; then
    sudo systemctl restart "$SERVICE_NAME"
    ok "${SERVICE_NAME} restarted with new port."
  else
    warn "Service ${SERVICE_NAME} not running — start it: sudo systemctl start ${SERVICE_NAME}"
  fi
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
  section "Local Services Tunnel — Summary"
  echo ""
  echo -e "  ${BOLD}Tunnel:${RESET}  ${TUNNEL_NAME}"
  echo -e "  ${BOLD}Service:${RESET} cloudflared-${TUNNEL_NAME}"
  echo ""
  echo -e "  ${BOLD}URLs:${RESET}"
  for svc in "${LOCAL_SERVICES[@]}"; do
    local port="${svc%%:*}" label="${svc#*:}"
    echo -e "    ${GREEN}https://${port}-${HOSTNAME_PREFIX}.${CF_DOMAIN}${RESET}  → localhost:${port} (${label})"
  done
  echo ""
  echo -e "  ${BOLD}Config:${RESET}   ${USER_HOME}/.cloudflared/config-${TUNNEL_NAME}.yml"
  echo -e "  ${BOLD}Logs:${RESET}     journalctl -u cloudflared-${TUNNEL_NAME} -f"
  echo ""
  echo -e "  ${BOLD}Add more ports later:${RESET}"
  echo "    sudo bash scripts/phase1-cloudflared.sh add-port 8080"
  echo ""
}

# =============================================================================
# Main
# =============================================================================
main() {
  # ── Subcommand: add-port ──
  if [ "${1:-}" = "add-port" ]; then
    shift
    echo -e "${BOLD}phase1-cloudflared.sh — add port${RESET}"
    cmd_add_port "$@"
    return
  fi

  echo -e "${BOLD}"
  echo "╔══════════════════════════════════════════════╗"
  echo "║   Rev5.7.2 — Cloudflare Local Services      ║"
  echo "║   Cockpit · Netdata · Bun Dev Ports         ║"
  echo "╚══════════════════════════════════════════════╝"
  echo -e "${RESET}"

  ensure_host_cloudflared
  cf_ensure_auth

  local _token; _token=$(cf_load_api_token)
  cf_select_domain "$_token"

  setup_local_tunnel
  print_summary
}

main "$@"
