echo "=== Systemd service file ==="
cat /lib/systemd/system/tailscaled.service 2>&1
echo ""
echo "=== Override files ==="
ls -la /etc/systemd/system/tailscaled* 2>&1
cat /etc/systemd/system/tailscaled.service.d/*.conf 2>/dev/null
echo ""
echo "=== Check systemd journal for crashes ==="
sudo journalctl -u tailscaled --since "5 minutes ago" --no-pager 2>&1 | grep -E "Failed|stop|stopping|started|stopped|main process|exited|status" | head -30
echo ""
echo "=== Check who is restarting it (timer?) ==="
systemctl list-timers --all 2>&1 | grep -i tail
echo ""
echo "=== is there a watchdog? ==="
find /etc/systemd /lib/systemd -name "*tailscale*" 2>/dev/null
echo ""
echo "=== Tailscale state file ==="
sudo ls -la /var/lib/tailscale/ 2>&1
