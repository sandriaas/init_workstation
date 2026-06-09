#!/usr/bin/env bash
#
# scripts/stalwart/01-get-credentials.sh
#
# Extracts the Stalwart mail server credentials from the running pod.
# The admin password is printed to the container stdout on first start.
#
# Usage:
#   sudo ./01-get-credentials.sh <service-pod-name> [namespace]
#   sudo ./01-get-credentials.sh service-6a242f96f1be9943f1f972a7-84d48c4859-dfjvc environment-6a242c9f95b39806d284aaa7
#
# Outputs:
#   - admin username (always 'admin')
#   - admin password (from container logs)
#   - HTTP API base URL (https://<domain>/api or http://pod-ip:8080/api)

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <service-pod-name> [namespace]" >&2
    exit 1
fi

POD="$1"
NAMESPACE="${2:-default}"

# Discover the pod's domain (if any) by looking for an Ingress
echo "==> Stalwart credentials for pod $POD"
echo
echo "--- 1. Service / pod info ---"
sudo kubectl -n "$NAMESPACE" get pod "$POD" -o wide
echo
echo "--- 2. Admin password (from container logs) ---"
password="$(sudo kubectl -n "$NAMESPACE" logs "$POD" 2>&1 | grep -oE "password '[A-Za-z0-9]+'" | head -1 | sed -E "s/^password '([^']+)'$/\\1/")"
if [ -n "$password" ]; then
    echo "  admin user: admin"
    echo "  admin pass: $password"
    echo
    echo "  HTTP Basic auth (base64): $(printf 'admin:%s' "$password" | base64 -w0)"
else
    echo "  (no password found in logs)"
fi
echo
echo "--- 3. Available API paths ---"
echo "  /api/auth                     - authentication (rate-limited, anonymous OK)"
echo "  /api/account                  - list accounts (requires auth)"
echo "  /api/principal                - principals CRUD (requires auth)"
echo "  /api/settings/keys            - list settings (requires auth)"
echo "  /api/settings/group           - list settings by group (requires auth)"
echo "  /api/settings/list            - list settings (requires auth)"
echo "  /api/update/webadmin          - trigger webadmin download (requires auth)"
echo "  /api/store/reindex            - FTS reindex (requires auth)"
echo
echo "  Note: Stalwart v0.11.8 does NOT include a WebAdmin UI by default."
echo "  To install the WebAdmin, trigger a download via:"
echo "    curl -u admin:\$PASS https://DOMAIN/api/update/webadmin"
echo
echo "--- 4. Test from the cluster ---"
echo "  sudo kubectl -n $NAMESPACE exec $POD -- stalwart-cli \\"
echo "    -u http://localhost:8080 -c admin:\$PASS database purge"
