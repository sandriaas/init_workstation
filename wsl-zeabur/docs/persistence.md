# Persistence Layer

How the WSL2 + k3s + Zeabur Wonder Mesh setup survives WSL reboots and
`systemctl restart k3s`. All fixes are idempotent and re-applied automatically.

---

## Why Persistence Is Needed

WSL2 + k3s has several sources of state loss:

1. **k3s addon manager** writes bundled manifests to
   `/var/lib/rancher/k3s/server/manifests/` on startup, overwriting
   manual ConfigMap edits.
2. **WSL launcher** regenerates `/etc/resolv.conf` unless
   `generateResolvConf = false` in `/etc/wsl.conf`.
3. **Pod resolv.conf** defaults to the WSL host's resolv.conf, but pods
   can't reach 1.1.1.1 over the WSL NAT (UDP not supported), so external
   DNS fails for image pulls and ACME challenges.
4. **NATS JetStream** is disabled in the default config; kube-watch can't
   publish to streams and user service env vars don't get populated.
5. **Tailscale** restarts in a loop under WSL2 (covered in troubleshooting #2).

Each of these needs a fix that survives restarts.

---

## The Persistence Architecture

```
WSL boot
  ↓
/etc/rc.local (rc-local.service)
  ↓
  - start-tailscale.sh (nohup tailscaled, no systemd restart loop)
  - apply-fixes.sh (early phase: pod resolv.conf, before k3s starts)
  ↓
systemd starts k3s.service
  ↓
  Drop-in: /etc/systemd/system/k3s.service.d/override.conf
    - --resolv-conf /etc/k3s-pod-resolv.conf (kubelet flag)
    - ExecStartPost=/opt/zeabur-fixes/apply-fixes.sh (post-start fix)
  ↓
  k3s writes bundled CoreDNS manifest
  ↓
  apply-fixes.sh waits 5s for manifest to stabilize
  ↓
  apply-fixes.sh patches manifest, touches it, forces redeploy
  ↓
  apply-fixes.sh ensures JetStream + KUBEWATCH stream + consumer
  ↓
  apply-fixes.sh restarts user service deployments to re-populate env vars
  ↓
  All Zeabur services healthy
```

---

## Files

| Path | Purpose | Installed By |
|------|---------|--------------|
| `/etc/wsl.conf` | WSL config (systemd, generateResolvConf=false) | Manual / WSL setup |
| `/etc/rc.local` | WSL boot hook (calls start-tailscale + apply-fixes) | `persistence/rc.local` |
| `/etc/systemd/system/rc-local.service` | systemd unit for rc.local | Manual / WSL setup |
| `/etc/systemd/system/tailscaled.service.d/override.conf` | Tailscale restart=never | Tailscale fix |
| `/usr/local/bin/start-tailscale.sh` | nohup tailscaled launcher | Tailscale fix |
| `/etc/systemd/system/k3s.service.d/override.conf` | k3s drop-in (resolv-conf + ExecStartPost) | `persistence/k3s.service.d-override.conf` |
| `/etc/k3s-pod-resolv.conf` | Pod DNS config (cluster DNS first) | `scripts/dns/01-create-pod-resolv-conf.sh` |
| `/opt/zeabur-fixes/apply-fixes.sh` | Idempotent fix script | `persistence/apply-fixes.sh` |
| `/opt/zeabur-fixes/install-nats-cli.sh` | nats CLI installer | `persistence/install-nats-cli.sh` |
| `/usr/local/bin/nats` | NATS CLI (v0.4.0) | `install-nats-cli.sh` |
| `/var/log/zeabur-fixes.log` | Fix script log | apply-fixes.sh |
| `/var/lib/rancher/k3s/server/manifests/coredns.yaml` | k3s CoreDNS manifest (edited) | k3s + apply-fixes.sh |

---

## k3s Service Drop-in

File: `/etc/systemd/system/k3s.service.d/override.conf`

```ini
[Service]
ExecStart=
ExecStart=/usr/local/bin/k3s server --resolv-conf /etc/k3s-pod-resolv.conf
ExecStartPost=/opt/zeabur-fixes/apply-fixes.sh
```

Why:
- The empty `ExecStart=` clears the main unit's `ExecStart` (so we don't
  double-start).
- The new `ExecStart` adds the `--resolv-conf` flag to kubelet.
- The `ExecStartPost` runs after k3s API is up but before user pods are
  fully scheduled (well, by the time kubelet is up).
- The drop-in is loaded after the main unit, so package upgrades that
  rewrite the main unit don't break the drop-in.

To reload after editing:
```bash
sudo systemctl daemon-reload
sudo systemctl restart k3s
```

---

## apply-fixes.sh

The main persistence script. Runs on every k3s start (and from rc.local
on WSL boot for early-phase fixes).

### Phases

**Phase 1: Wait for CoreDNS manifest to stabilize**

K3s addon manager writes the bundled CoreDNS manifest within ~1s of
startup. If we edit too early, our edit gets overwritten. We poll the
manifest's mtime; if it doesn't change for 5 consecutive seconds, we
proceed.

**Phase 2: Patch CoreDNS forward**

```bash
# Original (bundled):
forward . /etc/resolv.conf

# Patched:
forward . 8.8.8.8 1.0.0.1 8.8.4.4
```

We use `sed` to replace the line in-place.

**Phase 3: Add nats.zeabur.com rewrite block**

We append a new server block to the Corefile:

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

**Phase 4: Force k3s to redeploy CoreDNS**

`touch` the manifest. k3s watches the file mtime; if it changes, k3s
reapplies the manifest.

**Phase 5: Verify NATS JetStream**

Check if `jetstream` is in the NATS config. If not, patch the ConfigMap
and restart the statefulset.

**Phase 6: Verify KUBEWATCH stream and consumer**

Use the `nats` CLI to check if the stream exists. If not, create it
(equivalent to `scripts/sei-545/02-create-jetstream-stream.sh`).

**Phase 7: Restart user service deployments**

Trigger env-var re-population by deleting the deployment pods (the
statefulset/deployment controller recreates them). This is a workaround
for the SEI-545 issue where env vars don't propagate to existing pods.

**Phase 8: Log and exit**

All output goes to `/var/log/zeabur-fixes.log`. The script exits 0 even
if individual fixes fail (so it doesn't break the k3s service).

### Idempotency

Each step checks the current state before making changes:
- `grep -q` for the forward directive before sed-editing
- `kubectl get stream` before creating it
- etc.

This means the script is safe to re-run multiple times.

### Idempotency Caveats

- The `ExecStartPost` runs once per `systemctl start k3s`, not on
  every `k3s` binary invocation. So if k3s restarts itself (e.g., after
  a crash), the script may not run. But the script is also called from
  `rc.local` on WSL boot, which covers the most common case.
- The JetStream step is not idempotent in the strict sense — it patches
  the NATS ConfigMap and restarts the statefulset, which loses any
  in-flight messages. For a "real" deployment, you'd use a proper
  config management tool. For our setup, this is acceptable.

---

## /etc/rc.local

File: `/etc/rc.local`

```bash
#!/bin/bash
# WSL boot hook
# - Start Tailscale in detached mode (avoids restart loop)
# - Apply early-phase fixes (pod resolv.conf, before k3s starts)

/usr/local/bin/start-tailscale.sh
/opt/zeabur-fixes/apply-fixes.sh --early
exit 0
```

`apply-fixes.sh --early` runs only the steps that don't need k3s to be
up (currently just the resolv.conf setup, which is idempotent if the
file already exists).

---

## Manual Recovery

If something is broken, run apply-fixes.sh manually:

```bash
wsl -d wsl_test_server_001 -- bash -c "sudo /opt/zeabur-fixes/apply-fixes.sh"
```

If k3s itself is broken (e.g., won't start), the drop-in's ExecStartPost
won't run, so you may need to:

1. `sudo systemctl stop k3s`
2. `sudo /opt/zeabur-fixes/apply-fixes.sh --early` (manual early fixes)
3. `sudo systemctl start k3s` (will run ExecStartPost after k3s is up)

---

## Testing the Persistence

```bash
# Restart k3s and watch the log
wsl -d wsl_test_server_001 -- bash -c "
  sudo systemctl restart k3s
  sudo tail -f /var/log/zeabur-fixes.log
"

# Wait 60s, then verify
wsl -d wsl_test_server_001 -- bash -c "
  sudo /usr/local/bin/kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep -E 'forward|rewrite'
  sudo /usr/local/bin/kubectl -n default get pod -l name=zeabur-kube-watch
  sudo /usr/local/bin/kubectl -n default get pods -A
"
```

Expected output:
- `forward . 8.8.8.8 1.0.0.1 8.8.4.4`
- `rewrite name exact nats.zeabur.com nats.default.svc.cluster.local`
- `zeabur-kube-watch-...  1/1  Running`
- All system pods `Running`

For a full WSL reboot test:

```powershell
wsl --shutdown
# Wait for WSL to fully terminate
wsl -d wsl_test_server_001 -- echo "WSL is back"
# Then check apply-fixes.log
```
