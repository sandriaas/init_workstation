#!/usr/bin/env bash
#
# persistence/bootstrap.sh
#
# ONE-SHOT post-install bootstrap for Zeabur-on-WSL2.
#
# PREREQUISITES (must already be done by the user / Zeabur dashboard):
#   1. WSL2 distro `wsl_test_server_001` exists (Ubuntu 24.04)
#   2. Zeabur dashboard Wonder Mesh install script has been run inside WSL
#   3. `tailscale status` shows the gateway `active`
#   4. `kubectl get nodes` shows the node `Ready`
#
# This script does NOT install Tailscale or k3s - those come from the
# Zeabur dashboard. This script adds the persistence, public-exposure,
# and host-power-hardening layer on top.
#
# What it does, in order:
#   [A] Windows host: powercfg hardening (sleep / hibernate / unattended)
#   [B] Windows host: ensure C:\Users\Sandria\.wslconfig has vmIdleTimeout=2147483647
#   [C] wsl --shutdown + relaunch (picks up new timeout)
#   [D] WSL: verify Tailscale + k3s are healthy
#   [E] WSL: deploy our files (apply-fixes.sh, rc.local, start-tailscale.sh, cloudflared)
#   [F] WSL: install nats CLI (idempotent)
#   [G] WSL: install + start cloudflared
#   [H] WSL: run apply-fixes.sh to seed the cluster fixes
#   [I] WSL: seed exposures.d/stalwart.conf (data-driven Ingress)
#   [J] Verification: all 8 checks from CONTINUE.md §8
#
# Idempotent: safe to run multiple times.
#
# Run from Windows PowerShell:
#   bash C:\init_workstation\wsl-zeabur\persistence\bootstrap.sh
#
# Or from WSL:
#   bash /mnt/c/init_workstation/wsl-zeabur/persistence/bootstrap.sh
#
set -euo pipefail

# ---- paths & config --------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WSL_DISTRO="${WSL_DISTRO:-wsl_test_server_001}"
REPO_WIN='C:\init_workstation\wsl-zeabur'
WSLCONFIG_WIN='C:\Users\Sandria\.wslconfig'
EXPOSURES_DIR="/opt/zeabur-fixes/exposures.d"
STALWART_NS="environment-6a242c9f95b39806d284aaa7"
STALWART_SVC="service-6a242f96f1be9943f1f972a7"
STALWART_PORT=8080

# ---- helper functions ------------------------------------------------------
log()   { echo -e "\033[1;36m[$(date +%H:%M:%S)]\033[0m $*"; }
ok()    { echo -e "\033[1;32m  ✔\033[0m $*"; }
warn()  { echo -e "\033[1;33m  !\033[0m $*"; }
fail()  { echo -e "\033[1;31m  ✖\033[0m $*"; exit 1; }

in_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }

# Run a command in WSL. From Windows: `wsl -d`. From WSL: direct.
wsl_run() {
    if in_wsl; then
        sudo bash -c "$1"
    else
        wsl -d "$WSL_DISTRO" -- bash -c "$1"
    fi
}

# Run a PowerShell command. From Windows: pwsh. From WSL: powershell.exe.
ps_run() {
    if in_wsl; then
        powershell.exe -NoProfile -Command "$1"
    else
        pwsh -NoProfile -Command "$1"
    fi
}

# ---- preflight -------------------------------------------------------------
log "=== Zeabur-on-WSL2 Bootstrap (post-install) ==="
log "Repo:        $REPO_ROOT"
log "WSL distro:  $WSL_DISTRO"
log "Run from:    $(in_wsl && echo 'WSL' || echo 'Windows')"
echo

# Check the WSL distro actually exists (Windows side)
if ! in_wsl; then
    if ! wsl -l -q 2>/dev/null | grep -q "$WSL_DISTRO"; then
        fail "WSL distro '$WSL_DISTRO' not found. Install it first:
  wsl --install -d Ubuntu-24.04 --name $WSL_DISTRO"
    fi
    # Make sure it's actually running so wsl_run works
    wsl -d "$WSL_DISTRO" -- true || wsl -d "$WSL_DISTRO" -- true
    ok "WSL distro '$WSL_DISTRO' is reachable"
fi

# Check that the Zeabur install has already been run
log "[D] Preflight: Tailscale + k3s must already be installed by the Zeabur dashboard"
if in_wsl; then
    HAVE_TS=0
    command -v tailscale >/dev/null 2>&1 && HAVE_TS=1
    if [ "$HAVE_TS" = "0" ]; then
        fail "tailscale is not installed. Run the Zeabur Wonder Mesh install script first
  (Dashboard -> Servers -> Wonder Mesh -> copy the curl|bash install command)"
    fi
    ok "tailscale binary present"
    K3S_PRESENT=0
    command -v k3s >/dev/null 2>&1 && K3S_PRESENT=1
    [ "$K3S_PRESENT" = "0" ] && command -v kubectl >/dev/null 2>&1 && K3S_PRESENT=1
    if [ "$K3S_PRESENT" = "0" ]; then
        fail "k3s is not installed. Run the Zeabur install script first."
    fi
    ok "k3s present"
    if ! sudo kubectl get nodes >/dev/null 2>&1; then
        fail "kubectl get nodes failed. The cluster isn't up yet. Wait for k3s to finish
  starting (up to 2 minutes after the install script) and re-run bootstrap.sh."
    fi
    ok "k3s API responding"
    if ! sudo tailscale status >/dev/null 2>&1; then
        fail "tailscale status failed. Re-authenticate the mesh:
  sudo tailscale logout
  sudo tailscale up --auth-key=\$(cat /tmp/ts-key) --login-server=https://wonder.zeabur.com --accept-routes"
    fi
    ok "tailscale is running"
fi

# ---- [A] Windows host power hardening -------------------------------------
log ""
log "[A] Windows host power hardening (Modern Standby, unattended sleep, hibernate)"
PS_CMD='
$ErrorActionPreference = "Continue"
$schemes = powercfg -list | Select-String "Power Scheme GUID" | ForEach-Object { ($_ -split ":")[1].Trim() }
foreach ($s in $schemes) {
    powercfg -setactive $s 2>$null
    powercfg -change -standby-timeout-ac 0  2>$null
    powercfg -change -standby-timeout-dc 0  2>$null
    powercfg -change -hibernate-timeout-ac 0 2>$null
    powercfg -change -hibernate-timeout-dc 0 2>$null
    powercfg -setacvalueindex $s SUB_SLEEP UNATTENDSLEEP 0 2>$null
    powercfg -setdcvalueindex $s SUB_SLEEP UNATTENDSLEEP 0 2>$null
    powercfg -setacvalueindex $s SUB_SLEEP STANDBYIDLE 0 2>$null
    powercfg -setdcvalueindex $s SUB_SLEEP STANDBYIDLE 0 2>$null
}
Write-Host "  AC standby:        $(powercfg -query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE | Select-String CurrentACPowerSetting | ForEach-Object { (\$_ -split \"\\s+\")[3] })"
Write-Host "  DC standby:        $(powercfg -query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE | Select-String CurrentDCPowerSetting | ForEach-Object { (\$_ -split \"\\s+\")[3] })"
Write-Host "  Unattended sleep:  $(powercfg -query SCHEME_CURRENT SUB_SLEEP UNATTENDSLEEP | Select-String CurrentACPowerSetting | ForEach-Object { (\$_ -split \"\\s+\")[3] })"
Write-Host "  Hibernate:         $(powercfg -query SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE | Select-String CurrentACPowerSetting | ForEach-Object { (\$_ -split \"\\s+\")[3] })"
'
ps_run "$PS_CMD" || warn "powercfg ran with warnings (non-fatal)"
ok "Power settings configured to never sleep"

# ---- [B] .wslconfig with vmIdleTimeout ------------------------------------
log ""
log "[B] Ensure $WSLCONFIG_WIN has vmIdleTimeout=2147483647 (fixes WSL idle-shutdown)"
if [ -f "/mnt/c/Users/Sandria/.wslconfig" ]; then
    if grep -q "vmIdleTimeout" "/mnt/c/Users/Sandria/.wslconfig"; then
        ok ".wslconfig already has vmIdleTimeout"
    else
        # Add it under [wsl2]
        if in_wsl; then
            powershell.exe -NoProfile -Command "Add-Content -Path 'C:\Users\Sandria\.wslconfig' -Value 'vmIdleTimeout=2147483647'"
        else
            Add-Content -Path "$WSLCONFIG_WIN" -Value 'vmIdleTimeout=2147483647'
        fi
        ok "Appended vmIdleTimeout=2147483647 to .wslconfig"
    fi
    if in_wsl; then
        powershell.exe -NoProfile -Command "Get-Content 'C:\Users\Sandria\.wslconfig'"
    else
        Get-Content "$WSLCONFIG_WIN"
    fi
else
    warn ".wslconfig doesn't exist yet - skipping (the Zeabur install script creates it)"
fi

# ---- [C] wsl --shutdown to apply new timeout ------------------------------
log ""
log "[C] wsl --shutdown so the new vmIdleTimeout takes effect"
if ! in_wsl; then
    wsl --shutdown
    sleep 5
    # Re-launch the distro
    wsl -d "$WSL_DISTRO" -- true
    ok "WSL re-launched with new vmIdleTimeout"
else
    warn "Already in WSL; if you just changed .wslconfig, run 'wsl --shutdown' from PowerShell"
fi

# ---- [E] Deploy our files -------------------------------------------------
log ""
log "[E] Deploying wsl-zeabur files into WSL"
bash "$SCRIPT_DIR/deploy.sh" || fail "deploy.sh failed"
ok "All persistence + config files deployed"

# ---- [F] Install nats CLI -------------------------------------------------
log ""
log "[F] Install nats CLI (idempotent)"
wsl_run "command -v nats >/dev/null 2>&1 || bash /opt/zeabur-fixes/install-nats-cli.sh"
ok "nats CLI: $(wsl_run 'command -v nats && nats --version' 2>/dev/null | tail -1)"

# ---- [G] Install + start cloudflared --------------------------------------
log ""
log "[G] Install + start cloudflared (Cloudflare Tunnel)"
wsl_run '
  set -e
  if ! command -v cloudflared >/dev/null 2>&1; then
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared noble main" \
      > /etc/apt/sources.list.d/cloudflared.list
    apt-get update -y
    apt-get install -y cloudflared
  fi
  mkdir -p /etc/cloudflared
  cp -n /mnt/c/init_workstation/wsl-zeabur/config/cloudflared/credentials.json /etc/cloudflared/credentials.json 2>/dev/null || true
  chmod 600 /etc/cloudflared/credentials.json 2>/dev/null || true
  cp -f /mnt/c/init_workstation/wsl-zeabur/config/cloudflared/config.yml /etc/cloudflared/config.yml
  cp -f /mnt/c/init_workstation/wsl-zeabur/config/systemd/cloudflared.service /etc/systemd/system/cloudflared.service
  systemctl daemon-reload
  systemctl enable --now cloudflared
  sleep 3
  systemctl is-active cloudflared && echo "cloudflared: active"
' || fail "cloudflared install/start failed"
ok "cloudflared installed and started"

# ---- [H] Run apply-fixes.sh once to seed everything ------------------------
log ""
log "[H] Run /opt/zeabur-fixes/apply-fixes.sh to seed all cluster fixes"
wsl_run "sudo /opt/zeabur-fixes/apply-fixes.sh" || fail "apply-fixes.sh failed"
ok "apply-fixes.sh completed"

# ---- [I] Seed exposures.d/stalwart.conf ------------------------------------
log ""
log "[I] Seed exposures.d/stalwart.conf (data-driven Ingress for stalwart)"
wsl_run "
  mkdir -p $EXPOSURES_DIR
  cat > $EXPOSURES_DIR/stalwart.conf <<'EOF'
# Public exposure for stalwart.cfworkers.dpdns.org
# Auto-created by bootstrap.sh. To add more, run expose-service.sh, never edit this.
sub=stalwart
ns=$STALWART_NS
svc=$STALWART_SVC
port=$STALWART_PORT
EOF
  chmod 0644 $EXPOSURES_DIR/stalwart.conf
  echo 'exposure file:'
  cat $EXPOSURES_DIR/stalwart.conf
"
# Run apply-fixes.sh again so the Ingress gets created from the .conf
wsl_run "sudo /opt/zeabur-fixes/apply-fixes.sh" || warn "second apply-fixes.sh returned non-zero (probably already idempotent)"
ok "stalwart exposure seeded"

# ---- [J] Verification ------------------------------------------------------
log ""
log "[J] Final verification (all 8 checks from CONTINUE.md §8)"
PASS=0
FAIL=0
check() {
    local desc="$1"; shift
    local out
    out="$(wsl_run "$@" 2>/dev/null || true)"
    if echo "$out" | grep -qE "$PASS_RE"; then
        ok "$desc"
        PASS=$((PASS+1))
    else
        warn "$desc - did not match. Output:"
        echo "$out" | sed 's/^/      /'
        FAIL=$((FAIL+1))
    fi
}

PASS_RE='100\.64\.0\.1.*active'
check "1. Tailscale shows gateway active" \
    "sudo tailscale status 2>&1 | head -10" || true

PASS_RE='Ready\s+<none>'
check "2. k3s node Ready" \
    "sudo kubectl get nodes --no-headers 2>/dev/null" || true

PASS_RE='ingress-controller.*1/1'
check "3. ingress-controller Running" \
    "sudo kubectl get pods -A --no-headers 2>/dev/null" || true

PASS_RE='nats-0.*2/2'
check "4. nats-0 2/2 Running" \
    "sudo kubectl get pods -A --no-headers 2>/dev/null" || true

PASS_RE='zeabur-kube-watch.*1/1'
check "5. zeabur-kube-watch Running" \
    "sudo kubectl get pods -A --no-headers 2>/dev/null" || true

PASS_RE='forward \. 8\.8\.8\.8'
check "6. CoreDNS forward patched" \
    "sudo kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' 2>/dev/null" || true

PASS_RE='rewrite name exact nats\.zeabur\.com'
check "7. CoreDNS nats.zeabur.com rewrite present" \
    "sudo kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' 2>/dev/null" || true

PASS_RE='stalwart-cfworkers'
check "8. stalwart-cfworkers Ingress exists" \
    "sudo kubectl get ing --all-namespaces --no-headers 2>/dev/null" || true

# Public URL test
log ""
log "[J.9] Public URL test (https://stalwart.cfworkers.dpdns.org)"
if curl -sk --max-time 15 -I "https://stalwart.cfworkers.dpdns.org/admin" 2>/dev/null \
    | head -1 | grep -qE "HTTP/.*30[0-9]|HTTP/.*200"; then
    ok "Public URL returns 200/302 — public exposure works"
    PASS=$((PASS+1))
else
    warn "Public URL did NOT return 200/302. cloudflared may still be registering. Wait 60s and:"
    echo "      curl -I https://stalwart.cfworkers.dpdns.org/admin"
    FAIL=$((FAIL+1))
fi

log ""
log "=== Bootstrap complete: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    warn "Some checks failed. See above. Common fixes:"
    echo "      - Wait 60s and re-run this verification block (k3s may still be starting)"
    echo "      - Check /var/log/zeabur-fixes.log for the [X] step that didn't run"
    echo "      - Run 'sudo /opt/zeabur-fixes/apply-fixes.sh' manually and re-check"
    exit 1
fi
ok "All checks passed. Stalwart should be reachable at https://stalwart.cfworkers.dpdns.org"
