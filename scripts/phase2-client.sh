#!/usr/bin/env bash
# =============================================================================
# phase2-client.sh — Rev5.7.2 Phase 2 Client Setup (connect to VM tunnel)
# Supports: Arch · Ubuntu/Debian · Fedora · macOS · Android (Termux)
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
ask()     { echo -e "${YELLOW}[?]${RESET} $*"; }

detect_env() {
  if [ -d /data/data/com.termux ]; then
    ENV=termux
  elif [ "$(uname)" = "Darwin" ]; then
    ENV=macos
  elif [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
      cachyos|arch|endeavouros|manjaro) ENV=arch ;;
      ubuntu|debian|pop|linuxmint)      ENV=ubuntu ;;
      fedora|rhel|centos|rocky)         ENV=fedora ;;
      *)                                ENV=ubuntu ;;
    esac
  else
    ENV=generic
  fi
  info "Detected environment: $ENV"
}

install_websocat() {
  if command -v websocat &>/dev/null; then ok "websocat already installed"; return; fi
  case $ENV in
    arch)    sudo pacman -S --noconfirm --needed websocat ;;
    ubuntu)  curl -sL https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-musl -o /usr/local/bin/websocat && chmod +x /usr/local/bin/websocat ;;
    fedora)  sudo dnf install -y websocat ;;
    macos)   brew install websocat ;;
    termux)  pkg install -y websocat ;;
    generic) curl -sL https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-musl -o /usr/local/bin/websocat && chmod +x /usr/local/bin/websocat ;;
  esac
  ok "websocat installed"
}

install_ssh() {
  if command -v ssh &>/dev/null; then ok "ssh already installed"; return; fi
  case $ENV in
    termux) pkg install -y openssh ;;
    ubuntu) sudo apt-get install -y openssh-client ;;
    fedora) sudo dnf install -y openssh-clients ;;
    *) warn "ssh not found — install openssh manually" ;;
  esac
}

setup_ssh_config() {
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  SSH_CONFIG="$HOME/.ssh/config"

  ask "VM tunnel hostname (e.g. vm-abc123.example.com): "; read -r VM_TUNNEL_HOST
  ask "VM username (e.g. sandriaas): "; read -r VM_USER

  if grep -q "Host server-vm" "$SSH_CONFIG" 2>/dev/null; then
    warn "Host server-vm already exists in ~/.ssh/config (will append another block)."
  fi

  cat >> "$SSH_CONFIG" <<EOF

# Server VM via Cloudflare Tunnel
Host server-vm
  HostName ${VM_TUNNEL_HOST}
  ProxyCommand websocat -E --binary - wss://%h
  User ${VM_USER}
EOF
  chmod 600 "$SSH_CONFIG"
  ok "Added Host server-vm entry."
}

main() {
  echo -e "${BOLD}Rev5.7.2 — Phase 2 Client Setup${RESET}"
  detect_env
  install_ssh
  install_websocat
  setup_ssh_config
  echo ""
  echo -e "${GREEN}Done. Connect with: ssh server-vm${RESET}"
}

main "$@"
