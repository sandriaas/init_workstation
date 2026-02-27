#!/usr/bin/env bash
# =============================================================================
# cloudflared-addport.sh — Interactive Cloudflare tunnel port opener
# Detects token + domain, lets you pick subdomain(s), opens multiple ports
# =============================================================================
# Usage:
#   sudo bash scripts/cloudflared-addport.sh
#   sudo bash scripts/cloudflared-addport.sh 8080 3333 5555
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()     { echo -e "${RED}[ERR]${RESET}  $*" >&2; }
ask()     { echo -en "${YELLOW}[?]${RESET} $*"; }
section() { echo -e "\n${BOLD}══ $* ══${RESET}"; }

trap '_ec=$?; [ $_ec -ne 0 ] && err "Failed at line ${LINENO} (exit ${_ec})"' ERR

[ "$EUID" -ne 0 ] && { warn "Re-running with sudo..."; exec sudo bash "$0" "$@"; }

# ─── User / path detection ────────────────────────────────────────────────────
CURRENT_USER="${SUDO_USER:-$USER}"
if [ "$CURRENT_USER" = "root" ]; then
  ask "Running as root. Enter the main username: "; read -r CURRENT_USER
fi
USER_HOME=$(eval echo "~$CURRENT_USER")

CF_API_TOKEN_FILE="${USER_HOME}/.cloudflared/api-token"
CF_DOMAIN_FILE="${USER_HOME}/.cloudflared/minipc-domain"

# ─── Cloudflare helpers ───────────────────────────────────────────────────────
cf_load_api_token() {
  [ -f "$CF_API_TOKEN_FILE" ] && cat "$CF_API_TOKEN_FILE" 2>/dev/null || true
}

cf_store_api_token() {
  local token="$1"
  mkdir -p "$USER_HOME/.cloudflared"
  echo "$token" > "$CF_API_TOKEN_FILE"
  chmod 600 "$CF_API_TOKEN_FILE"
  chown "$CURRENT_USER:$CURRENT_USER" "$CF_API_TOKEN_FILE"
}

cf_list_zones() {
  local token="${1:-}"
  [ -z "$token" ] && return 1
  curl -sf -H "Authorization: Bearer $token" \
    "https://api.cloudflare.com/client/v4/zones?per_page=50&status=active" \
    | grep -oP '"name"\s*:\s*"[^"]*"' | sed 's/"name"[[:space:]]*:[[:space:]]*"//;s/"//' 2>/dev/null
}

cf_fetch_zone_id() {
  local token="$1" domain="$2"
  [ -z "$token" ] || [ -z "$domain" ] && return 1
  curl -sf -H "Authorization: Bearer $token" \
    "https://api.cloudflare.com/client/v4/zones?name=${domain}&status=active" \
    | grep -oP '"id"\s*:\s*"\K[^"]+' | head -1
}

_cf_api_create_cname() {
  local token="$1" zone_id="$2" hostname="$3" target="$4"
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
    info "Updating CNAME: ${hostname} -> ${target}"
    curl -sf -X PUT \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${target}\",\"proxied\":true}" \
      "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
      | grep -q '"success":true' && ok "Updated CNAME: ${hostname}" && return 0
    warn "Failed to update CNAME: ${hostname}"
    return 1
  fi

  info "Creating CNAME: ${hostname} -> ${target}"
  curl -sf -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${target}\",\"proxied\":true}" \
    "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
    | grep -q '"success":true' && ok "Created CNAME: ${hostname}" && return 0
  warn "Failed to create CNAME: ${hostname}"
  return 1
}

rand_subdomain() {
  head -c 6 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 8
}

# =============================================================================
# Step 1: API Token
# =============================================================================
section "Cloudflare API Token"

API_TOKEN=$(cf_load_api_token)

if [ -n "$API_TOKEN" ]; then
  ok "Saved API token detected"
  ask "Use saved token? [Y/n]: "; read -r _use
  if [[ "${_use:-Y}" =~ ^[Nn]$ ]]; then
    API_TOKEN=""
  fi
fi

if [ -z "$API_TOKEN" ]; then
  info "Get one at: https://dash.cloudflare.com/profile/api-tokens"
  info "Permissions needed: Zone:DNS:Edit"
  ask "Cloudflare API token: "; read -rs API_TOKEN; echo ""
  if [ -z "$API_TOKEN" ]; then
    err "API token is required."; exit 1
  fi
  cf_store_api_token "$API_TOKEN"
  ok "Token saved"
fi

# =============================================================================
# Step 2: Domain selection
# =============================================================================
section "Domain Selection"

CF_DOMAIN=""
stored_domain=""
[ -f "$CF_DOMAIN_FILE" ] && stored_domain=$(cat "$CF_DOMAIN_FILE" 2>/dev/null)

info "Fetching domains from your Cloudflare account..."
zones=$(cf_list_zones "$API_TOKEN" || true)

if [ -n "$zones" ]; then
  echo ""
  echo "  Available domains:"
  i=1; zone_arr=()
  while IFS= read -r z; do
    zone_arr+=("$z")
    marker=""
    [ "$z" = "$stored_domain" ] && marker=" <- current"
    printf "    %d) %s%s\n" "$i" "$z" "$marker"
    (( i++ ))
  done <<< "$zones"
  echo "    0) Enter a different domain"
  echo ""
  ask "Select domain [1-${#zone_arr[@]}, default=1]: "; read -r _choice
  _choice="${_choice:-1}"

  if [ "$_choice" = "0" ]; then
    ask "Enter domain (e.g. example.com): "; read -r CF_DOMAIN
  elif [[ "$_choice" =~ ^[0-9]+$ ]] && [ "$_choice" -ge 1 ] && [ "$_choice" -le "${#zone_arr[@]}" ]; then
    CF_DOMAIN="${zone_arr[$((_choice-1))]}"
  else
    CF_DOMAIN="${zone_arr[0]}"
  fi
else
  warn "Could not list domains — token may lack Zone:Read permission"
  if [ -n "$stored_domain" ]; then
    ask "Use saved domain '${stored_domain}'? [Y/n]: "; read -r _use_saved
    [[ "${_use_saved:-Y}" =~ ^[Yy]$ ]] && CF_DOMAIN="$stored_domain"
  fi
  [ -z "$CF_DOMAIN" ] && { ask "Enter domain (e.g. example.com): "; read -r CF_DOMAIN; }
fi

if [ -z "$CF_DOMAIN" ]; then
  err "No domain selected."; exit 1
fi

# Save domain
mkdir -p "$USER_HOME/.cloudflared"
echo "$CF_DOMAIN" > "$CF_DOMAIN_FILE"
chown "$CURRENT_USER:$CURRENT_USER" "$CF_DOMAIN_FILE"
ok "Domain: ${CF_DOMAIN}"

# =============================================================================
# Step 3: Detect existing tunnel
# =============================================================================
section "Tunnel Detection"

TUNNEL_NAME=""
CONFIG_FILE=""

for f in "$USER_HOME"/.cloudflared/config-*.yml; do
  [ -f "$f" ] || continue
  CONFIG_FILE="$f"
  TUNNEL_NAME=$(basename "$f" | sed 's/^config-//;s/\.yml$//')
  break
done

if [ -z "$TUNNEL_NAME" ]; then
  err "No existing tunnel found in ${USER_HOME}/.cloudflared/config-*.yml"
  err "Run the full setup first: sudo bash scripts/phase1-cloudflared.sh"
  exit 1
fi

ok "Tunnel: ${TUNNEL_NAME} (${CONFIG_FILE})"

# Get tunnel ID
TUNNEL_ID=$(sudo -u "$CURRENT_USER" cloudflared tunnel list 2>/dev/null \
  | awk -v n="${TUNNEL_NAME}" '$2 == n {print $1}' | head -1 || true)
if [ -z "$TUNNEL_ID" ]; then
  err "Tunnel '${TUNNEL_NAME}' not found in cloudflared tunnel list."
  exit 1
fi
ok "Tunnel ID: ${TUNNEL_ID}"

# Detect hostname prefix from existing config
HOSTNAME_PREFIX=$(grep 'hostname:' "$CONFIG_FILE" | grep -oP '\d+-\K[^.]+' | head -1 || echo "minipc-local")

# =============================================================================
# Step 4: Ports
# =============================================================================
section "Port Selection"

PORTS=()

# Accept ports from CLI args
if [ $# -gt 0 ]; then
  for arg in "$@"; do
    # Support comma-separated: 8080,3000,5555
    IFS=',' read -ra split <<< "$arg"
    for p in "${split[@]}"; do
      p=$(echo "$p" | tr -d '[:space:]')
      [[ "$p" =~ ^[0-9]+$ ]] && PORTS+=("$p")
    done
  done
fi

if [ ${#PORTS[@]} -eq 0 ]; then
  ask "Enter port(s) to expose (comma or space separated, e.g. 8080,3000,5555): "; read -r _ports_input
  IFS=', ' read -ra _ports_raw <<< "$_ports_input"
  for p in "${_ports_raw[@]}"; do
    p=$(echo "$p" | tr -d '[:space:]')
    [[ "$p" =~ ^[0-9]+$ ]] && PORTS+=("$p")
  done
fi

if [ ${#PORTS[@]} -eq 0 ]; then
  err "No valid ports provided."; exit 1
fi

ok "Ports to add: ${PORTS[*]}"

# =============================================================================
# Step 5: Subdomain naming
# =============================================================================
section "Subdomain Naming"

echo ""
echo "  Choose subdomain format for each port:"
echo "    1) Default: <port>-${HOSTNAME_PREFIX}.${CF_DOMAIN}  (e.g. 8080-${HOSTNAME_PREFIX}.${CF_DOMAIN})"
echo "    2) Custom:  you choose a subdomain for each port"
echo "    3) Random:  auto-generated random subdomains"
echo ""
ask "Naming mode [1/2/3, default=1]: "; read -r _naming_mode
_naming_mode="${_naming_mode:-1}"

declare -A PORT_HOSTNAMES

for port in "${PORTS[@]}"; do
  case "$_naming_mode" in
    2)
      ask "Subdomain for port ${port} (will become <name>.${CF_DOMAIN}): "; read -r _sub
      _sub=$(echo "$_sub" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
      [ -z "$_sub" ] && _sub="${port}-${HOSTNAME_PREFIX}"
      PORT_HOSTNAMES[$port]="${_sub}.${CF_DOMAIN}"
      ;;
    3)
      _sub=$(rand_subdomain)
      PORT_HOSTNAMES[$port]="${_sub}.${CF_DOMAIN}"
      ;;
    *)
      PORT_HOSTNAMES[$port]="${port}-${HOSTNAME_PREFIX}.${CF_DOMAIN}"
      ;;
  esac
done

echo ""
info "Routing plan:"
echo ""
printf "  %-45s  ->  %s\n" "HOSTNAME" "SERVICE"
printf "  %-45s  ->  %s\n" "--------" "-------"
for port in "${PORTS[@]}"; do
  printf "  %-45s  ->  %s\n" "${PORT_HOSTNAMES[$port]}" "http://localhost:${port}"
done
echo ""
ask "Proceed? [Y/n]: "; read -r _confirm
[[ "${_confirm:-Y}" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }

# =============================================================================
# Step 6: Apply — config + DNS + restart
# =============================================================================
section "Applying Changes"

TUNNEL_TARGET="${TUNNEL_ID}.cfargotunnel.com"
ZONE_ID=$(cf_fetch_zone_id "$API_TOKEN" "$CF_DOMAIN" || true)

for port in "${PORTS[@]}"; do
  hostname="${PORT_HOSTNAMES[$port]}"

  # ── Add to tunnel config ──
  if grep -q "localhost:${port}" "$CONFIG_FILE" 2>/dev/null; then
    ok "Port ${port} already in config — skipping config update"
  else
    # Dev ports get httpHostHeader so Vite/bun accept the hostname
    if [[ "$port" =~ ^(3000|3001|3002|4141|5173|5174|8080|8081|8082)$ ]]; then
      sed -i "/^  - service: http_status:404/i\\  - hostname: ${hostname}\\n    service: http://localhost:${port}\\n    originRequest:\\n      httpHostHeader: localhost:${port}" "$CONFIG_FILE"
    else
      sed -i "/^  - service: http_status:404/i\\  - hostname: ${hostname}\\n    service: http://localhost:${port}" "$CONFIG_FILE"
    fi
    ok "Config: ${hostname} -> localhost:${port}"
  fi

  # ── Create DNS CNAME ──
  if [ -n "$ZONE_ID" ] && [ -n "$API_TOKEN" ]; then
    _cf_api_create_cname "$API_TOKEN" "$ZONE_ID" "$hostname" "$TUNNEL_TARGET" || true
  else
    sudo -u "$CURRENT_USER" cloudflared tunnel route dns "${TUNNEL_NAME}" "${hostname}" 2>/dev/null \
      && ok "CNAME: ${hostname}" \
      || warn "Route DNS failed for ${hostname} — create CNAME manually in CF Dashboard"
  fi
done

# ── Restart cloudflared service ──
SERVICE_NAME="cloudflared-${TUNNEL_NAME}"
if systemctl is-active "$SERVICE_NAME" &>/dev/null; then
  systemctl restart "$SERVICE_NAME"
  ok "${SERVICE_NAME} restarted"
else
  warn "Service ${SERVICE_NAME} not running — start with: sudo systemctl start ${SERVICE_NAME}"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}Done. Ports added:${RESET}"
echo ""
for port in "${PORTS[@]}"; do
  echo -e "  ${GREEN}https://${PORT_HOSTNAMES[$port]}${RESET}  ->  localhost:${port}"
done
echo ""
echo "  Config: ${CONFIG_FILE}"
echo "  Service: ${SERVICE_NAME}"
echo ""
