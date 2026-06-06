# Troubleshooting Guide

Complete catalog of issues encountered while setting up Zeabur Wonder Mesh on WSL2,
with root cause analysis, detection, and fixes.

---

## Table of Contents

1. [Server Shows "Offline" in Dashboard](#1-server-shows-offline-in-dashboard)
2. [Tailscale Restart Loop (SIGTERM)](#2-tailscale-restart-loop-sigterm)
3. [Image Pull DNS Resolution Failure](#3-image-pull-dns-resolution-failure)
4. [CoreDNS Rewrite Reverts](#4-coredns-rewrite-reverts)
5. [zeabur-kube-watch CrashLoopBackOff](#5-zeabur-kube-watch-crashloopbackoff)
6. [NATS Authentication Error 503](#6-nats-authentication-error-503)
7. [JetStream "no response from stream"](#7-jetstream-no-response-from-stream)
8. [Zeabur API Returns "No such server"](#8-zeabur-api-returns-no-such-server)
9. [Wonder Mesh Gateway Cannot Reach Peer](#9-wonder-mesh-gateway-cannot-reach-peer)
10. [Container Sandbox Failure: flannel subnet.env](#10-container-sandbox-failure-flannel-subnetenv)
11. [ImagePullBackOff Due to QPS Limit](#11-imagepullbackoff-due-to-qps-limit)
12. [WSL2 Resource Limits](#12-wsl2-resource-limits)
13. [System Has Multiple init Processes](#13-system-has-multiple-init-processes)

---

## 1. Server Shows "Offline" in Dashboard

### Symptoms
- Server visible in Zeabur dashboard → Servers
- Status shows "Offline" or "Disconnected"
- Tailscale mesh shows local IP but no stable connection to gateway
- All system pods may still be Running locally

### Detection

```bash
# Run from WSL
wsl -d wsl_test_server_001 -- bash -c "
  tailscale status 2>&1
  echo '---'
  systemctl status tailscaled --no-pager | head -5
"
```

Expected good output:
```
100.64.3.1  desktop-hsbf3et  ...
100.64.0.1  ...              active; relay "sfo", tx <bytes> rx <bytes>
```

Expected bad output:
```
unexpected state: NoState
no current Tailscale IPs
```

### Root Cause
The most common cause is the **Tailscale restart loop** (see #2). When tailscaled
keeps restarting, the Wonder Mesh gateway never gets a stable connection to this peer,
so the control plane reports the server as offline.

Secondary causes:
- NATS 503 incident (SEI-545) - dashboard will auto-recover
- Wonder Mesh gateway can't reach this peer (SEI-548) - network/tunnel issue
- Server was deleted from Zeabur's backend (check `curl GraphQL server(_id:...)`)

### Fix
See #2 (Tailscale restart loop) for the primary fix. If that's not the cause,
try [Reinstall Zeabur Service] button in the dashboard.

---

## 2. Tailscale Restart Loop (SIGTERM)

### Symptoms
- `tailscaled` starts, connects, gets mesh IP
- 30-60s later: `tailscaled got signal terminated; shutting down`
- Cycle repeats indefinitely
- `Restart=on-failure` in systemd unit triggers restart

### Detection

```bash
wsl -d wsl_test_server_001 -- bash -c "
  sudo journalctl -u tailscaled --no-pager 2>&1 | grep 'signal terminated' | wc -l
  echo 'Restart count in last hour:'
  sudo journalctl -u tailscaled --since '1 hour ago' --no-pager 2>&1 | grep -c 'Starting tailscaled'
"
```

If the restart count is high (10+) in an hour, you have this issue.

### Root Cause
WSL2's launcher init process (PID 2, `/init`) sends `SIGTERM` to systemd services
when the network interface resets. The default Tailscale systemd unit uses
`Restart=on-failure`, which causes a tight restart loop. Each restart breaks
the Wonder Mesh control plane's persistent connection to the gateway.

The network resets happen when:
- WSL starts/stops
- Windows wakes from sleep
- VPN connects/disconnects
- DNS configuration changes (this is what broke our setup the first time!)

### Fix (Persistent)

See [scripts/fixes/persist-tailscale.sh](../scripts/fixes/persist-tailscale.sh) for
the full implementation.

```bash
# 1. Create systemd override to prevent auto-restart
sudo mkdir -p /etc/systemd/system/tailscaled.service.d/
sudo tee /etc/systemd/system/tailscaled.service.d/override.conf <<EOF
[Service]
Restart=no
RestartSec=60s
KillMode=process
TimeoutStopSec=120s
EOF

# 2. Disable and stop systemd-managed tailscaled
sudo systemctl daemon-reload
sudo systemctl disable tailscaled
sudo systemctl stop tailscaled

# 3. Create persistent auto-start script
sudo tee /usr/local/bin/start-tailscale.sh <<'SCRIPT'
#!/bin/bash
sleep 5
if pgrep -f "/usr/sbin/tailscaled" > /dev/null; then exit 0; fi
nohup /usr/sbin/tailscaled \
  --state=/var/lib/tailscale/tailscaled.state \
  --socket=/run/tailscale/tailscaled.sock \
  --port=41641 \
  > /var/log/tailscaled.log 2>&1 &
SCRIPT
sudo chmod +x /usr/local/bin/start-tailscale.sh

# 4. Wire to systemd via rc-local
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

# 5. Start it now
sudo /usr/local/bin/start-tailscale.sh
sleep 30
tailscale status
```

### Verification

```bash
# Should show stable connection with data flow
wsl -d wsl_test_server_001 -- bash -c "tailscale status 2>&1 | head -5"
# Expected: 100.64.0.1 ... active; relay "sfo", tx <increasing> rx <increasing>
```

---

## 3. Image Pull DNS Resolution Failure

### Symptoms
- Pod stuck in `ImagePullBackOff` or `ErrImagePull`
- `dial tcp: lookup registry-1.docker.io: i/o timeout` in pod events
- `dial tcp: lookup ghcr.io: i/o timeout` for Zeabur system images
- Image pull works from WSL host but not from inside k3s pods

### Detection

```bash
# From inside a pod
sudo k3s kubectl run dnstest --rm -i --image=busybox --restart=Never -- nslookup registry-1.docker.io
```

If this times out but `getent hosts registry-1.docker.io` works from WSL, the issue
is the pod's resolv.conf or the kubelet's `--resolv-conf` setting.

### Root Cause
WSL2 uses an internal DNS proxy at `10.255.255.254` which sometimes fails to
resolve external domains when many concurrent queries come from k3s pods.

Additionally, k3s passes `--resolv-conf /etc/resolv.kubelet.conf` to kubelet, which
is generated by k3s based on the host's resolv.conf.

### Fix (Multi-Layer)

**Layer 1: Disable WSL auto-generation of /etc/resolv.conf**

Edit `/etc/wsl.conf`:
```ini
[network]
generateResolvConf = false
```

**Layer 2: Use public DNS servers**

Replace `/etc/resolv.conf`:
```
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 9.9.9.9
```

**Layer 3: Make resolv.conf immutable**

```bash
sudo chattr +i /etc/resolv.conf
```

This prevents WSL and systemd-resolved from overwriting your config.

**Layer 4 (Optional): DNS Tunneling**

Edit `C:\Users\<user>\.wslconfig`:
```ini
[wsl2]
dnsTunneling=true
```

⚠️ **WARNING**: We tested this and it CAUSED the Tailscale restart loop! Don't enable
it unless you have a different problem.

### Verification

```bash
# Test from host
getent hosts registry-1.docker.io
getent hosts ghcr.io

# Test from inside pod
sudo k3s kubectl run dnstest --rm -i --image=busybox --restart=Never -- nslookup ghcr.io
```

---

## 4. CoreDNS Rewrite Reverts

### Symptoms
- You add the rewrite: `rewrite name regex nats\.zeabur\.com nats.default.svc.cluster.local`
- `kubectl get cm coredns -n kube-system -o jsonpath='{.data.Corefile}'` shows the rewrite
- But pods still fail with `dial tcp: lookup nats.zeabur.com: i/o timeout`
- `kubectl.kubernetes.io/last-applied-configuration` annotation has the rewrite, but the live config doesn't

### Detection

```bash
sudo k3s kubectl get cm coredns -n kube-system -o jsonpath='{.data.Corefile}' | grep rewrite
```

If empty, the rewrite is missing from the live config.

### Root Cause
K3s manages the CoreDNS ConfigMap via an Addon (Helm-style). When k3s restarts
the CoreDNS pod, it **re-applies the addon template** which **overwrites your
changes** to the ConfigMap.

### Fix (Two Options)

**Option A: Re-apply after every k3s restart (manual)**

```bash
sudo k3s kubectl apply -f wsl-zeabur/config/k3s/coredns-configmap.yaml
sudo k3s kubectl rollout restart deployment coredns -n kube-system
```

**Option B: Use k3s auto-deploy manifests (permanent)**

Place the file at `/var/lib/rancher/k3s/server/manifests/` and k3s will deploy it
on every startup:

```bash
sudo mkdir -p /var/lib/rancher/k3s/server/manifests/
sudo cp wsl-zeabur/config/k3s/coredns-rewrite-autodeploy.yaml /var/lib/rancher/k3s/server/manifests/
```

The `import /etc/coredns/custom/*.server` line in the Corefile will pick this up.

### Verification

```bash
# From inside a pod
sudo k3s kubectl run dnstest --rm -i --image=busybox --restart=Never -- nslookup nats.zeabur.com
# Should resolve to nats.default.svc.cluster.local
```

---

## 5. zeabur-kube-watch CrashLoopBackOff

### Symptoms
- `zeabur-kube-watch` pod stuck in `CrashLoopBackOff`
- Pod restart count keeps increasing (15+ restarts)
- Logs show: `dial tcp: lookup nats.zeabur.com: i/o timeout`
- Or: `nats: API error: code=503 err_code=10023 description=insufficient resources`

### Detection

```bash
sudo k3s kubectl get pods -n default -l name=zeabur-kube-watch
sudo k3s kubectl logs -l name=zeabur-kube-watch -n default --tail=20
```

### Root Cause
Two possible causes:
1. DNS can't resolve `nats.zeabur.com` → fix with #4 (CoreDNS rewrite)
2. NATS authentication required but kube-watch doesn't send credentials → fix with #6 (NATS auth)

### Fix
1. Apply the CoreDNS rewrite (fix #4)
2. Disable NATS auth (fix #6)
3. Restart the pod:
   ```bash
   sudo k3s kubectl delete pod -l name=zeabur-kube-watch -n default
   ```

---

## 6. NATS Authentication Error 503

### Symptoms
- `zeabur-kube-watch` logs: `nats: API error: code=503`
- NATS pod has authentication enabled
- kube-watch uses hardcoded credentials that don't match

### Detection

```bash
# Get current NATS config
sudo k3s kubectl get cm nats-config -n default -o jsonpath='{.data.nats\.conf}'
```

Look for `authorization: { user: ..., password: ... }` block.

### Root Cause
The `zeabur-kube-watch:1.0.4` binary has hardcoded NATS credentials (`zeabur-kube-watch:c2accc64db0c`) that don't match the NATS config in the cluster. The binary ignores the `NATS_URL`, `NATS_USER`, and `NATS_PASSWORD` environment variables.

### Fix
Disable authentication in the NATS ConfigMap:

```bash
sudo k3s kubectl apply -f wsl-zeabur/config/k3s/nats-configmap.yaml
sudo k3s kubectl rollout restart statefulset nats -n default
```

The new config removes the `authorization` block, so NATS accepts all connections.

---

## 7. JetStream "no response from stream"

### Symptoms
- `zeabur-kube-watch` pod is `1/1 Running` (not crashing)
- Logs show: `nats: no response from stream` repeated many times
- Pod keeps restarting (or restart count is high but status is Running)

### Detection

```bash
sudo k3s kubectl logs -l name=zeabur-kube-watch -n default --tail=50 | grep -c "no response from stream"
```

### Root Cause
**Known Zeabur incident (SEI-545)**: The shared NATS JetStream account used by
`zeabur-kube-watch` has hit the upstream stream limit. This is **NOT a user-fixable
issue** - it's on Zeabur's side.

### Status
The pod stays `Running` and continues to work, just with errors logged. These
errors are non-critical and will resolve automatically when Zeabur fixes the
upstream issue.

### Workaround
None needed - the dashboard will auto-recover. See [Zeabur forum thread](https://zeabur.com/forum/posts/6a004af6c0bbffb242e69776).

---

## 8. Zeabur API Returns "No such server"

### Symptoms
- Server visible in Zeabur dashboard
- GraphQL query `server(_id: "server-XXX")` returns `NOT_FOUND`
- `tailscale status` shows server is connected to mesh

### Detection

```bash
curl -s -X POST https://api.zeabur.com/graphql \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query":"query { server(_id: \"server-XXX\") { _id name } }"}'
```

### Root Cause
The server was either:
- Auto-deleted by Zeabur (likely if mesh was down for too long)
- Belongs to a different workspace/account

### Fix
1. Verify you're in the correct workspace: `npx zeabur workspace list`
2. If the server is gone, recreate it via the dashboard

---

## 9. Wonder Mesh Gateway Cannot Reach Peer

### Symptoms
- Tailscale shows local peer as `online` but `vm-2` (gateway) shows as `offline`
- `tailscale ping 100.64.0.1` fails or hangs
- SSH over mesh times out

### Detection

```bash
sudo tailscale ping 100.64.0.1 -c 3
```

### Root Cause
**Known Zeabur issue (SEI-548)**: Sometimes the WireGuard tunnel from Zeabur's
gateway to a peer doesn't establish. This can happen after:
- Peer is restarted
- Network changes
- Mesh ID changes (re-running the install script)

### Fix (Cleanest Reset)

1. On your local box, uninstall Tailscale:
   ```bash
   sudo tailscale logout
   sudo apt remove tailscale
   ```

2. In Zeabur Dashboard → Servers → delete this Wonder Mesh server

3. Create a new Wonder Mesh server in Dashboard → run the install script fresh

This gives a clean Tailscale machine identity and fresh mesh registration.

---

## 10. Container Sandbox Failure: flannel subnet.env

### Symptoms
- User services stuck in `ContainerCreating`
- Events show: `Failed to create pod sandbox: rpc error: code = Unknown desc = failed to setup network for sandbox "...": plugin type="flannel" failed (add): failed to load flannel 'subnet.env' file: open /run/flannel/subnet.env: no such file or directory`

### Detection

```bash
sudo k3s kubectl get events -A | grep flannel
```

### Root Cause
After WSL restart, k3s's flannel CNI doesn't have its subnet.env file, but
existing pods still try to use it.

### Fix
Restart the k3s service:

```bash
sudo systemctl restart k3s
```

Or wait for k3s to self-heal (it usually does within 1-2 minutes).

---

## 11. ImagePullBackOff Due to QPS Limit

### Symptoms
- Pod in `CrashLoopBackOff` keeps trying to pull the image
- Pod events: `Failed to pull image "X": pull QPS exceeded`
- Backoff timer increases

### Detection

```bash
sudo k3s kubectl describe pod <pod-name> | grep -i qps
```

### Root Cause
Docker Hub has rate limits (~100 pulls per 6 hours per IP for anonymous). When
a pod restarts too fast, it exceeds the rate limit.

### Fix
1. Fix the underlying crash (e.g., CoreDNS rewrite for kube-watch)
2. Once the pod runs successfully, the QPS issue resolves
3. Or use a registry mirror in `/etc/rancher/k3s/registries.yaml`

---

## 12. WSL2 Resource Limits

### Symptoms
- Tailscale OOM kills
- k3s pods evicted: `Evicted` status
- WSL VM uses all host memory

### Detection

```bash
free -h
cat /sys/fs/cgroup/system.slice/tailscaled.service/memory.max
```

### Fix
Edit `C:\Users\<user>\.wslconfig`:

```ini
[wsl2]
memory=8GB
processors=4
swap=2GB
```

Then `wsl --shutdown` to apply.

**Note**: k3s runs with aggressive defaults:
- `eviction-hard=memory.available<16Mi`
- `kube-reserved=cpu=250m,memory=512Mi`
- `system-reserved=cpu=250m,memory=512Mi`

So you need at least 1GB + k3s memory + user workloads.

---

## 13. System Has Multiple init Processes

### Expected
```
PID 1: /sbin/init (systemd)
```

### Actual in WSL2
```
PID 1: /sbin/init (systemd in WSL)
PID 2: /init (WSL launcher)
```

### Why This Matters
The WSL launcher (PID 2) is the parent of all init processes and may send SIGTERM
to its children when network interfaces change. This is the root cause of the
Tailscale restart loop (see #2).

### Workaround
None - this is a WSL2 design decision. The workaround is to use detached
processes (nohup) instead of systemd services for long-running daemons.

---

## Diagnostic Scripts Reference

| Script | Purpose | When to Use |
|--------|---------|-------------|
| [check-mesh.sh](../scripts/diagnostics/check-mesh.sh) | Tailscale + SSH + Zeabur state | First check when server offline |
| [check-tailscaled.sh](../scripts/diagnostics/check-tailscaled.sh) | Tailscale daemon logs | Tailscale not connecting |
| [check-systemd.sh](../scripts/diagnostics/check-systemd.sh) | Systemd unit config | Tailscale restarting |
| [check-state.sh](../scripts/diagnostics/check-state.sh) | State files + Zeabur registration | Auth/registration issues |
| [check-tunnel.sh](../scripts/diagnostics/check-tunnel.sh) | SSH + mesh IP listening | Can't SSH over mesh |
| [check-kube-watch.sh](../scripts/diagnostics/check-kube-watch.sh) | zeabur-kube-watch pod state | System health alert |
| [check-pod-dns.sh](../scripts/diagnostics/check-pod-dns.sh) | DNS from inside pods | Image pull failures |
| [check-dns-rewrite.sh](../scripts/diagnostics/check-dns-rewrite.sh) | CoreDNS rewrite status | kube-watch DNS errors |
| [check-nats-auth.sh](../scripts/diagnostics/check-nats-auth.sh) | NATS auth state | 503 errors |
| [find-sigterm.sh](../scripts/diagnostics/find-sigterm.sh) | SIGTERM source detection | Restart loop diagnosis |
| [mem-check.sh](../scripts/diagnostics/mem-check.sh) | Memory pressure check | OOM kills |
| [long-watch.sh](../scripts/verification/long-watch.sh) | 5-minute stability monitor | Verify stability |

## Verification Scripts Reference

| Script | Purpose | When to Use |
|--------|---------|-------------|
| [verify-online.sh](../scripts/verification/verify-online.sh) | All system pods + Tailscale | After applying fixes |
| [verify-dns.sh](../scripts/verification/verify-dns.sh) | All DNS resolutions | After DNS changes |
| [final-state.sh](../scripts/verification/final-state.sh) | Final comprehensive check | Before reporting "done" |
| [stability-check.sh](../scripts/verification/stability-check.sh) | 90-second stability | Quick stability test |
| [long-watch.sh](../scripts/verification/long-watch.sh) | 5-minute stability monitor | Deep stability test |
| [test-autostart.sh](../scripts/verification/test-autostart.sh) | Test auto-start works | After Tailscale fix |
