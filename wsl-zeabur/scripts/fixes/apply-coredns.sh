cat <<'EOF' | sudo k3s kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
  labels:
    objectset.rio.cattle.io/hash: bce283298811743a0386ab510f2f67ef74240c57
data:
  Corefile: |
    .:53 {
        errors
        health
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
        }
        hosts /etc/coredns/NodeHosts {
          ttl 60
          reload 15s
          fallthrough
        }
        rewrite name regex nats\.zeabur\.com nats.default.svc.cluster.local
        prometheus :9153
        cache 30
        loop
        reload
        loadbalance
        import /etc/coredns/custom/*.override
        forward . /etc/resolv.conf
    }
    import /etc/coredns/custom/*.server
  NodeHosts: |
    172.29.155.146 100.64.3.1 DESKTOP-HSBF3ET
EOF

echo ""
echo "=== Verify rewrite is now in live config ==="
sudo k3s kubectl get cm coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>&1
echo ""
echo "=== Restart CoreDNS to apply ==="
sudo k3s kubectl rollout restart deployment coredns -n kube-system 2>&1
sleep 10
echo ""
echo "=== Test DNS resolution again ==="
sudo k3s kubectl run dnstest2 --rm -i --image=busybox --restart=Never -- nslookup nats.zeabur.com 2>&1
