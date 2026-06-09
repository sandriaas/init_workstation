echo "=== Create systemd override to prevent restart loop ==="
sudo mkdir -p /etc/systemd/system/tailscaled.service.d/
cat <<'EOF' | sudo tee /etc/systemd/system/tailscaled.service.d/override.conf
[Service]
# Don't restart on SIGTERM, just keep running
Restart=no
# Longer restart delay to avoid tight loop
RestartSec=60s
# Don't kill on systemd stop, just let it keep running
KillMode=process
# Send SIGTERM but wait longer before SIGKILL
TimeoutStopSec=120s
EOF

echo ""
echo "=== Reload systemd ==="
sudo systemctl daemon-reload

echo ""
echo "=== Disable tailscaled (we'll start it manually as a daemon) ==="
sudo systemctl disable tailscaled 2>&1
sudo systemctl stop tailscaled 2>&1

echo ""
echo "=== Start tailscaled manually as a background process ==="
sudo nohup /usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock --port=41641 > /tmp/tailscaled.log 2>&1 &
sleep 5
echo "Started PID: $!"

echo ""
echo "=== Wait for connection ==="
for i in 1 2 3 4 5 6 7 8 9 10; do
  IP=$(tailscale ip -4 2>&1 | head -1)
  echo "[$(date +%H:%M:%S)] IP=$IP"
  if [[ "$IP" =~ ^100\. ]]; then break; fi
  sleep 3
done

echo ""
echo "=== Verify it stays connected for 30s ==="
for i in 1 2 3 4 5 6; do
  sleep 5
  IP=$(tailscale ip -4 2>&1 | head -1)
  TS=$(date +%H:%M:%S)
  echo "[$TS] IP=$IP"
done
