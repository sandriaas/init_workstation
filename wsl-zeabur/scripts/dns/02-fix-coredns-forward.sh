#!/usr/bin/env bash
#
# scripts/dns/02-fix-coredns-forward.sh
#
# Patches the k3s-managed CoreDNS manifest to:
#   1. Forward all queries to public DNS (8.8.8.8 1.0.0.1 8.8.4.4)
#      instead of /etc/resolv.conf (which loops to itself on WSL).
#   2. Add a rewrite block for nats.zeabur.com to nats.default.svc.cluster.local
#      so that zeabur-kube-watch can connect to the in-cluster NATS.
#
# The k3s addon manager writes the bundled manifest on startup, which
# overwrites any manual edits. This script should be called from a
# post-k3s-startup hook (e.g., /opt/zeabur-fixes/apply-fixes.sh which is
# invoked from k3s.service.d/override.conf ExecStartPost).
#
# For the race-free version, see /opt/zeabur-fixes/apply-fixes.sh which
# waits for the manifest to stabilize before editing.
#
# Usage:
#   sudo ./02-fix-coredns-forward.sh

set -euo pipefail

CORDNS_MANIFEST="/var/lib/rancher/k3s/server/manifests/coredns.yaml"
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

if [ ! -f "$CORDNS_MANIFEST" ]; then
    echo "ERROR: $CORDNS_MANIFEST not found" >&2
    exit 1
fi

# Wait for the manifest to stop being rewritten by the k3s addon manager
echo "Waiting for manifest to stabilize..."
prev_mtime=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    cur_mtime="$(stat -c %Y "$CORDNS_MANIFEST" 2>/dev/null || echo 0)"
    if [ "$cur_mtime" = "$prev_mtime" ] && [ "$cur_mtime" != "0" ]; then
        echo "  stable for 5s"
        break
    fi
    prev_mtime="$cur_mtime"
    sleep 1
done

# Patch forward directive
if grep -qF "$WANTED_FORWARD" "$CORDNS_MANIFEST"; then
    echo "forward directive already correct"
else
    sed -i "s|forward . /etc/resolv.conf|$WANTED_FORWARD|" "$CORDNS_MANIFEST"
    echo "patched forward directive"
fi

# Patch or insert nats.zeabur.com rewrite block
if grep -qF "nats.zeabur.com:53 {" "$CORDNS_MANIFEST" && \
   grep -qF "rewrite name exact nats.zeabur.com nats.default.svc.cluster.local" "$CORDNS_MANIFEST"; then
    echo "nats.zeabur.com rewrite block already up-to-date"
else
    # Remove old block if present
    if grep -qF "nats.zeabur.com:53 {" "$CORDNS_MANIFEST"; then
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
        echo "removed old rewrite block"
    fi
    # Insert new block
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
    echo "added nats.zeabur.com rewrite block"
fi

# Force the k3s addon manager to re-apply
touch "$CORDNS_MANIFEST"
echo "touched manifest; addon manager will redeploy within ~5s"

# Wait and verify
sleep 15
live_forward="$(sudo kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' 2>/dev/null | grep -oE 'forward \. [^[:space:]]+' | head -1 || true)"
echo "live Corefile forward: ${live_forward:-<unknown>}"

if sudo kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep -q "rewrite name exact nats.zeabur.com"; then
    echo "live Corefile has nats.zeabur.com rewrite: YES"
else
    echo "live Corefile has nats.zeabur.com rewrite: NO (addon manager may not have applied yet)"
fi
