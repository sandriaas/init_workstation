echo "=== Recent SIGTERM events (last 5 min) ==="
sudo journalctl -u tailscaled --since "5 minutes ago" --no-pager 2>&1 | grep -E "signal terminated|Stopping" | head -20
echo ""
echo "=== Find what process is sending SIGTERM ==="
ps -ef | grep -v grep | head -30
echo ""
echo "=== Check wonder binary for loops ==="
ps -ef | grep -E "wonder|mesh" | grep -v grep
echo ""
echo "=== Check crontab ==="
sudo crontab -l 2>&1
crontab -l 2>&1
echo ""
echo "=== /etc/cron* ==="
ls -la /etc/cron.d/ 2>&1
ls -la /etc/cron.hourly/ 2>&1
ls -la /etc/cron.daily/ 2>&1
echo ""
echo "=== systemd timers ==="
systemctl list-timers --all 2>&1 | head -20
echo ""
echo "=== Watch the daemon (10 second snapshot) ==="
for i in 1 2 3 4 5; do
  PID=$(pgrep -f "/usr/sbin/tailscaled" | head -1)
  echo "$(date '+%H:%M:%S') tailscaled PID: $PID"
  sleep 2
done
