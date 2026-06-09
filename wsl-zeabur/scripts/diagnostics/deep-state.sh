echo "=== Last 5 restart events with full context ==="
sudo journalctl -u tailscaled --no-pager 2>&1 | grep -B 3 "signal terminated" | tail -30
echo ""
echo "=== State machine: was Running, then? ==="
sudo journalctl -u tailscaled --no-pager 2>&1 | grep -E "ipn state|State:" | tail -20
echo ""
echo "=== Check Tailscale logs directly ==="
sudo journalctl -u tailscaled --no-pager 2>&1 | tail -50
echo ""
echo "=== systemd oom events? ==="
sudo journalctl --since "30 minutes ago" --no-pager 2>&1 | grep -iE "killed|oom|memory" | tail -10
