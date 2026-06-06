# Codex-Auth: Inspecting, Importing, and Diagnosing a 15th Account

Session log of investigating the `~/.codex/accounts/` directory, importing a CLIProxyAPI (CPA) flat-token JSON as a 15th account via `codex-auth`, and diagnosing why the imported account shows HTTP 401 on the usage API.

## Context

The user has 14 ChatGPT OAuth account snapshots stored in `~/.codex/accounts/*.auth.json` plus a `registry.json` index. They received a single flat-token JSON (the CPA/CLIProxyAPI format) and asked whether it could be added as a 15th account using the same file format.

Working directory: `/home/sandriaas/_projects/minipc` (project files; auth lives outside the repo at `~/.codex/`).

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
| `~/.codex/accounts/*.auth.json` (15) | Per-account token snapshots. Filename: `<b64(user-…)>::<b64(uuid)>.auth.json` |
| `~/.codex/accounts/registry.json` | Index: email, alias, plan, auth_mode, last_used_at, last_usage snapshots. Schema v3. |
| `~/.codex/accounts/auth.json.bak.<ts>` | Rotation snapshots written by `codex-auth` on every overwrite. |
| `~/.codex/accounts/registry.json.bak.<ts>` | Registry rotation snapshots. |
| `~/.codex/auth.json` | **Active** account (the one Codex CLI loads at startup). |
| `~/.codex/config.toml` | Codex CLI config. |
| `~/.codex/accounts/login-*-0/` | Live login session scratch dirs. |
| `~/.codex/accounts.backup.20260606-234353/` | One-shot snapshot before the 15th-account import. |
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
