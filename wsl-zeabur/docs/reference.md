# Reference

Quick reference for commands, endpoints, IDs, and configurations.

---

## Server Identifiers

| Resource | Value |
|----------|-------|
| Zeabur Server ID | `server-6a23cdf424701a8493345c17` |
| Tailscale Mesh IP | `100.64.3.1` |
| Wonder Mesh Gateway | `100.64.0.1` |
| Old VM (replaced) | `vm-2` at `100.64.2.166` (offline) |
| WSL Distro Name | `wsl_test_server_001` |
| Hostname | `desktop-hsbf3et` |
| K3s Node Name | `100.64.3.1` |
| WSL Internal IP | `172.29.155.146` |
| Zeabur User ID | `1245` |
| Tailscale Node ID | `805` |
| Tailscale Machine Key Fingerprint | `adb4b8c0-9556-428d-8575-0d9b9739fdfe` |

---

## Zeabur API Endpoints

| Endpoint | Purpose |
|----------|---------|
| `https://api.zeabur.com/graphql` | Main API (GraphQL) |
| `https://wonder.zeabur.com/` | Tailscale control server (Headscale) |
| `https://cdn.zeabur.com/` | Install scripts, wonder binary |
| `https://nats.zeabur.com` | NATS JetStream (external) - rewritten to internal |
| `https://log.tailscale.com` | Tailscale log upload |
| `https://controlplane.tailscale.com` | Tailscale DERP map |
| `https://zeabur.com/servers` | Dashboard - servers page |
| `https://zeabur.com/forum/posts/SEI-XXX` | Incident threads |

---

## Common Zeabur CLI Commands

```bash
# Login
npx -y zeabur@latest auth login --token <TOKEN>

# Workspaces
npx -y zeabur@latest workspace list
npx -y zeabur@latest workspace current
npx -y zeabur@latest workspace switch <team-name-or-id>

# Projects
npx -y zeabur@latest project ls
npx -y zeabur@latest project ls --project-id <ID>
npx -y zeabur@latest context set project --id <PROJECT_ID>

# Services
npx -y zeabur@latest service ls
npx -y zeabur@latest service restart

# Deployments
npx -y zeabur@latest deployment get
npx -y zeabur@latest deployment log -t=runtime
npx -y zeabur@latest deployment log -t=build

# Context (for non-interactive mode)
npx -y zeabur@latest context set project --name <NAME>
npx -y zeabur@latest context set service --name <NAME>
npx -y zeabur@latest context set env --id <ENV_ID>
```

---

## Common WSL Commands

```powershell
# List distros
wsl -l -v
wsl --list --verbose

# Set default distro
wsl --set-default wsl_test_server_001

# Run a command in a specific distro
wsl -d wsl_test_server_001 -- bash -c "command"

# Update package list
wsl -d wsl_test_server_001 -- sudo apt update

# Shutdown WSL
wsl --shutdown

# Restart specific distro
wsl -t wsl_test_server_001

# Export distro (backup)
wsl --export wsl_test_server_001 C:\backup.tar

# Import distro (restore)
wsl --import wsl_test_server_001 C:\WSL\path C:\backup.tar

# Unregister (remove)
wsl --unregister wsl_test_server_001
```

---

## Common Tailscale Commands

```bash
# Status
tailscale status
tailscale ip -4
tailscale ip -6

# Ping a peer
sudo tailscale ping 100.64.0.1 -c 3

# Check connectivity
sudo tailscale netcheck

# Check state file
sudo cat /var/lib/tailscale/tailscaled.state

# Logs
sudo journalctl -u tailscaled --no-pager
sudo journalctl -u tailscaled -n 100 --no-pager
sudo journalctl -u tailscaled -f  # follow

# Restart (if running via systemd - NOT for our setup)
sudo systemctl restart tailscaled

# Manual start (our setup)
sudo /usr/local/bin/start-tailscale.sh

# Logout / unregister
sudo tailscale logout

# Show debug info
sudo tailscale debug

# List debug options
sudo tailscale debug --help
```

---

## Common k3s Commands

```bash
# Get cluster info
sudo k3s kubectl cluster-info

# Get nodes
sudo k3s kubectl get nodes -o wide

# Get all pods
sudo k3s kubectl get pods -A
sudo k3s kubectl get pods -n default

# Get specific pod
sudo k3s kubectl get pod <pod-name> -n default -o yaml

# Get pod logs
sudo k3s kubectl logs <pod-name> -n default
sudo k3s kubectl logs <pod-name> -n default --previous  # previous instance
sudo k3s kubectl logs <pod-name> -n default -f  # follow

# Describe pod
sudo k3s kubectl describe pod <pod-name> -n default

# Get events
sudo k3s kubectl get events -A --sort-by='.lastTimestamp'
sudo k3s kubectl get events -n default

# Delete a pod (will be recreated if part of deployment)
sudo k3s kubectl delete pod <pod-name> -n default

# Restart a deployment
sudo k3s kubectl rollout restart deployment/<name> -n default

# Get configmaps
sudo k3s kubectl get cm -n default
sudo k3s kubectl get cm -n kube-system
sudo k3s kubectl get cm coredns -n kube-system -o yaml

# Get services
sudo k3s kubectl get svc -A

# Get namespaces
sudo k3s kubectl get ns

# Execute in pod
sudo k3s kubectl exec -it <pod-name> -n default -- sh
sudo k3s kubectl exec -it <pod-name> -n default -- bash

# Port forward
sudo k3s kubectl port-forward <pod-name> 8080:80 -n default
```

---

## k3s Service Configuration

### k3s Configuration File

`/etc/rancher/k3s/config.yaml` (if exists)

Common settings:
```yaml
disable:
  - traefik
  - servicelb
  - local-storage

node-args:
  - "server"
  - "--kubelet-arg=eviction-hard=memory.available<16Mi"
  - "--kubelet-arg=kube-reserved=cpu=250m,memory=512Mi"
  - "--kubelet-arg=system-reserved=cpu=250m,memory=512Mi"
  - "--tls-san=100.64.3.1"

secrets-encryption: true
```

### Default k3s args (from this install)

- `--kubelet-arg=eviction-hard=memory.available<16Mi` (aggressive!)
- `--kubelet-arg=kube-reserved=cpu=250m,memory=512Mi`
- `--kubelet-arg=system-reserved=cpu=250m,memory=512Mi`
- `--resolv-conf=/etc/resolv.kubelet.conf`
- `--tls-san=100.64.3.1`

---

## K3s File Locations

| File | Purpose |
|------|---------|
| `/etc/rancher/k3s/k3s.yaml` | Kubeconfig (requires sudo) |
| `/var/lib/rancher/k3s/` | k3s data directory |
| `/var/lib/rancher/k3s/server/manifests/` | Auto-deployed manifests |
| `/var/lib/rancher/k3s/server/db/` | SQLite (etcd replacement) |
| `/var/log/k3s.log` | k3s logs |
| `/run/flannel/subnet.env` | Flannel subnet config (may be missing) |
| `/etc/resolv.kubelet.conf` | kubelet's DNS config |

---

## System Pod Images

| Pod | Image |
|-----|-------|
| vector-aggregator | `docker.io/zeabur/vector-aggregator:latest` |
| zeabur-dns | `docker.io/zeabur/dns:latest` |
| zeabur-kube-watch | `docker.io/zeabur/kube-watch:1.0.4` |
| zeabur-log-api | `docker.io/zeabur/log-api:latest` |
| nats | `docker.io/library/nats:2.10.7-alpine` |
| cadvisor | `docker.io/zeabur/cadvisor:latest` |
| fluent-bit | `docker.io/zeabur/fluent-bit:latest` |
| ingress-controller | `docker.io/zeabur/ingress-nginx:latest` |
| node-exporter | `docker.io/zeabur/node-exporter:latest` |
| coredns | `docker.io/zeabur/coredns:latest` |

---

## Environment Variables for zeabur-kube-watch

```yaml
env:
  - name: REGION
    value: server-6a23cdf424701a8493345c17
  - name: VECTOR_URL
    value: http://vector-aggregator:8081/k8s-events
  - name: NATS_URL
    value: nats://zeabur-kube-watch:c2accc64db0c@nats.default.svc.cluster.local:4222
  - name: NATS_USER
    value: admin
  - name: NATS_PASSWORD
    value: c2accc64db0c
```

Note: The env vars are ignored by the binary; credentials are hardcoded.

---

## File Permissions

| File/Directory | Owner | Mode |
|----------------|-------|------|
| `/etc/resolv.conf` | root | 0644 |
| `/etc/wsl.conf` | root | 0644 |
| `/usr/local/bin/start-tailscale.sh` | root | 0755 |
| `/etc/rc.local` | root | 0755 |
| `/etc/systemd/system/rc-local.service` | root | 0644 |
| `/var/lib/tailscale/` | root | 0700 |
| `/etc/rancher/k3s/k3s.yaml` | root | 0600 |

---

## WSL2 Networking

| Setting | Default | Our Value |
|---------|---------|-----------|
| WSL2 IP | `172.29.x.x` | `172.29.155.146` |
| WSL2 Gateway | `172.29.x.1` | `172.29.144.1` |
| DNS Proxy | `10.255.255.254` | bypassed (we use 8.8.8.8) |
| Networking Mode | NAT | NAT |
| Memory | 50% host | 8GB |
| CPU | All cores | 4 |
| Swap | 0 | 2GB |

---

## Tailscale Endpoints (DERP Relays)

| Region | DERP Code | Typical Latency |
|--------|-----------|-----------------|
| Singapore | `sin` | 36ms |
| Hong Kong | `hkg` | 60ms |
| Tokyo | `tok` | 99ms |
| Sydney | `syd` | 213ms |
| San Francisco | `sfo` | 197ms |
| London | `lhr` | 176ms |

Our connection uses `relay "sfo"` (San Francisco) for the gateway hop.

---

## Useful Grep Patterns

```bash
# Find which Zeabur pod is using most CPU
sudo k3s kubectl top pods -n default

# Find pods in CrashLoopBackOff
sudo k3s kubectl get pods -A | grep -E "CrashLoop|ImagePull|Error"

# Find Tailscale restarts
sudo journalctl -u tailscaled --since "1 hour ago" --no-pager | grep -c "Starting tailscaled"

# Find CoreDNS errors
sudo k3s logs -n kube-system -l k8s-app=kube-dns --tail=100 | grep -i error

# Find NATS auth failures
sudo k3s logs -n default nats-0 -c nats --tail=100 | grep -i auth

# Find DNS issues
sudo k3s kubectl logs -n default -l name=zeabur-kube-watch --tail=20 | grep -i "dial tcp"
```

---

## Common Error Messages

| Error | Cause | Fix |
|-------|-------|-----|
| `dial tcp: lookup nats.zeabur.com: i/o timeout` | CoreDNS rewrite missing | Re-apply [coredns-configmap.yaml](../config/k3s/coredns-configmap.yaml) |
| `nats: API error: code=503` | NATS shared stream limit hit (Zeabur side) | Wait for SEI-545 fix, no action needed |
| `nats: no response from stream` | Same as above (non-critical) | Pod stays Running, ignore |
| `ImagePullBackOff: pull QPS exceeded` | Docker Hub rate limit | Fix the underlying crash, QPS resets |
| `Failed to create pod sandbox: flannel subnet.env` | k3s flannel not ready | Wait or `systemctl restart k3s` |
| `tailscaled got signal terminated` | WSL2 network reset | See [Tailscale fix](troubleshooting.md#2-tailscale-restart-loop-sigterm) |
| `unexpected state: NoState` | Tailscale not connected | Run `sudo /usr/local/bin/start-tailscale.sh` |
| `No such server` (GraphQL) | Server deleted from Zeabur | Re-create via dashboard |

---

## Version Information

| Component | Version |
|-----------|---------|
| Windows | 11 Build 28000.1575 |
| WSL | 2.6.3.0 |
| Ubuntu | 24.04 LTS (Noble) |
| Kernel | 6.6.87.2-1 |
| Tailscale | 1.98.4-t9e69045b2-ged3a62f14 |
| k3s | latest (auto-updated) |
| NATS | 2.10.7-alpine |
| Zeabur kube-watch | 1.0.4 |
| Go (in tailscale) | 1.26.3 |

---

## Glossary

- **Wonder Mesh** - Zeabur's self-hosted platform that turns your device into a compute node
- **Headscale** - Self-hosted Tailscale coordination server
- **DERP** - Designated Encrypted Relay for Packets (Tailscale relay servers)
- **Mesh IP** - IP assigned within the Tailscale network (100.64.0.0/10)
- **K3s** - Lightweight Kubernetes distribution
- **Flannel** - CNI plugin for k3s, provides pod networking
- **NATS JetStream** - Persistent messaging system used by Zeabur for events
- **Wonder Mesh Gateway** - Zeabur's relay/proxy at 100.64.0.1
- **SEI-XXX** - Zeabur internal incident tracking IDs
- **CRS** - Container Runtime Sandbox
- **CDI** - Container Device Interface
