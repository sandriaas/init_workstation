# Scripts Index

~60 bash scripts across 8 categories for diagnosing, fixing, verifying,
and operating your WSL2 + Zeabur Wonder Mesh setup.

> **All scripts must be run from inside WSL2** (not from Windows PowerShell).
> Mount the `wsl-zeabur/` folder at `/mnt/c/init_workstation/wsl-zeabur` and run
> scripts from there, or copy them into `/usr/local/bin/`.

---

## Diagnostics (25 scripts)

Read-only scripts that inspect system state and output findings.

| Script | Purpose |
|--------|---------|
| [check-dns-rewrite.sh](diagnostics/check-dns-rewrite.sh) | Verify CoreDNS rewrite for `nats.zeabur.com` is active |
| [check-kube-watch.sh](diagnostics/check-kube-watch.sh) | Inspect `zeabur-kube-watch` pod state, restarts, env |
| [check-mesh.sh](diagnostics/check-mesh.sh) | Verify Tailscale mesh connectivity to gateway |
| [check-nats-auth.sh](diagnostics/check-nats-auth.sh) | Check NATS authentication configuration |
| [check-pod-dns.sh](diagnostics/check-pod-dns.sh) | Verify pod DNS resolution works (kubectl exec nslookup) |
| [check-restart-cause.sh](diagnostics/check-restart-cause.sh) | Find why a pod keeps restarting |
| [check-state.sh](diagnostics/check-state.sh) | Snapshot of tailscaled + systemd + k3s state |
| [check-state2.sh](diagnostics/check-state2.sh) | Extended state with journal and pod list |
| [check-systemd.sh](diagnostics/check-systemd.sh) | List systemd units and their states |
| [check-tailscaled.sh](diagnostics/check-tailscaled.sh) | Check tailscaled process and state file |
| [check-tunnel.sh](diagnostics/check-tunnel.sh) | Verify WireGuard tunnel to gateway is up |
| [debug-kube-watch.sh](diagnostics/debug-kube-watch.sh) | Deep dive on kube-watch logs and config |
| [deep-state.sh](diagnostics/deep-state.sh) | Full system state: tailscale, k3s, dns, memory, cpu |
| [dns-test.sh](diagnostics/dns-test.sh) | Test DNS resolution for known hosts |
| [find-killer.sh](diagnostics/find-killer.sh) | Find which process is sending signals to tailscaled |
| [find-sigterm.sh](diagnostics/find-sigterm.sh) | Search journal for SIGTERM source |
| [get-deploy-yaml.sh](diagnostics/get-deploy-yaml.sh) | Export deployment YAML to /tmp |
| [get-kube-logs.sh](diagnostics/get-kube-logs.sh) | Get logs from all system pods |
| [journal-now.sh](diagnostics/journal-now.sh) | Recent journal entries for tailscaled |
| [logs2.sh](diagnostics/logs2.sh) | Alternative log fetcher (k3s crictl) |
| [mem-check.sh](diagnostics/mem-check.sh) | Check memory pressure and OOM events |
| [reinstall-check.sh](diagnostics/reinstall-check.sh) | Verify Zeabur install is intact |
| [wonder-check.sh](diagnostics/wonder-check.sh) | Test wonder binary and control plane |
| [wonder-config.sh](diagnostics/wonder-config.sh) | Show wonder configuration |

---

## Fixes (3 scripts)

Mutating scripts that repair known issues.

| Script | Purpose |
|--------|---------|
| [fix-tailscale.sh](fixes/fix-tailscale.sh) | Apply Tailscale restart-loop fix (one-time) |
| [persist-tailscale.sh](fixes/persist-tailscale.sh) | Make Tailscale fix survive WSL restarts |
| [apply-coredns.sh](fixes/apply-coredns.sh) | Re-apply CoreDNS rewrite ConfigMap (after k3s reverts) |

---

## SEI-545 (JetStream + Stream) (4 scripts)

Enable local NATS JetStream and create the KUBEWATCH stream so
`zeabur-kube-watch` can publish events and user services get env
vars populated.

| Script | Purpose |
|--------|---------|
| [01-enable-nats-jetstream.sh](sei-545/01-enable-nats-jetstream.sh) | Patch NATS ConfigMap to enable JetStream, restart statefulset |
| [02-create-jetstream-stream.sh](sei-545/02-create-jetstream-stream.sh) | Create the KUBEWATCH stream + zeabur-control-plane consumer |
| [03-create-stream.js](sei-545/03-create-stream.js) | Node.js helper to create the stream (called by 02) |
| [04-create-consumer.js](sei-545/04-create-consumer.js) | Node.js helper to create the consumer (called by 02) |

Order of execution:
```bash
wsl -d wsl_test_server_001 -- bash -c "bash /mnt/c/init_workstation/wsl-zeabur/scripts/sei-545/01-enable-nats-jetstream.sh"
wsl -d wsl_test_server_001 -- bash -c "bash /mnt/c/init_workstation/wsl-zeabur/scripts/sei-545/02-create-jetstream-stream.sh"
```

---

## Domain (4 scripts)

Manage Zeabur-generated domains for user services (and create manual
Ingress objects as a workaround for the auto-Ingress SEI-545 issue).

| Script | Purpose |
|--------|---------|
| [01-add-domain.sh](domain/01-add-domain.sh) | Generate a new Zeabur domain for a service |
| [02-create-ingress.sh](domain/02-create-ingress.sh) | Manually create a k3s Ingress object (workaround for SEI-545) |
| [03-delete-domain.sh](domain/03-delete-domain.sh) | Delete a domain (and its Ingress) |
| [04-list-domains.sh](domain/04-list-domains.sh) | List all domains on a service |

Example:
```bash
wsl -d wsl_test_server_001 -- bash -c "
  bash /mnt/c/init_workstation/wsl-zeabur/scripts/domain/01-add-domain.sh \
    <SERVICE_ID> <ENV_ID> [--custom example.com]
"
```

---

## DNS (2 scripts)

Apply DNS fixes for the cluster (k3s pod resolv.conf + CoreDNS
forward + nats.zeabur.com rewrite block).

| Script | Purpose |
|--------|---------|
| [01-create-pod-resolv-conf.sh](dns/01-create-pod-resolv-conf.sh) | Create `/etc/k3s-pod-resolv.conf` and install k3s drop-in |
| [02-fix-coredns-forward.sh](dns/02-fix-coredns-forward.sh) | Patch CoreDNS forward directive and add nats.zeabur.com rewrite block |

Note: These are the one-shot versions. For persistence, use
`/opt/zeabur-fixes/apply-fixes.sh` (installed from
`persistence/apply-fixes.sh`).

---

## Stalwart (1 script)

Helpers for the Stalwart Mail Server v0.11.8 service.

| Script | Purpose |
|--------|---------|
| [01-get-credentials.sh](stalwart/01-get-credentials.sh) | Get the admin password from container logs + service password from settings |

---

## Setup (11 scripts)

One-time install/config scripts and Zeabur API probes.

| Script | Purpose |
|--------|---------|
| [check-deploy.sh](setup/check-deploy.sh) | Check current Zeabur deployment status |
| [check-ws.sh](setup/check-ws.sh) | Check Zeabur WebSocket connectivity |
| [get-deploy.sh](setup/get-deploy.sh) | Get latest deployment info via API |
| [probe-graphql.sh](setup/probe-graphql.sh) | Probe Zeabur GraphQL endpoint |
| [zeabur-cli.sh](setup/zeabur-cli.sh) | Wrapper for `npx zeabur@latest` |
| [zeabur-introspect.sh](setup/zeabur-introspect.sh) | Introspect Zeabur installation |
| [zeabur-introspect2.sh](setup/zeabur-introspect2.sh) | Extended introspect |
| [zeabur-me.sh](setup/zeabur-me.sh) | Get current Zeabur user info via API |
| [zeabur-server.sh](setup/zeabur-server.sh) | Get server info via API |
| [zeabur-server2.sh](setup/zeabur-server2.sh) | Extended server info |
| [zeabur-svcs.sh](setup/zeabur-svcs.sh) | List services in current project |

---

## Verification (11 scripts)

End-to-end tests that confirm the setup is healthy and stable.

| Script | Purpose |
|--------|---------|
| [final-check.sh](verification/final-check.sh) | Comprehensive final health check |
| [final-state.sh](verification/final-state.sh) | Final stable state snapshot |
| [long-watch.sh](verification/long-watch.sh) | Watch system for 5+ minutes, log all changes |
| [stability-check.sh](verification/stability-check.sh) | 30-second stability test of pods |
| [test-autostart.sh](verification/test-autostart.sh) | Verify services auto-start after WSL restart |
| [verify-dns.sh](verification/verify-dns.sh) | Verify DNS for all critical domains |
| [verify-online.sh](verification/verify-online.sh) | Confirm server is "Online" in dashboard |
| [wait-log.sh](verification/wait-log.sh) | Wait for specific log line to appear |
| [wait-pod.sh](verification/wait-pod.sh) | Wait for pod to be Running |
| [watch-restart.sh](verification/watch-restart.sh) | Watch pod restart counter |
| [watch-tail.sh](verification/watch-tail.sh) | Tail logs with filtering |

---

## Common Patterns

### Run a script from WSL

```bash
# After mounting the repo
wsl -d wsl_test_server_001

# Copy the folder into WSL home for easier access
cp -r /mnt/c/init_workstation/wsl-zeabur ~/wsl-zeabur

# Run a script
bash ~/wsl-zeabur/scripts/diagnostics/check-mesh.sh
```

### Run a script from Windows (one-liner)

```powershell
wsl -d wsl_test_server_001 -- bash -c "bash /mnt/c/init_workstation/wsl-zeabur/scripts/diagnostics/check-mesh.sh"
```

### Run a script with sudo

```bash
sudo bash ~/wsl-zeabur/scripts/diagnostics/deep-state.sh
```

---

## Script Conventions

All scripts:

- Are `bash` (not `sh`, `zsh`, etc.)
- Use `set -euo pipefail` for safety
- Echo colored output (red=error, green=ok, yellow=warn, blue=info)
- End with a summary line `STATUS: OK` or `STATUS: FAIL`
- Are idempotent (safe to run multiple times)
- Don't require arguments (use env vars or interactive prompts)

To run a single script, just `bash <path>`.
To run an entire category, use a glob:

```bash
for s in ~/wsl-zeabur/scripts/diagnostics/*.sh; do echo "=== $s ==="; bash "$s"; done
```

---

## Adding a New Script

1. Pick the right category (diagnostics, fixes, setup, verification, sei-545, domain, dns, stalwart)
2. Use the conventions above
3. Add it to this README under the right table
4. Make sure it's executable: `chmod +x scripts/<category>/<name>.sh`
5. Update the count at the top of this file

---

## Script Source

The originals live at `C:\Users\Sandria\AppData\Local\Temp\opencode\*.sh`
(ephemeral). The canonical copies are now in this folder for permanence.
