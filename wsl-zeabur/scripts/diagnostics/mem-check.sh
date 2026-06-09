echo "=== Memory state right now ==="
free -h
echo ""
echo "=== Recent OOM kills in dmesg ==="
sudo dmesg 2>&1 | grep -iE "killed|oom" | tail -10
echo ""
echo "=== WSL init process info ==="
ls -la /proc/2/exe 2>&1
cat /proc/2/cmdline 2>&1 | tr '\0' ' '; echo ""
echo ""
echo "=== Check if there's a watchdog process ==="
ps aux | grep -E "watchdog|wsl-pro-service" | grep -v grep
echo ""
echo "=== Top memory consumers ==="
ps aux --sort=-%mem | head -10
echo ""
echo "=== Tailscale memory cgroup limit ==="
cat /sys/fs/cgroup/system.slice/tailscaled.service/memory.max 2>/dev/null
cat /sys/fs/cgroup/system.slice/tailscaled.service/memory.current 2>/dev/null
echo ""
echo "=== Check k3s eviction thresholds ==="
sudo k3s kubectl get nodes -o yaml 2>&1 | grep -A 5 "eviction" | head -10
