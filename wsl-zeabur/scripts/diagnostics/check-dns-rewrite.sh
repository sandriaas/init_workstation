echo "=== Check CoreDNS config for the rewrite ==="
sudo k3s kubectl get cm coredns -n kube-system -o yaml 2>&1
echo ""
echo "=== Test DNS resolution of nats.zeabur.com from inside k3s ==="
sudo k3s kubectl run dnstest --rm -i --image=busybox --restart=Never -- nslookup nats.zeabur.com 2>&1
echo ""
echo "=== Test DNS from inside k3s for the service ==="
sudo k3s kubectl run dnstest --rm -i --image=busybox --restart=Never -- nslookup nats.default.svc.cluster.local 2>&1
echo ""
echo "=== Test nats.zeabur.com from host (WSL) ==="
getent hosts nats.zeabur.com 2>&1
echo ""
echo "=== nodelocal-dns exists? ==="
sudo k3s kubectl get pods -n kube-system 2>&1
