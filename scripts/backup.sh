#!/usr/bin/env bash
# =============================================================================
# backup.sh — OS Reinstall Pre-Flight Backup
# Creates a single timestamped .tar.gz of everything not auto-restored
# by the phase scripts. Run this BEFORE reinstalling.
#
# Backs up (with Y/N prompt for each):
#   1.  Cloudflare tunnel credentials (~/.cloudflared/)
#   2.  SSH keys (~/.ssh/)
#   3.  GPG keys (exported as armored ASCII)
#   4.  Shell/terminal config (fish, ghostty, zellij, starship)
#   5.  XDG autostart (~/.config/autostart/)
#   6.  ~/_apps/ portable binaries
#   7.  Custom systemd units (cloudflared-*.service, user@.service.d/)
#   8.  Memory tuning config (sysctl, earlyoom, zram-generator)
#   9.  NetworkManager connections (WiFi/VPN saved passwords)
#  10.  /etc/fstab + btrfs subvolume list (reference)
#  11.  QEMU/KVM VM images + virsh XML definitions
#
# Output: ~/minipc-backup-YYYYMMDD-HHMMSS.tar.gz
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

# ─── Must NOT run as root (we need the real home dir) ────────────────────────
if [ "$EUID" -eq 0 ]; then
  err "Do NOT run this script as root. Run as your normal user (sudo will be called internally where needed)."
  exit 1
fi

CURRENT_USER="$USER"
USER_HOME="$HOME"

# ─── Timestamp + paths ───────────────────────────────────────────────────────
TS="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_NAME="minipc-backup-${TS}.tar.gz"
ARCHIVE_PATH="${USER_HOME}/${ARCHIVE_NAME}"
STAGE_DIR="$(mktemp -d "${USER_HOME}/.minipc-backup-stage-XXXXXX")"

cleanup() { sudo rm -rf "$STAGE_DIR"; }
trap cleanup EXIT

# ─── Banner ──────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   minipc — OS Reinstall Pre-Flight Backup    ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo
info "User   : ${CURRENT_USER}"
info "Home   : ${USER_HOME}"
info "Output : ${ARCHIVE_PATH}"
info "Stage  : ${STAGE_DIR}"
echo
warn "Answer Y/N for each section. Default is Y (press Enter to accept)."
echo

# ─── Helper: copy a single file with progress ────────────────────────────────
copy_with_progress() {
  # copy_with_progress <src> <dest_dir>  (dest_dir must exist)
  local src="$1" dest_dir="$2"
  local fname size_bytes
  fname="$(basename "$src")"
  size_bytes="$(sudo stat -c%s "$src" 2>/dev/null || stat -c%s "$src" 2>/dev/null || echo 0)"

  if command -v pv >/dev/null 2>&1; then
    sudo pv -N "$fname" -s "$size_bytes" "$src" > "${dest_dir}/${fname}"
  elif command -v rsync >/dev/null 2>&1; then
    sudo rsync --progress --no-inc-recursive "$src" "${dest_dir}/"
  else
    info "  (pv/rsync not found — plain copy)"
    sudo cp "$src" "${dest_dir}/"
  fi
}

# ─── Helper: copy with parent-dir preservation ───────────────────────────────
stage_copy() {
  # stage_copy <src_path> <dest_subdir_in_stage>
  local src="$1" dest_sub="$2"
  local dest="${STAGE_DIR}/${dest_sub}"
  mkdir -p "$dest"
  if [ -d "$src" ]; then
    cp -a "$src" "$dest/"
  elif [ -f "$src" ]; then
    cp -a "$src" "$dest/"
  else
    warn "  Source not found, skipping: $src"
    return 1
  fi
}

# ─── 1. Cloudflare credentials ───────────────────────────────────────────────
section "1 · Cloudflare tunnel credentials"
info "Source: ~/.cloudflared/"
if confirm "Back up Cloudflare credentials?"; then
  if [ -d "${USER_HOME}/.cloudflared" ]; then
    stage_copy "${USER_HOME}/.cloudflared" "cloudflared"
    ok "Cloudflare credentials staged."
  else
    warn "~/.cloudflared not found — skipping."
  fi
else
  info "Skipped."
fi

# ─── 2. SSH keys ─────────────────────────────────────────────────────────────
section "2 · SSH keys"
info "Source: ~/.ssh/"
if confirm "Back up SSH keys?"; then
  if [ -d "${USER_HOME}/.ssh" ]; then
    stage_copy "${USER_HOME}/.ssh" "ssh"
    ok "SSH keys staged."
  else
    warn "~/.ssh not found — skipping."
  fi
else
  info "Skipped."
fi

# ─── 3. GPG keys ─────────────────────────────────────────────────────────────
section "3 · GPG keys"
info "Exports all secret keys + trust db as armored ASCII."
if confirm "Back up GPG keys?"; then
  GPG_STAGE="${STAGE_DIR}/gpg"
  mkdir -p "$GPG_STAGE"
  GPG_IDS="$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^sec/{print $5}' || true)"
  if [ -n "$GPG_IDS" ]; then
    gpg --armor --export-secret-keys > "${GPG_STAGE}/secret-keys.asc"
    gpg --armor --export > "${GPG_STAGE}/public-keys.asc"
    gpg --export-ownertrust > "${GPG_STAGE}/ownertrust.txt"
    ok "GPG keys exported: $(echo "$GPG_IDS" | wc -l) secret key(s)."
  else
    warn "No GPG secret keys found — skipping."
  fi
else
  info "Skipped."
fi

# ─── 4. Shell/terminal config ─────────────────────────────────────────────────
section "4 · Shell/terminal config (fish, ghostty, zellij, starship)"
if confirm "Back up shell/terminal config?"; then
  CFG_STAGE="${STAGE_DIR}/config"
  mkdir -p "$CFG_STAGE"
  for cfg in fish ghostty zellij; do
    src="${USER_HOME}/.config/${cfg}"
    [ -d "$src" ] && { stage_copy "$src" "config"; ok "  ${cfg} staged."; } || warn "  ~/.config/${cfg} not found."
  done
  # starship.toml lives directly in ~/.config/
  star="${USER_HOME}/.config/starship.toml"
  [ -f "$star" ] && { cp -a "$star" "${STAGE_DIR}/config/"; ok "  starship.toml staged."; } || warn "  starship.toml not found."
else
  info "Skipped."
fi

# ─── 5. XDG autostart ────────────────────────────────────────────────────────
section "5 · XDG autostart (~/.config/autostart/)"
if confirm "Back up autostart entries?"; then
  src="${USER_HOME}/.config/autostart"
  if [ -d "$src" ]; then
    stage_copy "$src" "config"
    ok "Autostart staged."
  else
    warn "~/.config/autostart not found — skipping."
  fi
else
  info "Skipped."
fi

# ─── 6. _apps/ ────────────────────────────────────────────────────────────────
section "6 · ~/_apps/ portable binaries (Thorium, etc.)"
warn "This directory may be large. Check size first:"
du -sh "${USER_HOME}/_apps" 2>/dev/null || warn "  ~/_apps not found."
if confirm "Back up ~/_apps/?"; then
  src="${USER_HOME}/_apps"
  if [ -d "$src" ]; then
    dest="${STAGE_DIR}/home/_apps"
    mkdir -p "$dest"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --info=progress2 "${src}/" "${dest}/"
    else
      info "  (rsync not found — plain copy)"
      cp -a "${src}/." "${dest}/"
    fi
    ok "_apps staged."
  else
    warn "~/_apps not found — skipping."
  fi
else
  info "Skipped."
fi

# ─── 7. Custom systemd units ──────────────────────────────────────────────────
section "7 · Custom systemd units"
info "Backing up cloudflared-*.service and user@.service.d/ drop-ins."
if confirm "Back up systemd units?"; then
  SYS_STAGE="${STAGE_DIR}/systemd"
  mkdir -p "${SYS_STAGE}/system" "${SYS_STAGE}/user"

  # System units (requires sudo for /etc/systemd/system)
  CF_UNITS="$(sudo find /etc/systemd/system -maxdepth 1 -name 'cloudflared-*.service' 2>/dev/null || true)"
  if [ -n "$CF_UNITS" ]; then
    echo "$CF_UNITS" | xargs sudo cp -t "${SYS_STAGE}/system/"
    ok "  cloudflared service units staged."
  else
    warn "  No cloudflared-*.service units found in /etc/systemd/system."
  fi

  # user@.service.d drop-ins
  USER_AT_DROP="/etc/systemd/system/user@.service.d"
  if sudo test -d "$USER_AT_DROP"; then
    sudo cp -a "$USER_AT_DROP" "${SYS_STAGE}/system/"
    ok "  user@.service.d drop-ins staged."
  else
    warn "  No user@.service.d drop-ins found."
  fi

  # User-level systemd units
  USER_SYSTEMD="${USER_HOME}/.config/systemd/user"
  if [ -d "$USER_SYSTEMD" ]; then
    stage_copy "$USER_SYSTEMD" "systemd/user"
    ok "  User systemd units staged."
  else
    warn "  No user-level systemd units found."
  fi
else
  info "Skipped."
fi

# ─── 8. Memory tuning config ─────────────────────────────────────────────────
section "8 · Memory tuning config (sysctl, earlyoom, zram-generator)"
if confirm "Back up memory tuning config?"; then
  MEM_STAGE="${STAGE_DIR}/memory"
  mkdir -p "$MEM_STAGE"

  for f in \
    /etc/sysctl.d/99-minipc.conf \
    /etc/sysctl.d/90-memory.conf \
    /etc/earlyoom.conf \
    /etc/default/earlyoom \
    /etc/systemd/zram-generator.conf \
    /usr/lib/systemd/system/earlyoom.service.d/minipc.conf
  do
    if sudo test -f "$f"; then
      sudo cp "$f" "${MEM_STAGE}/"
      ok "  Staged: $f"
    fi
  done

  # Any sysctl drop-in that mentions vm. or minipc
  sudo find /etc/sysctl.d -name '*.conf' 2>/dev/null | while read -r sc; do
    if sudo grep -qE 'vm\.|minipc' "$sc" 2>/dev/null; then
      sudo cp "$sc" "${MEM_STAGE}/"
      ok "  Staged sysctl: $sc"
    fi
  done || true

  ok "Memory tuning config staged."
else
  info "Skipped."
fi

# ─── 9. NetworkManager connections ───────────────────────────────────────────
section "9 · NetworkManager connections (WiFi/VPN passwords)"
warn "This contains plaintext PSKs. The archive will be protected only by filesystem permissions."
if confirm "Back up NetworkManager connections?"; then
  NM_STAGE="${STAGE_DIR}/NetworkManager/system-connections"
  mkdir -p "$NM_STAGE"
  if sudo test -d /etc/NetworkManager/system-connections; then
    sudo cp -a /etc/NetworkManager/system-connections/. "${NM_STAGE}/"
    sudo chown -R "${CURRENT_USER}:${CURRENT_USER}" "${NM_STAGE}/"
    ok "NetworkManager connections staged."
  else
    warn "No NetworkManager connections found at /etc/NetworkManager/system-connections."
  fi
else
  info "Skipped."
fi

# ─── 10. /etc/fstab + Btrfs subvolume list ───────────────────────────────────
section "10 · /etc/fstab + Btrfs subvolume list (reference)"
if confirm "Back up fstab and Btrfs subvolume list?"; then
  FS_STAGE="${STAGE_DIR}/filesystem"
  mkdir -p "$FS_STAGE"
  sudo cp /etc/fstab "${FS_STAGE}/fstab"
  ok "  fstab staged."
  btrfs subvolume list / > "${FS_STAGE}/btrfs-subvolumes.txt" 2>/dev/null \
    && ok "  Btrfs subvolume list staged." \
    || warn "  Could not list Btrfs subvolumes (not Btrfs root?)."
  lsblk -f > "${FS_STAGE}/lsblk.txt" 2>/dev/null && ok "  lsblk output staged."
else
  info "Skipped."
fi

# ─── 11. QEMU/KVM VMs ────────────────────────────────────────────────────────
section "11 · QEMU/KVM VM images + virsh XML definitions"
LIBVIRT_DIR="/var/lib/libvirt/images"
VM_STAGE="${STAGE_DIR}/vms"
mkdir -p "${VM_STAGE}/xml" "${VM_STAGE}/images"

info "Scanning ${LIBVIRT_DIR} for VM disks..."
QCOW2_FILES="$(sudo find "$LIBVIRT_DIR" -maxdepth 1 \( -name '*.qcow2' -o -name '*-seed.iso' \) 2>/dev/null || true)"
if [ -n "$QCOW2_FILES" ]; then
  echo "$QCOW2_FILES" | while read -r f; do
    SIZE="$(sudo du -sh "$f" 2>/dev/null | cut -f1)"
    warn "  Found: $(basename "$f")  (${SIZE})"
  done
else
  warn "  No .qcow2 or seed .iso files found in ${LIBVIRT_DIR}."
fi

if confirm "Back up VM disk images (*.qcow2 + *-seed.iso)?"; then
  if [ -n "$QCOW2_FILES" ]; then
    echo "$QCOW2_FILES" | while read -r f; do
      copy_with_progress "$f" "${VM_STAGE}/images"
    done
    sudo chown -R "${CURRENT_USER}:${CURRENT_USER}" "${VM_STAGE}/images/"
    ok "VM images staged."
  else
    warn "Nothing to copy."
  fi
else
  info "VM images skipped."
fi

if confirm "Export virsh domain XML definitions?"; then
  VM_NAMES="$(virsh list --all --name 2>/dev/null | grep -v '^$' || true)"
  if [ -n "$VM_NAMES" ]; then
    echo "$VM_NAMES" | while read -r vm; do
      virsh dumpxml "$vm" > "${VM_STAGE}/xml/${vm}.xml" 2>/dev/null && ok "  Exported: ${vm}.xml"
    done
  else
    warn "  No libvirt domains found."
  fi
else
  info "virsh XML export skipped."
fi

# ─── Compress ─────────────────────────────────────────────────────────────────
section "Compressing archive"
info "Creating ${ARCHIVE_PATH} ..."
tar -czf "$ARCHIVE_PATH" -C "$STAGE_DIR" .
chmod 600 "$ARCHIVE_PATH"

ARCHIVE_SIZE="$(du -sh "$ARCHIVE_PATH" | cut -f1)"
echo
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║            Backup complete!                  ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${RESET}"
ok "Archive : ${ARCHIVE_PATH}"
ok "Size    : ${ARCHIVE_SIZE}"
echo
info "Move this file to external storage before reinstalling."
info "Restore with:  sudo bash scripts/restore.sh ${ARCHIVE_PATH}"
