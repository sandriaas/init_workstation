#!/bin/bash
# unexpose-service.sh - Remove a public exposure of a Kubernetes service
# Usage: unexpose-service.sh <subdomain>
# Example: unexpose-service.sh stalwart
#          => removes Ingress stalwart-cfworkers in any namespace

set -e

if [ $# -ne 1 ]; then
  echo "Usage: unexpose-service.sh <subdomain>"
  echo "Example: unexpose-service.sh stalwart"
  echo "  => removes Ingress stalwart-cfworkers (host: stalwart.cfworkers.dpdns.org)"
  exit 1
fi

SUBDOMAIN="$1"
INGRESS_NAME="${SUBDOMAIN//./-}-cfworkers"
HOST="${SUBDOMAIN}.cfworkers.dpdns.org"
KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG="$KUBECONFIG_PATH"

echo "=== Searching for Ingress: ${INGRESS_NAME} ==="
INGRESS_INFO=$(kubectl get ing --all-namespaces -l "kubernetes.io/ingress.class!=null" -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    name = item['metadata']['name']
    ns = item['metadata']['namespace']
    rules = item.get('spec', {}).get('rules', [])
    for rule in rules:
        if rule.get('host') == '${HOST}':
            print(f'{ns} {name}')
            sys.exit(0)
print('NOTFOUND')
" 2>/dev/null)

if [ "$INGRESS_INFO" = "NOTFOUND" ] || [ -z "$INGRESS_INFO" ]; then
  echo "No Ingress found for ${HOST}"
  # Fallback: try to find by exact name
  FOUND_NS=$(kubectl get ing --all-namespaces -o name 2>/dev/null | grep "/${INGRESS_NAME}$" | head -1 | cut -d/ -f1 || echo "")
  if [ -n "$FOUND_NS" ]; then
    echo "Found by name in namespace: $FOUND_NS"
    kubectl delete ing "$INGRESS_NAME" -n "$FOUND_NS" 2>&1
    echo ""
    echo "=== Done. ${HOST} is no longer exposed. ==="
  else
    echo "Nothing to delete."
  fi
else
  NS=$(echo "$INGRESS_INFO" | awk '{print $1}')
  NAME=$(echo "$INGRESS_INFO" | awk '{print $2}')
  echo "Found: $NS/$NAME"
  kubectl delete ing "$NAME" -n "$NS" 2>&1
  echo ""
  echo "=== Done. ${HOST} is no longer exposed. ==="
fi

echo ""
echo "Note: The wildcard DNS CNAME (*.cfworkers.dpdns.org) is still active."
echo "Re-run 'expose-service.sh' to expose a new service under this subdomain."
