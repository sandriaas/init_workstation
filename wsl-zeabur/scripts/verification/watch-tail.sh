echo "=== Real-time watch: 30 seconds, log all state changes ==="
for i in $(seq 1 15); do
  TS=$(date '+%H:%M:%S')
  PID=$(pgrep -f "/usr/sbin/tailscaled" | head -1)
  IP=$(tailscale ip -4 2>&1 | head -1)
  STATE=$(tailscale status 2>&1 | head -1)
  echo "[$TS] pid=$PID ip='$IP' state='$STATE'"
  sleep 2
done
