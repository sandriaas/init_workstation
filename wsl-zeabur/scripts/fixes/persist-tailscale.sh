echo "=== Create auto-start script for Tailscale ==="
cat <<'EOF' | sudo tee /usr/local/bin/start-tailscale.sh
#!/bin/bash
# Auto-start Tailscale daemon
# Used because systemd restart=on-failure causes flap loop in WSL2
# when network interface resets

# Wait for network to be ready
sleep 5

# Check if already running
if pgrep -f "/usr/sbin/tailscaled" > /dev/null; then
  echo "Tailscale already running"
  exit 0
fi

# Start tailscaled as a daemon
nohup /usr/sbin/tailscaled \
  --state=/var/lib/tailscale/tailscaled.state \
  --socket=/run/tailscale/tailscaled.sock \
  --port=41641 \
  > /var/log/tailscaled.log 2>&1 &

echo "Tailscale started with PID $!"
EOF
sudo chmod +x /usr/local/bin/start-tailscale.sh

echo ""
echo "=== Add to /etc/rc.local (systemd will run it after multi-user.target) ==="
cat <<'EOF' | sudo tee /etc/rc.local
#!/bin/bash
# Start Tailscale (workaround for WSL2 SIGTERM restart loop)
/usr/local/bin/start-tailscale.sh
exit 0
EOF
sudo chmod +x /etc/rc.local

echo ""
echo "=== Create systemd one-shot service for /etc/rc.local ==="
cat <<'EOF' | sudo tee /etc/systemd/system/rc-local.service
[Unit]
Description=/etc/rc.local Compatibility
After=network.target

[Service]
Type=oneshot
ExecStart=/etc/rc.local
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable rc-local.service 2>&1

echo ""
echo "=== Test the auto-start works ==="
sudo /usr/local/bin/start-tailscale.sh
sleep 10
tailscale status 2>&1 | head -3
echo ""
echo "=== Verify SSH listening on mesh ==="
sudo ss -tlnp 2>&1 | grep ":22 "
