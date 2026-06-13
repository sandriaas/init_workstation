# Synara Fixes Log

> Last updated: 2026-06-12 — Synara v0.1.9

## 1. OpenCode SQLite Error (`NOT NULL constraint failed: session_message.seq`)

**Problem:** When OpenCode switches agents (`session.next.agent.switched`), it tries to insert a message without providing the `seq` value, violating the `NOT NULL` constraint.

**Fixes:**

1. **Updated OpenCode SDK** — `@opencode-ai/sdk` from `1.15.13` → `1.17.3`
2. **Fixed SQLite schema** — Added `DEFAULT 0` to the `seq` column:
   ```sql
   -- Rebuilt session_message table with seq DEFAULT 0
   CREATE TABLE session_message_new (
       id TEXT PRIMARY KEY,
       session_id TEXT NOT NULL,
       type TEXT NOT NULL,
       time_created INTEGER NOT NULL,
       time_updated INTEGER NOT NULL,
       data TEXT NOT NULL,
       seq INTEGER NOT NULL DEFAULT 0,
       CONSTRAINT fk_session_message_session_id_session_id_fk FOREIGN KEY (session_id) REFERENCES session(id) ON DELETE CASCADE
   );
   INSERT INTO session_message_new SELECT * FROM session_message;
   DROP TABLE session_message;
   ALTER TABLE session_message_new RENAME TO session_message;
   -- Recreate indexes
   CREATE INDEX session_message_time_created_idx ON session_message(time_created);
   CREATE INDEX session_message_session_time_created_id_idx ON session_message(session_id, time_created, id);
   CREATE INDEX session_message_session_type_seq_idx ON session_message(session_id, type, seq);
   CREATE UNIQUE INDEX session_message_session_seq_idx ON session_message(session_id, seq);
   ```

**Files modified:**
- `apps/server/src/provider/Layers/OpenCodeAdapter.ts` — patched model provider filtering to show all providers
- `package.json` — updated `@opencode-ai/sdk` dependency

---

## 2. OpenCode Models Not Showing All Providers

**Problem:** Synara only showed ~19 OpenCode models (only `opencode-go/*`) instead of all 179 models from `opencode.json`.

**Root cause:** `resolvePreferredOpenCodeModelProviders()` filtered to only "connected" providers (those in OpenCode's `auth.json`). Custom providers (9router, omniroute, freemodel, databyte) had API keys inline in `opencode.json` but weren't registered as "connected" credentials.

**Fix:** Patched `OpenCodeAdapter.ts` to:
1. Use all providers from inventory (`providerList.all`) instead of only "connected" ones
2. Use all CLI models directly from `opencode models` instead of filtering by preferred providers

**File modified:**
- `apps/server/src/provider/Layers/OpenCodeAdapter.ts`
  - `resolvePreferredOpenCodeModelProviders()` — changed `connectedProviders` → `allProviders`
  - `listModels()` — removed `preferredCliModels` filter, use all `cliModels` directly

---

## 3. Synara Auth Error (`SocketOpenError`)

**Problem:** WebSocket auth failed with `SocketOpenError` because the web app didn't know the `--auth-token` passed to the server.

**Fix:** Restarted Synara **without** `--auth-token` flag (`authEnabled: false`). Auth is unnecessary since the app is behind an authenticated Cloudflare tunnel.

---

## 4. SSH MaxSessions Limit

**Problem:** emdash couldn't open enough SSH channels (default `MaxSessions 10`).

**Fix:** Changed `/etc/ssh/sshd_config`:
```ssh
MaxSessions 500
```
Then reloaded sshd.

---

## 5. Cloudflare Tunnel Setup

**Added DNS records & ingress rules** for the existing `minipc-local` named tunnel:

| Service | URL |
|---------|-----|
| Synara | `synara-minipc-local.easyrentbali.com` → `localhost:3773` |
| Paseo | `paseo-minipc-local.easyrentbali.com` → `localhost:6767` |

**File modified:**
- `~/.cloudflared/config-minipc-local.yml`

---

## 6. Claude Config/Model Resolution

**Problem:** Synara only showed hardcoded Claude models (Fable 5, Opus 4.8, etc.) and didn't respect the user's Claude config files (`~/.claude/settings.local.json`, `~/.claude/projects.json`).

**Fix:** Modified `listModels` in the Claude adapter to read Claude config files and extract custom models from env vars:
- `ANTHROPIC_MODEL`
- `ANTHROPIC_REASONING_MODEL`
- `ANTHROPIC_DEFAULT_HAIKU_MODEL`
- `ANTHROPIC_DEFAULT_SONNET_MODEL`
- `ANTHROPIC_DEFAULT_OPUS_MODEL`

Custom models appear in the UI with a `(config)` label alongside the built-in models.

**File modified:**
- `apps/server/src/provider/Layers/ClaudeAdapter.ts`
  - Added `fs`, `os`, `path` imports
  - Modified `listModels()` to read `settings.local.json`, `projects.json`, `settings.json`

---

## 7. Paseo Setup

- Installed `@getpaseo/cli` v0.1.91
- Set daemon password to `121212`
- Daemon running on `0.0.0.0:6767`
- Pairing link available via `paseo daemon pair`

---

## Files Changed (Summary)

| File | Change |
|------|--------|
| `apps/server/src/provider/Layers/OpenCodeAdapter.ts` | Fixed provider filtering & CLI model discovery |
| `apps/server/src/provider/Layers/ClaudeAdapter.ts` | Added Claude config file reading for custom models |
| `apps/server/package.json` | Updated `@opencode-ai/sdk` to `^1.17.4` |
| `~/.local/share/opencode/opencode.db` | Schema migration on `session_message.seq` |
| `~/.cloudflared/config-minipc-local.yml` | Added Synara & Paseo ingress rules |
| `/etc/ssh/sshd_config` | MaxSessions 10 → 500 |

---

## Known Issues

### Codex Token Refresh Error
`"Failed to refresh token: 400 Bad Request: Invalid 'refresh_token': empty string"`

This is a **Codex auth issue**, not a Synara bug. Codex's stored `refresh_token` is empty or missing. Fix:
```bash
codex login          # re-authenticate
# or
codex auth status    # check current auth state
```

### Synara Auth
Auth is currently disabled (`authEnabled: false`). If re-enabling with `--auth-token`, append `?token=<token>` to the URL for WebSocket to connect — the web app doesn't show a login prompt on its own.
