echo "=== kube-watch deployment spec ==="
sudo k3s kubectl get deployment zeabur-kube-watch -n default -o yaml 2>&1 | grep -E "dnsPolicy|dns|nodeName|hostNetwork" 
echo ""
echo "=== Test DNS from inside the kube-watch pod ==="
sudo k3s kubectl exec -it zeabur-kube-watch-b8d9dd6c9-ql2n9 -n default -- nslookup nats.zeabur.com 2>&1
echo ""
echo "=== If exec fails (CrashLoop), describe ==="
sudo k3s kubectl describe pod zeabur-kube-watch-b8d9dd6c9-ql2n9 -n default 2>&1 | grep -E "dns|resolv" | head -10
echo ""
echo "=== Test the rewrite works in the actual way kube-watch uses ==="
sudo k3s kubectl run kubednstest --rm -i --image=busybox --restart=Never -- sh -c '
echo "Test nats.zeabur.com:"
nslookup nats.zeabur.com
echo ""
echo "Test nats.zeabur.com (single name without dot):"
nslookup nats.zeabur.com 10.43.0.10
' 2>&1 | head -20
echo ""
echo "=== Check /etc/resolv.conf inside pods ==="
sudo k3s kubectl get cm -n kube-system coredns -o jsonpath='{.data}' 2>&1
