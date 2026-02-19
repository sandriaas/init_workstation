#!/usr/bin/env bash
# =============================================================================
# phase3-client.sh — Rev5.7.2 Phase 3: VM Client Setup
# Run this on ANY device to connect to the KVM VM via Cloudflare tunnel
# Supports: Arch · Ubuntu/Debian · Fedora · macOS · Android (Termux)
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase3-client.sh)
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
    macos)   brew install websocat ;;
    termux)  pkg install -y websocat ;;
    *)
      sudo curl -sL https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-musl \
        -o /usr/local/bin/websocat && sudo chmod +x /usr/local/bin/websocat ;;
  esac
  ok "websocat installed"
}

# ─── Install openssh ─────────────────────────────────────────────────────────
install_ssh() {
  if command -v ssh &>/dev/null; then ok "ssh already installed"; return; fi
  case $ENV in
    termux)  pkg install -y openssh ;;
    ubuntu)  sudo apt-get install -y openssh-client ;;
    fedora)  sudo dnf install -y openssh-clients ;;
    *) warn "ssh not found — install openssh manually" ;;
  esac
  ok "ssh installed"
}

# ─── Write ~/.ssh/config entry ────────────────────────────────────────────────
setup_ssh_config() {
  local SSH_DIR="$HOME/.ssh"
  local SSH_CONFIG="$SSH_DIR/config"
  mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"

  echo ""
  info "You need the VM tunnel hostname from the phase3 summary."
  ask "VM tunnel hostname (e.g. vm-abc123.yourdomain.com): "; read -r VM_TUNNEL_HOST
  ask "VM SSH username (e.g. sandriaas): ";                   read -r VM_USER

  # Derive a short alias from the hostname prefix (e.g. vm-abc123.yourdomain.com → vm-abc123)
  VM_ALIAS="${VM_TUNNEL_HOST%%.*}"
  # Fallback: if alias looks weird, prompt
  ask "SSH alias to use (press Enter for '${VM_ALIAS}'): "; read -r _alias
  VM_ALIAS="${_alias:-$VM_ALIAS}"

  # Skip if already configured
  if grep -q "Host ${VM_ALIAS}$" "$SSH_CONFIG" 2>/dev/null; then
    ok "~/.ssh/config already has 'Host ${VM_ALIAS}'. Skipping."
  else
    cat >> "$SSH_CONFIG" << SSHEOF

# KVM VM via Cloudflare Tunnel (phase3-client)
Host ${VM_ALIAS}
  HostName ${VM_TUNNEL_HOST}
  ProxyCommand websocat -E --binary - wss://%h
  User ${VM_USER}
SSHEOF
    chmod 600 "$SSH_CONFIG"
    ok "Written to ~/.ssh/config — alias: ${VM_ALIAS}"
  fi
}

# ─── Test the connection ──────────────────────────────────────────────────────
test_connection() {
  info "Testing SSH via Cloudflare tunnel (${VM_ALIAS})..."
  if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
         -o BatchMode=yes "${VM_ALIAS}" true 2>/dev/null; then
    ok "Connection test passed!"
  else
    warn "Connection test failed — tunnel may still be propagating DNS (try again in 1-2 min)"
    warn "Manual test: ssh -o ProxyCommand='websocat -E --binary - wss://%h' ${VM_USER}@${VM_TUNNEL_HOST}"
  fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  echo -e "${BOLD}"
  echo "╔══════════════════════════════════════════════╗"
  echo "║   Rev5.7.2 — Phase 3 Client Setup           ║"
  echo "║   VM access via Cloudflare tunnel            ║"
  echo "║   Arch · Ubuntu · Fedora · macOS · Termux   ║"
  echo "╚══════════════════════════════════════════════╝"
  echo -e "${RESET}"

  detect_env
  install_ssh
  install_websocat
  setup_ssh_config
  test_connection

  echo ""
  echo -e "${BOLD}╔════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║   Done! Connect to VM with:                    ║${RESET}"
  echo -e "${BOLD}║                                                ║${RESET}"
  echo -e "${BOLD}║   ${GREEN}ssh ${VM_ALIAS}${RESET}${BOLD}                                    ║${RESET}"
  echo -e "${BOLD}╚════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo "  Full tunnel command (no ~/.ssh/config needed):"
  echo "  ssh -o ProxyCommand='websocat -E --binary - wss://%h' ${VM_USER}@${VM_TUNNEL_HOST}"
  echo ""
}

main "$@"
