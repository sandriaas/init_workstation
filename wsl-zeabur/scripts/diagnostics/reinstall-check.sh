echo "=== zeabur-kube-watch logs ==="
sudo k3s kubectl logs -n default zeabur-kube-watch-b8d9dd6c9-252mt --tail=30 2>&1
echo ""
echo "=== Reinstall zeabur-kube-watch manually (delete pod, will be recreated) ==="
sudo k3s kubectl delete pod -n default zeabur-kube-watch-b8d9dd6c9-252mt 2>&1
sleep 3
echo ""
echo "=== Check what happens ==="
sudo k3s kubectl get pods -n default 2>&1 | head -20
echo ""
echo "=== Wonder Mesh install token file ==="
ls -la /etc/zeabur* /var/lib/zeabur* /tmp/zeabur* 2>/dev/null
echo ""
echo "=== Find the install token ==="
sudo find / -name "*.token*" -o -name "auth-token*" 2>/dev/null | grep -v proc | head -10
echo ""
echo "=== Look for the original install command in history ==="
sudo cat /root/.bash_history 2>&1 | grep -E "zeabur|wonder" | head -10
sudo cat /home/zeabur/.bash_history 2>&1 | grep -E "zeabur|wonder" | head -10
