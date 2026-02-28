#!/usr/bin/env bash
# =============================================================================
# restore.sh — OS Reinstall Post-Install Restore
# Extracts a backup archive created by backup.sh and restores each component.
#
# Usage:
#   sudo bash scripts/restore.sh /path/to/minipc-backup-YYYYMMDD-HHMMSS.tar.gz
#
# Steps (Y/N prompt for each):
#   0.  Run phase scripts (phase1.sh, phase1-cloudflared.sh, phase1-memory.sh)
#   1.  Restore Cloudflare credentials
#   2.  Restore SSH keys
#   3.  Import GPG keys
#   4.  Restore shell/terminal config (fish, ghostty, zellij, starship)
#   5.  Restore XDG autostart
#   6.  Restore ~/_apps/
#   7.  Restore custom systemd units
#   8.  Restore memory tuning config
#   9.  Restore NetworkManager connections
#  10.  Restore VM images + virsh define XML
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()     { echo -e "${RED}[ERR]${RESET}  $*" >&2; }
ask()     { echo -e "${YELLOW}[?]${RESET} $*"; }
section() { echo -e "\n${BOLD}══ $* ══${RESET}"; }
step()    { echo -e "\n${BOLD}  ── $* ──${RESET}"; }
confirm() { ask "$1 [Y/n]: "; read -r _r; [[ "${_r:-Y}" =~ ^[Yy]$ ]]; }

trap '_ec=$?; [ $_ec -ne 0 ] && err "Failed at line ${LINENO} (exit ${_ec}) in ${FUNCNAME[0]:-main}()"' ERR

# ─── Must run as root (restoring system paths needs it) ──────────────────────
[ "$EUID" -ne 0 ] && { warn "Re-running with sudo..."; exec sudo bash "$0" "$@"; }

# ─── Argument check ──────────────────────────────────────────────────────────
ARCHIVE="${1:-}"
if [ -z "$ARCHIVE" ]; then
  err "Usage: sudo bash scripts/restore.sh /path/to/minipc-backup-YYYYMMDD-HHMMSS.tar.gz"
  exit 1
fi
if [ ! -f "$ARCHIVE" ]; then
  err "Archive not found: ${ARCHIVE}"
  exit 1
fi

# ─── Detect real user ────────────────────────────────────────────────────────
CURRENT_USER="${SUDO_USER:-$USER}"
if [ "$CURRENT_USER" = "root" ]; then
  ask "Enter the main username to restore into: "; read -r CURRENT_USER
fi
USER_HOME="$(eval echo "~${CURRENT_USER}")"
info "Target user: ${CURRENT_USER} (home: ${USER_HOME})"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ─── Extract archive ─────────────────────────────────────────────────────────
EXTRACT_DIR="$(mktemp -d /tmp/minipc-restore-XXXXXX)"
cleanup() { rm -rf "$EXTRACT_DIR"; }
trap cleanup EXIT

section "Extracting archive"
info "Archive : ${ARCHIVE}"
info "Extract : ${EXTRACT_DIR}"
tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR"
ok "Archive extracted."

# ─── Banner ──────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   minipc — Post-Install Restore              ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo
warn "Answer Y/N for each section. Default is Y (press Enter to accept)."
echo

# ─── Helper: copy a single file with progress ────────────────────────────────
copy_with_progress() {
  # copy_with_progress <src> <dest_dir>  (dest_dir must exist)
  local src="$1" dest_dir="$2"
  local fname size_bytes
  fname="$(basename "$src")"
  size_bytes="$(stat -c%s "$src" 2>/dev/null || echo 0)"

  if command -v pv >/dev/null 2>&1; then
    pv -N "$fname" -s "$size_bytes" "$src" > "${dest_dir}/${fname}"
  elif command -v rsync >/dev/null 2>&1; then
    rsync --progress --no-inc-recursive "$src" "${dest_dir}/"
  else
    info "  (pv/rsync not found — plain copy)"
    cp "$src" "${dest_dir}/"
  fi
}

# ─── Helper: restore with ownership fix ──────────────────────────────────────
restore_to_home() {
  # restore_to_home <src_subpath_in_archive> <dest_relative_to_home>
  local src="${EXTRACT_DIR}/${1}" dest="${USER_HOME}/${2}"
  if [ ! -e "$src" ]; then
    warn "  Not in archive: ${1} — skipping."
    return 1
  fi
  mkdir -p "$(dirname "$dest")"
  cp -a "$src" "$dest"
  chown -R "${CURRENT_USER}:${CURRENT_USER}" "$dest"
}

# ─── 0. Phase scripts ────────────────────────────────────────────────────────
section "0 · Run phase setup scripts"
info "These install packages, cloudflared, and memory tuning on the fresh OS."

for script_name in phase1.sh phase1-cloudflared.sh phase1-memory.sh; do
  script_path="${REPO_DIR}/scripts/${script_name}"
  if confirm "Run ${script_name}?"; then
    if [ -f "$script_path" ]; then
      info "Running ${script_name} ..."
      bash "$script_path"
      ok "${script_name} complete."
    else
      warn "${script_path} not found — skipping. Clone the repo first."
    fi
  else
    info "Skipped ${script_name}."
  fi
done

# ─── 1. Cloudflare credentials ───────────────────────────────────────────────
section "1 · Cloudflare tunnel credentials"
if confirm "Restore ~/.cloudflared/?"; then
  src="${EXTRACT_DIR}/cloudflared/.cloudflared"
  if [ -d "$src" ]; then
    rm -rf "${USER_HOME}/.cloudflared"
    cp -a "$src" "${USER_HOME}/.cloudflared"
    chown -R "${CURRENT_USER}:${CURRENT_USER}" "${USER_HOME}/.cloudflared"
    chmod 700 "${USER_HOME}/.cloudflared"
    chmod 600 "${USER_HOME}/.cloudflared"/*.json 2>/dev/null || true
    ok "Cloudflare credentials restored."
  else
    warn "cloudflared directory not found in archive — skipping."
  fi
else
  info "Skipped."
fi

# ─── 2. SSH keys ─────────────────────────────────────────────────────────────
section "2 · SSH keys"
if confirm "Restore ~/.ssh/?"; then
  src="${EXTRACT_DIR}/ssh/.ssh"
  if [ -d "$src" ]; then
    rm -rf "${USER_HOME}/.ssh"
    cp -a "$src" "${USER_HOME}/.ssh"
    chown -R "${CURRENT_USER}:${CURRENT_USER}" "${USER_HOME}/.ssh"
    chmod 700 "${USER_HOME}/.ssh"
    find "${USER_HOME}/.ssh" -type f -name '*.pub' -exec chmod 644 {} \;
    find "${USER_HOME}/.ssh" -type f ! -name '*.pub' ! -name 'known_hosts' ! -name 'config' -exec chmod 600 {} \;
    find "${USER_HOME}/.ssh" -type f \( -name 'known_hosts' -o -name 'config' \) -exec chmod 644 {} \;
    ok "SSH keys restored."
  else
    warn "ssh directory not found in archive — skipping."
  fi
else
  info "Skipped."
fi

# ─── 3. GPG keys ─────────────────────────────────────────────────────────────
section "3 · GPG keys"
if confirm "Import GPG keys?"; then
  GPG_DIR="${EXTRACT_DIR}/gpg"
  if [ -d "$GPG_DIR" ]; then
    # Import as the target user, not root
    if [ -f "${GPG_DIR}/secret-keys.asc" ]; then
      sudo -u "$CURRENT_USER" gpg --import "${GPG_DIR}/secret-keys.asc"
      ok "  Secret keys imported."
    fi
    if [ -f "${GPG_DIR}/public-keys.asc" ]; then
      sudo -u "$CURRENT_USER" gpg --import "${GPG_DIR}/public-keys.asc"
      ok "  Public keys imported."
    fi
    if [ -f "${GPG_DIR}/ownertrust.txt" ]; then
      sudo -u "$CURRENT_USER" gpg --import-ownertrust "${GPG_DIR}/ownertrust.txt"
      ok "  Owner trust restored."
    fi
  else
    warn "gpg directory not found in archive — skipping."
  fi
else
  info "Skipped."
fi

# ─── 4. Shell/terminal config ─────────────────────────────────────────────────
section "4 · Shell/terminal config (fish, ghostty, zellij, starship)"
if confirm "Restore shell/terminal config?"; then
  CONFIG_SRC="${EXTRACT_DIR}/config"
  if [ -d "$CONFIG_SRC" ]; then
    mkdir -p "${USER_HOME}/.config"
    for cfg in fish ghostty zellij; do
      src="${CONFIG_SRC}/${cfg}"
      if [ -d "$src" ]; then
        rm -rf "${USER_HOME}/.config/${cfg}"
        cp -a "$src" "${USER_HOME}/.config/"
        chown -R "${CURRENT_USER}:${CURRENT_USER}" "${USER_HOME}/.config/${cfg}"
        ok "  ${cfg} restored."
      else
        warn "  ${cfg} not in archive."
      fi
    done
    if [ -f "${CONFIG_SRC}/starship.toml" ]; then
      cp -a "${CONFIG_SRC}/starship.toml" "${USER_HOME}/.config/starship.toml"
      chown "${CURRENT_USER}:${CURRENT_USER}" "${USER_HOME}/.config/starship.toml"
      ok "  starship.toml restored."
    fi
  else
    warn "config directory not found in archive — skipping."
  fi
else
  info "Skipped."
fi

# ─── 5. XDG autostart ────────────────────────────────────────────────────────
section "5 · XDG autostart"
if confirm "Restore ~/.config/autostart/?"; then
  src="${EXTRACT_DIR}/config/autostart"
  if [ -d "$src" ]; then
    rm -rf "${USER_HOME}/.config/autostart"
    cp -a "$src" "${USER_HOME}/.config/"
    chown -R "${CURRENT_USER}:${CURRENT_USER}" "${USER_HOME}/.config/autostart"
    ok "Autostart entries restored."
  else
    warn "autostart not found in archive — skipping."
  fi
else
  info "Skipped."
fi

# ─── 6. _apps/ ────────────────────────────────────────────────────────────────
section "6 · ~/_apps/ portable binaries"
if confirm "Restore ~/_apps/?"; then
  src="${EXTRACT_DIR}/home/_apps"
  if [ -d "$src" ]; then
    rm -rf "${USER_HOME}/_apps"
    cp -a "$src" "${USER_HOME}/_apps"
    chown -R "${CURRENT_USER}:${CURRENT_USER}" "${USER_HOME}/_apps"
    ok "_apps restored."
  else
    warn "_apps not found in archive — skipping."
  fi
else
  info "Skipped."
fi

# ─── 7. Custom systemd units ──────────────────────────────────────────────────
section "7 · Custom systemd units"
if confirm "Restore custom systemd units?"; then
  SYS_SRC="${EXTRACT_DIR}/systemd"

  # System units
  if [ -d "${SYS_SRC}/system" ]; then
    cp -a "${SYS_SRC}/system/." /etc/systemd/system/
    ok "  System units restored."
  else
    warn "  No system units in archive."
  fi

  # User-level units
  if [ -d "${SYS_SRC}/user" ]; then
    USYS_DEST="${USER_HOME}/.config/systemd/user"
    mkdir -p "$USYS_DEST"
    cp -a "${SYS_SRC}/user/." "$USYS_DEST/"
    chown -R "${CURRENT_USER}:${CURRENT_USER}" "$USYS_DEST"
    ok "  User systemd units restored."
  else
    warn "  No user systemd units in archive."
  fi

  systemctl daemon-reload
  ok "  systemd daemon reloaded."
else
  info "Skipped."
fi

# ─── 8. Memory tuning config ─────────────────────────────────────────────────
section "8 · Memory tuning config"
if confirm "Restore memory tuning config (sysctl, earlyoom, zram)?"; then
  MEM_SRC="${EXTRACT_DIR}/memory"
  if [ -d "$MEM_SRC" ]; then
    # Restore each file to its original path based on filename heuristics
    while IFS= read -r -d '' f; do
      fname="$(basename "$f")"
      case "$fname" in
        *sysctl*|99-*|90-*)
          dest="/etc/sysctl.d/${fname}"
          cp "$f" "$dest" && ok "  Restored: $dest"
          ;;
        earlyoom.conf)
          cp "$f" /etc/earlyoom.conf && ok "  Restored: /etc/earlyoom.conf"
          ;;
        earlyoom)
          cp "$f" /etc/default/earlyoom && ok "  Restored: /etc/default/earlyoom"
          ;;
        zram-generator.conf)
          cp "$f" /etc/systemd/zram-generator.conf && ok "  Restored: /etc/systemd/zram-generator.conf"
          ;;
        *)
          warn "  Unknown memory config file: ${fname} — skipping."
          ;;
      esac
    done < <(find "$MEM_SRC" -maxdepth 1 -type f -print0)
    sysctl --system >/dev/null 2>&1 && ok "  sysctl --system applied."
  else
    warn "memory directory not found in archive — skipping."
  fi
else
  info "Skipped."
fi

# ─── 9. NetworkManager connections ───────────────────────────────────────────
section "9 · NetworkManager connections"
if confirm "Restore NetworkManager connections (WiFi/VPN passwords)?"; then
  NM_SRC="${EXTRACT_DIR}/NetworkManager/system-connections"
  NM_DEST="/etc/NetworkManager/system-connections"
  if [ -d "$NM_SRC" ]; then
    mkdir -p "$NM_DEST"
    cp -a "${NM_SRC}/." "${NM_DEST}/"
    chmod 600 "${NM_DEST}"/*.nmconnection 2>/dev/null || true
    chmod 600 "${NM_DEST}"/* 2>/dev/null || true
    systemctl reload NetworkManager 2>/dev/null || true
    ok "NetworkManager connections restored. NM reloaded."
  else
    warn "NetworkManager connections not found in archive — skipping."
  fi
else
  info "Skipped."
fi

# ─── 10. VM images + virsh XML ───────────────────────────────────────────────
section "10 · QEMU/KVM VM images + virsh XML definitions"
LIBVIRT_DIR="/var/lib/libvirt/images"
VM_SRC="${EXTRACT_DIR}/vms"

if confirm "Restore VM disk images to ${LIBVIRT_DIR}?"; then
  VM_IMG_SRC="${VM_SRC}/images"
  if [ -d "$VM_IMG_SRC" ]; then
    mkdir -p "$LIBVIRT_DIR"
    find "$VM_IMG_SRC" -maxdepth 1 -type f | while read -r img; do
      copy_with_progress "$img" "$LIBVIRT_DIR"
    done
    chown -R libvirt-qemu:kvm "${LIBVIRT_DIR}" 2>/dev/null \
      || chown -R qemu:qemu "${LIBVIRT_DIR}" 2>/dev/null \
      || warn "  Could not set libvirt ownership — set manually if needed."
    ok "VM images restored."
  else
    warn "VM images not found in archive — skipping."
  fi
else
  info "VM images skipped."
fi

if confirm "Import virsh domain XML definitions?"; then
  VM_XML_SRC="${VM_SRC}/xml"
  if [ -d "$VM_XML_SRC" ]; then
    find "$VM_XML_SRC" -maxdepth 1 -name '*.xml' | while read -r xml; do
      vm_name="$(basename "$xml" .xml)"
      if virsh dominfo "$vm_name" >/dev/null 2>&1; then
        warn "  Domain '${vm_name}' already defined — skipping."
      else
        virsh define "$xml" && ok "  Defined: ${vm_name}"
      fi
    done
  else
    warn "virsh XML directory not found in archive — skipping."
  fi
else
  info "virsh XML import skipped."
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║         Restore complete!                    ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo
info "Verify with:"
cat <<'VERIFY'
  systemctl status cloudflared-minipc-local
  sysctl vm.dirty_ratio vm.page-cluster
  systemctl status earlyoom
  zramctl
  ssh -T git@github.com
  ls ~/.config/autostart/
  virsh list --all
  curl -s https://9090-minipc-local.easyrentbali.com | head -5
VERIFY
echo
warn "Reboot to fully activate ZRAM, sysctl, and any new systemd units."
