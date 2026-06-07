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
#   E. KUBEWATCH stream + zeabur-control-plane consumer (filter '>' to match
#      kube.events.server-*.pods.* subjects)
#   F. Public Ingress for stalwart (stalwart.cfworkers.dpdns.org via Cloudflare
#      Tunnel ingress-controller, NOT the broken zeabur.app domains)
#   G. Restart workloads to pick up new resolv.conf
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
# Marker file used to track whether the resolv.conf was newly created in
# this run. We only restart workloads on the *first* run after the file is
# created; subsequent runs (when the file already exists) leave running pods
# alone so we don't disrupt the ingress-controller / cloudflared tunnel.
RESOLV_CREATED_MARKER="/var/run/zeabur-fixes-resolv-created"
# Lock directory: when k3s restarts twice in a row (which happens often on
# WSL2 with Modern Standby), systemd fires TWO ExecStartPost hooks back-to-back
# and we get two apply-fixes.sh processes racing. The losing process used to
# see the marker from the winner and trigger a second ingress-controller
# restart. mkdir(1) is atomic on POSIX, so we use it as a file lock.
LOCK_DIR="/var/run/zeabur-fixes.lock"
# Public exposures: <subdomain>|<namespace>|<service-name>|<port>|<suffix>
#   host     = <subdomain>.<BASE_DOMAIN>
#   ingress  = <subdomain>-<suffix>
# One line per service. Idempotent reapply on k3s restart.
PUBLIC_BASE_DOMAIN="cfworkers.dpdns.org"
PUBLIC_EXPOSURES=(
    "stalwart|environment-6a242c9f95b39806d284aaa7|service-6a242f96f1be9943f1f972a7|8080|cfworkers"
)
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
        # Mark that the file was just created so the restart phase knows
        # this is the first run (the only time a restart is actually
        # needed to pick up the new DNS servers).
        mkdir -p "$(dirname "$RESOLV_CREATED_MARKER")"
        : > "$RESOLV_CREATED_MARKER"
    else
        log "  $POD_RESOLV already present"
        # File already existed: the resolv.conf is stable and immutable,
        # so we MUST NOT restart any workloads (that would break the
        # ingress-controller / cloudflared tunnel for ~30s every k3s
        # start). See the [G] step.
        rm -f "$RESOLV_CREATED_MARKER"
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
    # Consumer: filter MUST be '>' (matches kube.events.server-*.pods.* which
    # is the actual subject Zeabur backend publishes to). The legacy filter
    # `events.>` was wrong and never matched, so events were silently dropped.
    if nats consumer ls KUBEWATCH -s "$NATS_URL" 2>/dev/null | grep -q zeabur-control-plane; then
        # Check current filter; recreate if wrong
        local current_filter
        current_filter="$(nats consumer info KUBEWATCH zeabur-control-plane -s "$NATS_URL" 2>/dev/null | awk -F': ' '/Filter Subject/{print $2}' | tr -d ' ' || true)"
        if [ "$current_filter" = ">" ]; then
            log "  zeabur-control-plane consumer already exists with correct filter '>'"
        else
            log "  WARNING: consumer exists with wrong filter '$current_filter', recreating with '>'"
            nats consumer del KUBEWATCH zeabur-control-plane -f -s "$NATS_URL" >/dev/null 2>&1 || true
            nats consumer add KUBEWATCH zeabur-control-plane \
                --filter=">" --ack=explicit --pull \
                --deliver=all --replay=instant --defaults \
                --server="$NATS_URL" >/dev/null
            log "  recreated zeabur-control-plane consumer with filter '>'"
        fi
    else
        nats consumer add KUBEWATCH zeabur-control-plane \
            --filter=">" --ack=explicit --pull \
            --deliver=all --replay=instant --defaults \
            --server="$NATS_URL" >/dev/null
        log "  created zeabur-control-plane consumer with filter '>'"
    fi
}

ensure_public_ingresses() {
    # Re-create Ingresses for any service in PUBLIC_EXPOSURES array that
    # doesn't already exist. This is what makes stalwart.cfworkers.dpdns.org
    # survive k3s restarts.
    #
    # The ingress-controller creates Ingresses for *.zeabur.app domains
    # automatically, but those are NOT publicly routable (DNS points to
    # Tailscale IP 100.64.3.1). Public exposure requires us to manually
    # create an Ingress with a *.cfworkers.dpdns.org hostname, which
    # matches the Cloudflare Tunnel wildcard CNAME.
    log "[F] Public Ingresses (Cloudflare Tunnel)"
    if ! "$KUBECTL" get ns default >/dev/null 2>&1; then
        log "  SKIP: k3s not ready"
        return 0
    fi
    for entry in "${PUBLIC_EXPOSURES[@]}"; do
        IFS='|' read -r sub ns svc port suffix <<<"$entry"
        local host="${sub}.${PUBLIC_BASE_DOMAIN}"
        local ing_name="${sub}-${suffix}"
        # Validate namespace exists (depends on environment being deployed)
        if ! "$KUBECTL" get ns "$ns" >/dev/null 2>&1; then
            log "  SKIP: namespace $ns not found (environment not yet deployed?)"
            continue
        fi
        # Validate service exists
        if ! "$KUBECTL" -n "$ns" get svc "$svc" >/dev/null 2>&1; then
            log "  SKIP: service $ns/$svc not found"
            continue
        fi
        if "$KUBECTL" -n "$ns" get ing "$ing_name" >/dev/null 2>&1; then
            log "  Ingress $ns/$ing_name already present (host=$host)"
            continue
        fi
        # Create the Ingress
        cat <<EOF | "$KUBECTL" -n "$ns" apply -f - >/dev/null
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${ing_name}
  namespace: ${ns}
  annotations:
    ingress.kubernetes.io/ssl-redirect: "true"
spec:
  rules:
  - host: ${host}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${svc}
            port:
              number: ${port}
EOF
        log "  created Ingress $ns/$ing_name for $host"
    done
}

restart_deployments_for_resolv_conf() {
    # Pods that started before the new resolv.conf was in place need a
    # restart to pick up the new DNS servers.
    #
    # IMPORTANT: This is only needed on the FIRST run after /etc/k3s-pod-resolv.conf
    # is created. On subsequent k3s starts, the file is already there and is
    # immutable, so pods that are already running with the correct resolv.conf
    # MUST NOT be restarted - doing so disrupts the ingress-controller and
    # breaks the Cloudflare tunnel for ~30s (HTTP 530/502 from public URL).
    #
    # We gate this on the presence of the marker file written by
    # fix_pod_resolv_conf(). If the marker is absent, the resolv.conf was
    # already in place when this run started, so the workloads are already
    # up-to-date and we skip the restart.
    if [ ! -f "$RESOLV_CREATED_MARKER" ]; then
        log "[G] SKIP: resolv.conf was already in place at start; no restart needed"
        return 0
    fi
    log "[G] Restarting workloads to pick up new resolv.conf (first run after resolv.conf created)"
    local workloads=(
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
    # ingress-controller is a DaemonSet (rolling restart not natively supported;
    # delete the pod so the DaemonSet controller re-creates it with the new
    # resolv.conf baked in).
    if "$KUBECTL" -n "$NATS_NAMESPACE" get ds ingress-controller >/dev/null 2>&1; then
        "$KUBECTL" -n "$NATS_NAMESPACE" delete pod -l app.kubernetes.io/name=ingress-controller --grace-period=30 >/dev/null 2>&1 || true
        log "  restarted ds/ingress-controller (via pod delete)"
    fi
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
    # Acquire exclusive lock: if another apply-fixes.sh is already running
    # (e.g. systemd fired two ExecStartPost hooks back-to-back because k3s
    # restarted twice in a row), exit immediately. The first process owns
    # the entire fix pass; the second is a no-op.
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log "==== apply-fixes.sh SKIP: another instance holds the lock ===="
        exit 0
    fi
    # Make sure the lock is released no matter how we exit.
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM
    log "==== apply-fixes.sh start ===="
    fix_pod_resolv_conf
    if wait_for_k3s; then
        fix_coredns_forward
        fix_nats_jetstream
        ensure_jetstream_stream
        ensure_public_ingresses
        restart_deployments_for_resolv_conf
    fi
    log "==== apply-fixes.sh done ===="
}

main "$@"
