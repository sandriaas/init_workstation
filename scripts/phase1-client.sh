#!/usr/bin/env bash
# =============================================================================
# phase1-client.sh — Rev5.7.2 Phase 1: Client Setup
# Run this on ANY device you want to SSH from (phone, laptop, desktop)
# Supports: Arch · Ubuntu/Debian · Fedora · macOS · Android (Termux)
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
ask()     { echo -e "${YELLOW}[?]${RESET} $*"; }
confirm() { ask "$1 [Y/n]: "; read -r r; [[ "${r:-Y}" =~ ^[Yy]$ ]]; }

# ─── Detect environment ───────────────────────────────────────────────────────
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
    warn "Unknown environment — will attempt generic install"; ENV=generic
  fi
  info "Detected environment: $ENV"
}

# ─── Install websocat ─────────────────────────────────────────────────────────
install_websocat() {
  if command -v websocat &>/dev/null; then ok "websocat already installed"; return; fi
  info "Installing websocat..."
  case $ENV in
    arch)    sudo pacman -S --noconfirm --needed websocat ;;
    ubuntu)  sudo curl -sL https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-musl \
               -o /usr/local/bin/websocat && sudo chmod +x /usr/local/bin/websocat ;;
    fedora)  sudo curl -sL https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-musl \
               -o /usr/local/bin/websocat && sudo chmod +x /usr/local/bin/websocat ;;
    macos)   brew install websocat ;;
    termux)  pkg install -y websocat ;;
    generic) sudo curl -sL https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-musl \
               -o /usr/local/bin/websocat && sudo chmod +x /usr/local/bin/websocat ;;
  esac
  ok "websocat installed"
}

# ─── Install openssh (Termux doesn't have it by default) ─────────────────────
install_ssh() {
  if command -v ssh &>/dev/null; then ok "ssh already installed"; return; fi
  case $ENV in
    termux) pkg install -y openssh ;;
    ubuntu) sudo apt-get install -y openssh-client ;;
    fedora) sudo dnf install -y openssh-clients ;;
    *) warn "ssh not found — install openssh manually" ;;
  esac
  ok "ssh installed"
}

# ─── Write ~/.ssh/config entry ────────────────────────────────────────────────
setup_ssh_config() {
  SSH_DIR="$HOME/.ssh"
  SSH_CONFIG="$SSH_DIR/config"
  mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"

  ask "Tunnel hostname (e.g. abc123.yourdomain.com): "; read -r TUNNEL_HOST
  ask "Server username (e.g. sandriaas): ";             read -r SERVER_USER

  # Skip if already configured
  if grep -q "$TUNNEL_HOST" "$SSH_CONFIG" 2>/dev/null; then
    ok "~/.ssh/config already has entry for $TUNNEL_HOST. Skipping."; return
  fi

  cat >> "$SSH_CONFIG" << SSHEOF

# MiniPC via Cloudflare Tunnel
Host minipc
  HostName ${TUNNEL_HOST}
  ProxyCommand websocat -E --binary - wss://%h
  User ${SERVER_USER}
SSHEOF
  chmod 600 "$SSH_CONFIG"
  ok "Written to ~/.ssh/config"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  echo -e "${BOLD}"
  echo "╔══════════════════════════════════════════════╗"
  echo "║   Rev5.7.2 — Phase 1 Client Setup           ║"
  echo "║   Arch · Ubuntu · Fedora · macOS · Termux   ║"
  echo "╚══════════════════════════════════════════════╝"
  echo -e "${RESET}"

  detect_env

  install_ssh
  install_websocat
  setup_ssh_config

  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║   Done! Connect with:                ║${RESET}"
  echo -e "${BOLD}║                                      ║${RESET}"
  echo -e "${BOLD}║   ${GREEN}ssh minipc${RESET}${BOLD}                         ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════╝${RESET}"
  echo ""
}

main "$@"
