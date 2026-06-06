# Troubleshooting Guide

Complete catalog of issues encountered while setting up Zeabur Wonder Mesh on WSL2,
with root cause analysis, detection, and fixes.

---

## Table of Contents

1. [Server Shows "Offline" in Dashboard](#1-server-shows-offline-in-dashboard)
2. [Tailscale Restart Loop (SIGTERM)](#2-tailscale-restart-loop-sigterm)
3. [Image Pull DNS Resolution Failure](#3-image-pull-dns-resolution-failure)
4. [CoreDNS Forward and Rewrite Reverts](#4-coredns-forward-and-rewrite-reverts)
5. [zeabur-kube-watch CrashLoopBackOff](#5-zeabur-kube-watch-crashloopbackoff)
6. [NATS Authentication Error 503](#6-nats-authentication-error-503)
7. [SEI-545: zeabur-kube-watch Cannot Publish to JetStream](#7-sei-545-zeabur-kube-watch-cannot-publish-to-jetstream)
8. [Zeabur API Returns "No such server"](#8-zeabur-api-returns-no-such-server)
9. [Wonder Mesh Gateway Cannot Reach Peer](#9-wonder-mesh-gateway-cannot-reach-peer)
10. [Container Sandbox Failure: flannel subnet.env](#10-container-sandbox-failure-flannel-subnetenv)
11. [ImagePullBackOff Due to QPS Limit](#11-imagepullbackoff-due-to-qps-limit)
12. [WSL2 Resource Limits](#12-wsl2-resource-limits)
13. [System Has Multiple init Processes](#13-system-has-multiple-init-processes)
14. [Stalwart "No WebAdmin" / 404 on /admin](#14-stalwart-no-webadmin--404-on-admin)
15. [Fixes Don't Persist Across WSL/k3s Restart](#15-fixes-dont-persist-across-wslk3s-restart)

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

## 4. CoreDNS Forward and Rewrite Reverts

### Symptoms
- You add `rewrite name regex nats\.zeabur\.com nats.default.svc.cluster.local`
  to the Corefile
- `kubectl get cm coredns -n kube-system -o jsonpath='{.data.Corefile}'` shows the rewrite
- But pods still fail with `dial tcp: lookup nats.zeabur.com: i/o timeout`
- After `systemctl restart k3s`, public DNS resolution also fails (pod name lookups like
  `api.zeabur.com` time out)

### Detection

```bash
wsl -d wsl_test_server_001 -- bash -c "
  sudo /usr/local/bin/kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep -E 'forward|rewrite'
"
```

If the output is empty or only shows `forward . /etc/resolv.conf`, the fix is missing.

### Root Cause (Two Issues)
K3s manages the CoreDNS ConfigMap via an Addon (Helm-style). When k3s starts,
the **addon manager writes the bundled template** to
`/var/lib/rancher/k3s/server/manifests/coredns.yaml`, which **overwrites your
changes** to the ConfigMap.

Two specific configurations revert:
1. **`forward . 8.8.8.8 1.0.0.1 8.8.4.4`** (in the `.:53` block) - needed for
   public DNS resolution (ACME challenges, image pulls, etc.)
2. **Rewrite block `nats.zeabur.com:53 { rewrite name exact ... }`** - needed
   for Zeabur internal service discovery

### Fix (Permanent, Idempotent)

Use `/opt/zeabur-fixes/apply-fixes.sh` to re-apply both on every k3s start.
The script runs as `ExecStartPost` in
`/etc/systemd/system/k3s.service.d/override.conf` (k3s drop-in unit).

See:
- [scripts/dns/02-fix-coredns-forward.sh](../scripts/dns/02-fix-coredns-forward.sh) - one-shot fix
- [persistence/apply-fixes.sh](../persistence/apply-fixes.sh) - persistent fix
- [docs/persistence.md](persistence.md) - how the persistence works

```bash
# Apply the persistent fix
wsl -d wsl_test_server_001 -- bash -c "sudo /opt/zeabur-fixes/apply-fixes.sh"

# Verify
wsl -d wsl_test_server_001 -- bash -c "
  sudo /usr/local/bin/kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep -E 'forward|rewrite'
"
# Expected:
#   forward . 8.8.8.8 1.0.0.1 8.8.4.4
#   rewrite name exact nats.zeabur.com nats.default.svc.cluster.local
#   ...
```

### Why the rewrite block uses `kubernetes` (not `forward`)

Early attempts failed:
- `forward . 8.8.8.8` in the rewrite block → 8.8.8.8 doesn't know about
  `*.svc.cluster.local`, returns NXDOMAIN
- `forward . /etc/resolv.conf` in the rewrite block → loops back to
  CoreDNS itself (now that `/etc/k3s-pod-resolv.conf` points to CoreDNS)

**Correct approach** uses the `kubernetes` plugin which queries the
Kubernetes API for service discovery:

```toml
nats.zeabur.com:53 {
    errors
    cache 30
    rewrite name exact nats.zeabur.com nats.default.svc.cluster.local
    kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
    }
}
```

### Why k3s manifest edits are needed (not just ConfigMap patches)

If you only `kubectl apply` a patched ConfigMap, k3s's addon manager will
revert it on the next start. The bundled manifest at
`/var/lib/rancher/k3s/server/manifests/coredns.yaml` is the source of truth.

The apply-fixes.sh script:
1. Waits 5 seconds for the manifest mtime to stabilize (k3s addon manager
   writes the bundled manifest within ~1s of startup)
2. Edits the manifest directly (so k3s auto-redeploys when it sees the mtime change)
3. Touches the manifest after editing (to force a redeploy)

### Verification

```bash
# From inside a pod
wsl -d wsl_test_server_001 -- bash -c "
  sudo /usr/local/bin/kubectl run dnstest --image=alpine --restart=Never --command -- sleep 60
  sleep 5
  sudo /usr/local/bin/kubectl exec dnstest -- nslookup nats.zeabur.com 10.43.0.10
"
# Expected: Name: nats.zeabur.com, Address: 10.43.10.121

# Public DNS
wsl -d wsl_test_server_001 -- bash -c "
  sudo /usr/local/bin/kubectl exec dnstest -- nslookup api.zeabur.com 10.43.0.10
"
# Expected: Non-authoritative answer with Cloudflare IPs
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

## 7. SEI-545: zeabur-kube-watch Cannot Publish to JetStream

### Symptoms
- `zeabur-kube-watch` pod is `1/1 Running` (not crashing) but logs show:
  - `nats: no response from stream`
  - `pods.> : no responders` / `events.> : no responders`
- Zeabur user service pods never get `DOMAIN_GENERATED` env vars populated
- No automatic Ingress is created for user service domains
- Manual `kubectl apply ingress` is required as workaround
- Public ACME challenges fail because the ingress-controller can't resolve
  `nats.zeabur.com` to publish cert requests

### Detection

```bash
# Check kube-watch logs
wsl -d wsl_test_server_001 -- bash -c "
  sudo /usr/local/bin/kubectl logs -n default -l name=zeabur-kube-watch --tail=20
"

# Check if NATS has JetStream enabled
wsl -d wsl_test_server_001 -- bash -c "
  sudo /usr/local/bin/kubectl -n default exec nats-0 -- cat /etc/nats-config/nats.conf
" 2>&1 | grep -E "jetstream|store_dir"

# Check streams on NATS
wsl -d wsl_test_server_001 -- bash -c "
  sudo /usr/local/bin/kubectl -n default exec nats-0 -- \
    /bin/sh -c 'wget -qO- http://localhost:8222/jsz?streams=true | head -100'
"
```

### Root Cause
This is **NOT the same as the original "shared upstream limit" issue**. The
local NATS server in the k3s cluster runs **without JetStream enabled** by
default. When `zeabur-kube-watch` tries to publish to JetStream streams
(`pods.>`, `events.>`, `kube.>`), the streams don't exist, so publishing
fails with "no response from stream". Without those events flowing, the
Zeabur control plane can't populate the deployment env vars needed to
auto-create Ingress objects.

### Fix (Permanent)

Enable JetStream on the local NATS, create the streams kube-watch needs,
and create a durable consumer for the Zeabur backend.

See the full script set in [scripts/sei-545/](../scripts/sei-545/):

```bash
# 1. Enable JetStream
wsl -d wsl_test_server_001 -- bash scripts/sei-545/01-enable-nats-jetstream.sh

# 2. Create the KUBEWATCH stream
wsl -d wsl_test_server_001 -- bash scripts/sei-545/02-create-jetstream-stream.sh
```

The first script:
- Patches the `nats-config` ConfigMap to add a `jetstream { store_dir: ... }` block
- Restarts the `nats-0` statefulset (data persists in PVC `nats-data-nats-0`)
- Waits for JetStream to be enabled

The second script creates:
- Stream `KUBEWATCH` with subjects `events.>`, `kube.>`, `pods.>`, `events`
- Consumer `zeabur-control-plane` (durable, filter `events.>`, explicit ack)

### Verification

```bash
# Kube-watch should now publish successfully
wsl -d wsl_test_server_001 -- bash -c "
  sudo /usr/local/bin/kubectl logs -n default -l name=zeabur-kube-watch --tail=10
"
# Should show: 'service started' with no 'no response from stream' errors

# Check stream health
wsl -d wsl_test_server_001 -- bash -c "
  sudo /usr/local/bin/kubectl -n default exec nats-0 -- \
    wget -qO- 'http://localhost:8222/jsz?streams=true' | jq '.account_details[0].stream_detail'
"

# Stream should show messages = "0" (no events yet), state = "active"
```

### Why not just wait for Zeabur's fix?
The "no response from stream" was previously blamed on the upstream
shared account limit. But once you have a local NATS with JetStream
enabled, the local NATS handles all the events and the shared upstream
isn't involved. The fix is on the local cluster, not waiting for Zeabur.

### Long-term
Once the user-service auto-Ingress pipeline works via the local
JetStream, the manual `kubectl apply ingress` workaround is no longer
required for new services.

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

## 14. Stalwart "No WebAdmin" / 404 on /admin

### Symptoms
- Browsing to `https://<domain>/admin` or `/admin/login` returns 404
- No login form, no error page — just an HTTP 404
- Stalwart log shows only `webadmin` mentioned as a separate update endpoint
- The management endpoints at `/api/*` DO work (with auth)

### Detection

```bash
# All these return 404
curl -I https://yjhkbkjb.zeabur.app/admin
curl -I https://yjhkbkjb.zeabur.app/admin/login
curl -I https://yjhkbkjb.zeabur.app/account

# But the API works
curl -I -u admin:biqEbPXFxB https://yjhkbkjb.zeabur.app/api/settings/keys
# Expected: HTTP/1.1 200 OK with JSON
```

### Root Cause
**Stalwart v0.11.8 (and earlier) does NOT bundle the WebAdmin static assets
in the Docker image.** The WebAdmin is a separate download managed via the
`/api/update/webadmin` management endpoint. By default the image only
includes the server, JMAP, and management API.

### Fix (Two Options)

**Option A: Trigger WebAdmin download (one-time)**

```bash
curl -u admin:biqEbPXFxB "https://yjhkbkjb.zeabur.app/api/update/webadmin"
# Returns: "{\"data\":\"WebAdmin update has been triggered.\"}"
# After ~30s the /admin and /account paths return 200
```

**Option B: Use the REST API directly**

All management is done via `/api/*` (HTTP Basic auth). See
[data/stalwart-reference.md](../data/stalwart-reference.md) for the full
list of endpoints.

### Verification

```bash
# List all settings via the API
curl -s -u admin:biqEbPXFxB \
    "https://yjhkbkjb.zeabur.app/api/settings/keys" | jq .

# Expected: {"data":{...}} with all server settings
```

### Caveat for v0.11.x

In v0.11.x, the config schema requires every listener to define its
protocol explicitly. The 1.0+ release changed this to a more permissive
default.

---

## 15. Fixes Don't Persist Across WSL/k3s Restart

### Symptoms
- After `systemctl restart k3s` or WSL reboot:
  - Pods can't resolve `nats.zeabur.com` again
  - `zeabur-kube-watch` starts throwing "no response from stream"
  - Public DNS resolution from pods times out
  - User service env vars are not populated
  - Manual Ingress is required for any new service

### Detection

```bash
# Check k3s service unit has the drop-in
wsl -d wsl_test_server_001 -- bash -c "
  sudo systemctl cat k3s.service | grep -A 5 'override'
"
# Expected: shows /etc/systemd/system/k3s.service.d/override.conf with
#   --resolv-conf /etc/k3s-pod-resolv.conf
#   ExecStartPost=/opt/zeabur-fixes/apply-fixes.sh

# Check apply-fixes.sh ran on last k3s start
wsl -d wsl_test_server_001 -- bash -c "
  sudo tail -50 /var/log/zeabur-fixes.log
"
# Expected: Last entry timestamp matches k3s restart time
```

### Root Cause
WSL2 does not persist Linux filesystem state across Windows reboots
in a deterministic way. Also, k3s and other services have their own
initialization order issues:

1. k3s addon manager writes bundled CoreDNS manifest at startup
   (overwriting manual ConfigMap edits)
2. WSL `/etc/resolv.conf` is regenerated by WSL launcher unless
   `generateResolvConf = false` in `wsl.conf`
3. NATS JetStream config and streams need to be re-applied if the
   data volume is reset (rare, but possible)
4. Tailscale restarts in a loop under WSL2 (covered in #2)

### Fix (Permanent)

See [docs/persistence.md](persistence.md) for the full architecture.

Quick install:

```bash
# Copy persistence files to WSL
wsl -d wsl_test_server_001 -- bash -c "
  sudo mkdir -p /opt/zeabur-fixes
  sudo cp /mnt/c/init_workstation/wsl-zeabur/persistence/apply-fixes.sh /opt/zeabur-fixes/
  sudo chmod +x /opt/zeabur-fixes/apply-fixes.sh

  # Install the k3s drop-in
  sudo mkdir -p /etc/systemd/system/k3s.service.d/
  sudo cp /mnt/c/init_workstation/wsl-zeabur/persistence/k3s.service.d-override.conf \
          /etc/systemd/system/k3s.service.d/override.conf
  sudo systemctl daemon-reload

  # Install the WSL boot hook
  sudo cp /mnt/c/init_workstation/wsl-zeabur/persistence/rc.local /etc/rc.local
  sudo chmod +x /etc/rc.local
"

# Restart k3s to test
wsl -d wsl_test_server_001 -- bash -c "sudo systemctl restart k3s"
sleep 60

# Verify all fixes are applied
wsl -d wsl_test_server_001 -- bash -c "
  sudo /usr/local/bin/kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep -E 'forward|rewrite'
  sudo /usr/local/bin/kubectl -n default get pod -l name=zeabur-kube-watch
"
```

### What apply-fixes.sh does (in order)

1. Waits for `/var/lib/rancher/k3s/server/manifests/coredns.yaml` to
   stabilize (5s no mtime change)
2. Patches `forward . 8.8.8.8 1.0.0.1 8.8.4.4` into the `.:53` block
3. Adds the `nats.zeabur.com:53` server block with rewrite + kubernetes
4. Touches the manifest to force k3s to redeploy CoreDNS
5. Verifies NATS JetStream is enabled; enables if not
6. Verifies stream `KUBEWATCH` and consumer `zeabur-control-plane` exist
7. Restarts any user service deployments to re-trigger env-var population
8. Logs everything to `/var/log/zeabur-fixes.log`

### Why a drop-in (not direct edit)?

k3s may rewrite `/etc/systemd/system/k3s.service` during package upgrades.
A drop-in at `/etc/systemd/system/k3s.service.d/override.conf` is loaded
**after** the main unit and survives main unit rewrites.

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
