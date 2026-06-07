#!/bin/bash
# list-exposed.sh - List all publicly exposed services via Cloudflare Tunnel
# Usage: list-exposed.sh

set -e

KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG="$KUBECONFIG_PATH"

echo "=== Public exposures (cfworkers.dpdns.org) ==="
echo ""
kubectl get ing --all-namespaces -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
found = False
for item in data.get('items', []):
    name = item['metadata']['name']
    ns = item['metadata']['namespace']
    rules = item.get('spec', {}).get('rules', [])
    for rule in rules:
        host = rule.get('host', '')
        if host.endswith('.cfworkers.dpdns.org'):
            paths = rule.get('http', {}).get('paths', [])
            for p in paths:
                backend = p.get('backend', {}).get('service', {})
                svc = backend.get('name', '?')
                port = backend.get('port', {}).get('number', '?')
                print(f'  https://{host:50s} -> {ns}/{svc}:{port}')
            found = True
if not found:
    print('  No services exposed yet.')
    print('  Use: expose-service.sh <subdomain> <namespace> <service-name> <port>')
" 2>&1

echo ""
echo "=== DNS configuration ==="
echo "  Wildcard CNAME: *.cfworkers.dpdns.org -> Cloudflare tunnel (d1534e02-b697-4e99-bb0d-cf04c79199a9)"
echo "  Auto-routes ANY subdomain to the WSL ingress-controller"
echo ""
echo "=== Tunnel status ==="
if pgrep -f "cloudflared.*tunnel" > /dev/null; then
  echo "  cloudflared: RUNNING (PID $(pgrep -f 'cloudflared.*tunnel'))"
else
  echo "  cloudflared: NOT RUNNING"
  echo "  Start with: nohup /usr/local/bin/cloudflared --config /etc/cloudflared/config.yml tunnel run &"
fi
