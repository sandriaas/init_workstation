# Zeabur Runner + Multica Ops Sheet

Updated: 2026-06-13
Timezone: Asia/Singapore

## Scope

This file summarizes the current Zeabur Ubuntu runner, Hermes, installed CLI agents, Multica project/services, connection methods, config locations, and session notes gathered during this work.

I am intentionally not storing raw secrets in this file. It includes:

- secret names
- secret file locations
- redacted examples
- commands to retrieve them locally

It does not include raw token values.

## Secret handling

Raw secrets were used during the session from local config and runner config, but are not reproduced here.

Current secret locations used in this session:

- Local Zeabur CLI token:
  - `~/.config/zeabur/cli.yaml`
- Runner Hermes secrets:
  - `/workspace/config/hermes/.env`
- Runner Claude settings:
  - `/workspace/home/.claude/settings.json`
- Runner Codex auth:
  - `/root/.codex/auth.json`
- Runner OpenCode config:
  - `/workspace/config/opencode/opencode.json`
- Runner Multica token:
  - `/workspace/config/multica/config.json`

Local commands to inspect secret-bearing files yourself:

```bash
sed -n '1,120p' ~/.config/zeabur/cli.yaml
ssh -F /dev/null -p 30309 root@139.59.229.185 'sed -n "1,120p" /workspace/config/hermes/.env'
ssh -F /dev/null -p 30309 root@139.59.229.185 'sed -n "1,220p" /workspace/home/.claude/settings.json'
ssh -F /dev/null -p 30309 root@139.59.229.185 'sed -n "1,220p" /workspace/config/opencode/opencode.json'
ssh -F /dev/null -p 30309 root@139.59.229.185 'sed -n "1,120p" /workspace/config/multica/config.json'
```

## Zeabur access

Local Zeabur CLI:

- binary: `~/.local/bin/zeabur`
- version: `0.18.0`
- workspace context: `personal`

Useful CLI commands:

```bash
zeabur version
zeabur profile info --json
zeabur project list --json
zeabur service list --project-id 6a20ce0af1be9943f1f89bb4 --json
zeabur service get --id service-6a20e044f1be9943f1f89efd --env-id 6a20ce0a95b39806d284a4c0 --json
zeabur service network --id service-6a20e044f1be9943f1f89efd --env-id 6a20ce0a95b39806d284a4c0 --json
zeabur domain list --id service-6a20e044f1be9943f1f89efd --env-id 6a20ce0a95b39806d284a4c0 --json
```

## Ubuntu runner

### Zeabur object

- Project: `runner-ubuntu_1`
- Project ID: `6a20ce0af1be9943f1f89bb4`
- Environment ID: `6a20ce0a95b39806d284a4c0`
- Service: `ubuntu-runner-lavert`
- Service ID: `6a20e044f1be9943f1f89efd`
- Template: `PREBUILT_V2`
- Status: `RUNNING`
- Internal DNS: `ubuntu-runner-lavert.zeabur.internal`

### Public/network

- Hermes URL: `https://runnerubu1hermes.zeabur.app`
- Hermes sessions URL: `https://runnerubu1hermes.zeabur.app/sessions`
- SSH host: `139.59.229.185`
- SSH forwarded port: `30309` -> runner `22/TCP`
- Hermes forwarded host port: `32377` -> runner `9119/HTTP`

### Connect to runner

Direct SSH:

```bash
ssh -F /dev/null -p 30309 root@139.59.229.185
```

Recommended local SSH config entry:

```sshconfig
Host zeabur-runner
  HostName 139.59.229.185
  Port 30309
  User root
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
```

Then:

```bash
ssh zeabur-runner
```

### Hermes access

Public:

```text
https://runnerubu1hermes.zeabur.app/
https://runnerubu1hermes.zeabur.app/sessions
```

SSH tunnel:

```bash
ssh -L 9119:127.0.0.1:9119 zeabur-runner
```

Then open:

```text
http://127.0.0.1:9119
http://127.0.0.1:9119/sessions
```

### Live processes

Current persistent processes observed:

- `supervisord`
- `sshd`
- `hermes.real dashboard --host 0.0.0.0 --port 9119 --no-open --insecure`
- `multica daemon start --runtime-name zeabur-ubuntu-runner --device-name zeabur-ubuntu-runner --max-concurrent-tasks 1 --foreground --no-auto-update`

Transient/active Hermes-related processes observed during inspection:

- Hermes TUI node process
- 2 Hermes `tui_gateway.slash_worker` processes

Not currently running as persistent daemons:

- `claude`
- `codex`
- `opencode`
- `copilot`
- `pi`
- `cc-switch`

### Installed CLI agents and tools

Paths:

- `claude` -> `/workspace/bin/claude`
- `hermes` -> `/workspace/pipx-bin/hermes`
- `codex` -> `/workspace/npm-global/bin/codex`
- `opencode` -> `/workspace/bin/opencode`
- `copilot` -> `/workspace/npm-global/bin/copilot`
- `pi` -> `/workspace/npm-global/bin/pi`
- `cc-switch` -> `/root/.local/bin/cc-switch`
- `node` -> `/workspace/node/bin/node`
- `npm` -> `/workspace/node/bin/npm`
- `npx` -> `/workspace/node/bin/npx`

Versions:

- Claude Code: `2.1.162`
- Hermes Agent: `0.16.0`
- Codex CLI: `0.139.0`
- OpenCode: `1.16.2`
- GitHub Copilot CLI: `1.0.61`
- Pi: `0.79.1`
- cc-switch: `5.8.1`
- Node: `v22.19.0`
- npm: `10.9.3`

Verification commands:

```bash
ssh zeabur-runner '
export PATH="/workspace/node/bin:/workspace/bin:/workspace/npm-global/bin:/workspace/pipx-bin:/root/.local/bin:$PATH"
claude --version
hermes --version
codex --version
opencode --version
copilot --version
pi --version
cc-switch --version
node --version
npm --version
'
```

### Supervisor wiring

Supervisor config:

- `/workspace/supervisord.conf`

Programs:

- `sshd`
- `hermes-dashboard`

Hermes launcher wrapper:

- `/workspace/pipx/venvs/hermes-agent/bin/hermes`

Wrapper behavior:

- loads `/workspace/config/hermes/.env`
- rewrites `--host 127.0.0.1` to `0.0.0.0`
- appends `--insecure` for non-loopback bind
- when Hermes dashboard starts under supervisor, it also launches `/workspace/bin/start-multica-daemon` in the background

Multica daemon helper:

- `/workspace/bin/start-multica-daemon`

Helper behavior:

- copies `/workspace/config/multica/config.json` to `/root/.multica/config.json`
- restores login state from the persisted Multica token if auth is missing
- starts the daemon with runtime name `zeabur-ubuntu-runner`

### Hermes config

Files:

- config: `/workspace/config/hermes/config.yaml`
- env: `/workspace/config/hermes/.env`
- logs:
  - `/workspace/logs/hermes-dashboard.log`
  - `/workspace/logs/hermes-dashboard-err.log`

Current main model config:

- provider: `omnirouter`
- default model: `oc/deepseek-v4-flash-free`
- api mode: `chat_completions`

Configured named providers:

- `omnirouter`
- `genfity`
- `9router`

Fallback chain:

1. `omnirouter -> oc/deepseek-v4-flash-free`
2. `genfity -> genfity/gpt-5.5`
3. `9router -> cx/gpt-5.5`

Hermes provider secret names present:

- `OMNIROUTE_API_KEY`
- `GENFITY_API_KEY`
- `ROUTER9_API_KEY`

Current Hermes API state:

- public dashboard responds
- `/api/model/info` resolves:
  - provider `omnirouter`
  - model `oc/deepseek-v4-flash-free`

Check commands:

```bash
ssh zeabur-runner 'curl -sS http://127.0.0.1:9119/api/model/info'
ssh zeabur-runner 'sed -n "1,120p" /workspace/config/hermes/config.yaml'
ssh zeabur-runner 'sed -E "s/=.*/=REDACTED/" /workspace/config/hermes/.env'
```

### Claude on runner

Files:

- config dir: `/workspace/home/.claude`
- main settings: `/workspace/home/.claude/settings.json`

Observed state:

- OmniRoute-compatible Anthropic env settings are configured
- Current Claude defaults still include:
  - `ANTHROPIC_MODEL = xiaomi-mimo/mimo-v2.5-pro`
  - `ANTHROPIC_DEFAULT_HAIKU_MODEL = omniroute/oc/deepseek-v4-flash-free`

Inspect:

```bash
ssh zeabur-runner 'sed -n "1,220p" /workspace/home/.claude/settings.json'
```

### Codex on runner

Files:

- config: `/root/.codex/config.toml`
- auth: `/root/.codex/auth.json`
- symlink target: `/workspace/home/.codex`

Observed state:

- current mode stayed on original ChatGPT path
- configured model: `gpt-5.5`
- auth remains in the Codex auth file
- MCP entries present for:
  - `exa`
  - `context7`
  - `clickup`
  - `serena` (disabled)

Inspect:

```bash
ssh zeabur-runner 'sed -n "1,220p" /root/.codex/config.toml'
ssh zeabur-runner 'python3 - <<\"PY\"\nimport json; print(json.load(open(\"/root/.codex/auth.json\")))\nPY'
```

### OpenCode on runner

Files:

- config: `/workspace/config/opencode/opencode.json`

Observed state:

- current default model in config: `9router/cx/gpt-5.5`
- custom providers configured include `9router` and `genfity`
- file is secret-bearing

Inspect:

```bash
ssh zeabur-runner 'sed -n "1,260p" /workspace/config/opencode/opencode.json'
```

### Other runner config directories

- `/workspace/config/claude-code`
- `/workspace/config/claude-code-router`
- `/workspace/config/hermes`
- `/workspace/config/llm`
- `/workspace/config/multica`
- `/workspace/config/opencode`
- `/workspace/config/paperclip`

## Multica project

### Zeabur object

- Project: `Multica`
- Project ID: `6a1faee98197c9aa0ae31bc2`
- Region/server: `Digital_Ocean_1`
- Region server ID: `server-6a1fa910cbf5edab5ff3d0a7`

### Public URLs

- app: `https://taasdasd.zeabur.app/`
- workspace settings/tokens: `https://taasdasd.zeabur.app/easy-rent-bali/settings?tab=tokens`

Public app observations:

- responds `200`
- Next.js frontend
- title: `Multica — Project Management for Human + Agent Teams`
- metadata describes it as an open-source platform for human + agent teams

### Multica services in Zeabur

1. PostgreSQL
   - service ID: `6a1faf0d8197c9aa0ae31bc5`
   - internal DNS: `postgresql.zeabur.internal`
   - port forwarding: enabled
   - forwarded TCP: `32569 -> 5432`

2. backend
   - service ID: `6a1faf0d8197c9aa0ae31bc6`
   - internal DNS: `backend.zeabur.internal`
   - port forwarding: disabled
   - port: `8080` (`api`, HTTP)

3. frontend
   - service ID: `6a1faf0d8197c9aa0ae31be2`
   - internal DNS: `frontend.zeabur.internal`
   - port forwarding: disabled
   - port: `3000` (`web`, HTTP)

4. gateway
   - service ID: `6a1faf0d8197c9aa0ae31be3`
   - internal DNS: `gateway.zeabur.internal`
   - port forwarding: disabled
   - port: `3000` (`proxy`, HTTP)

Operationally:

- the public `https://taasdasd.zeabur.app/` site is serving the frontend app

### Runner-side Multica daemon

Files on runner:

- config: `/workspace/config/multica/config.json`
- daemon ID: `/workspace/config/multica/daemon.id`
- daemon log: `/workspace/config/multica/daemon.log`
- daemon PID file: `/workspace/config/multica/daemon.pid`

What config points to:

- server URL: `https://taasdasd.zeabur.app`
- app URL: `https://taasdasd.zeabur.app`
- workspace: `Easy Rent Bali`
- workspace ID present in config
- token present in config

What the daemon log showed historically:

- daemon version: `0.3.15`
- registered runtimes:
  - `claude`
  - `hermes`
- watched workspace: `Easy Rent Bali`

Current daemon status:

- running
- health server listening on `127.0.0.1:19514`
- active runtimes registered:
  - `claude`
  - `codex`
  - `opencode`
  - `hermes`
  - `pi`
  - `copilot`
- verified autostart path:
  - removed `/root/.multica/config.json`
  - restarted the supervised Hermes dashboard
  - wrapper recreated auth from `/workspace/config/multica/config.json`
  - Multica daemon came back automatically and re-registered all 6 runtimes

Inspect:

```bash
ssh zeabur-runner 'for f in /workspace/config/multica/*; do echo "## $f"; sed -n "1,160p" "$f" 2>/dev/null || true; done'
```

## What was used in this session

### Connection methods used

Zeabur CLI:

```bash
zeabur project list --json
zeabur service list --project-id 6a20ce0af1be9943f1f89bb4 --json
zeabur service get --id service-6a20e044f1be9943f1f89efd --env-id 6a20ce0a95b39806d284a4c0 --json
zeabur service network --id service-6a20e044f1be9943f1f89efd --env-id 6a20ce0a95b39806d284a4c0 --json
zeabur domain list --id service-6a20e044f1be9943f1f89efd --env-id 6a20ce0a95b39806d284a4c0 --json
zeabur service list --project-id 6a1faee98197c9aa0ae31bc2 --json
zeabur service get --id 6a1faf0d8197c9aa0ae31bc5 --json
zeabur service network --id 6a1faf0d8197c9aa0ae31bc5 --json
```

SSH to runner:

```bash
ssh -F /dev/null -p 30309 root@139.59.229.185
```

Hermes verification:

```bash
curl -sS http://127.0.0.1:9119/api/model/info
curl -I -L -sS https://runnerubu1hermes.zeabur.app/
curl -I -L -sS https://runnerubu1hermes.zeabur.app/sessions
```

Multica verification:

```bash
curl -I -L -sS https://taasdasd.zeabur.app/
curl -I -L -sS 'https://taasdasd.zeabur.app/easy-rent-bali/settings?tab=tokens'
```

### Secret names referenced during the session

These names were referenced or verified during the session:

- `ZEABUR_TOKEN` or Zeabur token in `~/.config/zeabur/cli.yaml`
- `OMNIROUTE_API_KEY`
- `GENFITY_API_KEY`
- `ROUTER9_API_KEY`
- `ANTHROPIC_AUTH_TOKEN`
- Codex auth tokens in `/root/.codex/auth.json`
- OpenCode provider API keys in `/workspace/config/opencode/opencode.json`
- Multica token in `/workspace/config/multica/config.json`

I did not copy raw values into this file.

## Session notes

These were the working notes/checkpoints from the session:

> I’m pulling the current live state from the Zeabur runner and the local Zeabur tooling now. I’ll keep it to concrete inventory: services, access paths, installed agents, config locations, and anything that matters operationally.

> I’ve got the Zeabur CLI locally and your cached Zeabur config. Next I’m pulling the live inventory from the runner itself and seeing what the CLI can still tell us about both service IDs directly.

> The runner is healthy and the dashboard is live. I’m filling in the missing operational details now: actual install paths, versions, supervisor wiring, and what `multica` is storing under `/workspace/config`.

> I’ve got the runner install paths and most versions already. I’m polling the rest of that same SSH inventory now so I can give you the final picture in one pass instead of half-complete snippets.

> I’ve got the runner internals. Now I’m asking Zeabur for the two project/service records directly so I can tie the live container state back to the actual Zeabur objects, domains, and networking.

> I’ve got the Zeabur object model now: runner project/service IDs and the four Multica services. I’m grabbing the per-service status, domains, and network mapping for Multica so the summary is actually usable.

> I can’t get the Multica environment ID from the CLI surface directly, so I’m verifying the two public URLs themselves now. That at least lets me tie the public app behavior back to the four service layout we already have from Zeabur.

> The public `taasdasd.zeabur.app` site is definitely the Multica frontend: Next.js app, title `Multica — Project Management for Human + Agent Teams`. I’m checking the runner-side `multica` daemon files too, since there’s a separate local agent/daemon config under `/workspace/config/multica`.

> I found the runner-side Multica daemon config too. It’s pointed at `https://taasdasd.zeabur.app`, bound to the `Easy Rent Bali` workspace, and it’s registering exactly two runtimes there: `claude` and `hermes`.

> One useful correction: the Multica daemon is configured on the runner, but it is not currently running. The old log shows successful registration before, but there’s no live process and no health server on `127.0.0.1:19514` right now.

> I confirmed the actual daemon auth requirement too: Multica needs its authenticated `/root/.multica/config.json` state present at runtime. I patched the runner helper so it reconstructs that state from the persisted `/workspace/config/multica/config.json` before launching the daemon.

> Final verification passed: after deleting `/root/.multica/config.json` and restarting the supervised Hermes dashboard, the wrapper recreated Multica auth, started the daemon automatically, and registered all six installed runtimes.

## Bottom line

- The Ubuntu runner is a single Zeabur service running `sshd` and Hermes dashboard persistently.
- The Ubuntu runner also auto-starts the Multica daemon through the Hermes supervisor startup path.
- Claude, Codex, OpenCode, Copilot, Pi, and cc-switch are installed as CLIs, not long-running services.
- Hermes and the Multica daemon are the active long-running services on the runner right now.
- The Multica Zeabur project has 4 services:
  - `PostgreSQL`
  - `backend`
  - `frontend`
  - `gateway`
- The public `https://taasdasd.zeabur.app/` app is live and is the Multica frontend.
- The runner has a separate Multica daemon config for the `Easy Rent Bali` workspace, but that daemon is currently stopped.
