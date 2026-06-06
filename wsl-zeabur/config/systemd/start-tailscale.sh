#!/bin/bash
#
# /usr/local/bin/start-tailscale.sh
# Persistent Tailscale daemon starter (workaround for WSL2 SIGTERM flap)
#
# Why this exists:
#   WSL2's launcher init process (PID 2) sends SIGTERM to systemd services
#   when the network interface resets. The default Tailscale systemd unit
#   uses Restart=on-failure, which causes a tight restart loop.
#   This script starts Tailscale as a detached process so it survives
#   systemd's stop signals.
#

# Wait for network to be ready
sleep 5

# Check if already running
if pgrep -f "/usr/sbin/tailscaled" > /dev/null; then
  echo "Tailscale already running"
  exit 0
fi

# Start tailscaled as a detached daemon
nohup /usr/sbin/tailscaled \
  --state=/var/lib/tailscale/tailscaled.state \
  --socket=/run/tailscale/tailscaled.sock \
  --port=41641 \
  > /var/log/tailscaled.log 2>&1 &

echo "Tailscale started with PID $!"
