# Setup Walkthrough

Step-by-step setup of Zeabur Wonder Mesh on Windows WSL2 Ubuntu 24.04.

---

## Prerequisites

- Windows 11 (Build 22000+) with WSL 2.6.3.0+
- Admin access to PowerShell
- 8GB+ RAM (16GB recommended)
- 50GB+ free disk space
- Tailscale account (created automatically during Zeabur install)
- Zeabur account with Wonder Mesh beta access

---

## Step 1: Install WSL2 Ubuntu 24.04

### Option A: New install with custom name

```powershell
# Open PowerShell as Administrator
wsl --install -d Ubuntu-24.04

# Rename to our required name
wsl --export Ubuntu-24.04 C:\temp\ubuntu.tar
wsl --unregister Ubuntu-24.04
wsl --import wsl_test_server_001 C:\WSL\wsl_test_server_001 C:\temp\ubuntu.tar
wsl -d wsl_test_server_001
```

### Option B: Reinstall with specific name

```powershell
wsl --install -d Ubuntu-24.04 --name wsl_test_server_001
```

### Verify

```powershell
wsl -l -v
# Expected:
#   NAME                    STATE    VERSION
#   wsl_test_server_001    Stopped  2
```

---

## Step 2: Apply Windows-Side Config

Create `C:\Users\<user>\.wslconfig`:

```ini
[wsl2]
networkingMode=nat
memory=8GB
processors=4
swap=2GB
```

See [config/wsl/wslconfig](../config/wsl/wslconfig) for the full annotated version.

### Apply

```powershell
wsl --shutdown
```

Wait 5 seconds for the config to be picked up.

---

## Step 3: Launch WSL and Apply Linux-Side Config

```powershell
wsl -d wsl_test_server_001
```

### Apply wsl.conf

```bash
sudo tee /etc/wsl.conf <<'EOF'
[boot]
systemd=true

[user]
default=zeabur

[network]
generateResolvConf = false
EOF
```

### Apply static resolv.conf

```bash
sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf <<'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 9.9.9.9
EOF

sudo chattr +i /etc/resolv.conf
```

This makes the file immutable so WSL/systemd can't overwrite it.

### Verify DNS

```bash
getent hosts registry-1.docker.io
getent hosts ghcr.io
getent hosts wonder.zeabur.com
```

All should return IP addresses.

---

## Step 4: Run Zeabur Install Script

In the Zeabur Dashboard:
1. Go to **Projects** → **Create New Project**
2. Choose **Bind External Server** → **Wonder Mesh**
3. Select **Linux** + **amd64** (or arm64 if Apple Silicon)
4. Click **View Install Command**
5. Copy the command
6. Run it in WSL:

```bash
# Paste the command from dashboard
# It will look like:
# curl -fsSL https://cdn.zeabur.com/wonder/install.sh | sudo bash -s -- <token>
```

The script will:
- Install Tailscale
- Create a `zeabur` system user
- Configure SSH
- Join the Wonder Mesh network
- Register the server

### Verify Install

```bash
tailscale status
# Expected: 100.64.3.1 desktop-hsbf3et ...
```

---

## Step 5: Install K3s

Back in the Zeabur Dashboard:
1. Click **Install K3s** button on the server page
2. Wait for the install to complete (2-5 minutes)

K3s will be installed as a system service and start automatically.

### Verify K3s

```bash
sudo k3s kubectl get nodes
# Expected: 100.64.3.1   Ready   control-plane,master

sudo k3s kubectl get pods -A
# Expected: coredns, local-path-provisioner, metrics-server all Running
```

---

## Step 6: Apply Tailscale Restart Loop Fix

This is the **critical fix** that makes the server stay online. Without it,
Tailscale will flap every 30s and the dashboard will show "Offline".

See [troubleshooting.md #2](troubleshooting.md#2-tailscale-restart-loop-sigterm) for full details.

### Quick Apply

```bash
# 1. Create systemd override
sudo mkdir -p /etc/systemd/system/tailscaled.service.d/
sudo tee /etc/systemd/system/tailscaled.service.d/override.conf <<'EOF'
[Service]
Restart=no
RestartSec=60s
KillMode=process
TimeoutStopSec=120s
EOF

# 2. Disable systemd-managed tailscaled
sudo systemctl daemon-reload
sudo systemctl disable tailscaled
sudo systemctl stop tailscaled

# 3. Create persistent auto-start script
sudo tee /usr/local/bin/start-tailscale.sh <<'SCRIPT'
#!/bin/bash
sleep 5
if pgrep -f "/usr/sbin/tailscaled" > /dev/null; then
  exit 0
fi
nohup /usr/sbin/tailscaled \
  --state=/var/lib/tailscale/tailscaled.state \
  --socket=/run/tailscale/tailscaled.sock \
  --port=41641 \
  > /var/log/tailscaled.log 2>&1 &
SCRIPT
sudo chmod +x /usr/local/bin/start-tailscale.sh

# 4. Create rc.local and rc-local service
sudo tee /etc/rc.local <<'EOF'
#!/bin/bash
/usr/local/bin/start-tailscale.sh
exit 0
EOF
sudo chmod +x /etc/rc.local

sudo tee /etc/systemd/system/rc-local.service <<'EOF'
[Unit]
Description=/etc/rc.local Compatibility
After=network.target

[Service]
Type=oneshot
ExecStart=/etc/rc.local
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable rc-local.service

# 5. Start Tailscale
sudo /usr/local/bin/start-tailscale.sh
sleep 30
tailscale status
```

Expected:
```
100.64.3.1  desktop-hsbf3et  ...
100.64.0.1  ...               active; relay "sfo", tx <bytes> rx <bytes>
```

---

## Step 7: Apply CoreDNS Rewrite

This fixes `zeabur-kube-watch` which tries to connect to `nats.zeabur.com`.

### Quick Apply

```bash
sudo k3s kubectl apply -f - <<'EOF'
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
          fallthrough in-addr-arpa ip6.arpa
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

sudo k3s kubectl rollout restart deployment coredns -n kube-system
```

### Verify

```bash
sudo k3s kubectl run dnstest --rm -i --image=busybox --restart=Never -- nslookup nats.zeabur.com
# Expected: nats.default.svc.cluster.local
```

---

## Step 8: Disable NATS Authentication

This fixes `zeabur-kube-watch` which has hardcoded NATS credentials that don't
match the NATS config.

```bash
sudo k3s kubectl apply -f wsl-zeabur/config/k3s/nats-configmap.yaml
sudo k3s kubectl rollout restart statefulset nats -n default
sleep 30
```

---

## Step 9: Verify Everything

```bash
# Check Tailscale
tailscale status
# Should show stable connection to 100.64.0.1

# Check all system pods
sudo k3s kubectl get pods -n default
# All should be 1/1 Running

# Check DNS
getent hosts zeabur.com wonder.zeabur.com api.zeabur.com registry-1.docker.io ghcr.io
# All should resolve

# Final check script
bash wsl-zeabur/scripts/verification/final-state.sh
```

---

## Step 10: Test Dashboard Status

1. Go to [https://zeabur.com/servers](https://zeabur.com/servers)
2. Your server should now show as **Online** (green)
3. The Tailscale mesh IP should be `100.64.3.1`

If it still shows offline:
- Wait 2-3 minutes (Zeabur heartbeat is every 30s)
- Click **Reinstall Zeabur Service** in the dashboard
- Check the [troubleshooting.md](troubleshooting.md) for other issues

---

## Post-Setup: Deploying Services

You can now deploy services just like on regular Zeabur:

```bash
# In WSL, check existing deployments
sudo k3s kubectl get pods -A
```

The user has 12 services running in `environment-6a2445fa95b39806d284aadf`:
realtime-dev, storage, minio, kong, auth, postgresql, functions, imgproxy, rest,
studio, meta, supavisor (a Supabase stack).

To deploy a new service:
1. Go to your project in the dashboard
2. Click **Add Service** → choose a template or push code
3. The service will deploy to this WSL server

---

## Backup & Maintenance

### Daily Operations

```bash
# Check server health
wsl -d wsl_test_server_001 -- bash wsl-zeabur/scripts/verification/final-state.sh

# Restart Tailscale if needed
wsl -d wsl_test_server_001 -- bash -c "sudo /usr/local/bin/start-tailscale.sh"
```

### Weekly Maintenance

```bash
# Update k3s
wsl -d wsl_test_server_001 -- bash -c "curl -sfL https://get.k3s.io | sh -"

# Check for failed pods
sudo k3s kubectl get pods -A | grep -v Running
```

### Backup Important Files

```bash
# Backup Tailscale state (preserves mesh identity)
sudo cp /var/lib/tailscale/tailscaled.state ~/tailscale-backup.state

# Backup kubeconfig
sudo cat /etc/rancher/k3s/k3s.yaml > ~/kubeconfig.yaml
```

### WSL Backup

```powershell
# Export the entire WSL distro
wsl --export wsl_test_server_001 C:\backup\wsl_test_server_001-$(Get-Date -Format yyyyMMdd).tar

# Restore
wsl --import wsl_test_server_001 C:\WSL\wsl_test_server_001 C:\backup\wsl_test_server_001-20260607.tar
```

---

## Uninstall

```bash
# Remove Zeabur system components
sudo k3s kubectl delete -f /var/lib/rancher/k3s/server/manifests/

# Uninstall k3s
/usr/local/bin/k3s-uninstall.sh

# Remove Tailscale
sudo tailscale logout
sudo apt remove tailscale

# Remove Zeabur user
sudo userdel -r zeabur
```

From PowerShell:
```powershell
# Remove the WSL distro
wsl --unregister wsl_test_server_001

# Remove the config
Remove-Item $env:USERPROFILE\.wslconfig
```
