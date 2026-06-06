echo "=== Wait for Tailscale to fully start ==="
for i in 1 2 3 4 5 6 7 8 9 10; do
  sleep 3
  STATE=$(tailscale status 2>&1 | head -1)
  IP=$(tailscale ip -4 2>&1 | head -1)
  echo "[$(date +%H:%M:%S)] state='$STATE' ip='$IP'"
  if [[ "$IP" =~ ^100\. ]]; then break; fi
done

echo ""
echo "=== DNS resolution tests ==="
echo "zeabur.com:"
getent hosts zeabur.com | head -2
echo "wonder.zeabur.com:"
getent hosts wonder.zeabur.com | head -2
echo "api.zeabur.com:"
getent hosts api.zeabur.com | head -2
echo "registry-1.docker.io:"
getent hosts registry-1.docker.io | head -2
echo "cdn.zeabur.com:"
getent hosts cdn.zeabur.com | head -2

echo ""
echo "=== Verify resolv.conf is intact ==="
ls -la /etc/resolv.conf
cat /etc/resolv.conf
echo "Immutable check:"
lsattr /etc/resolv.conf 2>&1

echo ""
echo "=== Tailscale status (full) ==="
tailscale status 2>&1 | head -10

echo ""
echo "=== Tailscale control plane reachable? ==="
curl -sk --max-time 5 https://wonder.zeabur.com/ 2>&1 | head -3
echo ""
curl -sk --max-time 5 https://api.zeabur.com/ 2>&1 | head -3
