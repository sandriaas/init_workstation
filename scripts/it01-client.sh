#!/usr/bin/env bash
# =============================================================================
# it01-client.sh — client bootstrap for the dedicated it01 host tunnel
# Supports: Arch · Ubuntu/Debian · Fedora · macOS · Android (Termux)
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info() { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()   { echo -e "${GREEN}[OK]${RESET}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()  { echo -e "${YELLOW}[ERR]${RESET}  $*" >&2; }

IT01_TUNNEL_HOST="${IT01_TUNNEL_HOST:-}"
IT01_SSH_USER="${IT01_SSH_USER:-it01}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)
      IT01_TUNNEL_HOST="${2:-}"
      shift 2
      ;;
    --user)
      IT01_SSH_USER="${2:-}"
      shift 2
      ;;
    *)
      err "Unknown argument: $1"
      exit 1
      ;;
  esac
done

[ -n "${IT01_TUNNEL_HOST}" ] || { err "Usage: $0 --host <public-hostname>"; exit 1; }

get_linux_websocat_asset() {
  case "$(uname -m)" in
    x86_64) echo "websocat.x86_64-unknown-linux-musl" ;;
    aarch64|arm64) echo "websocat.aarch64-unknown-linux-musl" ;;
    *)
      warn "Unsupported Linux architecture for automatic websocat install: $(uname -m)"
      return 1
      ;;
  esac
}

detect_env() {
  if [ -d /data/data/com.termux ]; then
    ENV=termux
  elif [ "$(uname)" = "Darwin" ]; then
    ENV=macos
  elif [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
      cachyos|arch|endeavouros|manjaro) ENV=arch ;;
      ubuntu|debian|pop|linuxmint) ENV=ubuntu ;;
      fedora|rhel|centos|rocky) ENV=fedora ;;
      *) ENV=ubuntu ;;
    esac
  else
    ENV=generic
  fi
  info "Detected environment: ${ENV}"
}

install_websocat() {
  if command -v websocat >/dev/null 2>&1; then
    ok "websocat already installed"
    return
  fi

  info "Installing websocat..."
  case "${ENV}" in
    arch) sudo pacman -S --noconfirm --needed websocat ;;
    ubuntu|fedora|generic)
      local asset
      asset="$(get_linux_websocat_asset)" || return 1
      sudo curl -sL "https://github.com/vi/websocat/releases/latest/download/${asset}" \
        -o /usr/local/bin/websocat
      sudo chmod +x /usr/local/bin/websocat
      ;;
    macos) brew install websocat ;;
    termux) pkg install -y websocat ;;
  esac
  ok "websocat installed"
}

install_ssh() {
  if command -v ssh >/dev/null 2>&1; then
    ok "ssh already installed"
    return
  fi

  case "${ENV}" in
    termux) pkg install -y openssh ;;
    ubuntu) sudo apt-get install -y openssh-client ;;
    fedora) sudo dnf install -y openssh-clients ;;
    *) warn "ssh not found — install OpenSSH manually" ;;
  esac
  ok "ssh installed"
}

write_ssh_config() {
  local ssh_dir ssh_config tmp_file
  ssh_dir="${HOME}/.ssh"
  ssh_config="${ssh_dir}/config"
  tmp_file="$(mktemp)"

  mkdir -p "${ssh_dir}"
  chmod 700 "${ssh_dir}"
  touch "${ssh_config}"

  awk '
    BEGIN { skip=0 }
    /^# BEGIN it01 host$/ { skip=1; next }
    /^# END it01 host$/ { skip=0; next }
    skip == 0 { print }
  ' "${ssh_config}" > "${tmp_file}"

  cat >> "${tmp_file}" <<EOF
# BEGIN it01 host
Host it01
  HostName ${IT01_TUNNEL_HOST}
  ProxyCommand websocat -E --binary - wss://%h
  User ${IT01_SSH_USER}
# END it01 host
EOF

  mv "${tmp_file}" "${ssh_config}"
  chmod 600 "${ssh_config}"
  ok "Updated ${ssh_config}"
}

main() {
  detect_env
  install_ssh
  install_websocat
  write_ssh_config

  echo ""
  echo -e "${BOLD}Done. Connect with:${RESET} ${GREEN}ssh it01${RESET}"
  echo ""
}

main "$@"
