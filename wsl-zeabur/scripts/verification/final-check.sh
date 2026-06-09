POD=$(sudo k3s kubectl get pods -n default -l app=zeabur-kube-watch -o name 2>/dev/null | head -1 | sed 's|pod/||')
echo "Pod: $POD"
echo ""
echo "=== Current logs (last 30) ==="
sudo k3s kubectl logs $POD -n default --tail=30 2>&1
echo ""
echo "=== All 9 system components status ==="
sudo k3s kubectl get pods -n default 2>&1 | tail -15
echo ""
echo "=== Tailscale state ==="
tailscale status 2>&1 | head -3
echo ""
echo "=== Tailscale ping to gateway ==="
timeout 8 sudo tailscale ping 100.64.0.1 2>&1 | head -5
