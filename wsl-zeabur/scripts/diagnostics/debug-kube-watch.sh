#!/bin/bash
POD=$(sudo k3s kubectl get pods -n default -l name=zeabur-kube-watch -o name 2>/dev/null | head -1 | sed 's|pod/||')
echo "Pod: $POD"
if [ -n "$POD" ]; then
  echo ""
  echo "=== Previous logs (most recent crash) ==="
  sudo k3s kubectl logs $POD -n default --previous 2>&1 | tail -30
  echo ""
  echo "=== Current container state ==="
  sudo k3s kubectl get pod $POD -n default -o jsonpath='{.status.containerStatuses[0]}' 2>&1
  echo ""
fi
echo ""
echo "=== Check NATS auth status ==="
sudo k3s kubectl get cm -n default nats-config 2>&1
sudo k3s kubectl get cm -n default nats -o yaml 2>&1 | head -30
echo ""
echo "=== NATS pod logs ==="
sudo k3s kubectl logs nats-0 -n default -c nats --tail=20 2>&1
