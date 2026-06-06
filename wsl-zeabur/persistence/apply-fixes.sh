#!/usr/bin/env bash
#
# /opt/zeabur-fixes/apply-fixes.sh
#
# Idempotent startup script that re-applies the Zeabur-on-WSL2 fixes after
# WSL/k3s restarts. Run automatically via:
#   1. /etc/rc.local on WSL boot (pre-k3s phase)
#   2. k3s.service.d/override.conf ExecStartPost (post-k3s phase)
#
# Fixes applied:
#   A. Pod resolv.conf (k3s --resolv-conf points to /etc/k3s-pod-resolv.conf)
#   B. CoreDNS forward to public DNS (k3s-managed coredns.yaml manifest)
#   C. CoreDNS rewrite block for nats.zeabur.com
#   D. NATS JetStream config (ConfigMap + StatefulSet + PVC)
#   E. zeabur-kube-watch namespace label (so events flow into KUBEWATCH stream)
#
# All operations are idempotent: safe to run multiple times.
#
# Logs to /var/log/zeabur-fixes.log
#
set -euo pipefail

LOGFILE="/var/log/zeabur-fixes.log"
KUBECTL="${KUBECTL:-/usr/local/bin/kubectl}"
CORDNS_MANIFEST="/var/lib/rancher/k3s/server/manifests/coredns.yaml"
NATS_CM="nats-config"
NATS_STS="nats"
NATS_NAMESPACE="default"
POD_RESOLV="/etc/k3s-pod-resolv.conf"
WANTED_FORWARD="forward . 8.8.8.8 1.0.0.1 8.8.4.4"
WANTED_REWRITE_BLOCK='nats.zeabur.com:53 {
        errors
        cache 30
        rewrite name exact nats.zeabur.com nats.default.svc.cluster.local
        kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
        }
    }'

mkdir -p "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1

log() { echo "[$(date -Iseconds)] $*"; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "FATAL: must run as root" >&2
        exit 1
    fi
}

wait_for_k3s() {
    # K3s may not be up yet if we're called from rc.local. Wait up to 90s.
    for i in $(seq 1 90); do
        if "$KUBECTL" get nodes >/dev/null 2>&1; then
            log "k3s API is up"
            return 0
        fi
        sleep 1
    done
    log "WARN: k3s API did not come up in 90s; skipping cluster fixes"
    return 1
}

fix_pod_resolv_conf() {
    log "[A] Pod resolv.conf"
    if [ ! -f "$POD_RESOLV" ]; then
        cat > "$POD_RESOLV" <<EOF
# /etc/k3s-pod-resolv.conf
# Used by k3s via --resolv-conf flag.
# Cluster DNS first, public resolvers as fallback.
nameserver 10.43.0.10
nameserver 8.8.8.8
nameserver 1.1.1.1
options edns0 trust-ad
search default.svc.cluster.local svc.cluster.local cluster.local
EOF
        log "  created $POD_RESOLV"
    else
        log "  $POD_RESOLV already present"
    fi
    # Immutable to prevent WSL from overwriting on next wsl.conf change
    chattr +i "$POD_RESOLV" 2>/dev/null || true
}

fix_coredns_forward() {
    log "[B] CoreDNS forward to public DNS"
    if [ ! -f "$CORDNS_MANIFEST" ]; then
        log "  SKIP: $CORDNS_MANIFEST not found (k3s not installed?)"
        return 0
    fi
    # Wait for the manifest file to stop being rewritten by the k3s addon
    # manager (which writes the bundled template at startup, racing with us).
    # We watch the mtime: if it has been stable for 5s, the manager is done.
    local prev_mtime=""
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        local cur_mtime
        cur_mtime="$(stat -c %Y "$CORDNS_MANIFEST" 2>/dev/null || echo 0)"
        if [ "$cur_mtime" = "$prev_mtime" ] && [ "$cur_mtime" != "0" ]; then
            log "  manifest stable for 5s, applying patch"
            break
        fi
        prev_mtime="$cur_mtime"
        sleep 1
    done
    local changed=0
    if grep -qF "$WANTED_FORWARD" "$CORDNS_MANIFEST"; then
        log "  forward directive already correct"
    else
        sed -i "s|forward . /etc/resolv.conf|$WANTED_FORWARD|" "$CORDNS_MANIFEST"
        log "  patched forward directive in $CORDNS_MANIFEST"
        changed=1
    fi
    # Check if the rewrite block uses the OLD (forward . 8.8.8.8) or the
    # NEW (kubernetes cluster.local) approach. If old, replace.
    if grep -qF "nats.zeabur.com:53 {" "$CORDNS_MANIFEST" && \
       grep -qF "rewrite name exact nats.zeabur.com nats.default.svc.cluster.local" "$CORDNS_MANIFEST"; then
        log "  nats.zeabur.com rewrite block already up-to-date"
    else
        # Remove any existing rewrite block first
        if grep -qF "nats.zeabur.com:53 {" "$CORDNS_MANIFEST"; then
            # Use awk to delete from the `nats.zeabur.com:53 {` line to the
            # matching `}` line.
            local tmpfile
            tmpfile="$(mktemp)"
            awk '
                /^    nats\.zeabur\.com:53 \{/ { skip = 1; depth = 0 }
                skip {
                    for (i = 1; i <= length($0); i++) {
                        c = substr($0, i, 1)
                        if (c == "{") depth++
                        if (c == "}") { depth--; if (depth == 0) { skip = 0; next } }
                    }
                    next
                }
                { print }
            ' "$CORDNS_MANIFEST" > "$tmpfile"
            mv "$tmpfile" "$CORDNS_MANIFEST"
            log "  removed old rewrite block"
        fi
        # Insert the new rewrite block immediately after the line containing
        # `import /etc/coredns/custom/*.server`. Use awk for multi-line insert.
        local tmpfile
        tmpfile="$(mktemp)"
        awk -v block="$WANTED_REWRITE_BLOCK" '
            /import \/etc\/coredns\/custom\/\*\.server/ {
                print
                print "    " block
                next
            }
            { print }
        ' "$CORDNS_MANIFEST" > "$tmpfile"
        mv "$tmpfile" "$CORDNS_MANIFEST"
        log "  added nats.zeabur.com rewrite block"
        changed=1
    fi
    if [ "$changed" = "1" ]; then
        # Force the k3s addon manager to re-apply by touching the file.
        touch "$CORDNS_MANIFEST"
        log "  touched manifest; addon manager will redeploy"
        # Give the addon manager time to apply, then verify the live config
        sleep 15
        local live_forward
        live_forward="$("$KUBECTL" -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' 2>/dev/null | grep -oE 'forward \. [^[:space:]]+' | head -1 || true)"
        log "  live Corefile forward: ${live_forward:-<unknown>}"
    fi
}

fix_nats_jetstream() {
    log "[D] NATS JetStream"
    if ! "$KUBECTL" -n "$NATS_NAMESPACE" get cm "$NATS_CM" >/dev/null 2>&1; then
        log "  SKIP: $NATS_CM ConfigMap not found"
        return 0
    fi
    # Detect which key holds the NATS config (Zeabur uses 'nats.conf')
    local cm_json cm_key
    cm_json="$("$KUBECTL" -n "$NATS_NAMESPACE" get cm "$NATS_CM" -o json 2>/dev/null || true)"
    if [ -z "$cm_json" ]; then
        log "  SKIP: $NATS_CM ConfigMap not readable"
        return 0
    fi
    for k in nats.conf config.conf; do
        if echo "$cm_json" | jq -e ".data.\"$k\"" >/dev/null 2>&1; then
            cm_key="$k"
            break
        fi
    done
    if [ -z "$cm_key" ]; then
        log "  SKIP: no nats.conf or config.conf key in $NATS_CM"
        return 0
    fi
    local cm_data
    cm_data="$(echo "$cm_json" | jq -r ".data.\"$cm_key\"")"
    if echo "$cm_data" | grep -q "store_dir"; then
        log "  JetStream already enabled in $NATS_CM/$cm_key"
    else
        # Append jetstream { } block to the existing config
        local patched
        patched="$cm_data

jetstream {
  store_dir: \"/data/jetstream\"
  max_memory_store: 256MB
  max_file_store: 1GB
}"
        "$KUBECTL" -n "$NATS_NAMESPACE" patch cm "$NATS_CM" --type merge \
            -p "{\"data\":{\"$cm_key\":$(echo "$patched" | jq -Rs .)}}" >/dev/null
        log "  enabled JetStream in $NATS_CM/$cm_key"
    fi
    # StatefulSet volume mount for /data
    local sts
    sts="$("$KUBECTL" -n "$NATS_NAMESPACE" get sts "$NATS_STS" -o json 2>/dev/null || true)"
    if [ -z "$sts" ]; then
        log "  SKIP: $NATS_STS StatefulSet not found"
    elif echo "$sts" | grep -q '"name": "nats-data"'; then
        log "  volume mount nats-data already present"
    else
        "$KUBECTL" -n "$NATS_NAMESPACE" patch sts "$NATS_STS" --type json \
            -p "$(cat <<'EOF'
[
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"nats-data","mountPath":"/data"}},
  {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"nats-data","persistentVolumeClaim":{"claimName":"nats-data-nats-0"}}}
]
EOF
)" >/dev/null
        log "  added nats-data volume mount to $NATS_STS"
    fi
    # PVC if missing
    if ! "$KUBECTL" -n "$NATS_NAMESPACE" get pvc nats-data-nats-0 >/dev/null 2>&1; then
        "$KUBECTL" -n "$NATS_NAMESPACE" apply -f - <<'EOF' >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nats-data-nats-0
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: local-path
EOF
        log "  created PVC nats-data-nats-0"
    fi
}

ensure_jetstream_stream() {
    log "[E] JetStream stream KUBEWATCH"
    if ! "$KUBECTL" -n "$NATS_NAMESPACE" get pod nats-0 >/dev/null 2>&1; then
        log "  SKIP: nats-0 pod not found"
        return 0
    fi
    if ! command -v nats >/dev/null 2>&1; then
        log "  SKIP: nats CLI not installed (run persistence/install-nats-cli.sh)"
        return 0
    fi
    # Try the cluster service IP first (fastest path), then port-forward
    # fallback. Pick whichever is reachable.
    local NATS_URL
    if nats stream ls -s nats://10.43.10.121:4222 >/dev/null 2>&1; then
        NATS_URL="nats://10.43.10.121:4222"
    else
        # Port-forward
        "$KUBECTL" -n "$NATS_NAMESPACE" port-forward nats-0 30222:4222 >/dev/null 2>&1 &
        local pf_pid=$!
        sleep 3
        if nats stream ls -s nats://127.0.0.1:30222 >/dev/null 2>&1; then
            NATS_URL="nats://127.0.0.1:30222"
        else
            kill "$pf_pid" 2>/dev/null || true
            log "  SKIP: could not reach NATS"
            return 0
        fi
    fi
    # Check stream existence
    if nats stream ls -s "$NATS_URL" 2>/dev/null | grep -q KUBEWATCH; then
        log "  KUBEWATCH stream already exists"
    else
        nats stream add KUBEWATCH \
            --subjects="events.>,kube.>,pods.>,events" \
            --retention=limits --storage=file --replicas=1 \
            --max-msgs=-1 --max-bytes=-1 --max-age=-1 \
            --server="$NATS_URL" >/dev/null
        log "  created KUBEWATCH stream"
    fi
    if nats consumer ls KUBEWATCH -s "$NATS_URL" 2>/dev/null | grep -q zeabur-control-plane; then
        log "  zeabur-control-plane consumer already exists"
    else
        nats consumer add KUBEWATCH zeabur-control-plane \
            --durable --filter="events.>" --ack=explicit \
            --server="$NATS_URL" >/dev/null
        log "  created zeabur-control-plane consumer"
    fi
}

restart_deployments_for_resolv_conf() {
    # Pods that started before the new resolv.conf was in place need a
    # restart to pick up the new DNS servers. Restart the most affected
    # workloads only.
    log "[F] Restarting workloads to pick up new resolv.conf"
    local workloads=(
        "deployment/ingress-controller"
        "deployment/zeabur-kube-watch"
        "deployment/zeabur-log-api"
        "deployment/zeabur-dns"
    )
    for w in "${workloads[@]}"; do
        if "$KUBECTL" -n "$NATS_NAMESPACE" get "$w" >/dev/null 2>&1; then
            "$KUBECTL" -n "$NATS_NAMESPACE" rollout restart "$w" >/dev/null
            log "  restarted $w"
        fi
    done
    # StatefulSet
    if "$KUBECTL" -n "$NATS_NAMESPACE" get sts nats >/dev/null 2>&1; then
        local replicas
        replicas="$("$KUBECTL" -n "$NATS_NAMESPACE" get sts nats -o jsonpath='{.spec.replicas}')"
        # Only restart if not already restarting
        if [ "$replicas" = "1" ]; then
            "$KUBECTL" -n "$NATS_NAMESPACE" delete pod nats-0 --grace-period=30 >/dev/null 2>&1 || true
            log "  restarted sts/nats (via pod delete)"
        fi
    fi
}

main() {
    require_root
    log "==== apply-fixes.sh start ===="
    fix_pod_resolv_conf
    if wait_for_k3s; then
        fix_coredns_forward
        fix_nats_jetstream
        ensure_jetstream_stream
        restart_deployments_for_resolv_conf
    fi
    log "==== apply-fixes.sh done ===="
}

main "$@"
