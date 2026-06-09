#!/bin/bash
# expose-service.sh - Expose a Kubernetes service to the public internet via Cloudflare Tunnel
#
# Usage: expose-service.sh <subdomain> <namespace> <k8s-service-name> <port>
# Example: expose-service.sh mail environment-6a242c9f95b39806d284aaa7 service-6a242f96f1be9943f1f972a7 8080
#
# What it does (fully automatic, no code edits):
#   1. Writes an exposure file to /opt/zeabur-fixes/exposures.d/<subdomain>.conf
#      so the exposure is PERSISTENT - apply-fixes.sh re-creates the Ingress on
#      every k3s restart, exactly like stalwart.
#   2. Creates the Ingress immediately so the URL works right away.
#
# DNS is already handled by the wildcard CNAME *.cfworkers.dpdns.org -> tunnel,
# and cloudflared routes *.cfworkers.dpdns.org to the ingress-controller, so a
# brand-new subdomain needs NO DNS or tunnel changes.

set -e

if [ $# -ne 4 ]; then
  echo "Usage: expose-service.sh <subdomain> <namespace> <k8s-service-name> <port>"
  echo ""
  echo "Examples:"
  echo "  expose-service.sh stalwart environment-6a242c9f95b39806d284aaa7 service-6a242f96f1be9943f1f972a7 8080"
  echo "    => https://stalwart.cfworkers.dpdns.org"
  echo ""
  echo "DNS is auto-handled by wildcard CNAME: *.cfworkers.dpdns.org -> Cloudflare tunnel"
  echo "Exposure is auto-persisted to /opt/zeabur-fixes/exposures.d/<subdomain>.conf"
  exit 1
fi

SUBDOMAIN="$1"
NAMESPACE="$2"
SERVICE_NAME="$3"
PORT="$4"
BASE_DOMAIN="${BASE_DOMAIN:-cfworkers.dpdns.org}"
SUFFIX="${EXPOSURE_SUFFIX:-cfworkers}"
HOST="${SUBDOMAIN}.${BASE_DOMAIN}"
INGRESS_NAME="${SUBDOMAIN//./-}-${SUFFIX}"
KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG="$KUBECONFIG_PATH"
EXPOSURES_DIR="${EXPOSURES_DIR:-/opt/zeabur-fixes/exposures.d}"
EXPOSURE_FILE="${EXPOSURES_DIR}/${SUBDOMAIN}.conf"

echo "=== Persisting exposure (survives k3s restarts) ==="
mkdir -p "$EXPOSURES_DIR"
cat > "$EXPOSURE_FILE" <<EOF
# Public exposure for ${HOST}
# Written by expose-service.sh on $(date -Is)
# apply-fixes.sh reads this on every k3s restart and re-creates the Ingress.
sub=${SUBDOMAIN}
ns=${NAMESPACE}
svc=${SERVICE_NAME}
port=${PORT}
EOF
echo "  wrote $EXPOSURE_FILE"
echo ""

echo "=== Creating Ingress for ${HOST} ==="
echo "Namespace: $NAMESPACE"
echo "Service:   $SERVICE_NAME:$PORT"
echo ""

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${INGRESS_NAME}
  namespace: ${NAMESPACE}
  annotations:
    ingress.kubernetes.io/ssl-redirect: "true"
spec:
  rules:
  - host: ${HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${SERVICE_NAME}
            port:
              number: ${PORT}
EOF

echo ""
echo "=== Verifying Ingress ==="
kubectl -n "$NAMESPACE" get ing "$INGRESS_NAME" 2>&1
echo ""
echo "=== Public URL ==="
echo "  https://${HOST}"
echo ""
echo "=== Test ==="
sleep 2
HTTP_STATUS=$(curl -k -s -o /dev/null -w "%{http_code}" -m 15 -H "Host: ${HOST}" https://172.29.155.146 2>/dev/null || echo "000")
echo "Local HTTPS test: HTTP $HTTP_STATUS"
echo ""
echo "Public access should work in ~10 seconds. Test with:"
echo "  curl -I https://${HOST}/"
