# Architecture

How Zeabur Wonder Mesh works on WSL2.

---

## Components Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│ Windows 11                                                          │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ .wslconfig (resource limits)                                   │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                          │                                           │
│                          ▼                                           │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ WSL2 Hyper-V VM                                                │ │
│  │  - systemd (PID 1)                                             │ │
│  │  - WSL launcher init (PID 2) ←── Sends SIGTERM on net change │ │
│  │  - Ubuntu 24.04                                                │ │
│  │  - 8GB RAM, 4 CPU, 2GB swap                                    │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                          │                                           │
│                          ▼                                           │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ /etc/wsl.conf                                                  │ │
│  │  systemd=true, generateResolvConf=false                        │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                          │                                           │
│                          ▼                                           │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ /etc/resolv.conf (immutable, chattr +i)                        │ │
│  │  nameserver 8.8.8.8 1.1.1.1 9.9.9.9                            │ │
│  └────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Ubuntu 24.04 (wsl_test_server_001)                                  │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ tailscaled (PID via nohup, not systemd)                        │ │
│  │  - WireGuard tunnel                                            │ │
│  │  - Mesh IP: 100.64.3.1                                         │ │
│  │  - Control: https://wonder.zeabur.com                          │ │
│  │  - State: /var/lib/tailscale/tailscaled.state                  │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                          │                                           │
│                          ▼                                           │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ sshd (port 22, password auth for zeabur user)                 │ │
│  │  Accessible via 100.64.3.1:22 over Tailscale mesh              │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                          │                                           │
│                          ▼                                           │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ k3s server (PID 1's child, single-node cluster)               │ │
│  │  - etcd (SQLite for single-node)                               │ │
│  │  - flannel CNI                                                 │ │
│  │  - kubelet, kube-apiserver, scheduler, controller-manager      │ │
│  │  - /etc/rancher/k3s/k3s.yaml (kubeconfig)                      │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                          │                                           │
│                          ▼                                           │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ Zeabur System Pods (in `default` namespace)                   │ │
│  │  - vector-aggregator (logs)                                    │ │
│  │  - zeabur-dns (DNS for *.zeabur.internal)                      │ │
│  │  - zeabur-kube-watch (pods → NATS → cloud)                     │ │
│  │  - zeabur-log-api (log API)                                    │ │
│  │  - nats (JetStream for events)                                 │ │
│  │  - cadvisor (metrics)                                          │ │
│  │  - fluent-bit (log shipping)                                   │ │
│  │  - ingress-controller (public networking)                      │ │
│  │  - node-exporter (metrics)                                     │ │
│  │  - coredns (cluster DNS, with rewrite)                         │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                          │                                           │
│                          ▼                                           │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ User Services (in `environment-*` namespaces)                  │ │
│  │  - 12 services in environment-6a2445fa95b39806d284aadf         │ │
│  │    (Supabase stack: kong, auth, storage, postgresql, etc)     │ │
│  └────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
                               │
                               │ (WireGuard UDP 41641)
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Zeabur Wonder Mesh (Cloud)                                          │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ Tailscale Coordination Server (Headscale)                      │ │
│  │  wonder.zeabur.com                                              │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                          │                                           │
│                          ▼                                           │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ Wonder Mesh Gateway (100.64.0.1)                               │ │
│  │  - Relays SSH connections to peer machines                     │ │
│  │  - Receives NATS events from kube-watch                        │ │
│  │  - Manages deployments                                         │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                          │                                           │
│                          ▼                                           │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ Zeabur Control Plane                                           │ │
│  │  - API: api.zeabur.com                                         │ │
│  │  - Dashboard: zeabur.com                                       │ │
│  │  - Stores: project, service, environment, server, deployment   │ │
│  │  - Triggered by NATS events from kube-watch                    │ │
│  └────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Network Flow

### User Deploys a Service

```
1. User: Click "Deploy" in dashboard
2. Zeabur Control Plane → Gateway (100.64.0.1) → SSH to peer (100.64.3.1:22)
3. Peer: sshd receives command, runs as `zeabur` user
4. Peer: Command creates K8s resource (e.g., new Pod in environment-* namespace)
5. Peer: kube-watch observes the change
6. Peer: kube-watch publishes event to NATS (nats.default.svc.cluster.local:4222)
7. Peer: NATS relays event through Tailscale tunnel to gateway
8. Zeabur: Gateway receives event, updates dashboard
9. User: Sees "Running" status in dashboard
```

### Server Comes Online (Heartbeat)

```
1. Peer: tailscaled connects to wonder.zeabur.com
2. Peer: tailscaled registers with control plane, gets mesh IP 100.64.3.1
3. Peer: sshd starts listening on all interfaces (including 100.64.3.1:22)
4. Peer: kube-watch starts and connects to NATS
5. Peer: kube-watch starts publishing heartbeats to NATS
6. Zeabur: Receives heartbeats, marks server as "Online"
```

### Server Goes Offline

```
1. Peer: tailscaled dies (OOM, SIGTERM, etc.)
2. Peer: sshd still listens on localhost but not on 100.64.3.1
3. Peer: kube-watch still tries to publish but NATS queue fills up
4. Zeabur: Stops receiving heartbeats after 30s
5. Zeabur: Marks server as "Offline" in dashboard
```

---

## Tailscale Mesh Topology

```
Tailscale Net (100.64.0.0/10)

100.64.0.1   lke505319-728018-...   linux   active; relay "sfo"   ← Zeabur gateway
100.64.3.1   desktop-hsbf3et        linux   -                      ← Our WSL server
100.64.2.166 vm-2                   linux   offline, 9d ago        ← Old VM (replaced)
```

When our WSL server boots:
1. Tailscale registers with the control server
2. Receives the netmap (list of all peers)
3. Establishes WireGuard tunnels to active peers
4. For unreachable peers (NAT, firewall), uses DERP relay servers
5. Tailscale's `tailscale ping` uses both direct paths and relays

---

## Data Flow Example: Service Health Check

```
User Browser → zeabur.com → Load Balancer
                              │
                              ▼
                          Zeabur API
                              │
                              │ GraphQL query
                              ▼
                          Database (reads last known state)
                              │
                              │ Returns: "Service X status: Running"
                              ▼
                          User Browser
```

Meanwhile, the actual state is being kept fresh by:
```
WSL k3s pod → K8s API → kube-watch → NATS → Tailscale → Gateway → Zeabur API → DB
```

So the dashboard reads cached data, while the control plane is constantly
updated by kube-watch events. This is why a brief network outage doesn't
immediately make the dashboard "stale" - the cached state is shown for some time.

---

## Security Model

### Authentication

- **SSH**: `zeabur` user with password (set by install script)
- **Tailscale**: Auto-registered with control plane
- **Kubernetes**: Service accounts + RBAC (default k3s)
- **NATS**: No auth (we disabled it; in production, would use tokens)

### Authorization

- **Zeabur API**: Bearer token (the `sk-*` API key)
- **Tailscale**: ACLs managed by Zeabur's Headscale
- **K3s API**: Only accessible from localhost (default)
- **SSH over mesh**: Only by Zeabur's gateway IP

### Network Isolation

- WSL2 is isolated from Windows host (separate IP 172.29.155.146)
- Tailscale mesh is a private WireGuard network
- K3s pods communicate via flannel (10.42.0.0/24)
- User services are in separate `environment-*` namespaces

---

## Why WSL2?

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| WSL2 | Native Linux, free, easy setup, integrates with Windows | Network flapping, SIGTERM issues, memory pressure | ✅ Best for dev |
| VirtualBox | Stable, full VM | Licensing, slow, separate UI | ❌ |
| VMware | Best performance | Licensing, expensive | ❌ for personal use |
| Hyper-V | Native Windows | Complex setup, Pro only | ⚠️ if Hyper-V available |
| Docker Desktop | Easy | Licensing, resource heavy | ❌ |
| Native Linux on Mini PC | Best perf, no WSL quirks | Need separate hardware | ✅ for production |

WSL2 is the **best choice for development** because:
- Zero licensing cost
- Native Linux for k3s, Tailscale, etc.
- Easy Windows integration
- Quick reset/export for testing

For production, use a dedicated Linux server (mini PC, cloud VM, etc.) to avoid
WSL2's network flapping and SIGTERM issues.

---

## Zeabur Service Architecture (User Perspective)

```
User Project
├── Production Environment
│   ├── Service A (e.g., web app)
│   │   ├── Pod (1+ replicas)
│   │   ├── Persistent volume (if needed)
│   │   ├── Public domain (optional)
│   │   └── Environment variables
│   ├── Service B (e.g., database)
│   └── Service C (e.g., cache)
└── (Optional) Preview Environment (per PR)
    ├── Service A (PR version)
    └── ...
```

When you deploy to this WSL server:
- A new namespace is created: `environment-<id>`
- Services are deployed as Deployments
- Pods get IPs in the 10.42.0.0/24 range (flannel)
- Services get ClusterIPs in the 10.43.0.0/16 range
- Public networking: ingress-controller routes via port mapping

---

## DNS Resolution Flow (Post-Persistence)

The DNS layer has three concentric circles. Each pod's resolv.conf
points to the cluster DNS service (10.43.0.10), which is CoreDNS.

```
Pod application queries "api.zeabur.com"
  → kubelet uses --resolv-conf /etc/k3s-pod-resolv.conf
    → nameserver 10.43.0.10 (kube-dns VIP)
      → CoreDNS pod matches "zeabur.com" → ".:53" server block
        → forward . 8.8.8.8 1.0.0.1 8.8.4.4
          → Public DNS recursive → 8.8.8.8 returns A record

Pod application queries "nats.zeabur.com"
  → CoreDNS matches "zeabur.com" → "nats.zeabur.com:53" server block
    → rewrite name exact nats.zeabur.com nats.default.svc.cluster.local
      → kubernetes plugin queries k8s API for service "nats" in "default"
        → returns ClusterIP 10.43.10.121

Pod application queries "service-6a242f96f1be9943f1f972a7.environment-..."
  → CoreDNS matches "cluster.local" → ".:53" kubernetes plugin block
    → returns ClusterIP 10.43.6.160
```

Key points:
- Pods use cluster DNS first (so internal service names work)
- Public DNS as fallback (8.8.8.8 etc.)
- The k3s addon manager overwrites the bundled CoreDNS manifest, so our
  edits must be re-applied on every k3s start (see persistence layer)

---

## SEI-545 Event Flow (After Local JetStream Enabled)

The `zeabur-kube-watch` pod publishes pod events to local NATS. Local
NATS has JetStream enabled, with a `KUBEWATCH` stream. A durable consumer
(`zeabur-control-plane`) is bound to the stream.

```
k3s API
  ↓ (pod create/update/delete events)
zeabur-kube-watch pod
  ↓ (publish to subject pods.> / events.> / kube.>)
local NATS (nats-0)
  ↓ (JetStream stream KUBEWATCH stores messages)
NATS consumer zeabur-control-plane
  ↓ (subscribed to events.>, durable, explicit ack)
nats.default.svc.cluster.local:4222
  ↓ (Tailscale mesh)
Zeabur Gateway (100.64.0.1)
  ↓ (Zeabur API call)
Zeabur Control Plane
  ↓ (triggers domain/ingress creation, env var injection)
Updated deployment in environment-* namespace
  ↓ (DOMAIN_GENERATED env var populated)
zeabur-kube-watch pod (re-publishes env var)
  ↓
Pod receives env var on next restart
```

The 18 subjects used (per the stream definition) cover all Zeabur
internal events. Once the stream is in place, the upstream "shared
JetStream account limit" issue (SEI-545 as originally reported) is
bypassed because we're using a local, dedicated stream.

---

## HTTPS Ingress Flow

```
User browser → https://yjhkbkjb.zeabur.app
  ↓ (DNS: 172.29.155.146)
WSL eth0:443
  ↓ (k3s ingress controller pod binds 443 on host)
ingress-controller
  ↓ (matches ingress yjhkbkjb-zeabur-app)
  - Caddy / certmagic module
  - Checks for secret yjhkbkjb.zeabur.app in default ns
  - If missing, triggers ACME HTTP-01 challenge
  ↓
  ACME challenge → Let's Encrypt
  ↓
  cert stored in secret yjhkbkjb.zeabur.app (default ns)
  ↓
  TLS termination (Caddy)
  ↓ (HTTPS → HTTP, back to service)
service-6a242f96f1be9943f1f972a7:8080 (NodePort 32247)
  ↓
Stalwart pod (10.42.0.55:8080)
  ↓
  /api/principal, /api/settings/keys, etc.
```

The ingress controller uses Caddy + certmagic for ACME. The account
key is stored in `secret/certmagic-acme-account` (default ns).

---

## Why a Drop-in Unit for k3s?

Direct edits to `/etc/systemd/system/k3s.service` would be overwritten
by k3s package upgrades. A drop-in at
`/etc/systemd/system/k3s.service.d/override.conf` is loaded after the
main unit and survives main unit rewrites.

The drop-in also includes `ExecStartPost` so apply-fixes.sh runs on
every k3s start. This is the foundation of the persistence layer —
see [persistence.md](persistence.md) for details.

---

## Reference: WSL Boot Sequence

The complete boot order, with all persistence hooks:

```
Windows boot
  ↓
WSL launcher (init at PID 2)
  ↓
  /etc/wsl.conf loads (systemd=true, generateResolvConf=false)
  ↓
systemd starts (PID 1)
  ↓
  - rc-local.service (oneshot)
    - start-tailscale.sh (nohup tailscaled, log to /var/log/tailscaled.log)
    - apply-fixes.sh --early (pod resolv.conf setup, no k3s needed)
  - k3s.service
    - /usr/local/bin/k3s server --resolv-conf /etc/k3s-pod-resolv.conf
    - ExecStartPost=/opt/zeabur-fixes/apply-fixes.sh
      ↓
      Waits 5s for CoreDNS manifest mtime to stabilize
      Patches forward directive, adds nats.zeabur.com server block
      Touches manifest → k3s redeploys CoreDNS
      Verifies NATS JetStream, KUBEWATCH stream, zeabur-control-plane consumer
      Restarts user service deployments (env var re-population)
      Logs to /var/log/zeabur-fixes.log
  - All other systemd services
  ↓
User logs in, sees healthy cluster
```
