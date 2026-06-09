#!/bin/bash
# Wait for pod
echo "Waiting for new pod..."
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  POD=$(sudo k3s kubectl get pods -n default -l app=zeabur-kube-watch -o name 2>/dev/null | head -1 | sed 's|pod/||')
  if [ -n "$POD" ]; then
    STATUS=$(sudo k3s kubectl get pod $POD -n default -o jsonpath='{.status.containerStatuses[0].state}' 2>/dev/null)
    if echo "$STATUS" | grep -q "running\|terminated\|waiting"; then
      echo "Pod ready: $POD"
      break
    fi
  fi
  sleep 5
done

if [ -z "$POD" ]; then
  echo "No pod found"
  exit 1
fi

echo ""
echo "=== Current state ==="
sudo k3s kubectl get pod $POD -n default 2>&1

echo ""
echo "=== Current logs ==="
sudo k3s kubectl logs $POD -n default --tail=30 2>&1

echo ""
echo "=== Previous instance logs (if exists) ==="
sudo k3s kubectl logs $POD -n default --previous --tail=30 2>&1

echo ""
echo "=== Full describe ==="
sudo k3s kubectl describe pod $POD -n default 2>&1 | tail -50
