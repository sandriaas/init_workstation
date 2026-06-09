echo "=== Check NATS config map ==="
sudo k3s kubectl get cm nats-config -n default -o yaml 2>&1
echo ""
echo "=== Get the actual nats.conf being used ==="
sudo k3s kubectl get cm nats-config -n default -o jsonpath='{.data.nats\.conf}' 2>&1
echo ""
echo "=== Get kube-watch full container log (live, run for 30s) ==="
sudo k3s kubectl logs -f -l name=zeabur-kube-watch -n default --tail=50 2>&1 &
LOG_PID=$!
sleep 30
kill $LOG_PID 2>/dev/null
echo ""
echo "=== Test connectivity from inside cluster ==="
sudo k3s kubectl run nats-test --rm -i --tty --image=alpine --restart=Never -- sh -c "
  apk add --no-cache nats 2>&1 | tail -1
  echo '=== Test NATS no auth ==='
  nats -s nats://nats.default.svc.cluster.local:4222 pub test.message 'hello' 2>&1
" 2>&1 | head -20
