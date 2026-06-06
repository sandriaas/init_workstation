echo "=== Wait 30s for pod to settle ==="
sleep 30
echo ""
echo "=== Check zeabur-kube-watch status ==="
sudo k3s kubectl get pods -n default -l app=zeabur-kube-watch 2>&1
echo ""
echo "=== Get its logs ==="
sudo k3s kubectl logs -n default -l app=zeabur-kube-watch --tail=20 2>&1
echo ""
echo "=== Check all system pods ==="
sudo k3s kubectl get pods -A 2>&1 | grep -v -E "service-|kube-system" | head -20
echo ""
echo "=== Is Tailscale connected? ==="
tailscale status 2>&1 | head -3
