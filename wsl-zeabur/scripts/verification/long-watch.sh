echo "=== Watch Tailscale over 5 minutes, log every change ==="
LOG=/tmp/tailscale-watch.log
> $LOG
START_TIME=$(date +%s)
INITIAL_PID=$(pgrep -f "/usr/sbin/tailscaled" | head -1)
INITIAL_STATE=$(tailscale status 2>&1 | head -1)

echo "START: PID=$INITIAL_PID state='$INITIAL_STATE'" | tee -a $LOG

for i in $(seq 1 60); do
  sleep 5
  NOW_PID=$(pgrep -f "/usr/sbin/tailscaled" | head -1)
  NOW_STATE=$(tailscale status 2>&1 | head -1)
  NOW_IP=$(tailscale ip -4 2>&1 | head -1)
  NOW_TIME=$(date +%H:%M:%S)
  ELAPSED=$(( $(date +%s) - START_TIME ))
  
  if [ "$NOW_PID" != "$INITIAL_PID" ]; then
    echo "[$NOW_TIME +${ELAPSED}s] PID CHANGE: $INITIAL_PID -> $NOW_PID  state='$NOW_STATE' ip='$NOW_IP'" | tee -a $LOG
    INITIAL_PID=$NOW_PID
    
    # Capture journal at moment of change
    echo "--- Journal at moment of change ---" | tee -a $LOG
    sudo journalctl -u tailscaled -n 15 --no-pager 2>&1 | tail -15 | tee -a $LOG
    echo "--- End journal ---" | tee -a $LOG
  else
    echo "[$NOW_TIME +${ELAPSED}s] PID=$NOW_PID state='$NOW_STATE' ip='$NOW_IP'" >> $LOG
  fi
done
echo ""
echo "=== Summary ==="
echo "Total time: 300 seconds"
echo "Restart events:"
grep "PID CHANGE" $LOG | wc -l
echo ""
echo "=== Full log ==="
cat $LOG
