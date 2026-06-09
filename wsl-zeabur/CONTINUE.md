# CONTINUE.md — Handoff Log + Prompt

> **Read this first if you are a new agent picking up the Zeabur-on-WSL2 work.**
> Everything in this document is the result of ~18 hours of trial and error.
> The goal: a clean, reproducible post-install bootstrap that runs **after**
> the Zeabur dashboard finishes installing Tailscale mesh + k3s.

---

## 1. The 30-Second Summary

**Setup order is fixed** (and **NOT under our control** for steps 1–3):

1. Windows host: `wsl --install -d Ubuntu-24.04 --name wsl_test_server_001`
2. Zeabur Dashboard → Wonder Mesh → **install script** (Tailscale + k3s)
3. Wait until `tailscale status` shows `100.64.0.1 active; direct` and
   `kubectl get nodes` shows the node `Ready`
4. **Run our bootstrap** (the only thing we own):
   `bash /mnt/c/init_workstation/wsl-zeabur/persistence/bootstrap.sh`
5. The bootstrap deploys `apply-fixes.sh`, the public-tunnel helpers, the
   rc.local start hook, and the Windows power-sleep hardening.

**Public URL comes up ~2 min after the bootstrap finishes:**
`https://<sub>.cfworkers.dpdns.org` (Cloudflare Tunnel wildcard).

---

## 2. Full Chronological Log of Tries

### Day 1 — Bootstrapping Zeabur

| # | Action | Result | Lesson |
|---|--------|--------|--------|
| 1.1 | `wsl --install -d Ubuntu-24.04` | Distro created but no systemd | WSL2 needs `[boot] systemd=true` in `wsl.conf` |
| 1.2 | Ran Zeabur's `install.sh` | Wonder mesh + k3s installed | `tailscale up --login-server=https://wonder.zeabur.com --auth-key=...` |
| 1.3 | Dashboard shows server offline | `tailscale status` = `NoState` | WSL2 SIGTERM flap (see #2.1) |
| 1.4 | Restarted tailscaled manually | Works for ~30s | Root cause: systemd service on WSL2 = death |
| 1.5 | Disabled `tailscaled.service` | Daemon stays up | But auto-restart on next WSL boot broke it |
| 1.6 | Wrote `start-tailscale.sh` (nohup launcher) | Daemon survived | Proved the design works |
| 1.7 | Wired to `/etc/rc.local` + `rc-local.service` | Persistent across reboots | Required `RemainAfterExit=yes` |

### Day 2 — DNS, Image Pulls, zeabur-kube-watch

| # | Action | Result | Lesson |
|---|--------|--------|--------|
| 2.1 | `tailscaled got signal terminated` in journal | Restart loop | WSL2 init sends SIGTERM to systemd services on net reset |
| 2.2 | Added override `Restart=no, RestartSec=60s, KillMode=process` | No more loop | But daemon still dies on its own after a while |
| 2.3 | `pgrep tailscaled` not atomic | Two instances race | Switched to `flock(1)` guard |
| 2.4 | Pods `ImagePullBackOff` on `ghcr.io` | DNS broken inside pods | WSL2 resolv.conf regen'd by launcher |
| 2.5 | `wsl.conf` `generateResolvConf=false` | Sticky resolv.conf | But k3s overrides it on `kubectl apply` |
| 2.6 | `k3s --resolv-conf /etc/k3s-pod-resolv.conf` | Custom resolv.conf | Works! Made it immutable with `chattr +i` |
| 2.7 | `coredns.yaml` edits get reverted on k3s start | k3s addon manager wins | Patch the *manifest*, not the live ConfigMap |
| 2.8 | `zeabur-kube-watch` crash-loops | `nats: 503 insufficient resources` | NATS needs JetStream enabled |
| 2.9 | Patched `nats-config` ConfigMap to add `jetstream {}` | Stream KUBEWATCH works | But consumer never gets events |
| 2.10 | `nats consumer info` shows `Filter Subject: events.>` | Wrong filter | Real subject is `kube.events.server-...` |
| 2.11 | Recreated consumer with `--filter=">"` | Events flow | Documented in §18 |

### Day 3 — Public Exposure

| # | Action | Result | Lesson |
|---|--------|--------|--------|
| 3.1 | `https://stalwart-2932989.zeabur.app/admin` | Times out from any device | DNS for `*.zeabur.app` per-service CNAME → `100.64.3.1` (Tailscale IP, not public) |
| 3.2 | Tried `zeabur domain create stalwart zeabur.app` | "Domain is not available" | Zeabur CLI doesn't allow custom domains in our tier |
| 3.3 | Tried port-forward 443 on Windows → WSL | Router port-forward required | No admin access to ISP router |
| 3.4 | Installed cloudflared + created tunnel `d1534e02-...` | Tunnel up | DNS wildcard covers `*.cfworkers.dpdns.org` |
| 3.5 | First wildcard was `*.sub.cfworkers.dpdns.org` | SSL error 40 | Cloudflare Free Universal SSL only covers **one-level** wildcards |
| 3.6 | Changed to `*.cfworkers.dpdns.org` | SSL works | Documented in §17 |
| 3.7 | Cloudflared config had wrong source IP `127.0.0.1` | 502 bad gateway | ingress-controller is on `172.29.155.146:443` (eth0, not lo) |
| 3.8 | Set `service: https://172.29.155.146:443` + `noTLSVerify: true` | Public URL works | Documented in §16 |
| 3.9 | Created Ingress `stalwart-cfworkers` manually | URL works immediately | But next k3s restart wipes it |
| 3.10 | Hardcoded stalwart into `apply-fixes.sh` | Works for stalwart only | Bad design: any new service breaks |

### Day 4 — Persistence + Data-Driven Exposures

| # | Action | Result | Lesson |
|---|--------|--------|--------|
| 4.1 | Wrote `apply-fixes.sh` idempotent re-apply | Survives k3s restarts | But ingress-controller restart on every k3s start = 30s downtime |
| 4.2 | **Marker file** `/var/run/zeabur-fixes-resolv-created` | Only restart on first run | 530/502 disappeared |
| 4.3 | **mkdir-based flock** `/var/run/zeabur-fixes.lock` | Two concurrent runs = no-op | Eliminated race when k3s restarts twice |
| 4.4 | Refactored `apply-fixes.sh` to read `exposures.d/*.conf` | Add a domain = drop a file | No more code edits |
| 4.5 | Wrote `expose-service.sh` and `unexpose-service.sh` | Self-service add/remove | Writes .conf + creates Ingress atomically |
| 4.6 | E2E test: `expose-service.sh test2 ...` → wipe k3s → re-run apply-fixes.sh | Ingress re-created from .conf | PASSED |

### Day 5 — The Real Root Cause

| # | Action | Result | Lesson |
|---|--------|--------|--------|
| 5.1 | Public URL flaky: works for hours, then breaks for 30s | `wsl -d ... -- echo uptime` returns < 60s | WSL VM is shutting down and re-spawning |
| 5.2 | Checked Windows sleep settings | `powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE` | Modern Standby (S0) was active, even on AC |
| 5.3 | `powercfg /change standby-timeout-ac 0` | Disables AC sleep | But VM still died |
| 5.4 | `powercfg /change standby-timeout-dc 0` | Disables DC sleep | But VM still died |
| 5.5 | `powercfg /change hibernate-timeout-ac 0` and `-dc 0` | No hibernate | VM uptime now 2 min before dying |
| 5.6 | `powercfg /setacvalueindex SUB_SLEEP UNATTENDSLEEP 0` | No unattended sleep | Improved but still flapping |
| 5.7 | **`vmIdleTimeout=2147483647` in `.wslconfig`** | **The real fix** | WSL2's default 60s idle-shutdown was killing the VM |
| 5.8 | Verified VM uptime 1192s+ with no session attached | Stability confirmed | Took effect only after `wsl --shutdown` |
| 5.9 | Restored `rc.local` with `start-tailscale.sh` | tailscale comes up on boot | One launch path = no double-spawn |
| 5.10 | Removed watchdog/timer (unnecessary now) | Simpler | The host fix is the right fix |

---

## 3. What Didn't Work (Don't Repeat)

| Bad idea | Why |
|----------|-----|
| `dnsTunneling=true` in `.wslconfig` | Caused Tailscale flap every 30s |
| `autoMemoryReclaim` in `.wslconfig` | Unknown key in WSL 2.6.3.0 |
| `k3s` installed by us (not Zeabur) | Zeabur's dashboard is the only blessed path |
| Installing `k0s` instead of `k3s` | Same kubelet under the hood; no help |
| `k3s` with `cgroup-driver=systemd` | WSL2 has broken cgroup v1 + systemd story |
| Patching CoreDNS ConfigMap directly | k3s addon manager overwrites on every start |
| `forward . /etc/resolv.conf` in the nats.zeabur.com block | Loops back to CoreDNS — use `kubernetes` plugin |
| `forward . 8.8.8.8` in the nats.zeabur.com block | 8.8.8.8 doesn't know about `*.svc.cluster.local` |
| `*.sub.cfworkers.dpdns.org` (two-level wildcard) | Cloudflare Free Universal SSL only covers one-level |
| `cloudflared` pointing to `127.0.0.1:443` | ingress-controller is on eth0 `172.29.155.146` |
| `consumer filter="events.>"` | Real subject is `kube.events.server-...`, must be `>` |
| Patching `tailscaled.service` to `Restart=always` | Tight SIGTERM loop |
| Re-joining Wonder Mesh with `wonder worker join` | The token format is different (use the install.sh token) |
| `wonder worker leave` then re-install | Left state file stale — daemon stuck NoState |
| `tailscale up --force-reauth` while a daemon is up | Local state is corrupted; logout+up is cleaner |
| Running `bootstrap.sh` as `zeabur` user, not root | Systemd units, /etc files, /opt all need root |
| WSL-side watchdog (timer) restarting tailscale | Mask the root cause; fix Windows power + .wslconfig instead |
| `wonder-config.sh` rewriting the worker.json | Lost the auth key; never re-join this way |

---

## 4. Current File Layout (post-day-5)

```
C:\init_workstation\wsl-zeabur\                     <-- git repo (main)
├── README.md
├── CONTINUE.md                                     <-- THIS FILE
├── docs/
│   ├── architecture.md
│   ├── persistence.md
│   ├── setup-walkthrough.md
│   ├── troubleshooting.md                          <-- has §1-§20
│   └── reference.md
├── config/
│   ├── wsl/         (wsl.conf, wslconfig, resolv.conf)   <-- VM-level
│   ├── systemd/     (rc-local.service, rc.local,
│   │                 start-tailscale.sh,
│   │                 tailscaled-override.conf,
│   │                 cloudflared.service)
│   ├── cloudflared/ (config.yml, credentials.json)
│   └── k3s/         (coredns-configmap.yaml, nats-configmap.yaml, …)
├── persistence/
│   ├── bootstrap.sh                                <-- ONE-SHOT (new)
│   ├── deploy.sh                                   <-- pushes files to WSL
│   ├── apply-fixes.sh                              <-- idempotent, marker+lock
│   ├── k3s.service.d-override.conf                 <-- --resolv-conf + ExecStartPost
│   ├── rc.local                                    <-- runs start-tailscale.sh + apply-fixes
│   ├── install-nats-cli.sh
│   ├── bin/nats                                    <-- nats CLI 0.4.0
│   └── exposures.d/                                <-- data-driven Ingresses
│       └── stalwart.conf
├── scripts/
│   ├── setup/        (zeabur-cli, check-deploy, …)
│   ├── fixes/        (apply-coredns, fix-tailscale, …)
│   ├── diagnostics/  (check-mesh, check-state, …)
│   ├── dns/          (create-pod-resolv-conf, fix-coredns-forward)
│   ├── sei-545/      (enable-jetstream, create-stream, create-consumer)
│   ├── stalwart/     (get-credentials)
│   ├── domain/       (02-expose-service, 05-unexpose-service, 06-list-exposed)
│   └── verification/ (final-state, stability-check, long-watch, …)
├── data/             (cluster-inventory, dns-reference, stalwart-reference, zeabur-projects)
└── logs/             (before-after, diagnostics, fixes)

C:\Users\Sandria\.wslconfig                          <-- INCLUDES vmIdleTimeout
```

---

## 5. The One-Shot Bootstrap (`persistence/bootstrap.sh`)

The bootstrap is **post-install only**. It assumes:
- WSL2 distro `wsl_test_server_001` exists and is running
- Zeabur's mesh + k3s install script has already been run
- Tailscale is up (`tailscale status` shows the gateway `active`)
- k3s API is up (`kubectl get nodes` shows the node `Ready`)

It does:
1. Windows-side power hardening (`powercfg` — runs from PowerShell, not WSL)
2. Writes `.wslconfig` with `vmIdleTimeout=2147483647` (only if missing)
3. `wsl --shutdown` to make the WSL VM pick up the new timeout
4. Re-launches the distro, waits for it
5. Verifies Tailscale and k3s are up
6. Deploys our files (`deploy.sh`)
7. Installs `nats` CLI
8. Installs `cloudflared` + starts it
9. Runs `apply-fixes.sh` once to seed all cluster fixes
10. Verifies public URL is reachable

---

## 6. Copy-Paste Prompt for the Next Agent

Use this as the FIRST message when starting a new agent on this work:

```
You are continuing the Zeabur-on-WSL2 setup. Read C:\init_workstation\wsl-zeabur\CONTINUE.md
in full before doing anything — it has the full chronological log, the bad-ideas list,
and the current file layout.

Goal: make the one-shot bootstrap at wsl-zeabur/persistence/bootstrap.sh work
end-to-end on a fresh WSL where the Zeabur dashboard install script has already
been run. Do NOT touch the mesh install or the k3s install — those come from
the dashboard.

Constraints (read AGENTS.md too):
- WSL2 distro name MUST be wsl_test_server_001
- User identity: sandriaas <andriz.mitnick619sas@gmail.com>
- Public URL pattern: https://<sub>.cfworkers.dpdns.org (one-level wildcard)
- All fixes must be idempotent and survive WSL + k3s restarts
- Bash tool is PowerShell 7+: use script files in C:\Users\Sandria\AppData\Local\Temp\opencode\
- Cron/timer/watchdog on the WSL side is BANNED — fix Windows power + .wslconfig instead
- vmIdleTimeout=2147483647 is REQUIRED in C:\Users\Sandria\.wslconfig
- Do NOT add dnsTunneling, autoMemoryReclaim, or any other "experimental" WSL keys

Steps to verify and harden:
1. Run wsl-zeabur/persistence/bootstrap.sh on a fresh setup. Fix any failures.
2. Verify https://stalwart.cfworkers.dpdns.org/admin is reachable from a phone
   on cellular (NOT on Tailscale).
3. Add a second service via expose-service.sh, then restart k3s, then verify
   the URL still works (proves the data-driven .conf design).
4. Pin Stalwart admin password with STALWART_RECOVERY_ADMIN env var in the
   Zeabur UI (current setup re-generates it on every pod restart because
   the BOOTSTRAP password is in the pod spec, not a persistent volume).
5. Add a Task Scheduler entry on Windows host that runs `wsl -d wsl_test_server_001 -- echo up`
   on user logon (so reboots actually start WSL).
6. Update wsl-zeabur/docs/troubleshooting.md with anything new you discover.

Current state of THIS WSL (FX506):
- Tailscale state is stuck NoState (daemon running but no IP). See §6 of CONTINUE.md.
- Dashboard "1 server needs attention": SSH Disconnected, K3s status unknown, Latency 0ms (Excellent).
- All WSL processes survived the last host power-event because vmIdleTimeout is set.
- The next session should NOT try to fix the stale state — just confirm the bootstrap
  works on a fresh install, then come back to this one.

Tokens you'll need (NEVER commit them — store in `C:\init_workstation\.tokens\`
or ask the user):
- **Zeabur API**: `sk-zhw6hjoambkyva6hudyt3twsijjmz` (or rotate via Dashboard)
- **Cloudflare DNS+Tunnel**: ask user (rotated per project; lives in
  `C:\init_workstation\.tokens\cloudflare.txt` when set)
- **Tailscale auth key**: rotated per install; pulled from the Zeabur
  install.sh output, never stored
- **GitHub PAT**: ask user (used for `git push` only when Windows
  credential manager returns 401)
```

---

## 7. Open / In-Progress Items

- [ ] Tailscale re-auth on this WSL: stuck in `NoState` after `wonder mesh install`
      and `wonder worker leave + rejoin` — see `logs/diagnostics/tailscaled-journal-broken.log`.
      Resolution: probably needs `tailscale logout && tailscale up --auth-key=<fresh>
      --login-server=https://wonder.zeabur.com --accept-routes --reset`. But the
      daemon is currently up with a stale state file. The next agent can either:
      (a) do the re-auth on this machine, or
      (b) leave it for the bootstrap-on-fresh-WSL validation.
      Preference: **(b)** — confirm the bootstrap works on a clean install first.
- [ ] Stalwart admin password rotates every pod restart. Pin via
      `STALWART_RECOVERY_ADMIN=admin:<chosen-password>` env var in the Zeabur service
      UI. The env var must be set BEFORE the next `Apply` so the pod spec includes it.
- [ ] Windows Task Scheduler auto-start for WSL: not yet created. See `setup-walkthrough.md`
      for the planned entry.
- [ ] Backup of the working WSL: a tar.gz of /opt/zeabur-fixes + /etc/rancher/k3s + the
      relevant k3s state is in `/backup/k3s-migration/2026-06-07/` (in WSL). The next
      agent should `cp` that off to `C:\init_workstation\wsl-zeabur\data\backup\` so it's
      in git.

---

## 8. Verification Cheat-Sheet (Post-Bootstrap)

Run these on the WSL after `bootstrap.sh` returns 0:

```bash
# 1. Tailscale healthy
sudo tailscale status
# Expected: 100.64.3.1 ... 100.64.0.1 active; direct tx <bytes> rx <bytes>

# 2. k3s healthy
sudo kubectl get nodes
# Expected: 1 node Ready, no MemoryPressure, no DiskPressure

# 3. System pods healthy
sudo kubectl get pods -A | grep -v kube-system
# Expected: ingress-controller 1/1, nats-0 2/2, zeabur-kube-watch 1/1, stalwart 1/1

# 4. CoreDNS patched
sudo kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep -E 'forward|rewrite'
# Expected: forward . 8.8.8.8 1.0.0.1 8.8.4.4
#           rewrite name exact nats.zeabur.com nats.default.svc.cluster.local

# 5. KUBEWATCH consumer has the right filter
sudo nats consumer info KUBEWATCH zeabur-control-plane | grep "Filter Subject"
# Expected: Filter Subject: >

# 6. Public ingress exists
sudo kubectl -n environment-6a242c9f95b39806d284aaa7 get ing stalwart-cfworkers
# Expected: HOSTS = stalwart.cfworkers.dpdns.org, ADDRESS = 172.29.155.146

# 7. Cloudflared running
systemctl status cloudflared
# Expected: Active: active (running)

# 8. Public URL from any device
curl -I https://stalwart.cfworkers.dpdns.org/admin
# Expected: HTTP/2 302
```

If all 8 pass, you're done. If any fails, run `/opt/zeabur-fixes/apply-fixes.sh`
manually and check `/var/log/zeabur-fixes.log` for the [X] step that didn't run.

---

## 9. Logs of Failed Tries (Verbatim)

Saved for the next agent to grep:

| File | What it shows |
|------|---------------|
| `logs/diagnostics/tailscaled-journal-broken.log` | SIGTERM storm on first install |
| `logs/diagnostics/registry-pull-error.log` | `ghcr.io` DNS fail from inside pods |
| `logs/diagnostics/nats-auth-error.log` | NATS 503 from kube-watch |
| `logs/diagnostics/kube-watch-errors.log` | `events.> : no responders` |
| `logs/fixes/coredns-rewrite-output.log` | First successful CoreDNS rewrite |
| `logs/fixes/dns-resolv-conf.log` | First successful /etc/k3s-pod-resolv.conf |
| `logs/fixes/nats-noauth-config.log` | Disabling NATS auth |
| `logs/fixes/tailscale-fix-output.log` | First working detached tailscaled |
| `logs/fixes/verify-online.log` | All system pods green for the first time |
| `logs/fixes/final-state-snapshot.txt` | Snapshot after the public URL first worked |
| `logs/before-after/server-status.txt` | Dashboard states before/after the fix |
