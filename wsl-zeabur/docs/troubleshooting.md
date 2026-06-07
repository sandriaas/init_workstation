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
16. [Zeabur-Generated Domain Not Publicly Accessible](#16-zeabur-generated-domain-not-publicly-accessible)
17. [Sub-Subdomain Wildcard SSL Fails on Cloudflare Free](#17-sub-subdomain-wildcard-ssl-fails-on-cloudflare-free)
18. [KUBEWATCH Consumer Filter `events.>` Matches Nothing](#18-kubewatch-consumer-filter-events-matches-nothing)
19. [Public URL Returns 530/502 Every k3s Restart](#19-public-url-returns-530502-every-k3s-restart)
20. [WSL2 VM Keeps Shutting Down (vmIdleTimeout / Modern Standby)](#20-wsl2-vm-keeps-shutting-down-vmidletimeout--modern-standby)

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
   with the **correct filter `>`** (recreates if filter is wrong)
7. Re-creates any `PUBLIC_EXPOSURES` Ingresses (Cloudflare Tunnel pattern)
8. Restarts workloads to pick up the new resolv.conf
9. Logs everything to `/var/log/zeabur-fixes.log`

### Why a drop-in (not direct edit)?

k3s may rewrite `/etc/systemd/system/k3s.service` during package upgrades.
A drop-in at `/etc/systemd/system/k3s.service.d/override.conf` is loaded
**after** the main unit and survives main unit rewrites.

---

## 16. Zeabur-Generated Domain Not Publicly Accessible

### Symptoms

- `curl https://<service>-<id>.zeabur.app/` times out from any device NOT on Tailscale
- `dig <service>-<id>.zeabur.app` returns `100.64.3.1` (Tailscale IP)
- ACME challenges fail (HTTP-01 never reaches WSL)
- Dashboard shows domain as `PROVISIONING` forever

### Detection

```bash
# From any device, look up the auto-generated domain
nslookup stalwart-2932989.zeabur.app
# Server:  dns.google
# Address:  8.8.8.8
#
# Non-authoritative answer:
# Name:    stalwart-2932989.zeabur.app
# Address:  100.64.3.1   <-- Tailscale IP, NOT publicly routable

# The wildcard *.zeabur.app points to AWS Global Accelerator
dig +short zeabur.app
# 52.223.32.133

# But the per-service subdomain is a CNAME to a Tailscale-only IP
dig +short stalwart-2932989.zeabur.app
# 100.64.3.1
```

### Root Cause

Two issues, both architectural in Zeabur's WSL setup:

1. **Per-service subdomains CNAME to Tailscale IP** (`100.64.3.1`):
   Only devices on the Tailscale mesh (including Zeabur's gateway at
   `100.64.0.1`) can reach the WSL. This is by design — Zeabur uses
   Tailscale for control plane communication, but it inadvertently makes
   the public domain also Tailscale-only.
2. **Wildcard `*.zeabur.app` points to AWS Global Accelerator**:
   `52.223.32.133` is an anycast IP that should route to Zeabur's edge.
   But the per-service subdomain overrides the wildcard with a CNAME to
   the Tailscale IP, so the public edge never sees requests for that
   subdomain.
3. **WSL public IP is behind a home router**: `182.253.129.75` (BIZNET,
   Bali) port 443 is not port-forwarded. So even if the CNAME pointed
   there, it wouldn't work.

### Fix (Use Cloudflare Tunnel)

We add a parallel public exposure via Cloudflare Tunnel. See
[setup-walkthrough.md Step 11](setup-walkthrough.md#step-11-expose-a-service-to-the-public-internet)
for full setup. Short version:

```bash
# 1. Install cloudflared
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared noble main' | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt update && sudo apt install -y cloudflared

# 2. Place credentials (chmod 600) and config at /etc/cloudflared/

# 3. Enable the systemd service (see config/systemd/cloudflared.service)
sudo systemctl enable --now cloudflared

# 4. Add wildcard CNAME in Cloudflare DNS:
#    *.cfworkers.dpdns.org CNAME <TUNNEL_ID>.cfargotunnel.com (proxied)

# 5. Create an Ingress for your service:
sudo /opt/zeabur-fixes/expose-service.sh stalwart environment-XXX service-XXX 8080
# => https://stalwart.cfworkers.dpdns.org is now publicly accessible
```

### Verification

```bash
# Public access from any device
curl -I https://stalwart.cfworkers.dpdns.org/admin
# Expected: HTTP/2 302 (Stalwart WebUI redirect)

# Tunnel health
sudo systemctl status cloudflared
# Expected: Active: active (running), 4 connections to Cloudflare SIN edge

# Ingress exists in k8s
sudo kubectl -n environment-XXX get ing stalwart-cfworkers
# Expected: HOSTS = stalwart.cfworkers.dpdns.org, ADDRESS = 172.29.155.146
```

### Caveat

This does **NOT** fix `*.zeabur.app` domains. Those remain Tailscale-only.
The Cloudflare Tunnel gives you a parallel public URL that works from
any device.

---

## 17. Sub-Subdomain Wildcard SSL Fails on Cloudflare Free

### Symptoms

- `*.example.com` works fine (one-level wildcard)
- `*.sub.example.com` returns `ERR_SSL_VERSION_OR_CIPHER_MISMATCH` in browsers
- `openssl s_client -connect sub.example.com:443` returns `SSL alert 40`

### Detection

```bash
# One-level wildcard: works
openssl s_client -connect foo.example.com:443 -servername foo.example.com < /dev/null 2>&1 | grep -E "subject|verify return"
# subject=CN = *.example.com
# Verify return code: 0 (ok)

# Sub-subdomain: fails
openssl s_client -connect foo.sub.example.com:443 -servername foo.sub.example.com < /dev/null 2>&1 | grep -E "subject|verify return"
# SSL alert 40 (no certificate matches)
```

### Root Cause

Cloudflare's **Universal SSL** on the Free plan covers:
- Apex domain: `example.com`
- Single-level wildcard: `*.example.com`

It does **NOT** cover sub-subdomain wildcards (`*.sub.example.com`). You
need an Advanced Certificate Manager subscription for that, or you can
use a one-level wildcard pattern with a different naming scheme.

### Fix

Use a **one-level wildcard** with a meaningful subdomain. Examples:

| Instead of                  | Use                              |
|-----------------------------|----------------------------------|
| `*.sub.example.com`         | `*.example.com` (one-level)      |
| `service-XXXX.sub.zone.com` | `service-XXXX.zone.com` (one-level) |

In our setup, the base domain is `cfworkers.dpdns.org` and we use
`<subdomain>.cfworkers.dpdns.org` for each service (stalwart, mail, etc.).
The wildcard `*.cfworkers.dpdns.org` CNAME → tunnel covers all of them.

### Verification

```bash
# Should connect successfully
curl -I https://stalwart.cfworkers.dpdns.org/admin
# Expected: HTTP/2 302
```

---

## 18. KUBEWATCH Consumer Filter `events.>` Matches Nothing

### Symptoms

- zeabur-kube-watch publishes events to NATS (no errors in pod logs)
- Stream `KUBEWATCH` accumulates messages (e.g. 535)
- Consumer `zeabur-control-plane` shows `Unprocessed Messages: 0` but
  `Last Delivered Message: Consumer sequence: 0 Stream sequence: 0`
- Zeabur backend does not see any events → no auto-Ingress creation
  (this is OK; we create Ingresses manually), no env-var population

### Detection

```bash
# Actual subjects in the stream
sudo nats stream subjects KUBEWATCH
# Subject                                                                                                 Count
# kube.events.server-6a23cdf424701a8493345c17.pods.zeabur-system.added.kube-system.helper-pod-delete-...   1
# kube.events.server-6a23cdf424701a8493345c17.pods.user-service.added.environment-XXX.service-XXX-...      1
# ...

# Consumer filter (should be '>' or 'kube.>')
sudo nats consumer info KUBEWATCH zeabur-control-plane | grep "Filter Subject"
# Filter Subject: events.>     <-- WRONG
```

### Root Cause

The consumer was originally created with `filter="events.>"` but the
actual subjects are `kube.events.server-...`. The filter never matches,
so the consumer never gets any messages. This is why SEI-545
("events don't reach the Zeabur backend") partially persists even after
JetStream is enabled.

### Fix

The consumer filter MUST be `>` (matches all subjects) since the subject
prefix varies. `apply-fixes.sh` now detects and recreates the consumer
if the filter is wrong:

```bash
sudo /opt/zeabur-fixes/apply-fixes.sh
# [E] JetStream stream KUBEWATCH
#   KUBEWATCH stream already exists
#   zeabur-control-plane consumer already exists with correct filter '>'
```

If you need to do it manually:

```bash
sudo nats consumer del KUBEWATCH zeabur-control-plane -f
sudo nats consumer add KUBEWATCH zeabur-control-plane \
    --filter=">" --ack=explicit --pull \
    --deliver=all --replay=instant --defaults
```

### Verification

```bash
# After fix, consumer should show unprocessed messages
sudo nats consumer info KUBEWATCH zeabur-control-plane | grep -E "Unprocessed|Filter"
# Filter Subject: >
# Unprocessed Messages: 535     <-- now matches the stream contents
```

### Why not just fix it once?

The consumer is durable and persists across k3s restarts. But if the
NATS StatefulSet's PVC is wiped, the consumer is recreated from
`apply-fixes.sh` — and the legacy script had the wrong filter. The new
script handles both cases.

---

## 19. Public URL Returns 530/502 Every k3s Restart

### Symptoms

- `https://<service>.cfworkers.dpdns.org` returns `HTTP 530` (cloudflared:
  "no more connections active") or `HTTP 502` (cloudflared: "bad gateway")
  for ~30 seconds after every k3s restart, then recovers.
- `kubectl get pod -n default -l app.kubernetes.io/name=ingress-controller`
  shows frequent `RESTARTS` increments (one per k3s start).
- `/var/log/zeabur-fixes.log` shows lines like
  `restarted ds/ingress-controller (via pod delete)` on every run.

### Root Cause

`apply-fixes.sh` (the idempotent fix-up script that runs on every k3s
start via `k3s.service`'s `ExecStartPost`) used to **unconditionally delete
the ingress-controller pod** so it would re-mount the new
`/etc/k3s-pod-resolv.conf`. But the resolv.conf is created and made
immutable on the first run, so every subsequent run was deleting a pod
that was already running with the correct resolv.conf, just to "be safe".

This caused:

1. **Direct downtime**: the ingress-controller takes 5-10 seconds to
   become Ready after a pod delete. During that window the public URL
   returns 530/502.
2. **Race condition**: when k3s restarted twice in a row (common on WSL2
   with Modern Standby), systemd fired two `ExecStartPost` hooks
   back-to-back. The first script would create the resolv.conf, mark
   the marker file, and start the restart. The second script would
   see the marker (or be racing with the first), and trigger a *second*
   pod delete, compounding the downtime.

### Fix

Two changes in `persistence/apply-fixes.sh`:

1. **Skip the restart on subsequent runs** (commit `a3b33b3`). Track
   whether `/etc/k3s-pod-resolv.conf` was newly created in this run via
   a marker file at `/var/run/zeabur-fixes-resolv-created`. The
   `[G]` step only restarts workloads if the marker is present, i.e.
   only on the first run after the resolv.conf was created. On every
   subsequent k3s start the script logs:

   ```
   [G] SKIP: resolv.conf was already in place at start; no restart needed
   ```

2. **Acquire an exclusive lock at startup** (same commit). `mkdir(1)` is
   atomic on POSIX, so we use `/var/run/zeabur-fixes.lock` as a mutex.
   The second of two concurrent runs exits immediately:

   ```
   ==== apply-fixes.sh SKIP: another instance holds the lock ====
   ```

### Verification

After deploying the fix, run the public URL test:

```bash
for i in 1 2 3 4 5; do
  curl -sk -o /dev/null -w "%{http_code}\n" \
    https://stalwart.cfworkers.dpdns.org/admin
  sleep 5
done
```

Expected: 4-5 out of 5 return `302` (or `200`), and any failures are
limited to the first ~15 seconds (cloudflared reconnect window). Before
the fix, the success rate was 0-1 out of 5 because every k3s restart
triggered an ingress-controller restart.

### Why not just not run apply-fixes.sh at all?

`apply-fixes.sh` is idempotent — it only changes things that are
*missing* or *wrong*. Skipping it would mean losing the
CoreDNS forward, the NATS JetStream stream, the KUBEWATCH consumer, the
public Ingress, etc. when k3s restarts and reverts those settings. The
lock + marker approach keeps all those fixes but stops the gratuitous
ingress-controller restarts.

---

## 20. WSL2 VM Keeps Shutting Down (vmIdleTimeout / Modern Standby)

### Symptoms

- `wsl -d wsl_test_server_001 -- echo uptime` returns **`< 60s`** even though
  you've been "using" the WSL for minutes
- Tailscale mesh comes up, holds for ~30-90s, then the node drops and the
  dashboard flips to "1 server needs attention"
- k3s pods restart every 1-2 minutes (`kubectl get pods -A` shows non-zero
  `RESTARTS` accumulating)
- `apply-fixes.sh` runs frequently (`/var/log/zeabur-fixes.log` has many
  `==== apply-fixes.sh start ====` entries spaced ~60s apart)
- All fixes in `apply-fixes.sh` look correct — the problem is upstream of it
- After ANY of these, it briefly works again:
  - `wsl --shutdown` (works for ~2 min)
  - Clicking on the WSL terminal window (works for ~2 min)
  - Plugging in / unplugging the charger

### Detection

```powershell
# From Windows PowerShell: how long since the WSL VM was last running?
wsl -d wsl_test_server_001 -- echo "$(uptime)"

# Expected (good): up 5 minutes, ...
# Expected (bad):  up 0 minutes, ...    (always sub-minute)
```

```bash
# From inside WSL: was the VM suspended recently?
journalctl --since "1 hour ago" --no-pager | grep -E "suspend|wakeup" | wc -l
# Expected (good): 0
# Expected (bad):  20+   <-- VM is bouncing
```

```powershell
# From Windows: what are the sleep / Modern Standby settings?
powercfg -query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE | Select-String "Current"
powercfg -query SCHEME_CURRENT SUB_SLEEP UNATTENDSLEEP | Select-String "Current"
powercfg -availablesleepstates
# If the last command shows "S0 Low Power Idle", you have Modern Standby.
```

### Root Cause

Windows machines with **Modern Standby (S0 Low Power Idle)** periodically
suspend the system even when on AC power, and Windows also has a default
**WSL2 idle timeout** that shuts down the WSL VM after **60 seconds of
"no WSL process running"** (per Microsoft: `vmIdleTimeout=60000` is the
default).

A related problem: the Windows "Balanced" power scheme has a non-zero
`UNATTENDSLEEP` AC timeout (usually 2 minutes) that fires when the user
is detected "idle" — even with the screen on.

So the death cycle is:

```
1. User "uses" the WSL (any process)
2. User walks away / closes the terminal
3. 60s later: WSL VM shuts down (vmIdleTimeout)
4. 120s later: Windows Modern Standby would also kick in (UNATTENDSLEEP)
5. tailscaled, k3s, cloudflared all die with the VM
6. Dashboard reports "disconnected"
7. Apply-fixes.sh runs on every VM start, races itself, public URL is flaky
```

The cgroup / SIGTERM fixes in `troubleshooting.md` §2 are SYMPTOMS, not
the root cause. As long as the VM is dying every 60-120s, nothing in
the WSL can be stable.

### Fix (Permanent)

Two changes, both on the Windows host:

**1. Set `vmIdleTimeout=2147483647` (max int) in `.wslconfig`**

Edit `C:\Users\<user>\.wslconfig`:

```ini
[wsl2]
memory=8GB
processors=4
swap=2GB
networkingMode=nat
vmIdleTimeout=2147483647     ; <-- ADD THIS LINE
```

Then from PowerShell:

```powershell
wsl --shutdown
# Wait 10s, then re-launch your distro
wsl -d wsl_test_server_001
```

`vmIdleTimeout=2147483647` is 68 years — effectively "never". Microsoft
documented this setting in WSL 2.0.0+; older versions silently ignore it
(use the [GitHub issue workaround](https://github.com/microsoft/WSL/issues/8496)
or just live with the WSL dying when the laptop sleeps, which we'll fix next).

**2. Disable Windows Modern Standby / unattended sleep on AC and DC**

Run from an *elevated* PowerShell (Run as Administrator):

```powershell
# Apply to all power schemes
$schemes = powercfg -list | Select-String "Power Scheme GUID" | ForEach-Object { ($_ -split ":")[1].Trim() }
foreach ($s in $schemes) {
    powercfg -setactive $s
    # Never sleep on AC or DC
    powercfg -change -standby-timeout-ac 0
    powercfg -change -standby-timeout-dc 0
    # Never hibernate
    powercfg -change -hibernate-timeout-ac 0
    powercfg -change -hibernate-timeout-dc 0
    # Disable unattended sleep
    powercfg -setacvalueindex $s SUB_SLEEP UNATTENDSLEEP 0
    powercfg -setdcvalueindex $s SUB_SLEEP UNATTENDSLEEP 0
    # Belt-and-suspenders: also kill the legacy STANDBYIDLE
    powercfg -setacvalueindex $s SUB_SLEEP STANDBYIDLE 0
    powercfg -setdcvalueindex $s SUB_SLEEP STANDBYIDLE 0
}
```

If your machine is on a **domain** with a Group Policy that re-enables
sleep every reboot, run `gpresult /h sleep.html` and look at
`Computer Configuration → Administrative Templates → System → Power Management`.
Domain GPOs can override per-user `powercfg` settings on every reboot.

### Verification

```powershell
# 1. WSL VM should NOT die when you walk away
$elapsed = Measure-Command {
    # Do nothing for 3 minutes
    Start-Sleep -Seconds 180
}
wsl -d wsl_test_server_001 -- uptime
# Expected: up 3 minutes, ... (NOT "0 minutes")

# 2. Dashboard should NOT flip to "1 server needs attention" over 5 min
Start-Sleep -Seconds 300
curl -s -H "Authorization: Bearer $env:ZEABUR_TOKEN" `
    -H "Content-Type: application/json" `
    -d '{"query":"{ server(_id: \"server-6a23cdf424701a8493345c17\") { status } }"}' `
    https://api.zeabur.com/graphql
# Expected: status = "ONLINE" or "READY", not "DISCONNECTED"
```

### Why we don't use a WSL-side watchdog

We tried writing a systemd timer that would `wsl --shutdown` and
re-launch on certain conditions, but that's whack-a-mole. The right fix
is to keep the VM from dying in the first place. Once the host settings
are correct, the WSL stays up indefinitely and **all** the
apply-fixes.sh / cluster fixes / Tailscale work is automatically
stable.

If you absolutely must run a WSL-side watchdog (e.g. on a laptop that
still sleeps for hardware reasons), see
[scripts/fixes/persist-tailscale.sh](../scripts/fixes/persist-tailscale.sh) —
the `start-tailscale.sh` detached launcher will at least keep tailscaled
from being SIGTERM'd by systemd restarts. But the VM can still die.

### What does NOT fix this

- ❌ Setting `cgroup-driver=cgroupfs` (fixes kubelet, not VM)
- ❌ Disabling systemd in WSL (worse, breaks k3s)
- ❌ Adding memory limits to `.wslconfig` (irrelevant)
- ❌ Increasing `swap=8GB` (irrelevant)
- ❌ Setting Windows "Power mode" to "Best performance" (only changes
  the visible UI, doesn't change the underlying timeouts unless you
  also `powercfg` it)
- ❌ `wsl --update` (no behavior change for vmIdleTimeout)

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
