#!/usr/bin/env bash
# =============================================================================
# vm-guard.sh — Keep selected libvirt VM online (no-GPU stable mode friendly)
# - Starts VM if it is not running
# - Optionally starts default libvirt network if down
# - Reports cloudflared status (host tunnel)
# Safe to run from cron/systemd timer every minute.
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
ok()      { echo -e "${GREEN}[OK]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
err()     { echo -e "${RED}[ERR]${RESET}  $*" >&2; }
section() { echo -e "\n${BOLD}══ $* ══${RESET}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_FILE="${REPO_DIR}/generated-vm/.state"
VM_CONF="$(ls "${REPO_DIR}"/generated-vm/*.conf 2>/dev/null | head -1 || true)"

VM_NAME=""
if [ -f "${STATE_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${STATE_FILE}" 2>/dev/null || true
  VM_NAME="${LAST_VM_NAME:-}"
fi
if [ -z "${VM_NAME}" ] && [ -n "${VM_CONF}" ] && [ -f "${VM_CONF}" ]; then
  # shellcheck disable=SC1090
  set +u
  source "${VM_CONF}" 2>/dev/null || true
  set -u
  VM_NAME="${VM_NAME:-}"
fi
[ -n "${VM_NAME}" ] || VM_NAME="vm_1"

section "VM Guard"
info "Target VM: ${VM_NAME}"

if ! command -v virsh >/dev/null 2>&1; then
  err "virsh not found"
  exit 1
fi

# Ensure default NAT network is up (harmless if already active)
if virsh net-info default >/dev/null 2>&1; then
  NET_ACTIVE="$(virsh net-info default 2>/dev/null | awk '/^Active:/{print $2; exit}' || true)"
  if [ "${NET_ACTIVE}" != "yes" ]; then
    info "libvirt network 'default' inactive — starting it"
    if virsh net-start default >/dev/null 2>&1; then
      ok "libvirt network 'default' started"
    else
      warn "Could not start libvirt network 'default'"
    fi
  fi
fi

VM_STATE="$(virsh domstate "${VM_NAME}" 2>/dev/null || echo "not found")"
case "${VM_STATE}" in
  running)
    ok "VM '${VM_NAME}' is running"
    ;;
  "not found")
    err "VM '${VM_NAME}' not found in libvirt"
    exit 1
    ;;
  *)
    warn "VM '${VM_NAME}' state is '${VM_STATE}' — attempting start"
    if virsh start "${VM_NAME}" >/dev/null 2>&1; then
      ok "Started VM '${VM_NAME}'"
    else
      err "Failed to start VM '${VM_NAME}'"
      exit 1
    fi
    ;;
esac

if systemctl is-active cloudflared >/dev/null 2>&1; then
  ok "cloudflared is active"
else
  warn "cloudflared is not active (host tunnel may be unavailable)"
fi
