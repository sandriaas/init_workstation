echo "=== Last 200 lines of tailscaled journal ==="
sudo journalctl -u tailscaled -n 200 --no-pager 2>&1 | tail -100
echo ""
echo "=== Is tailscaled alive right now? ==="
ps -ef | grep tailscaled | grep -v grep
echo ""
echo "=== systemctl status ==="
systemctl status tailscaled --no-pager 2>&1 | head -10
