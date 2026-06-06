# DNS Configuration Reference

> Generated: 2026-06-07
> Status: All fixes applied and verified after k3s restart

## Resolution Layers (top to bottom)

When a pod queries a name, the resolution path is:

```
Pod application
  → kubelet (creates /etc/resolv.conf from --resolv-conf)
    → /etc/k3s-pod-resolv.conf  [our custom file]
      → 10.43.0.10 (kube-dns service → CoreDNS pod)
        → CoreDNS Corefile
          → forward . 8.8.8.8 1.0.0.1 8.8.4.4  [our fix]
            → Public DNS (recursive)
```

For Zeabur-internal names (`nats.zeabur.com`):
```
Pod queries nats.zeabur.com
  → CoreDNS server block "nats.zeabur.com:53"  [our rewrite block]
    → rewrite name exact nats.zeabur.com nats.default.svc.cluster.local
      → kubernetes plugin resolves cluster.local
        → 10.43.10.121 (ClusterIP of nats service)
```

## Files

| File | Purpose | Persistence |
|------|---------|-------------|
| `/etc/k3s-pod-resolv.conf` | Pod DNS config (cluster DNS first) | WSL filesystem (immutable) |
| `/etc/systemd/system/k3s.service.d/override.conf` | k3s drop-in with `--resolv-conf` | WSL filesystem |
| `/var/lib/rancher/k3s/server/manifests/coredns.yaml` | k3s CoreDNS manifest (with our fix) | k3s-managed, but our edits persist after apply-fixes.sh |
| `/etc/rc.local` | WSL boot hook (calls apply-fixes.sh) | WSL filesystem |
| `/opt/zeabur-fixes/apply-fixes.sh` | Idempotent fix script | WSL filesystem |
| `/var/log/zeabur-fixes.log` | Fix script log | WSL filesystem |

## /etc/k3s-pod-resolv.conf

```
nameserver 10.43.0.10      # cluster DNS (CoreDNS service VIP)
nameserver 8.8.8.8         # fallback public DNS
nameserver 1.1.1.1         # fallback public DNS
options edns0 trust-ad
search default.svc.cluster.local svc.cluster.local cluster.local
```

Without `--resolv-conf /etc/k3s-pod-resolv.conf`, kubelet uses the
host's `/etc/resolv.conf` (which has 1.1.1.1 first). The pod network
(10.42.0.0/16) cannot reach 1.1.1.1 via WSL NAT (UDP not supported).

## CoreDNS forward fix

**Before fix:**
```toml
forward . /etc/resolv.conf
```

**After fix (our edit):**
```toml
forward . 8.8.8.8 1.0.0.1 8.8.4.4
```

This is in the k3s-managed manifest at `/var/lib/rancher/k3s/server/manifests/coredns.yaml`.
The k3s addon manager writes the bundled template on startup, overwriting
manual edits. The fix is reapplied by `/opt/zeabur-fixes/apply-fixes.sh`
which waits for the manifest to stabilize (5s no mtime change) before
editing.

## nats.zeabur.com rewrite block

**Before fix:** No rewrite block. Pods cannot resolve `nats.zeabur.com`.

**After fix (our edit):**
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

**Why this works:**
- Server block `nats.zeabur.com:53` matches queries for that exact domain
- `rewrite name exact` rewrites the query name from `nats.zeabur.com` to
  `nats.default.svc.cluster.local` (the in-cluster DNS name)
- The `kubernetes` plugin resolves `*.svc.cluster.local` via the
  Kubernetes API, returning the Service ClusterIP (10.43.10.121)

**Why NOT `forward . 8.8.8.8` in the rewrite block:**
- 8.8.8.8 doesn't know about `*.svc.cluster.local`
- Only the kubernetes plugin in CoreDNS can resolve those

**Why NOT `forward . /etc/resolv.conf` in the rewrite block:**
- The CoreDNS pod's /etc/resolv.conf is now 10.43.0.10 (cluster DNS)
- Forwarding to itself creates a loop (broken by CoreDNS's `loop` plugin,
  but results in SERVFAIL)

## Verification commands

```bash
# From WSL host
sudo kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'

# From a test pod
sudo kubectl run dnstest --image=alpine --restart=Never --command -- sleep 60
sudo kubectl exec dnstest -- nslookup nats.zeabur.com 10.43.0.10
# Expected: Name: nats.zeabur.com, Address: 10.43.10.121

sudo kubectl exec dnstest -- nslookup api.zeabur.com 10.43.0.10
# Expected: Non-authoritative answer with Cloudflare IPs

# From Windows (after updating hosts file or after public DNS propagation)
nslookup yjhkbkjb.zeabur.app
curl -I https://yjhkbkjb.zeabur.app/api
```
