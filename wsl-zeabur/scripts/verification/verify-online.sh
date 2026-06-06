echo "=== Check Tailscale status after 30s ==="
tailscale status 2>&1 | head -5
echo ""
echo "=== Verify SSH listening on mesh IP ==="
sudo ss -tlnp 2>&1 | grep ":22 "
echo ""
echo "=== Verify Zeabur system pods still healthy ==="
sudo k3s kubectl get pods -n default 2>&1 | head -15
echo ""
echo "=== Tailscale ping to gateway ==="
timeout 5 sudo tailscale ping 100.64.0.1 -c 2 2>&1 | tail -5
echo ""
echo "=== Test SSH over mesh from Windows ==="
echo "Tailscale: $(tailscale ip -4)"
