#!/usr/bin/env bash
#
# scripts/domain/02-create-ingress.sh
#
# Creates a manual Kubernetes Ingress for a Zeabur service. This is a
# workaround for SEI-545 where zeabur-kube-watch can't auto-create the
# Ingress (because NATS JetStream was disabled, see scripts/sei-545/).
#
# Usage:
#   ./02-create-ingress.sh <service-id> <env-id> <domain>
#   ./02-create-ingress.sh 6a242f96f1be9943f1f972a7 environment-6a242c9f95b39806d284aaa7 yjhkbkjb.zeabur.app
#
# The ingress controller (zeabur/ingress-controller) watches Ingress
# objects across all namespaces and provisions an HTTPS endpoint with
# Let's Encrypt cert when a new Ingress is created.

set -euo pipefail

if [ $# -lt 3 ]; then
    echo "Usage: $0 <service-id> <env-id> <domain>" >&2
    echo "Example: $0 6a242f96f1be9943f1f972a7 environment-6a242c9f95b39806d284aaa7 yjhkbkjb.zeabur.app" >&2
    exit 1
fi

SERVICE_ID="$1"
ENV_ID="$2"
DOMAIN="$3"

# Convert env-id "environment-XXX" to "XXX" for the namespace name (k8s
# namespace uses just XXX).
NAMESPACE="${ENV_ID#environment-}"

# Generate a valid k8s resource name from the domain
INGRESS_NAME="$(echo "$DOMAIN" | tr '.' '-' | tr '[:upper:]' '[:lower:]')-zeabur-app"

echo "Creating Ingress $INGRESS_NAME in namespace $NAMESPACE for $DOMAIN..."

# Write a temp yaml file and apply
tmpfile="$(mktemp --suffix=.yaml)"
cat > "$tmpfile" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $INGRESS_NAME
  namespace: $NAMESPACE
  annotations:
    ingress.kubernetes.io/force-ssl-redirect: "true"
    ingress.kubernetes.io/ssl-redirect: "true"
spec:
  rules:
  - host: $DOMAIN
    http:
      paths:
      - backend:
          service:
            name: service-$SERVICE_ID
            port:
              number: 8080
        path: /
        pathType: Prefix
EOF

echo "--- Ingress yaml ---"
cat "$tmpfile"
echo "--------------------"

sudo kubectl apply -f "$tmpfile"
rm -f "$tmpfile"

echo
echo "==> Ingress created. Verify with:"
echo "    sudo kubectl get ingress -n $NAMESPACE"
echo
echo "Watch the cert provisioning:"
echo "    sudo kubectl logs -n default -l app=ingress-controller --tail=20 -f"
echo
echo "Test HTTPS (once cert is issued):"
echo "    curl -I https://$DOMAIN/api"
