echo "=== Get deployment yaml for kube-watch ==="
sudo k3s kubectl get deployment zeabur-kube-watch -n default -o yaml 2>&1 | head -80
echo ""
echo "=== Check the system namespace state ==="
sudo k3s kubectl get all -n default 2>&1 | head -30
echo ""
echo "=== Check if there's a system namespace ==="
sudo k3s kubectl get namespaces 2>&1
echo ""
echo "=== List all deployments ==="
sudo k3s kubectl get deployments -A 2>&1
