echo "=== Tailscale status ==="
sudo tailscale status 2>&1 | head -20
echo ""
echo "=== Tailscale IP ==="
tailscale ip -4 2>&1
echo ""
echo "=== Tailscale ping to Zeabur gateway (100.64.0.1) ==="
sudo tailscale ping 100.64.0.1 --c 3 2>&1 | head -10
echo ""
echo "=== SSH listening on port 22 ==="
sudo ss -tlnp 2>&1 | grep -E ':22\s' || echo "port 22 not listening"
echo ""
echo "=== zeabur user exists? ==="
id zeabur 2>&1
echo ""
echo "=== Zeabur install log tail ==="
tail -30 /tmp/zeabur-install.log 2>&1
echo ""
echo "=== wonder binary ==="
ls -la /usr/local/bin/wonder 2>&1
echo ""
echo "=== mesh IP reported to API ==="
cat /etc/zeabur/mesh.json 2>/dev/null || cat /var/lib/zeabur/registration.json 2>/dev/null || echo "no mesh config file"
