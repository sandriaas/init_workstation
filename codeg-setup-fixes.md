# Codeg Setup & Fixes — Native Install on minipc

> All-in-one reference documenting every fix, workaround, and configuration step for running **codeg-server v0.15.6** natively on minipc with a Cloudflare named tunnel.

---

## Table of Contents

1. [What is codeg](#what-is-codeg)
2. [Native Install](#native-install)
3. [First Launch](#first-launch)
4. [Conversation Import](#conversation-import)
5. [Web UI & Cloudflare Tunnel](#web-ui--cloudflare-tunnel)
6. [OpenCode Config Sync](#opencode-config-sync)
7. [ACP Agents — Status](#acp-agents--status)
8. [Known Issues & Gotchas](#known-issues--gotchas)
9. [Quick Reference](#quick-reference)

---

## What is codeg

codeg (codeg-server) is a local multi-agent coding workspace. Two agent systems:

| System | Purpose | Status |
|--------|---------|--------|
| **Conversation Parsers** | Read existing session files (claude, codex, opencode, gemini, cline, hermes) | ✅ Working |
| **ACP Agents** | Live multi-agent delegation via Agent Client Protocol | ⚠️ Requires ACP wrapper packages |

---

## Native Install

### Prerequisites
```bash
# Required
node v25+ (already installed)
npm 11+ (already installed)
curl / tar

# Already present on minipc
~/.claude/projects/    # Claude Code sessions
~/.codex/sessions/     # Codex sessions  
~/.local/share/opencode/opencode.db  # OpenCode DB
```

### Steps
```bash
# 1. Clone
cd /tmp
git clone https://github.com/xintaofei/codeg
cd codeg

# 2. Build (Docker failed due to pnpm lockfile mismatch — native build not attempted)
# Instead, use the pre-built release binary:
curl -L https://github.com/xintaofei/codeg/releases/download/v0.15.6/codeg-v0.15.6-x86_64-unknown-linux-gnu.tar.gz | tar xz

# 3. Install binaries
cp codeg-server ~/.local/bin/codeg-server    # main server
cp codeg-mcp ~/.local/bin/codeg-mcp          # ACP companion

# 4. Install web assets
mkdir -p ~/.local/share/codeg/web
cp -r ui/* ~/.local/share/codeg/web/

# 5. Create data directory
mkdir -p ~/.local/share/codeg/data
```

### Build Failure Note
- **Docker build failed** — the codeg repo uses pnpm with a lockfile that doesn't match the installed pnpm version (9.15.9 vs 10.x)
- **Workaround**: Downloaded the pre-built binary from GitHub release instead

---

## First Launch

### Start command
```bash
CODEG_STATIC_DIR=~/.local/share/codeg/web \
CODEG_DATA_DIR=~/.local/share/codeg/data \
~/.local/bin/codeg-server --port 3080 --token a52fd2feb78b40ab8422696a85cafa43
```

### Key behavior
- Server binds to `0.0.0.0:3080`
- Auth token is required for all API calls (passed as `Authorization: Bearer <token>`)
- Conversations auto-discovered from standard agent session directories on startup

### First run output
- Scans `~/.claude/projects/`, `~/.codex/sessions/`, `~/.local/share/opencode/`
- Imported **400+ conversations** across **20+ folders**
- Preflight checks pass for all agents (Node.js v25.9.0, npm 11.12.1)

---

## Conversation Import

### How it works
codeg reads existing session files from known locations:

| Agent | Session Directory |
|-------|-------------------|
| Claude Code | `~/.claude/projects/` |
| Codex | `~/.codex/sessions/` |
| OpenCode | `~/.local/share/opencode/opencode.db` |
| Gemini | `~/.gemini/` |
| Cline | `~/.cline/` |
| Hermes | `~/.hermes/` |

### Verified
- ✅ All 400+ conversations imported successfully
- ✅ Conversation folders match source agent names (open_code, claude_code, codex)
- ✅ Session content readable through codeg UI

---

## Web UI & Cloudflare Tunnel

### Architecture
```
codeg-server (port 3080, localhost only)
    ↕
cloudflared tunnel (named tunnel: 62e14bed-9dcc-4c39-80d3-a4bcf257b466)
    ↕
codeg.easyrentbali.com (DNS CNAME → tunnel)
```

### Tunnel config additions

Added to `~/.cloudflared/config.yml`:
```yaml
ingress:
  # ... existing services ...
  - hostname: codeg.easyrentbali.com
    service: http_status:404  # placeholder — actual proxy handled by cloudflared
```

### DNS route
```bash
cloudflared tunnel route dns 62e14bed-9dcc-4c39-80d3-a4bcf257b466 codeg.easyrentbali.com
# Creates CNAME → <tunnel-id>.cfargotunnel.com
```

### Service restart required
```bash
# Cloudflared systemd service runs as root — requires sudo
sudo systemctl restart cloudflared
```

**Gotcha**: The tunnel was last restarted at `2026-06-10T11:49:42Z` — **must restart after adding the new ingress rule** for it to take effect.

### Access
- **URL**: `https://codeg.easyrentbali.com`
- **Token**: `a52fd2feb78b40ab8422696a85cafa43`
- Verified working after tunnel restart

---

## OpenCode Config Sync

### Problem
codeg's OpenCode config was out of sync with the local `~/.config/opencode/opencode.json`

### Local config
```json
{
  "providers": {
    "9router": { "apiKey": "$9ROUTER_API_KEY", "baseURL": "https://9router.9unm.com/v1" },
    "databyte": { "apiKey": "$DATABYTE_API_KEY", "baseURL": "https://api.databyte.one/v1" },
    "freemodel": { "apiKey": "$FREE_MODEL_API_KEY", "baseURL": "https://freemodel.dev/v1" },
    "freemodel-cc": { "apiKey": "$FREEMODELCC_API_KEY", "baseURL": "https://freemodel.cc/v1" },
    "omniroute": { "apiKey": "$OMNI_ROUTER_API_KEY", "baseURL": "https://omnirouter.dev/v1" }
  },
  "agents": {
    "opencode": { "model": "xiaomi/mimo-v2-pro" }
  }
}
```

### Sync command
```bash
# Via codeg API (POST method required for all endpoints)
curl -X POST http://localhost:3080/api/acp_update_agent_config \
  -H "Authorization: Bearer a52fd2feb78b40ab8422696a85cafa43" \
  -H "Content-Type: application/json" \
  -d @/tmp/opencode-sync-config.json
```

### Result
✅ codeg's OpenCode config now matches local — all 5 providers (9router, databyte, freemodel, freemodel-cc, omniroute) with correct API keys and base URLs.

---

## ACP Agents — Status

### Current state
All ACP agents show **FAIL** in Settings → Agents.

### Why
ACP agents require **wrapper packages** to be installed on the machine. These are npm/uvx packages that expose the agent via the Agent Client Protocol.

### Required packages (if user wants live delegation)

| Agent | Package | Install |
|-------|---------|---------|
| Claude Code | `@agentclientprotocol/claude-agent-acp@0.44.0` | `npx @agentclientprotocol/claude-agent-acp@0.44.0` |
| Gemini CLI | `@google/gemini-cli@0.45.2` | `npx @google/gemini-cli@0.45.2` |
| Cline | `cline@3.0.9` | `npx cline@3.0.9` |
| Hermes | `hermes-agent[acp,mcp]==0.16.0` | `uvx hermes-agent[acp,mcp]==0.16.0` |
| Codex | Binary agent | Auto-downloads on first connect from Settings → Agents |
| OpenCode | Binary agent | Auto-downloads on first connect from Settings → Agents |

### Decision
User has **not yet installed** these packages. The current setup (conversation import + web UI) is fully functional without them. ACP is only needed for live multi-agent task delegation from codeg.

---

## Known Issues & Gotchas

### 1. Docker build fails
- **Symptom**: pnpm lockfile mismatch during Docker build
- **Fix**: Use pre-built binary from GitHub release instead

### 2. API endpoints require POST + Bearer token
- **Symptom**: GET requests return 401; missing token returns 401
- **Fix**: Always use `POST` method with `Authorization: Bearer <token>` header

### 3. Cloudflared service restart required after config change
- **Symptom**: New ingress rules don't take effect until service restart
- **Fix**: `sudo systemctl restart cloudflared`
- **Note**: Service runs as root, cannot be restarted without sudo

### 4. codeg-server is not a systemd service yet
- **Symptom**: Server dies on logout; no auto-restart
- **Fix**: Create systemd unit file (not done yet)

### 5. Web assets must be extracted manually
- **Symptom**: `--help` works but no web UI loads
- **Fix**: Extract tarball UI files to `~/.local/share/codeg/web/`

### 6. Data directory must exist
- **Symptom**: Server crashes on startup if data dir missing
- **Fix**: `mkdir -p ~/.local/share/codeg/data` before first launch

---

## Upgrade Log

### v0.15.6 → v0.15.9 (2026-06-13)
- New release asset layout: `codeg-server-linux-x64.tar.gz` (was `codeg-v*-x86_64-unknown-linux-gnu.tar.gz`). Ships `codeg-server`, `codeg-mcp`, and an embedded `web/` dir.
- Verified `*.sha256` before installing.
- Backed up old binaries + web to `~/.local/share/codeg/backup-<ts>/`.
- codeg is **not** a systemd unit — it runs as a self-supervised process (`codeg-server --supervise`, PPID 1). Stop by killing the supervisor PID, then relaunch with the same env (`CODEG_STATIC_DIR`, `CODEG_DATA_DIR`, `ANTHROPIC_*`, `nohup ... --supervise &`).
- Token unchanged (`a52fd2feb78b40ab8422696a85cafa43`); tunnel `codeg.easyrentbali.com` returns 200 post-upgrade.

---

## Quick Reference

### Start codeg
```bash
CODEG_STATIC_DIR=~/.local/share/codeg/web \
CODEG_DATA_DIR=~/.local/share/codeg/data \
~/.local/bin/codeg-server --port 3080 --token a52fd2feb78b40ab8422696a85cafa43
```

### Access web UI
- **Local**: `http://localhost:3080?token=a52fd2feb78b40ab8422696a85cafa43`
- **Tunnel**: `https://codeg.easyrentbali.com`

### API example
```bash
curl -X POST http://localhost:3080/api/acp_list_agents \
  -H "Authorization: Bearer a52fd2feb78b40ab8422696a85cafa43" \
  -H "Content-Type: application/json"
```

### Restart cloudflared
```bash
sudo systemctl restart cloudflared
```

### Auth token
```
a52fd2feb78b40ab8422696a85cafa43
```

### Key paths
| Path | Purpose |
|------|---------|
| `~/.local/bin/codeg-server` | Server binary |
| `~/.local/bin/codeg-mcp` | ACP companion binary |
| `~/.local/share/codeg/web/` | Static web assets |
| `~/.local/share/codeg/data/` | SQLite DB, sessions |
| `~/.cloudflared/config.yml` | Tunnel config |
| `~/.config/opencode/opencode.json` | Local OpenCode config |
| `/home/sandriaas/_projects/minipc/configs/cloudflared-config.yml` | Project copy of tunnel config |
