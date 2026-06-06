echo "=== Last 200 lines journal, focus on signal cause ==="
sudo journalctl -u tailscaled -n 200 --no-pager 2>&1 | grep -B 2 -A 5 "signal terminated" | head -50
echo ""
echo "=== Watch for restart events over 30s ==="
INITIAL_PID=$(pgrep -f "/usr/sbin/tailscaled" | head -1)
echo "Initial PID: $INITIAL_PID"
for i in 1 2 3 4 5 6; do
  sleep 5
  NEW_PID=$(pgrep -f "/usr/sbin/tailscaled" | head -1)
  TS=$(date +%H:%M:%S)
  if [ "$NEW_PID" != "$INITIAL_PID" ]; then
    echo "[$TS] PID CHANGED: $INITIAL_PID -> $NEW_PID (RESTARTED)"
    INITIAL_PID=$NEW_PID
  else
    echo "[$TS] PID: $NEW_PID (stable)"
  fi
done
echo ""
echo "=== audit log for SIGTERM events ==="
sudo ausearch -m SIGNAL -ts recent 2>&1 | head -20
echo ""
echo "=== Check who has open files to tailscaled.state ==="
sudo lsof /var/lib/tailscale/tailscaled.state 2>&1 | head -10
