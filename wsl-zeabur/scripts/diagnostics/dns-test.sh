echo "=== DNS test for ghcr.io (where Zeabur images live) ==="
getent hosts ghcr.io | head -3
echo ""
echo "=== DNS test for k8s.gcr.io ==="
getent hosts k8s.gcr.io 2>&1 | head -3
echo ""
echo "=== DNS test for docker.io ==="
getent hosts docker.io 2>&1 | head -3
echo ""
echo "=== Try pull manually ==="
sudo ctr -n k8s.io images pull ghcr.io/zeabur/kube-watch:1.0.4 2>&1 | tail -10
echo ""
echo "=== Check what pod events say ==="
sudo k3s kubectl describe pod zeabur-kube-watch-b8d9dd6c9-ql2n9 -n default 2>&1 | tail -30
