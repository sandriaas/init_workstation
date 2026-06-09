#!/usr/bin/env bash
#
# persistence/deploy.sh
#
# Copy all `persistence/` and `config/` files to WSL at their proper
# runtime locations. Use this after editing apply-fixes.sh or any
# config files locally.
#
# Idempotent: safe to run multiple times.
#
# Can be run from:
#   - Windows PowerShell:  bash wsl-zeabur/persistence/deploy.sh
#   - WSL/Linux directly:  bash /mnt/c/init_workstation/wsl-zeabur/persistence/deploy.sh
#     (the WSL commands below will be skipped since they don't exist inside WSL)
#
set -euo pipefail

WSL_DISTRO="${WSL_DISTRO:-wsl_test_server_001}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Detect if we're inside WSL or on Windows
IN_WSL=0
if grep -qi microsoft /proc/version 2>/dev/null; then
    IN_WSL=1
fi
if [ "$IN_WSL" = "1" ]; then
    log "Detected: running inside WSL (skipping nested wsl calls)"
else
    log "Detected: running on Windows (will invoke wsl -d $WSL_DISTRO)"
fi

# Run a command in the WSL distro. On Windows, this invokes `wsl -d`.
# Inside WSL, this just runs the command directly with sudo.
wsl_run() {
    local cmd="$1"
    if [ "$IN_WSL" = "1" ]; then
        sudo bash -c "$cmd"
    else
        wsl -d "$WSL_DISTRO" -- bash -c "$cmd"
    fi
}

copy_to_wsl() {
    local src_rel="$1"   # path relative to repo root
    local dst="$2"       # absolute path in WSL
    local mode="${3:-0755}"
    log "Copying $src_rel -> $dst (mode $mode)"
    wsl_run "install -m $mode -D '/mnt/c/init_workstation/wsl-zeabur/$src_rel' '$dst'"
}

main() {
    log "=== Deploying wsl-zeabur files to $WSL_DISTRO ==="

    # 1. apply-fixes.sh
    copy_to_wsl "persistence/apply-fixes.sh" "/opt/zeabur-fixes/apply-fixes.sh"

    # 2. install-nats-cli.sh
    copy_to_wsl "persistence/install-nats-cli.sh" "/opt/zeabur-fixes/install-nats-cli.sh"

    # 3. nats CLI binary
    if [ -f "$REPO_ROOT/persistence/bin/nats" ]; then
        log "Copying nats CLI binary"
        wsl_run "install -m 0755 -D /mnt/c/init_workstation/wsl-zeabur/persistence/bin/nats /usr/local/bin/nats"
    fi

    # 4. k3s drop-in
    copy_to_wsl "persistence/k3s.service.d-override.conf" "/etc/systemd/system/k3s.service.d/override.conf"
    wsl_run "systemctl daemon-reload"

    # 5. rc.local
    copy_to_wsl "persistence/rc.local" "/etc/rc.local"
    wsl_run "chmod +x /etc/rc.local"

    # 5b. start-tailscale.sh (the detached launcher with flock guard)
    if [ -f "$REPO_ROOT/config/systemd/start-tailscale.sh" ]; then
        copy_to_wsl "config/systemd/start-tailscale.sh" "/usr/local/bin/start-tailscale.sh"
    fi

    # 5c. tailscaled systemd override (Restart=no, KillMode=process, etc.)
    if [ -f "$REPO_ROOT/config/systemd/tailscaled-override.conf" ]; then
        wsl_run "mkdir -p /etc/systemd/system/tailscaled.service.d"
        copy_to_wsl "config/systemd/tailscaled-override.conf" \
                    "/etc/systemd/system/tailscaled.service.d/override.conf"
        wsl_run "systemctl daemon-reload"
    fi

    # 5d. rc-local.service (Type=oneshot, RemainAfterExit=yes - keeps cgroup alive)
    if [ -f "$REPO_ROOT/config/systemd/rc-local.service" ]; then
        copy_to_wsl "config/systemd/rc-local.service" "/etc/systemd/system/rc-local.service"
        wsl_run "systemctl daemon-reload && systemctl enable rc-local.service"
    fi

    # 5e. Disable systemd-managed tailscaled (the detached launcher owns it)
    wsl_run "systemctl disable tailscaled 2>/dev/null || true"
    wsl_run "systemctl stop tailscaled 2>/dev/null || true"

    # 6. cloudflared config (if present)
    if [ -d "$REPO_ROOT/config/cloudflared" ]; then
        log "Copying cloudflared config"
        wsl_run "mkdir -p /etc/cloudflared"
        for f in "$REPO_ROOT/config/cloudflared/"*; do
            if [ -f "$f" ]; then
                fname="$(basename "$f")"
                # Credentials must be 0600, others 0644
                if [ "$fname" = "credentials.json" ]; then
                    copy_to_wsl "config/cloudflared/$fname" "/etc/cloudflared/$fname" "0600"
                else
                    copy_to_wsl "config/cloudflared/$fname" "/etc/cloudflared/$fname" "0644"
                fi
            fi
        done
    fi

    # 7. cloudflared systemd unit
    if [ -f "$REPO_ROOT/config/systemd/cloudflared.service" ]; then
        copy_to_wsl "config/systemd/cloudflared.service" "/etc/systemd/system/cloudflared.service"
        wsl_run "systemctl daemon-reload && systemctl enable cloudflared.service"
    fi

    # 8. Domain scripts (repo uses numbered prefixes; deploy under stable names)
    declare -A domain_scripts=(
        ["scripts/domain/02-expose-service.sh"]="/opt/zeabur-fixes/expose-service.sh"
        ["scripts/domain/05-unexpose-service.sh"]="/opt/zeabur-fixes/unexpose-service.sh"
        ["scripts/domain/06-list-exposed.sh"]="/opt/zeabur-fixes/list-exposed.sh"
    )
    for src in "${!domain_scripts[@]}"; do
        if [ -f "$REPO_ROOT/${src#scripts/domain/}" ] || [ -f "$REPO_ROOT/$src" ]; then
            copy_to_wsl "$src" "${domain_scripts[$src]}"
        fi
    done

    # 9. Public exposures (data-driven). Seed any *.conf shipped in the repo
    #    under persistence/exposures.d/ so a fresh machine re-creates the same
    #    public Ingresses. Never hardcoded in apply-fixes.sh.
    if [ -d "$REPO_ROOT/persistence/exposures.d" ]; then
        wsl_run "mkdir -p /opt/zeabur-fixes/exposures.d"
        for f in "$REPO_ROOT/persistence/exposures.d/"*.conf; do
            [ -f "$f" ] || continue
            fname="$(basename "$f")"
            copy_to_wsl "persistence/exposures.d/$fname" "/opt/zeabur-fixes/exposures.d/$fname" "0644"
        done
    fi

    log "=== Deployment complete ==="
    log ""
    log "Next steps:"
    log "  1. To test apply-fixes.sh idempotency: wsl -d $WSL_DISTRO -- sudo /opt/zeabur-fixes/apply-fixes.sh"
    log "  2. To test the tunnel: curl -I https://stalwart.cfworkers.dpdns.org/admin"
}

main "$@"
