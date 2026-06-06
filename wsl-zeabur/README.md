# WSL2 + Zeabur Wonder Mesh - Complete Toolkit

Comprehensive documentation, diagnostic scripts, fixes, and configuration files
for running **Zeabur Wonder Mesh** (self-hosted K3s) on **Windows WSL2 Ubuntu 24.04**.

## Server Details

- **Server ID**: `server-6a23cdf424701a8493345c17`
- **WSL Distro Name**: `wsl_test_server_001`
- **Tailscale IP**: `100.64.3.1`
- **Mesh Gateway**: `100.64.0.1` (Zeabur Wonder Mesh)
- **Hostname**: `desktop-hsbf3et`
- **OS**: Ubuntu 24.04 LTS (Noble)
- **Kernel**: 6.6.87.2-1
- **WSL Version**: 2.6.3.0
- **Windows Build**: 28000.1575

## Quick Start (TL;DR)

```powershell
# 1. Install WSL2
wsl --install -d Ubuntu-24.04
wsl --set-default Ubuntu-24.04

# 2. Apply Windows-side config
Copy-Item wsl-zeabur\config\wsl\wslconfig $env:USERPROFILE\.wslconfig
wsl --shutdown

# 3. Launch WSL and apply Linux-side config
wsl -d wsl_test_server_001
sudo tee /etc/wsl.conf < wsl-zeabur/config/wsl/wsl.conf
sudo tee /etc/resolv.conf < wsl-zeabur/config/wsl/resolv.conf
sudo chattr +i /etc/resolv.conf

# 4. Run Zeabur install script (paste from dashboard)

# 5. Apply persistent Tailscale fix
sudo bash -c "cat wsl-zeabur/config/systemd/tailscaled-override.conf > /etc/systemd/system/tailscaled.service.d/override.conf"
sudo bash -c "cat wsl-zeabur/config/systemd/start-tailscale.sh > /usr/local/bin/start-tailscale.sh"
sudo chmod +x /usr/local/bin/start-tailscale.sh
sudo bash -c "cat wsl-zeabur/config/systemd/rc.local > /etc/rc.local"
sudo bash -c "cat wsl-zeabur/config/systemd/rc-local.service > /etc/systemd/system/rc-local.service"
sudo chmod +x /etc/rc.local
sudo systemctl daemon-reload
sudo systemctl enable rc-local.service
sudo systemctl disable tailscaled
sudo /usr/local/bin/start-tailscale.sh

# 6. Apply CoreDNS rewrite
sudo k3s kubectl apply -f wsl-zeabur/config/k3s/coredns-configmap.yaml
sudo k3s kubectl rollout restart deployment coredns -n kube-system

# 7. Verify
bash wsl-zeabur/scripts/verification/final-state.sh
```

## Folder Structure

```
wsl-zeabur/
├── README.md                          # This file
├── docs/                              # Full documentation
│   ├── README.md                      # Master comprehensive document
│   ├── troubleshooting.md             # Detailed troubleshooting guide
│   ├── setup-walkthrough.md           # Step-by-step setup
│   ├── architecture.md                # How Wonder Mesh works
│   └── reference.md                   # API endpoints, commands
├── scripts/
│   ├── diagnostics/                   # 25 diagnostic scripts
│   ├── fixes/                         # 3 fix scripts (Tailscale, CoreDNS, etc)
│   ├── setup/                         # 11 Zeabur API/CLI probe scripts
│   └── verification/                  # 11 stability/verification scripts
├── config/
│   ├── wsl/                           # Windows + WSL config files
│   ├── k3s/                           # K3s/CoreDNS/NATS configmaps
│   ├── systemd/                       # Systemd unit files & scripts
│   └── dns/                           # DNS-related configs
└── logs/                              # Diagnostic logs from troubleshooting
```

## Key Issues Solved

1. **DNS resolution for image pulls** — Public DNS (8.8.8.8) + immutable resolv.conf
2. **NATS authentication** — Disabled in NATS config (kube-watch ignores env vars)
3. **CoreDNS rewrite** — `nats.zeabur.com` → `nats.default.svc.cluster.local`
4. **Tailscale restart loop** — Disabled `Restart=on-failure`, used nohup daemon
5. **CoreDNS reversion** — K3s addon reverts; need to re-apply or use auto-deploy

## Current Status

✅ All 9 Zeabur system components healthy
✅ Tailscale stable connection to gateway
✅ Persistent across WSL restarts
✅ DNS resolution for all Zeabur domains
✅ Image pulls working (docker.io, ghcr.io)
✅ Supabase stack (12 services) running successfully

## Documentation

Start with [docs/README.md](docs/README.md) — the master comprehensive document.

## Verification

```bash
# Quick health check
wsl -d wsl_test_server_001 -- bash -c "
  echo 'Tailscale:'; tailscale status | head -3
  echo ''; echo 'Pods:'
  sudo k3s kubectl get pods -n default
"
```
