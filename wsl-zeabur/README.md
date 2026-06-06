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
│   ├── troubleshooting.md             # Detailed troubleshooting guide (15 issues)
│   ├── setup-walkthrough.md           # Step-by-step setup
│   ├── architecture.md                # How Wonder Mesh works (with DNS/event flow)
│   ├── persistence.md                 # Persistence layer (apply-fixes.sh, drop-in)
│   └── reference.md                   # API endpoints, commands
├── scripts/
│   ├── diagnostics/                   # 25 diagnostic scripts
│   ├── fixes/                         # 3 fix scripts (Tailscale, CoreDNS, etc)
│   ├── sei-545/                       # 4 scripts: enable NATS JetStream + create stream
│   ├── domain/                        # 4 scripts: add/delete/list domains + manual ingress
│   ├── dns/                           # 2 scripts: pod resolv.conf + CoreDNS forward
│   ├── stalwart/                      # 1 script: get Stalwart admin password
│   ├── setup/                         # 11 Zeabur API/CLI probe scripts
│   └── verification/                  # 11 stability/verification scripts
├── config/
│   ├── wsl/                           # Windows + WSL config files
│   ├── k3s/                           # K3s/CoreDNS/NATS configmaps
│   ├── systemd/                       # Systemd unit files & scripts
│   └── dns/                           # DNS-related configs
├── persistence/                       # Files for cross-restart persistence
│   ├── apply-fixes.sh                 # Idempotent fix script (runs on every k3s start)
│   ├── install-nats-cli.sh            # nats CLI installer
│   ├── k3s.service.d-override.conf    # k3s drop-in (--resolv-conf + ExecStartPost)
│   ├── rc.local                       # WSL boot hook
│   └── bin/nats                       # nats CLI v0.4.0 binary (25MB)
├── data/                              # Current state snapshots (regenerable)
│   ├── cluster-inventory.md           # Pods, services, ingresses, PVCs
│   ├── dns-reference.md               # DNS resolution layers and CoreDNS config
│   ├── stalwart-reference.md          # Stalwart v0.11.8 API endpoints and credentials
│   └── zeabur-projects.md             # All 10 Zeabur projects in workspace
└── logs/                              # Diagnostic logs from troubleshooting
```

## Key Issues Solved

1. **DNS resolution for image pulls** — Public DNS (8.8.8.8) + immutable resolv.conf
2. **Pod DNS resolution** — Custom `/etc/k3s-pod-resolv.conf` via k3s `--resolv-conf` flag
3. **NATS JetStream disabled** — Enabled via ConfigMap patch; created KUBEWATCH stream
4. **CoreDNS forward** — `forward . 8.8.8.8 1.0.0.1 8.8.4.4` in `.:53` block
5. **CoreDNS rewrite for `nats.zeabur.com`** — Uses `kubernetes` plugin (not `forward`)
6. **Tailscale restart loop** — Disabled `Restart=on-failure`, used nohup daemon
7. **CoreDNS reversion** — apply-fixes.sh re-patches on every k3s start
8. **SEI-545 (auto-Ingress missing)** — Local JetStream + stream + consumer fix
9. **Stalwart "no WebAdmin"** — Use REST API at `/api/*` with HTTP Basic auth
10. **Fixes don't persist** — k3s drop-in unit + WSL rc.local + apply-fixes.sh

## Current Status

✅ All Zeabur system pods healthy (9 components)
✅ Tailscale stable connection to gateway (100.64.0.1)
✅ Persistent across WSL/k3s restarts (apply-fixes.sh runs on every start)
✅ DNS resolution for all Zeabur domains + public DNS
✅ Image pulls working (docker.io, ghcr.io)
✅ NATS JetStream enabled with KUBEWATCH stream + zeabur-control-plane consumer
✅ HTTPS for `yjhkbkjb.zeabur.app` working (Let's Encrypt cert obtained)
✅ Stalwart v0.11.8 accessible via REST API

## Documentation

Start with [docs/README.md](docs/README.md) — the master comprehensive document.

For new issues, see [docs/troubleshooting.md](docs/troubleshooting.md) (15 cataloged issues).

For understanding the persistence layer, see [docs/persistence.md](docs/persistence.md).

## Verification

```bash
# Quick health check
wsl -d wsl_test_server_001 -- bash -c "
  echo 'Tailscale:'; tailscale status | head -3
  echo ''; echo 'Pods:'
  sudo /usr/local/bin/kubectl get pods -n default
  echo ''; echo 'CoreDNS:'
  sudo /usr/local/bin/kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep -E 'forward|rewrite'
  echo ''; echo 'HTTPS:'
  curl -sI https://yjhkbkjb.zeabur.app/api | head -1
"
```
