echo "=== Last 200 lines of tailscaled logs from journal ==="
sudo journalctl -u tailscaled -n 200 --no-pager 2>&1 | tail -100
echo ""
echo "=== Look for 'killed' or 'OOM' messages ==="
sudo dmesg 2>&1 | grep -iE "killed|oom|tailscale" | tail -20
echo ""
echo "=== Memory state ==="
free -h
echo ""
echo "=== is cgroup memory limit hitting tailscaled? ==="
cat /sys/fs/cgroup/system.slice/tailscaled.service/memory.current 2>/dev/null
cat /sys/fs/cgroup/system.slice/tailscaled.service/memory.high 2>/dev/null
cat /sys/fs/cgroup/system.slice/tailscaled.service/memory.max 2>/dev/null
echo ""
echo "=== Service active status ==="
systemctl is-active tailscaled 2>&1
systemctl status tailscaled --no-pager 2>&1 | head -10
