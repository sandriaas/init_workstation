echo "=== Test 1: Kill Tailscale and see if rc.local-like restart brings it back ==="
PID_BEFORE=$(pgrep -f "/usr/sbin/tailscaled" | head -1)
echo "Current PID: $PID_BEFORE"
sudo kill $PID_BEFORE
sleep 3
echo "After kill:"
pgrep -f "/usr/sbin/tailscaled" | head -1
echo ""
echo "=== Test 2: Run the auto-start script ==="
sudo /usr/local/bin/start-tailscale.sh
sleep 10
echo "After auto-start:"
pgrep -f "/usr/sbin/tailscaled" | head -1
tailscale ip -4 2>&1 | head -1
echo ""
echo "=== Test 3: Verify Zeabur connectivity ==="
tailscale status 2>&1 | head -3
