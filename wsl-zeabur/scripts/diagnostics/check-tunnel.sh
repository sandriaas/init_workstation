echo "=== Tailscale status (peers) ==="
tailscale status 2>&1
echo ""
echo "=== Tailscale ping to gateway (need Tailscale running state) ==="
sudo tailscale ping 100.64.0.1 2>&1 | head -10 &
PID=$!
sleep 6
kill $PID 2>/dev/null
echo ""
echo "=== Try SSH from Windows side over Tailscale ==="
echo "Port 22 listening on this WSL?"
sudo ss -tlnp 2>&1 | grep ":22 "
echo ""
echo "=== Verify SSH password is set for zeabur user ==="
sudo grep -E "PasswordAuth|PermitRoot" /etc/ssh/sshd_config 2>&1
ls /etc/ssh/sshd_config.d/ 2>&1
cat /etc/ssh/sshd_config.d/00-zeabur-password-auth.conf 2>&1
echo ""
echo "=== Check what mesh IP is exposed via wonder binary ==="
sudo cat /etc/environment 2>&1 | head -20
echo ""
echo "=== Check the install script's last action / registration data ==="
sudo find / -name "*.zeabur*" -o -name "registration*" 2>/dev/null | grep -v proc | head -10
sudo find / -path "*/zeabur*" -type d 2>/dev/null | head -10
