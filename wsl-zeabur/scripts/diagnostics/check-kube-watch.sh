echo "=== Check zeabur-kube-watch current state ==="
sudo k3s kubectl get pods -A 2>&1 | grep -E "kube-watch|zeabur" | head -10
echo ""
echo "=== Describe zeabur-kube-watch for full error ==="
sudo k3s kubectl describe pod -l app=zeabur-kube-watch -n default 2>&1 | tail -30
echo ""
echo "=== Recent events ==="
sudo k3s kubectl get events -A --sort-by='.lastTimestamp' 2>&1 | tail -10
echo ""
echo "=== Check NATS errors in logs ==="
sudo k3s kubectl logs -n default -l app=zeabur-kube-watch --tail=20 2>&1 | tail -20
echo ""
echo "=== Is Tailscale still stable? ==="
tailscale status 2>&1 | head -3
