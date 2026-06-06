# Codex-Auth: Importing, Diagnosing, and Reference

Reference for importing ChatGPT/Codex account snapshots into `~/.codex/accounts/` via `codex-auth`, with two worked case studies: a CLIProxyAPI (CPA) flat-token import (15th account) that turned out to have a server-revoked token, and a ChatGPT web-session bootstrap import (16th account) that required manual conversion and a synthetic `id_token`.

## Context

The user has 16 ChatGPT OAuth account snapshots stored in `~/.codex/accounts/*.auth.json` plus a `registry.json` index. Two non-standard blobs were imported into the set: a 15th account from a CLIProxyAPI (CPA) flat-token JSON (turned out to have a server-revoked token), and a 16th account from a ChatGPT web-session bootstrap JSON (no `refresh_token`, required a synthetic `id_token`).

Working directory: `/home/sandriaas/_projects/minipc` (project files; auth lives outside the repo at `~/.codex/`).

## Quick Reference

### Which import path for which blob shape?

| Blob shape | Telltale fields | Tool path | Refreshable? |
|---|---|---|---|
| **ChatGPT OAuth snapshot** (the 14 originals) | `tokens.{id_token,access_token,refresh_token,account_id}`, `auth_mode: "chatgpt"` | already in place | yes |
| **CLIProxyAPI flat** (`type: "codex"`) | `access_token`, `refresh_token`, `id_token`, `account_id`, `email`, all top-level | `codex-auth import --cpa <file>` | yes |
| **ChatGPT web-session bootstrap** (DevTools / `__remixContext`) | `accessToken` (camelCase), `sessionToken` (JWE), `user`, `account`, `expires`, **no `refresh_token`** | manual write + `codex-auth import --purge` | **no** |

### Standard import flow

```bash
# 1. Backup (always — even for --cpa)
BACKUP=~/.codex/accounts.backup.$(date +%Y%m%d-%H%M%S)
cp -a ~/.codex/accounts "$BACKUP"

# 2. Stage
chmod 600 /tmp/codex-import-<id>.json

# 3a. CPA flat format
codex-auth import --cpa /tmp/codex-import-<id>.json

# 3b. Web-session format (no refresh_token)
#    Compute filename, write file with synthetic id_token, register
b64u() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
FILE=~/.codex/accounts/$(b64u "user-<user_id>")::$(b64u "<uuid>").auth.json
# ... write JSON (see section 10) ...
chmod 600 "$FILE"
codex-auth import --purge

# 4. Verify
codex-auth list
ls ~/.codex/accounts/*.auth.json | wc -l

# 5. Liveness test (always)
TOK=$(jq -r '.tokens.access_token' <new_auth_file>)
curl -sS -o /tmp/wham.json -w "HTTP %{http_code}\n" \
  -H "Authorization: Bearer $TOK" -H "Accept: application/json" \
  "https://chatgpt.com/backend-api/wham/usage"

# 6. Cleanup
shred -u /tmp/codex-import-<id>.json /tmp/wham.json
```

### Filename convention

```
<b64(user-...)>::<b64(uuid)>.auth.json
```

`b64u` is base64url (no padding, `-_` instead of `+/`):

```bash
b64u() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
```

### Liveness test (after any import)

```bash
TOK=$(jq -r '.tokens.access_token' <new_auth_file>)
curl -sS -o /tmp/wham.json -w "HTTP %{http_code}\n" \
  -H "Authorization: Bearer $TOK" -H "Accept: application/json" \
  "https://chatgpt.com/backend-api/wham/usage"
jq -c '{email, plan_type, primary: .rate_limit.primary_window.used_percent, weekly: .rate_limit.secondary_window.used_percent}' /tmp/wham.json
shred -u /tmp/wham.json
```

| HTTP code | Meaning |
|---|---|
| 200 | Live, safe to switch |
| 401 `token_invalidated` | Server-side revoked — dead, do not bother switching |
| 401 other | Wrong audience/scope, try a different endpoint |
| 403 + Cloudflare challenge | Browser-gated endpoint, not usable from CLI |

### Common pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `--cpa`: `MissingRefreshToken` | Blob is web-session, not CPA | Switch to manual write path (section 10) |
| `--purge`: `MissingEmail` (or file silently skipped from registry) | `id_token` lacks standard top-level `email` claim (web-session access tokens put email under `https://api.openai.com/profile.email`) | Construct a synthetic `id_token` JWT with `email` at payload root |
| New file mode 0644, others 0600 | `--cpa` import doesn't preserve umask | `chmod 600` after import for parity |
| `last_used_at: null` in list | Never `codex-auth switch`ed to it | Normal until first use; flips to `Now` after switch |
| `last_usage: null` in list | No successful API refresh yet | Triggers automatically on next `list` / `status` |
| `401` in list table | Tool prints the raw integer `used_percent` value, which on a failed refresh can be the HTTP status code | Run the liveness test to confirm |

---

## 1. Locating the Auth Directory

The user said "not in this codebase but machine". Searched the filesystem:

```bash
ls -la ~/.codex/
```

Found:

- `/home/sandriaas/.codex/accounts/` — the per-account store
- `/home/sandriaas/.codex/auth.json` — the **active** account (Codex CLI reads this)
- `/home/sandriaas/.codex/config.toml` — Codex CLI config

The accounts directory contained exactly **14 `*.auth.json` files** (matching the user's count) plus 5 `auth.json.bak.<timestamp>` rotation snapshots and a `registry.json` + its rotation backups.

## 2. Schema of an Existing Auth File

Read one example: `dXNlci1qYnZGWllJTHB5djNtbUdpZjBIZzQ4cHk6OjQxZjUyYzkzLTczOGYtNDlhNy1hMDhhLTBmYjkzMDFiYTk4Nw.auth.json`

```json
{
  "auth_mode": "chatgpt",
  "OPENAI_API_KEY": null,
  "tokens": {
    "id_token":      "<JWT, alg=RS256, ~1.5KB>",
    "access_token":  "<JWT, alg=RS256, ~1.5KB>",
    "refresh_token": "rt_<scope>.<random>",
    "account_id":    "<uuid v4>"
  },
  "last_refresh": "<RFC3339 timestamp>"
}
```

**Shape notes:**

- `auth_mode` = `"chatgpt"` (OAuth flow, not API key).
- `OPENAI_API_KEY` = `null` — these accounts authenticate via OAuth tokens only.
- `id_token` and `access_token` are real JWTs. The `id_token` payload includes `email`, `email_verified`, `chatgpt_account_id`, `chatgpt_plan_type`, `chatgpt_user_id`, `organizations[]`, `exp`, `iat`. The `access_token` carries `session_id`, `scp: ["openid","profile","email","offline_access"]`, and `https://api.openai.com/auth` claims.
- `refresh_token` is opaque (`rt_…`), used to rotate the access token.
- `tokens.account_id` is the ChatGPT account UUID.
- `last_refresh` is when tokens were last rotated.

**Filename convention** (base64 of two values, joined by `::`):

```
<base64(user-...)>::<base64(uuid)>.auth.json
```

Example: `dXNlci1qYnZGWllJTHB5djNtbUdpZjBIZzQ4cHk6OjQxZjUyYzkzLTczOGYtNDlhNy1hMDhhLTBmYjkzMDFiYTk4Nw` decodes to `user-jbvFZ…4py::41f52c93-738f-49a7-a08a-0fb9301ba987`.

## 3. Confirming `codex-auth list` Reads These Files

Found the CLI in two pieces:

| File | Purpose |
|---|---|
| `/usr/bin/codex-auth` → `@loongphy/codex-auth/bin/codex-auth.js` (3.2KB shim) | Node entry, requires Node 22+, dispatches to platform package |
| `@loongphy/codex-auth-linux-x64/bin/codex-auth` (native ELF) | Real implementation |

The shim spawns the native binary with the user's argv. From the README, the command table confirms:

```
codex-auth list [--debug]              List all accounts
codex-auth login [--device-auth]       Add current account
codex-auth switch [<email>]            Switch active account
codex-auth remove                      Remove accounts
codex-auth status                      Show auto-switch, service, usage status
codex-auth import <path> [--alias …]   Import auth file or folder
codex-auth import --cpa [<path>]       Import CLIProxyAPI tokens
codex-auth import --purge [<path>]     Rebuild registry.json from auth files
```

**Strings extracted from the native binary confirm what `list` reads:**

```
~/.codex/accounts
registry.json
.auth.json
auth.json (active)
List available accounts.
```

So `codex-auth list` reads:

- `registry.json` — for the table data (email, alias, plan, 5h/weekly usage snapshots, `active` flag, `last_used_at`)
- Each `*.auth.json` — for live `account_id` + token presence

`codex-auth import --purge` does the reverse: rebuilds `registry.json` from the `*.auth.json` files.

## 4. The CPA Blob

The user pasted a flat-token JSON (CLIProxyAPI format). Key fields:

```json
{
  "access_token":  "<JWT>",
  "refresh_token": "rt.1.AAA…",
  "id_token":      "<JWT>",
  "account_id":    "5683b77b-2326-4688-adc7-694ffc43c7ac",
  "email":         "mailf85zhqie59@team.wenjie.codes",
  "outlook_email": "mailf85zhqie59@team.wenjie.codes",
  "expired":       "2026-06-15T15:24:37.496026+00:00",
  "last_refresh":  "2026-06-05T15:24:38.496070+00:00",
  "oai_password":  "qq2580115083",
  "disabled":      false,
  "status":        "success",
  "type":          "codex"
}
```

`type: "codex"` is the CPA "Codex" subtype — top-level tokens with no `tokens` wrapper, plus CPA-only metadata (`oai_password`, `outlook_email`, `expired`, `disabled`, `status`).

**Predicted target filename:**

```
<base64(user-YNkc3JGulXL6lhYEdJrnYB7D)>::<base64(5683b77b-2326-4688-adc7-694ffc43c7ac)>.auth.json
= dXNlci1ZTmtjM0pHdWxYTDZsaFlFZEpybllCN0Q6OjU2ODNiNzdiLTIzMjYtNDY4OC1hZGM3LTY5NGZmYzQzYzdhYw.auth.json
```

## 5. Import Flow (Executed)

### 5.1 Backup

```bash
BACKUP=~/.codex/accounts.backup.$(date +%Y%m%d-%H%M%S)
cp -a ~/.codex/accounts "$BACKUP"
```

Result: `/home/sandriaas/.codex/accounts.backup.20260606-234353/` (27 items: 14 `*.auth.json` + 5 `auth.json.bak.*` + 1 active `auth.json` (in 0) + 2 `registry.json` + 5 `registry.json.bak.*` + 2 `login-*` dirs).

### 5.2 Stage JSON

Wrote the CPA blob to `/tmp/codex-import-5683b77b.json` with the `write` tool, then `chmod 600`.

### 5.3 Import (no alias, per user request)

```bash
codex-auth import --cpa /tmp/codex-import-5683b77b.json
# ✓ imported  codex-import-5683b77b
```

The `--cpa` flag auto-detected the CPA flat format and converted to the nested `tokens` / `auth_mode: "chatgpt"` shape used by the 14 existing files. No `--alias` was used (user said "don't use alias") to keep the entry shape identical to the others.

### 5.4 Verify

```bash
ls ~/.codex/accounts/*.auth.json | wc -l   # 15 ✓
```

New file: `~/.codex/accounts/dXNlci1ZTmtjM0pHdWxYTDZsaFlFZEpybllCN0Q6OjU2ODNiNzdiLTIzMjYtNDY4OC1hZGM3LTY5NGZmYzQzYzdhYw.auth.json` (4765 bytes, mode 0644).

Sanity check of the new file (redacted):

```json
{
  "auth_mode": "chatgpt",
  "OPENAI_API_KEY": null,
  "last_refresh": "2026-06-05T15:24:38.496070+00:00",
  "tokens": {
    "access_token": "eyJhbGciOiJSUzI1NiIsImtpZ…",
    "id_token": "eyJhbGciOiJSUzI1NiIsImtpZ…",
    "refresh_token": "rt.1.AAAMJ…",
    "account_id": "5683b77b-2326-4688-adc7-694ffc43c7ac"
  }
}
```

`codex-auth list` now shows the new account at slot 09:

```
09 mailf85zhqie59@team.wenjie.codes   Business  401   401   -
```

### 5.5 Cleanup

```bash
shred -u /tmp/codex-import-5683b77b.json
```

## 6. The 401 Mystery

The new account shows `401 / 401 / -` in the list table, while the other 14 show real percentages and `Last activity: Now`.

### 6.1 What the columns mean

- `5H USAGE` / `WEEKLY USAGE` columns: `last_usage` from `registry.json`. The native tool prints the raw integer `used_percent` (or the literal HTTP status code if the live refresh failed).
- `LAST ACTIVITY`: `last_used_at` (epoch seconds). `-` means `null` — the account has never been `switch`ed to.

The new account's registry entry:

```json
{
  "account_key": "user-YNkc3JGulXL6lhYEdJrnYB7D::5683b77b-2326-4688-adc7-694ffc43c7ac",
  "chatgpt_account_id": "5683b77b-2326-4688-adc7-694ffc43c7ac",
  "chatgpt_user_id": "user-YNkc3JGulXL6lhYEdJrnYB7D",
  "email": "mailf85zhqie59@team.wenjie.codes",
  "alias": "",
  "account_name": null,
  "plan": "team",
  "auth_mode": "chatgpt",
  "created_at": 1780760702,
  "last_used_at": null,
  "last_usage": null,
  "last_usage_at": null,
  "last_local_rollout": null
}
```

`last_usage: null` + `last_used_at: null` explains the dashes.

### 6.2 Live verification (curl against the access token)

```bash
TOK=$(jq -r '.tokens.access_token' <new_auth_file>)

# 1) ChatGPT usage endpoint
curl -sS -o /tmp/wham-resp.json -w "HTTP %{http_code}\n" \
  -H "Authorization: Bearer $TOK" -H "Accept: application/json" \
  "https://chatgpt.com/backend-api/wham/usage"
# → HTTP 401
# {"error":{"code":"token_invalidated",
#   "message":"Your authentication token has been invalidated. Please try signing in again."},
#  "status":401}

# 2) Account check endpoint (team name)
curl -sS -o /tmp/check-resp.json -w "HTTP %{http_code}\n" \
  -H "Authorization: Bearer $TOK" -H "Accept: application/json" \
  "https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27"
# → HTTP 403 (Cloudflare JS challenge: "Enable JavaScript and cookies to continue")
```

### 6.3 Diagnosis

| Endpoint | Result | Meaning |
|---|---|---|
| `wham/usage` | `401 token_invalidated` | **OpenAI explicitly revoked this token server-side.** Not expired (JWT `exp: 2026-06-15`), not just CPA rejection — upstream kill switch. |
| `accounts/check/v4-2023-04-27` | `403` + Cloudflare challenge | Endpoint is browser-gated regardless of token state. |

The CPA tool minted a snapshot token (note `auth_provider: "workos"` and `sso_connection_id` claim in the id_token — WorkOS is a B2B SSO provider, not the normal `passwordless` flow). The token was likely bound to a session that has since been invalidated, or the CPA tool's token generation process is incompatible with OpenAI's session validation.

JWT payload hints (from the id_token, redacted):

- `auth_provider: "workos"` (Team/Enterprise SSO)
- `chatgpt_plan_type: "team"` (Business plan — confirmed by list output)
- `sso_connection_id: "conn_01KT9YVHEVYX3V4MK0A5J9R4EZ"`

## 7. Recovery

The 15th account as-imported is **unusable for live API calls** (token revoked). To get a working 15th account, re-authenticate live:

```bash
# Remove the dead snapshot first (optional, codex-auth will overwrite on re-login)
rm ~/.codex/accounts/dXNlci1ZTmtjM0pHdWxYTDZsaFlFZEpybllCN0Q6OjU2ODNiNzdiLTIzMjYtNDY4OC1hZGM3LTY5NGZmYzQzYzdhYw.auth.json
codex-auth import --purge

# Re-auth live (pops a browser/code pairing flow)
codex-auth login --device-auth
```

`--device-auth` runs `codex login --device-auth` under the hood, then writes a fresh `auth.json` + new `*.auth.json`. The old file gets rotated to `auth.json.bak.<timestamp>`.

## 8. File Map

| Path | Purpose |
|---|---|
| `~/.codex/accounts/*.auth.json` (16) | Per-account token snapshots. Filename: `<b64(user-…)>::<b64(uuid)>.auth.json` |
| `~/.codex/accounts/registry.json` | Index: email, alias, plan, auth_mode, last_used_at, last_usage snapshots. Schema v3. |
| `~/.codex/accounts/auth.json.bak.<ts>` | Rotation snapshots written by `codex-auth` on every overwrite. |
| `~/.codex/accounts/registry.json.bak.<ts>` | Registry rotation snapshots. |
| `~/.codex/auth.json` | **Active** account (the one Codex CLI loads at startup). |
| `~/.codex/config.toml` | Codex CLI config. |
| `~/.codex/accounts/login-*-0/` | Live login session scratch dirs. |
| `~/.codex/accounts.backup.20260606-234353/` | One-shot snapshot before the 15th-account import. |
| `~/.codex/accounts.backup.20260607-000814/` | One-shot snapshot before the 16th-account import. |
| `/usr/lib/node_modules/@loongphy/codex-auth/` | CLI package (npm). |
| `/usr/lib/node_modules/@loongphy/codex-auth-linux-x64/bin/codex-auth` | Native binary, ELF x86-64, debug symbols present, not stripped. |
| `/usr/bin/codex-auth` | Symlink to the npm shim. |

## 9. Lessons

- **`codex-auth import --cpa` is the supported path for flat CPA/CLIProxyAPI tokens** — it handles the `tokens`-wrapper conversion, sets `auth_mode: "chatgpt"`, and registers in `registry.json` in one step. Manual conversion via `jq` is a viable fallback.
- **CPA-generated tokens are snapshots, not live sessions.** A token that decodes successfully (JWT still valid) can still be `token_invalidated` server-side. Always verify with a live API call after import, not just by parsing the JWT.
- **`401` in the list table = HTTP status, not percent.** A `last_usage: null` entry also displays as `null`/empty depending on the tool version. The native binary prints the raw integer for any non-null `used_percent`, including HTTP error codes.
- **Backup the accounts dir before any import or `switch`.** The CLI rotates automatically (`auth.json.bak.<ts>`), but a one-shot external `cp -a` is cheap insurance and rolls back cleanly.
- **Cleanup `/tmp` staging files** with `shred -u`, not just `rm` — JWTs are bearer tokens, and `/tmp` is often world-readable on shared systems.
- **Cloudflare-gated endpoints** (`accounts/check/v4-2023-04-27`) cannot be queried from a CLI. Even with a valid token, the response is a JS challenge. Team-name refresh is browser-only.
- **Web-session bootstrap is a different shape than CPA.** `accessToken` (camelCase) + JWE `sessionToken` + `user`/`account` blocks, **no `refresh_token`**. Treat it as a 3-month TTL snapshot. If a rotatable long-lived account is needed for the same email, re-auth via `codex-auth login --device-auth`.
- **`--cpa` validates `refresh_token` upfront.** A web-session blob fails with `MissingRefreshToken` before any conversion. Don't fight it — switch to the manual write path.
- **`--purge` reads `email` from `tokens.id_token`.** The web-session's only JWT is the `accessToken`, which puts email under the namespaced `https://api.openai.com/profile.email` claim. Construct a synthetic `id_token` (real header + payload with standard `email` + random signature) — the tool decodes for display, not verifies.
- **Synthetic `id_token` works today, but watch for verification.** If a future `codex-auth` release verifies the JWT signature, web-session imports will break and need a real OAuth round-trip to fix.
- **Use `agent-browser` for deeper validation** (not yet done in this session): load `https://chatgpt.com` with the `accessToken` pre-set as `Authorization: Bearer …` via CDP `page.setExtraHTTPHeaders`, or set the `__Secure-next-auth.session-token` cookie with the JWE `sessionToken`. Confirms full web UI works, not just the API. Useful when the 3-month window is critical.

---

## 10. Second Import Case: Web-Session Bootstrap (14 → 16)

A second blob, this time a **ChatGPT web session payload** (the kind of data you see in browser DevTools on `chatgpt.com` when logged in, or in `__remixContext`).

### 10.1 Shape differences from CPA

```json
{
  "WARNING_BANNER": "...",
  "user":      { "id": "user-…", "name": "...", "email": "...", "idp": "auth0", "iat": …, "amr": ["pwd"], "mfa": false },
  "expires":   "2026-09-03T16:22:36.625Z",
  "account":   { "id": "18174c1e-…", "planType": "plus", "structure": "personal", … },
  "accessToken":  "<JWT>",     // camelCase! not "access_token"
  "authProvider": "openai",
  "sessionToken": "<JWE>",     // encrypted, not usable as bearer
  "rumViewTags": { … }
}
```

| Field | CPA | Web-session |
|---|---|---|
| Access token key | `access_token` (snake) | `accessToken` (camel) |
| Refresh token | `refresh_token` (real) | **missing** |
| ID token | `id_token` (real) | **missing** |
| Session token | n/a | `sessionToken` (JWE, encrypted) |
| User info | `email` only | `user.{id,name,email,idp,amr,mfa}` |
| Account info | `account_id` only | `account.{id,planType,…}` |
| Plan type | from id_token JWT claim | top-level `account.planType` |
| Expiry | `expired` | `expires` (3 months out) |
| `idp` | n/a | `auth0` (password AMR, no MFA) |

### 10.2 `--cpa` rejects it

```bash
codex-auth import --cpa /tmp/codex-import-18174c1e.json
# ✗ skipped   codex-import-18174c1e: MissingRefreshToken
# Import Summary: 0 imported, 1 skipped
```

CPA validates the structure upfront and bails if no `refresh_token` is present.

### 10.3 Manual conversion path

Three steps: (1) compute filename, (2) write file with synthetic `id_token`, (3) `--purge` to register.

**Step 1 — compute filename:**

```bash
b64u() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
echo "$(b64u 'user-rhkxPDnWRQULhe2IKgOvJrIy')::$(b64u '18174c1e-86ad-4ce8-9217-63126a1bf803').auth.json"
# → dXNlci1yaGt4UERuV1JRVUxoRTJJS2dPdkpySXk6OjE4MTc0YzFlLTg2YWQtNGNlOC05MjE3LTYzMTI2YTFiZjgwMw.auth.json
```

**Step 2 — write the file** at the computed path:

```json
{
  "auth_mode": "chatgpt",
  "OPENAI_API_KEY": null,
  "tokens": {
    "id_token":      "<synthetic JWT, see below>",
    "access_token":  "<from accessToken>",
    "refresh_token": "",
    "account_id":    "<from account.id>"
  },
  "last_refresh": "<current RFC3339 timestamp>"
}
```

**Step 2a — construct a synthetic `id_token`.** `codex-auth import --purge` reads the `email` claim from `tokens.id_token` to populate the registry. The web-session's only JWT is the `accessToken`, which puts email under the namespaced `https://api.openai.com/profile.email` claim. We need a standard `email` claim at the payload root.

The tool decodes for display, not verifies — so the signature can be random bytes:

```bash
b64url() { python3 -c "import base64,sys;print(base64.urlsafe_b64encode(sys.stdin.buffer.read()).rstrip(b'=').decode())"; }

HDR=$(printf '%s' '{"alg":"RS256","kid":"19344e65-bbc9-44d1-a9d0-f957b079bd0e","typ":"JWT"}' | b64url)
PAY=$(printf '%s' '{"at_hash":"bPMtD6sPQ_evLFtIiGrH2Q","aud":["app_X8zY6vW2pQ9tR3dE7nK1jL5gH"],"auth_provider":"openai","auth_time":1780578151,"email":"sean973austin@gmail.com","email_verified":true,"exp":1890987000,"https://api.openai.com/auth":{"chatgpt_account_id":"18174c1e-86ad-4ce8-9217-63126a1bf803","chatgpt_plan_type":"plus","chatgpt_user_id":"user-rhkxPDnWRQULhe2IKgOvJrIy","user_id":"user-rhkxPDnWRQULhe2IKgOvJrIy"},"iat":1780578151,"iss":"https://auth.openai.com","jti":"0b6d2d71-33e1-4e2d-8c14-293e9f4181a4","sid":"78a1ef13-80e6-4876-b529-cdf383e43176","sub":"auth0|a3Qtki3o3878OTqEUoiMABtK"}' | b64url)
SIG=$(head -c 32 /dev/urandom | b64url)
ID_TOKEN="${HDR}.${PAY}.${SIG}"

# Inject into the file
jq --arg t "$ID_TOKEN" '.tokens.id_token = $t' "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
chmod 600 "$FILE"
```

**Required claims** (based on what `--purge` reads + what the 14 originals have):

- `email` (standard, top-level) — required, drives the registry entry
- `email_verified`
- `chatgpt_account_id`, `chatgpt_user_id`, `chatgpt_plan_type` (under `https://api.openai.com/auth`)
- `iat`, `exp`, `iss`, `aud`, `sub`, `jti`, `sid`
- `auth_provider`, `auth_time`, `at_hash`

**Step 3 — register:**

```bash
codex-auth import --purge
# ✓ imported  dXNlci1yaGt4UERuV1JRVUxoRTJJS2dPdkpySXk6OjE4MTc0YzFlLTg2YWQtNGNlOC05MjE3LTYzMTI2YTFiZjgwMw
# Registry: 16 accounts
```

### 10.4 Liveness test

```bash
TOK=$(jq -r '.tokens.access_token' "$FILE")
curl -sS -o /tmp/wham.json -w "HTTP %{http_code}\n" \
  -H "Authorization: Bearer $TOK" -H "Accept: application/json" \
  "https://chatgpt.com/backend-api/wham/usage"
# → HTTP 200
# {"email":"sean973austin@gmail.com","plan_type":"plus",
#  "rate_limit":{"primary_window":{"used_percent":1,...},
#                "secondary_window":{"used_percent":0,...}}}
```

**List output:**

```
12 sean973austin@gmail.com   Plus   99% (05:15)   100% (00:15 on 14 Jun)   Now
```

### 10.5 Caveats

- **No `refresh_token`** → token cannot be rotated. `codex-auth` will try to refresh and fail. Account dies when `access_token` JWT `exp` is reached (~3 months from `iat`).
- **Synthetic `id_token` signature** → tool decodes for display only, not verifies. If the tool is later updated to verify, this import will fail validation and need a real OAuth round-trip to fix.
- **Server-side revocation still possible** — even with a valid-looking JWT, OpenAI can `token_invalidate` at any time (as seen with the CPA import). Always run the liveness test before relying on the account.
- **JWE `sessionToken` is unusable for the API** — it's the web app's session cookie, encrypted with a key the client doesn't have. The CLI path (header bearer) is the only viable use of this blob.

### 10.6 Backup

`~/.codex/accounts.backup.20260607-000814/` (28 items, full snapshot before the 16th-account import).
