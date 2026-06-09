echo "=== Watch for the SIGTERM event in real-time ==="
PID_BEFORE=$(pgrep -f "/usr/sbin/tailscaled" | head -1)
echo "Current PID: $PID_BEFORE"

# Watch for PID change
for i in $(seq 1 30); do
  PID_NOW=$(pgrep -f "/usr/sbin/tailscaled" | head -1)
  if [ "$PID_NOW" != "$PID_BEFORE" ] && [ -n "$PID_NOW" ]; then
    echo ""
    echo "=================================================="
    echo "RESTART DETECTED at $(date +%H:%M:%S)"
    echo "Old PID: $PID_BEFORE -> New PID: $PID_NOW"
    echo "=================================================="
    echo ""
    echo "=== Last 30 lines of journal BEFORE the kill ==="
    sudo journalctl -u tailscaled -n 30 --no-pager 2>&1 | tail -30
    break
  fi
  sleep 2
done
echo ""
echo "=== Audit who can send signals ==="
cat /proc/$PID_BEFORE/status 2>/dev/null | grep -E "Uid|Gid|Cap"
echo ""
echo "=== Systemd Restart= settings ==="
grep -E "Restart|RestartSec" /lib/systemd/system/tailscaled.service
