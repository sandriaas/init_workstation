# Windows WSL2 + Zeabur Wonder Mesh - Complete Setup Guide

**Date**: 2026-06-06  
**Environment**: Windows 11 + WSL2 + Ubuntu 24.04  
**Platform**: Zeabur Wonder Mesh (Self-Hosted K3s)

---

## Table of Contents
1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [WSL2 Installation](#wsl2-installation)
4. [System Configuration](#system-configuration)
5. [Zeabur Wonder Mesh Setup](#zeabur-wonder-mesh-setup)
6. [Troubleshooting](#troubleshooting)
7. [DNS Fix](#dns-fix)
8. [NATS Configuration](#nats-configuration)
9. [CoreDNS Rewrite](#coredns-rewrite)
10. [Verification](#verification)
11. [Architecture](#architecture)
12. [References](#references)

---

## Overview

This document describes the complete process of setting up a Zeabur Wonder Mesh server on a Windows 11 machine using WSL2 (Windows Subsystem for Linux 2) with Ubuntu 24.04. The setup replicates a production-like environment (vm_2) where Zeabur runs as a self-hosted platform with K3s (Kubernetes) for container orchestration.

### What is Zeabur Wonder Mesh?
Zeabur Wonder Mesh is a self-hosted deployment platform that turns your own device (laptop, desktop, or server) into a Zeabur compute node. It uses:
- **Tailscale** for secure mesh networking (WireGuard-based)
- **K3s** for lightweight Kubernetes orchestration
- **NATS** for messaging between components
- **CoreDNS** for internal DNS resolution

---

## Prerequisites

### Hardware
- Windows 11 (Build 22000+)
- At least 8GB RAM (16GB recommended)
- 50GB free disk space
- Virtualization enabled in BIOS/UEFI (Intel VT-x or AMD-V)

### Software
- WSL 2.6.3.0 or higher
- Windows Terminal (recommended)
- Admin access to PowerShell

### Verification Commands
```powershell
# Check WSL version
wsl --version

# Check Windows version
winver

# Check virtualization
# Task Manager > Performance > CPU > Virtualization: Enabled
```

---

## WSL2 Installation

### Step 1: Install Ubuntu 24.04 with Custom Name

```powershell
# Run in Admin PowerShell
wsl --install -d Ubuntu-24.04 --name wsl_test_server_001
```

**Note**: The initial setup will prompt for UNIX username/password. If running headless, the distro starts as `root` until user setup is completed.

### Step 2: Verify Installation

```powershell
wsl --list --verbose
```

Expected output:
```
  NAME                    STATE    VERSION
* wsl_test_server_001     Running  2
```

---

## System Configuration

### Enable systemd (Required for Zeabur)

systemd is required for proper service management (Tailscale, K3s, SSH, etc.).

```bash
# Inside WSL
sudo tee /etc/wsl.conf <<'EOF'
[boot]
systemd=true

[user]
default=zeabur

[network]
generateResolvConf = false
EOF

# Restart WSL from PowerShell
wsl --shutdown
wsl -d wsl_test_server_001
```

### Update System Packages

```bash
sudo apt update && sudo apt upgrade -y
```

### Install Essential Tools

```bash
sudo apt install -y curl wget git nano
```

---

## Zeabur Wonder Mesh Setup

### Installation Command

The Zeabur installation script is provided when you create a Wonder Mesh server in the Zeabur dashboard. It includes a JWT token for server registration.

```bash
# Inside WSL (run as root or with sudo)
curl -fsSL 'https://api.zeabur.com/mesh-server/install.sh?token=<YOUR_TOKEN>' | bash
```

### What the Script Does

1. **Installs Tailscale** - Mesh networking client
2. **Joins Wonder Mesh Network** - Connects to Zeabur control plane
3. **Installs SSH Server** - For remote access via Tailscale IP
4. **Registers Server** - Sends server info to Zeabur cloud
5. **Installs K3s** - Lightweight Kubernetes (triggered from dashboard)

### Expected Output

```
=== Zeabur Mesh Server Setup ===
Installing Tailscale...
Tailscale installed: 1.98.4
Ensuring tailscaled is running...
Downloading wonder binary...
Joining Wonder Mesh Network...
Successfully joined Wonder Mesh Net!
Installing SSH server...
=== Zeabur Mesh Server Setup Complete ===
Mesh IP: 100.64.3.1
```

### Post-Installation Status

```bash
# Check Tailscale
tailscale status

# Check SSH
sudo systemctl status ssh

# Check Tailscale daemon
sudo systemctl status tailscaled
```

---

## Troubleshooting

### Issue 1: Image Pull Failures (DNS Resolution)

**Symptom**: 
```
Failed to pull image "docker.io/zeabur/kube-watch:1.0.4": 
dial tcp 44.193.130.145:443: i/o timeout
```

**Root Cause**: WSL's internal DNS (10.255.255.254) cannot resolve `registry-1.docker.io`.

**Fix**: Use public DNS servers.

```bash
# Create resolv.conf with public DNS
sudo tee /etc/resolv.conf <<'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
```

**Note**: Set `generateResolvConf = false` in `/etc/wsl.conf` to make this persistent.

---

### Issue 2: zeabur-kube-watch CrashLoopBackOff

**Symptom**:
```
{"level":"fatal","msg":"dial tcp: lookup nats.zeabur.com: i/o timeout"}
```

**Root Cause**: The kube-watch service tries to connect to external `nats.zeabur.com` domain, but DNS cannot resolve it in a self-hosted environment.

**Fix**: Add CoreDNS rewrite rule to map `nats.zeabur.com` to the internal Kubernetes service.

```bash
# Update kube-system coredns configmap
sudo k3s kubectl patch configmap coredns -n kube-system -p '
{
  "data": {
    "Corefile": ".:53 {\n    errors\n    health\n    ready\n    kubernetes cluster.local in-addr.arpa ip6.arpa {\n      pods insecure\n      fallthrough in-addr.arpa ip6.arpa\n    }\n    hosts /etc/coredns/NodeHosts {\n      ttl 60\n      reload 15s\n      fallthrough\n    }\n    prometheus :9153\n    rewrite name regex nats\\.zeabur\\.com nats.default.svc.cluster.local\n    cache 30\n    loop\n    reload\n    loadbalance\n    import /etc/coredns/custom/*.override\n    forward . /etc/resolv.conf\n}\n    import /etc/coredns/custom/*.server"
  }
}'

# Restart CoreDNS
sudo k3s kubectl delete pod -n kube-system -l k8s-app=kube-dns
```

---

### Issue 3: NATS Authorization Violation

**Symptom**:
```
{"level":"fatal","msg":"nats: Authorization Violation"}
```

**Root Cause**: The `zeabur-kube-watch` binary does not read NATS_URL or NATS_USER/NATS_PASSWORD environment variables. The connection string appears to be hardcoded.

**Fix**: Temporarily disable NATS authentication.

```bash
# Create NATS config without auth
sudo tee /tmp/nats.conf <<'EOF'
port: 4222
pid_file: "/var/run/nats/nats.pid"
http: 8222
server_name: $POD_NAME
lame_duck_grace_period: 10s
lame_duck_duration: 30s
EOF

# Update configmap
sudo k3s kubectl create configmap nats-config -n default \
  --from-file=nats.conf=/tmp/nats.conf --dry-run=client -o yaml | \
  sudo k3s kubectl apply -f -

# Restart NATS
sudo k3s kubectl delete pod nats-0 -n default
```

**Note**: This is a workaround. The proper fix requires the Zeabur control plane to provision the correct NATS credentials for the kube-watch service.

---

### Issue 4: JetStream Stream Errors

**Symptom** (after NATS auth is disabled):
```
{"level":"error","msg":"error publishing event","error":"nats: no response from stream"}
```

**Root Cause**: The Zeabur control plane has not yet provisioned the JetStream streams and consumers required by kube-watch.

**Impact**: The kube-watch pod stays Running (1/1) despite the errors. The service is functional but cannot publish events to the control plane.

**Resolution**: 
- Wait for the Zeabur control plane to sync (usually within 5-10 minutes)
- Or click "Reinstall Zeabur Service" in the Zeabur dashboard

---

## DNS Fix

### Why WSL DNS Fails

WSL2 uses a virtualized network with an internal DNS proxy (10.255.255.254). This proxy sometimes fails to resolve external domains like `registry-1.docker.io`, causing image pull failures in k3s.

### Permanent DNS Fix

1. **Disable WSL auto-generation** of `/etc/resolv.conf`:
   ```ini
   # /etc/wsl.conf
   [network]
   generateResolvConf = false
   ```

2. **Set public DNS**:
   ```bash
   sudo tee /etc/resolv.conf <<'EOF'
   nameserver 8.8.8.8
   nameserver 1.1.1.1
   EOF
   ```

3. **Verify**:
   ```bash
   getent hosts registry-1.docker.io
   nslookup registry-1.docker.io 8.8.8.8
   ```

### Alternative: Use WSL Mirrored Mode

Windows 11 22H2+ supports mirrored networking mode where WSL shares the host's network interfaces. This can improve DNS resolution but only works for one WSL instance at a time.

```ini
# C:\Users\<user>\.wslconfig
[wsl2]
networkingMode=mirrored
```

---

## NATS Configuration

### NATS ConfigMap Structure

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nats-config
  namespace: default
data:
  nats.conf: |
    port: 4222
    pid_file: "/var/run/nats/nats.pid"
    http: 8222
    server_name: $POD_NAME
    lame_duck_grace_period: 10s
    lame_duck_duration: 30s
    # authorization: { user: admin, password: "c2accc64db0c" }
```

### NATS Authentication (Original Config)

```yaml
authorization: {
    user: admin,
    password: "c2accc64db0c"
}
```

### Checking NATS Status

```bash
# Check NATS pod
sudo k3s kubectl get pods -n default | grep nats

# Check NATS logs
sudo k3s kubectl logs nats-0 -n default

# Test NATS connection
sudo k3s kubectl exec nats-0 -n default -- \
  wget -qO- http://localhost:8222/varz
```

---

## CoreDNS Rewrite

### Understanding the Problem

The `zeabur-kube-watch` binary has a hardcoded reference to `nats.zeabur.com`. In a cloud Zeabur environment, this resolves to the Zeabur NATS cluster. In a self-hosted Wonder Mesh, we need to redirect this to the local NATS service.

### Solution: CoreDNS Rewrite Rule

The `rewrite` plugin in CoreDNS can rewrite DNS query names before resolving them.

```yaml
# In Corefile
.:53 {
    # ... other plugins ...
    rewrite name regex nats\.zeabur\.com nats.default.svc.cluster.local
    # ... other plugins ...
}
```

### How It Works

1. kube-watch queries DNS for `nats.zeabur.com`
2. CoreDNS intercepts the query
3. The `rewrite` plugin matches the regex pattern
4. The name is rewritten to `nats.default.svc.cluster.local`
5. CoreDNS resolves the rewritten name to the local NATS service IP
6. kube-watch connects to the local NATS

### Verifying the Rewrite

```bash
# From inside a pod
sudo k3s kubectl run -it --rm --restart=Never --image=busybox:1.36 nslookup \
  -- nats.zeabur.com

# Should resolve to the NATS ClusterIP (e.g., 10.43.10.121)
```

---

## Verification

### All Components Running

```bash
sudo k3s kubectl get pods -A
```

Expected output:
```
NAMESPACE     NAME                          READY   STATUS    RESTARTS   AGE
default       cadvisor-swl65                1/1     Running   0          59m
default       fluent-bit-87fch              1/1     Running   0          59m
default       ingress-controller-8n9fr      1/1     Running   0          55m
default       nats-0                        2/2     Running   0          5m
default       node-exporter-cxgw6           1/1     Running   0          59m
default       vector-aggregator-d5c7cc7d7   1/1     Running   0          55m
default       zeabur-dns-5dc4f478b4-x22b7   1/1     Running   0          59m
default       zeabur-kube-watch-b8d9dd6c9  1/1     Running   0          2m
default       zeabur-log-api-7dbd78668d     1/1     Running   0          59m
kube-system   coredns-5d5748897c-cw9rc      1/1     Running   0          47m
kube-system   metrics-server-5fd775b5fc    1/1     Running   0          59m
```

### Tailscale Mesh Status

```bash
tailscale status
```

Expected output:
```
100.64.3.1    desktop-hsbf3et                linux  -
100.64.0.1    lke505319-728018-5b5f0f5f0000  linux  -
```

### Test Gateway Connectivity

```bash
tailscale ping 100.64.0.1
```

Expected output:
```
pong from lke505319-728018-5b5f0f5f0000 (100.64.0.1) via DERP(sfo) in 203ms
```

### SSH Access

```bash
# From another machine on the Tailscale network
ssh zeabur@100.64.3.1
```

---

## Architecture

### Network Topology

```
┌─────────────────────────────────────────────────────────────────┐
│  WINDOWS HOST                                                   │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ WSL2 (Ubuntu 24.04) - wsl_test_server_001              │  │
│  │ ┌─────────────────────────────────────────────────────┐ │  │
│  │ │ Tailscale (100.64.3.1) ←→ Tailscale Mesh            │ │  │
│  │ │       ↓                                             │ │  │
│  │ │ K3s (Lightweight Kubernetes)                        │ │  │
│  │ │   ├── zeabur-kube-watch (CrashLoopBackOff fixed)    │ │  │
│  │ │   ├── nats (JetStream messaging)                    │ │  │
│  │ │   ├── zeabur-dns (CoreDNS)                          │ │  │
│  │ │   ├── vector-aggregator (Log aggregation)           │ │  │
│  │ │   ├── fluent-bit (Log collection)                   │ │  │
│  │ │   ├── cadvisor (Container metrics)                  │ │  │
│  │ │   ├── node-exporter (Node metrics)                  │ │  │
│  │ │   ├── ingress-controller (Service routing)          │ │  │
│  │ │   └── zeabur-log-api (Log API)                      │ │  │
│  │ └─────────────────────────────────────────────────────┘ │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
         │
         │ Tailscale WireGuard Tunnel
         ▼
┌─────────────────────────────────────────────────────────────────┐
│  ZEABUR CLOUD                                                   │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ Zeabur Control Plane (100.64.0.1)                       │  │
│  │   ├── NATS Cluster (Cloud)                              │  │
│  │   ├── API Gateway                                       │  │
│  │   ├── Dashboard                                         │  │
│  │   └── Deployment Manager                                │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Component Dependencies

```
zeabur-kube-watch
    ├── Requires: NATS connectivity (nats.default.svc.cluster.local:4222)
    ├── Requires: DNS resolution (CoreDNS)
    ├── Requires: Image pull (registry-1.docker.io)
    └── Publishes: Kubernetes events to NATS

zeabur-dns
    ├── Provides: DNS resolution for *.zeabur.internal
    └── Forwards: External queries to upstream DNS

coredns (kube-system)
    ├── Provides: Cluster DNS (cluster.local)
    ├── Rewrites: nats.zeabur.com → nats.default.svc.cluster.local
    └── Forwards: External queries to /etc/resolv.conf

nats
    ├── Provides: JetStream messaging
    ├── Authentication: Originally admin/c2accc64db0c (now disabled)
    └── Storage: /var/lib/rancher/k3s/storage
```

### Data Flow

1. **User deploys service** via Zeabur dashboard
2. **Control plane** sends deployment request via Tailscale mesh
3. **kube-watch** receives request, creates Kubernetes resources
4. **Pods start**, pull images from Docker Hub (requires DNS fix)
5. **Ingress controller** routes traffic to services
6. **Logs/metrics** flow through Fluent Bit → Vector → NATS → Control plane

---

## Quick Reference

### Common Commands

```bash
# Enter WSL
wsl -d wsl_test_server_001

# Check all pods
sudo k3s kubectl get pods -A

# Check specific component
sudo k3s kubectl logs -n default zeabur-kube-watch-<id> --tail=20

# Restart a deployment
sudo k3s kubectl rollout restart deploy zeabur-kube-watch -n default

# Delete a stuck pod
sudo k3s kubectl delete pod <pod-name> -n default --force --grace-period=0

# Check Tailscale
tailscale status

# Check system resources
free -h
df -h /
nproc

# Check DNS resolution
getent hosts registry-1.docker.io
getent hosts nats.default.svc.cluster.local
```

### File Locations

| File | Purpose |
|------|---------|
| `/etc/wsl.conf` | WSL configuration (systemd, network, user) |
| `/etc/resolv.conf` | DNS configuration |
| `C:\Users\<user>\.wslconfig` | Global WSL settings (memory, CPU) |
| `/etc/rancher/k3s/k3s.yaml` | Kubeconfig (requires sudo) |
| `/var/lib/rancher/k3s/` | K3s data directory |
| `/var/lib/tailscale/` | Tailscale state |

---

## Known Issues & Limitations

### 1. NATS Authentication
- The `zeabur-kube-watch` binary ignores NATS_URL/NATS_USER/NATS_PASSWORD env vars
- Workaround: Disable NATS auth (security trade-off)
- Proper fix: Requires Zeabur control plane update

### 2. JetStream Streams
- Streams are not auto-provisioned in self-hosted mode
- kube-watch logs "no response from stream" errors
- Non-critical: Pod stays Running, only event publishing is affected

### 3. WSL Memory Management
- WSL2 dynamically allocates RAM (up to 50% of host)
- For production-like workloads, set explicit limits:

```ini
# C:\Users\<user>\.wslconfig
[wsl2]
memory=8GB
processors=4
swap=2GB
autoMemoryReclaim=gradual
```

### 4. Port Forwarding
- WSL2 uses NAT; ports are not directly accessible from LAN
- Access services via Tailscale mesh IP (100.64.3.1) or localhost
- For LAN access, use WSL mirrored mode (single instance only) or port forwarding

---

## References

### Official Documentation
- [Zeabur Wonder Mesh Docs](https://zeabur.com/docs/en-US/wonder-mesh)
- [WSL2 Installation Guide](https://learn.microsoft.com/en-us/windows/wsl/install)
- [K3s Documentation](https://docs.k3s.io/)
- [Tailscale Documentation](https://tailscale.com/kb/)

### Related Articles
- [CoreDNS Rewrite Plugin](https://coredns.io/plugins/rewrite/)
- [NATS JetStream](https://docs.nats.io/nats-concepts/jetstream)
- [WSL2 Networking](https://learn.microsoft.com/en-us/windows/wsl/networking)

### Server Details
- **Server ID**: `6a23cdf424701a8493345c17`
- **Tailscale IP**: `100.64.3.1`
- **Hostname**: `desktop-hsbf3et`
- **OS**: Ubuntu 24.04 LTS (Noble)
- **Kernel**: 6.6.87.2-1
- **WSL Version**: 2.6.3.0
- **Windows Build**: 28000.1575

---

## Changelog

### 2026-06-06 - Initial Setup
- Installed WSL2 Ubuntu 24.04 (wsl_test_server_001)
- Enabled systemd in WSL
- Installed Zeabur Wonder Mesh via official script
- Tailscale connected (100.64.3.1)
- K3s installed and running
- Fixed DNS resolution (public DNS 8.8.8.8, 1.1.1.1)
- Added CoreDNS rewrite rule for nats.zeabur.com
- Disabled NATS authentication (workaround for kube-watch)
- All 10 Zeabur system components Running

---

**Status**: ✅ All Zeabur Wonder Mesh components operational  
**Dashboard**: Server should show as "Healthy"  
**Next Steps**: Deploy services from Zeabur dashboard
