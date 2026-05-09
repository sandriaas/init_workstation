#!/usr/bin/env bash
# =============================================================================
# it01-host.sh — host-only SSH bootstrap for this machine
# Configures SSH + Cloudflare Tunnel so clients can connect with `ssh it01`
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info() { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()   { echo -e "${GREEN}[OK]${RESET}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()  { echo -e "${RED}[ERR]${RESET}  $*" >&2; }

trap '_ec=$?; [ $_ec -ne 0 ] && err "Failed at line ${LINENO} (exit ${_ec})"' ERR

[ "${EUID}" -ne 0 ] && exec sudo -E bash "$0" "$@"

IT01_SSH_USER="${IT01_SSH_USER:-it01}"
IT01_CF_DOMAIN="${IT01_CF_DOMAIN:-easyrentbali.com}"
IT01_TUNNEL_NAME="${IT01_TUNNEL_NAME:-it01-ssh}"
IT01_TUNNEL_HOST="${IT01_TUNNEL_HOST:-}"

CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"

SYSTEMD_SERVICE="it01-cloudflared.service"
SERVICE_ENV_DIR="/etc/cloudflared"
SERVICE_ENV_FILE="${SERVICE_ENV_DIR}/it01.env"
HOSTNAME_FILE_SYSTEM="${SERVICE_ENV_DIR}/it01-hostname"

id -u "${IT01_SSH_USER}" >/dev/null 2>&1 || { err "User '${IT01_SSH_USER}' does not exist."; exit 1; }
USER_HOME="$(eval echo "~${IT01_SSH_USER}")"
STATE_DIR="${USER_HOME}/.cloudflared"
TOKEN_FILE="${STATE_DIR}/api-token"
HOSTNAME_FILE_USER="${STATE_DIR}/it01-hostname"

mkdir -p "${STATE_DIR}" "${SERVICE_ENV_DIR}"
chmod 700 "${STATE_DIR}"
chown "${IT01_SSH_USER}:${IT01_SSH_USER}" "${STATE_DIR}"

require_env() {
  [ -n "${CLOUDFLARE_API_TOKEN}" ] || { err "CLOUDFLARE_API_TOKEN is required."; exit 1; }
  [ -n "${CLOUDFLARE_ACCOUNT_ID}" ] || { err "CLOUDFLARE_ACCOUNT_ID is required."; exit 1; }
}

detect_os() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID}" in
      cachyos|arch|endeavouros|manjaro) OS=arch ;;
      ubuntu|debian|pop|linuxmint) OS=ubuntu ;;
      fedora|rhel|centos|rocky|almalinux) OS=fedora ;;
      *) err "Unsupported OS: ${ID}"; exit 1 ;;
    esac
  else
    err "Cannot detect OS."
    exit 1
  fi
  info "Detected OS: ${OS}"
}

pkg_install() {
  case "${OS}" in
    arch) pacman -S --noconfirm --needed "$@" ;;
    ubuntu) apt-get update && apt-get install -y "$@" ;;
    fedora) dnf install -y "$@" ;;
  esac
}

install_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    ok "cloudflared already installed"
    return
  fi

  info "Installing cloudflared..."
  case "${OS}" in
    arch)
      pacman -S --noconfirm --needed cloudflared
      ;;
    ubuntu)
      curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
      echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
        | tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
      apt-get update && apt-get install -y cloudflared
      ;;
    fedora)
      curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-x86_64.rpm \
        -o /tmp/cloudflared.rpm
      rpm -i /tmp/cloudflared.rpm
      ;;
  esac
  ok "cloudflared installed"
}

install_dependencies() {
  info "Installing host SSH dependencies..."
  case "${OS}" in
    arch) pkg_install openssh fail2ban curl python ;;
    ubuntu) pkg_install openssh-server fail2ban curl python3 lsb-release ;;
    fedora) pkg_install openssh-server fail2ban curl python3 ;;
  esac
  install_cloudflared
  ok "Dependencies installed."
}

configure_ssh() {
  info "Configuring sshd..."
  systemctl enable --now sshd 2>/dev/null || systemctl enable --now ssh
  systemctl enable --now fail2ban || true
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  if grep -q '^#\?ChallengeResponseAuthentication' /etc/ssh/sshd_config 2>/dev/null; then
    sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config
  fi
  systemctl reload sshd 2>/dev/null || systemctl reload ssh
  ok "sshd active with password authentication enabled."
}

persist_api_token() {
  printf '%s\n' "${CLOUDFLARE_API_TOKEN}" > "${TOKEN_FILE}"
  chmod 600 "${TOKEN_FILE}"
  chown "${IT01_SSH_USER}:${IT01_SSH_USER}" "${TOKEN_FILE}"
  ok "Saved API token to ${TOKEN_FILE}"
}

rand_subdomain() {
  head -c 6 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 8
}

choose_hostname() {
  local stored=""
  [ -f "${HOSTNAME_FILE_SYSTEM}" ] && stored="$(cat "${HOSTNAME_FILE_SYSTEM}" 2>/dev/null || true)"
  [ -z "${stored}" ] && [ -f "${HOSTNAME_FILE_USER}" ] && stored="$(cat "${HOSTNAME_FILE_USER}" 2>/dev/null || true)"

  if [ -n "${IT01_TUNNEL_HOST}" ]; then
    HOST_TUNNEL_HOST="${IT01_TUNNEL_HOST}"
  elif [ -n "${stored}" ]; then
    HOST_TUNNEL_HOST="${stored}"
  else
    HOST_TUNNEL_HOST="$(rand_subdomain).${IT01_CF_DOMAIN}"
  fi

  printf '%s\n' "${HOST_TUNNEL_HOST}" | tee "${HOSTNAME_FILE_SYSTEM}" > "${HOSTNAME_FILE_USER}"
  chmod 600 "${HOSTNAME_FILE_SYSTEM}" "${HOSTNAME_FILE_USER}"
  chown "${IT01_SSH_USER}:${IT01_SSH_USER}" "${HOSTNAME_FILE_USER}"
  ok "Public SSH hostname: ${HOST_TUNNEL_HOST}"
}

cf_api() {
  local method="$1"
  local endpoint="$2"
  local payload="${3:-}"
  local tmp
  tmp="$(mktemp)"
  local http_code

  if [ -n "${payload}" ]; then
    http_code="$(curl -sS -o "${tmp}" -w '%{http_code}' \
      -X "${method}" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "${payload}" \
      "https://api.cloudflare.com/client/v4${endpoint}")"
  else
    http_code="$(curl -sS -o "${tmp}" -w '%{http_code}' \
      -X "${method}" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      "https://api.cloudflare.com/client/v4${endpoint}")"
  fi

  if [ "${http_code}" -lt 200 ] || [ "${http_code}" -ge 300 ]; then
    err "Cloudflare API ${method} ${endpoint} failed (${http_code})"
    cat "${tmp}" >&2
    rm -f "${tmp}"
    exit 1
  fi

  cat "${tmp}"
  rm -f "${tmp}"
}

py_extract() {
  local expr="$1"
  python3 -c "import json,sys; data=json.load(sys.stdin); ${expr}"
}

ensure_tunnel() {
  info "Ensuring remote-managed tunnel '${IT01_TUNNEL_NAME}'..."
  local response tunnel_id

  response="$(cf_api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel?is_deleted=false")"
  tunnel_id="$(printf '%s' "${response}" | py_extract "result=data.get('result', []); print(next((item['id'] for item in result if item.get('name') == '${IT01_TUNNEL_NAME}'), ''))")"

  if [ -z "${tunnel_id}" ]; then
    response="$(cf_api POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel" "{\"name\":\"${IT01_TUNNEL_NAME}\",\"config_src\":\"cloudflare\"}")"
    TUNNEL_ID="$(printf '%s' "${response}" | py_extract "print(data['result']['id'])")"
    TUNNEL_TOKEN="$(printf '%s' "${response}" | py_extract "print(data['result']['token'])")"
    ok "Created tunnel ${IT01_TUNNEL_NAME} (${TUNNEL_ID})"
  else
    TUNNEL_ID="${tunnel_id}"
    response="$(cf_api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token")"
    TUNNEL_TOKEN="$(printf '%s' "${response}" | py_extract "print(data['result'])")"
    ok "Reusing tunnel ${IT01_TUNNEL_NAME} (${TUNNEL_ID})"
  fi
}

configure_tunnel_route() {
  info "Configuring tunnel ingress for SSH..."
  cf_api PUT "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
    "{\"config\":{\"ingress\":[{\"hostname\":\"${HOST_TUNNEL_HOST}\",\"service\":\"ssh://localhost:22\",\"originRequest\":{}},{\"service\":\"http_status:404\"}]}}" >/dev/null
  ok "Tunnel ingress set for ${HOST_TUNNEL_HOST}"
}

ensure_zone_id() {
  local response
  response="$(cf_api GET "/zones?name=${IT01_CF_DOMAIN}&status=active")"
  ZONE_ID="$(printf '%s' "${response}" | py_extract "result=data.get('result', []); print(result[0]['id'] if result else '')")"
  [ -n "${ZONE_ID}" ] || { err "Could not resolve zone ID for ${IT01_CF_DOMAIN}"; exit 1; }
}

ensure_dns_record() {
  info "Ensuring DNS CNAME for ${HOST_TUNNEL_HOST}..."
  local response record_id current target payload
  target="${TUNNEL_ID}.cfargotunnel.com"
  response="$(cf_api GET "/zones/${ZONE_ID}/dns_records?type=CNAME&name=${HOST_TUNNEL_HOST}")"
  record_id="$(printf '%s' "${response}" | py_extract "result=data.get('result', []); print(result[0]['id'] if result else '')")"
  current="$(printf '%s' "${response}" | py_extract "result=data.get('result', []); print(result[0].get('content', '') if result else '')")"
  payload="{\"type\":\"CNAME\",\"proxied\":true,\"name\":\"${HOST_TUNNEL_HOST}\",\"content\":\"${target}\"}"

  if [ -n "${record_id}" ]; then
    if [ "${current}" = "${target}" ]; then
      ok "DNS already points ${HOST_TUNNEL_HOST} -> ${target}"
      return
    fi
    cf_api PUT "/zones/${ZONE_ID}/dns_records/${record_id}" "${payload}" >/dev/null
    ok "Updated DNS CNAME ${HOST_TUNNEL_HOST} -> ${target}"
  else
    cf_api POST "/zones/${ZONE_ID}/dns_records" "${payload}" >/dev/null
    ok "Created DNS CNAME ${HOST_TUNNEL_HOST} -> ${target}"
  fi
}

install_service() {
  info "Installing ${SYSTEMD_SERVICE}..."
  printf 'TUNNEL_TOKEN=%s\n' "${TUNNEL_TOKEN}" > "${SERVICE_ENV_FILE}"
  chmod 600 "${SERVICE_ENV_FILE}"

  cat > "/etc/systemd/system/${SYSTEMD_SERVICE}" <<EOF
[Unit]
Description=Cloudflare Tunnel for it01 host SSH
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${SERVICE_ENV_FILE}
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate run --token \${TUNNEL_TOKEN}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SYSTEMD_SERVICE}"
  ok "${SYSTEMD_SERVICE} active."
}

print_summary() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║        it01 host SSH bootstrap ready        ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
  echo ""
  echo "Public hostname: ${HOST_TUNNEL_HOST}"
  echo "Login target   : ${IT01_SSH_USER}@${HOST_TUNNEL_HOST}"
  echo "Client alias   : ssh it01"
  echo ""
  echo "Client setup:"
  echo "  bash scripts/it01-client.sh --host ${HOST_TUNNEL_HOST}"
  echo ""
}

main() {
  require_env
  detect_os
  install_dependencies
  configure_ssh
  persist_api_token
  choose_hostname
  ensure_tunnel
  configure_tunnel_route
  ensure_zone_id
  ensure_dns_record
  install_service
  print_summary
}

main "$@"
