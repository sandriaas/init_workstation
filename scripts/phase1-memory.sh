#!/usr/bin/env bash
# =============================================================================
# phase1-memory.sh — Memory tuning: ZRAM 4× + sysctl + earlyoom + OOM protect
# Prevents kernel OOM killer from firing by adding proactive memory management:
#   1. ZRAM 4× RAM (~96 GiB virtual swap) with zstd compression
#   2. sysctl tuning (earlier reclaim, page-cluster=0 for ZRAM latency)
#   3. earlyoom — proactive OOM handler (kills node/bun before browser)
#   4. OOMScoreAdjust=-200 for all user session processes
# Idempotent: safely re-run
# =============================================================================
# Usage:
#   sudo bash scripts/phase1-memory.sh
# Verify after reboot:
#   zramctl | free -h
#   sysctl vm.page-cluster vm.watermark_scale_factor vm.dirty_ratio
#   systemctl status earlyoom
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()     { echo -e "${RED}[ERR]${RESET}  $*" >&2; }
section() { echo -e "\n${BOLD}══ $* ══${RESET}"; }

trap '_ec=$?; [ $_ec -ne 0 ] && err "Failed at line ${LINENO} (exit ${_ec}) in ${FUNCNAME[0]:-main}()"' ERR

[ "$EUID" -ne 0 ] && { warn "Re-running with sudo..."; exec sudo bash "$0" "$@"; }

OS_ID=$(grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')

# ── 1. ZRAM ────────────────────────────────────────────────────────────────────
section "ZRAM (4× RAM)"

cat > /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = ram * 4
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

ok "Written /etc/systemd/zram-generator.conf"
info "ZRAM size change takes effect after reboot (or manual: systemctl restart systemd-zram-setup@zram0)"

# ── 2. sysctl memory tuning ───────────────────────────────────────────────────
section "sysctl memory tuning"

cat > /etc/sysctl.d/99-minipc-memory.conf <<'EOF'
# ZRAM-optimised memory tuning for minipc workstation
# vm.swappiness=150  — aggressive swap-to-ZRAM before evicting page cache
# vm.page-cluster=0  — read 1 page at a time (ZRAM is fast; no readahead needed)
# vm.watermark_scale_factor=125 — wake kswapd earlier, reclaim before OOM
# vm.vfs_cache_pressure=50 — keep dentries/inodes in cache longer
# vm.dirty_ratio=20  — allow 20% dirty pages before blocking writes
# vm.dirty_background_ratio=5 — start background writeback at 5%
vm.swappiness = 150
vm.page-cluster = 0
vm.watermark_scale_factor = 125
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
EOF

sysctl --system &>/dev/null
ok "Written /etc/sysctl.d/99-minipc-memory.conf and applied live"
info "Active: $(sysctl -n vm.dirty_ratio vm.page-cluster vm.watermark_scale_factor 2>/dev/null | paste - - - | awk '{print "dirty_ratio="$1" page-cluster="$2" watermark_scale="$3}')"

# ── 3. earlyoom — proactive OOM handler ───────────────────────────────────────
section "earlyoom install + configure"

if ! command -v earlyoom &>/dev/null; then
  case "$OS_ID" in
    cachyos|arch|artix|endeavouros|manjaro)
      pacman -S --noconfirm --needed earlyoom
      ;;
    ubuntu|debian|linuxmint|pop)
      apt-get install -y earlyoom
      ;;
    fedora|rhel|centos|rocky|almalinux)
      dnf install -y earlyoom
      ;;
    opensuse*|sles)
      zypper install -y earlyoom
      ;;
    *)
      warn "Unknown distro '${OS_ID}' — install earlyoom manually, then re-run"
      ;;
  esac
else
  ok "earlyoom already installed: $(earlyoom --version 2>/dev/null | head -1)"
fi

if command -v earlyoom &>/dev/null; then
  mkdir -p /etc/default
  cat > /etc/default/earlyoom <<'EOF'
# earlyoom configuration for minipc workstation
# Kill thresholds: < 4% free RAM OR < 10% free swap
# -r 60: report memory stats to journal every 60 seconds
#
# Prefer to kill (recoverable background processes):
#   node, bun
#
# Avoid killing (critical / hard to restore):
#   qemu-system (VMs), cloudflared (tunnels), claude, copilot, codex,
#   opencode, antigravity, zellij, code-insiders (VS Code),
#   ghostty, kitty, alacritty, konsole (terminals), plasmashell (desktop)
EARLYOOM_ARGS="-r 60 -m 4 -s 10 --prefer '(^|/)node$|(^|/)bun$' --avoid '(^|/)qemu-system|(^|/)cloudflared|(^|/)claude|(^|/)copilot|(^|/)codex|(^|/)opencode|(^|/)antigravity|(^|/)zellij|(^|/)code-insiders|(^|/)ghostty|(^|/)kitty|(^|/)alacritty|(^|/)konsole|(^|/)plasmashell'"
EOF

  systemctl enable --now earlyoom
  ok "earlyoom enabled and running"
  info "Status: $(systemctl is-active earlyoom)"
else
  warn "earlyoom not found after install attempt — skip earlyoom configuration"
fi

# ── 4. OOMScoreAdjust for user sessions ───────────────────────────────────────
section "OOMScoreAdjust for user sessions"

# user@.service.d drop-in: all user session processes get OOMScoreAdjust=-200
# This makes them substantially less likely to be killed than browser tabs,
# which Chromium/Electron automatically sets to +300 via their own units.
mkdir -p /etc/systemd/system/user@.service.d
cat > /etc/systemd/system/user@.service.d/oom-protect.conf <<'EOF'
[Service]
OOMScoreAdjust=-200
EOF

systemctl daemon-reload
ok "Written /etc/systemd/system/user@.service.d/oom-protect.conf (OOMScoreAdjust=-200)"
info "Active for new user sessions (existing sessions need re-login or reboot)"

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}Memory tuning complete.${RESET}"
echo ""
echo "  Files written:"
echo "    /etc/systemd/zram-generator.conf          (ZRAM 4× RAM — reboot to activate)"
echo "    /etc/sysctl.d/99-minipc-memory.conf       (applied live)"
echo "    /etc/default/earlyoom                      (applied live)"
echo "    /etc/systemd/system/user@.service.d/oom-protect.conf"
echo ""
echo "  Verify after reboot:"
echo "    zramctl"
echo "    free -h"
echo "    sysctl vm.page-cluster vm.watermark_scale_factor vm.dirty_ratio"
echo "    systemctl status earlyoom"
echo "    journalctl -u earlyoom -f"
