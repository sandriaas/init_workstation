echo "=== tailscaled service status ==="
sudo systemctl status tailscaled --no-pager 2>&1 | head -20
echo ""
echo "=== tailscaled is running? ==="
ps aux | grep -E "tailscaled|wonder" | grep -v grep
echo ""
echo "=== tailscaled logs (last 50 lines) ==="
sudo journalctl -u tailscaled -n 50 --no-pager 2>&1
echo ""
echo "=== Tailscale control server setting ==="
sudo tailscale debug --control 2>&1 | head -10 || true
echo ""
echo "=== Network interfaces ==="
ip -4 addr show 2>&1 | grep -E "inet|tailscale"
echo ""
echo "=== Try Tailscale login (dry check) ==="
sudo tailscale netcheck 2>&1 | head -30
