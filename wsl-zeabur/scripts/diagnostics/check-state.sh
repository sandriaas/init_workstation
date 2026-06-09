echo "=== Latest tailscaled logs ==="
sudo journalctl -u tailscaled -n 30 --no-pager 2>&1
echo ""
echo "=== Check if Tailscale can reach Zeabur control server ==="
curl -sk --max-time 5 https://wonder.zeabur.com/ 2>&1 | head -3
echo ""
echo "=== Curl tailscale state file ==="
ls -la /var/lib/tailscale/ 2>&1
echo ""
echo "=== Check wonder registration state ==="
ls -la /var/lib/zeabur/ 2>&1
cat /var/lib/zeabur/*.json 2>/dev/null
cat /var/lib/zeabur/*.state 2>/dev/null
cat /var/log/zeabur* 2>/dev/null
echo ""
echo "=== is there a zeabur-registration? ==="
find / -name "*zeabur*" -type f 2>/dev/null | grep -v proc | head -20
