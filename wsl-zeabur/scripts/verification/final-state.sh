echo '=== FINAL STATE ==='
echo ''
echo '--- Tailscale ---'
tailscale status 2>&1
echo ''
echo '--- All 9 System Pods ---'
sudo k3s kubectl get pods -n default 2>&1
echo ''
echo '--- DNS Verification ---'
for d in zeabur.com wonder.zeabur.com api.zeabur.com cdn.zeabur.com registry-1.docker.io ghcr.io; do
  IP=$(getent hosts $d 2>&1 | head -1 | awk '{print $1}')
  echo "  $d -> $IP"
done
