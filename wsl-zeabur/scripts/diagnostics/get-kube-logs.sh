echo "=== Get kube-watch pod name and logs ==="
POD=$(sudo k3s kubectl get pods -n default -l app=zeabur-kube-watch -o jsonpath='{.items[0].metadata.name}' 2>&1)
echo "Pod: $POD"
echo ""
echo "=== Previous logs ==="
sudo k3s kubectl logs -n default $POD --previous --tail=30 2>&1
echo ""
echo "=== Current logs ==="
sudo k3s kubectl logs -n default $POD --tail=30 2>&1
echo ""
echo "=== Describe pod for events ==="
sudo k3s kubectl describe pod $POD -n default 2>&1 | tail -40
echo ""
echo "=== Check NATS pod logs ==="
sudo k3s kubectl logs -n default nats-0 -c nats --tail=30 2>&1
echo ""
echo "=== Check what port kube-watch is trying ==="
sudo k3s kubectl get pod $POD -n default -o yaml 2>&1 | head -80
