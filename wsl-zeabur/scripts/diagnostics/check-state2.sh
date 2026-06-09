echo "=== Current Tailscale state ==="
tailscale status 2>&1 | head -3
echo ""
echo "=== tailscaled uptime ==="
systemctl status tailscaled --no-pager 2>&1 | head -10
echo ""
echo "=== Verify Wonder Mesh is connected to Zeabur ==="
sudo tailscale ping 100.64.0.1 -c 3 2>&1 | head -10
echo ""
echo "=== SSH to mesh IP (loopback) ==="
ssh -o ConnectTimeout=5 -o BatchMode=yes zeabur@100.64.3.1 'echo "OK: $(hostname)"; uptime' 2>&1
echo ""
echo "=== Tailscale netcheck ==="
sudo tailscale netcheck 2>&1 | head -15
echo ""
echo "=== Zeabur state file (if any) ==="
sudo cat /var/lib/tailscale/tailscaled.state 2>&1 | head -20
