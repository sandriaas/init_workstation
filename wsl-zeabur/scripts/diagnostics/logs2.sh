#!/bin/bash
POD=$(sudo k3s kubectl get pods -n default -l app=zeabur-kube-watch -o name 2>/dev/null | head -1 | sed 's|pod/||')
echo "Pod: $POD"
if [ -n "$POD" ]; then
  echo ""
  echo "=== Previous logs ==="
  sudo k3s kubectl logs -n default $POD --previous 2>&1 | tail -20
  echo ""
  echo "=== Current logs ==="
  sudo k3s kubectl logs -n default $POD 2>&1 | tail -20
fi
echo ""
echo "=== NATS logs ==="
sudo k3s kubectl logs -n default nats-0 -c nats --tail=10 2>&1
echo ""
echo "=== Zeabur system pods (all) ==="
sudo k3s kubectl get pods -n default 2>&1 | head -20
