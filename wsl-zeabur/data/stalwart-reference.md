# Stalwart Mail Server Reference

> Image: `stalwartlabs/mail-server:v0.11.8`
> Service ID: `6a242f96f1be9943f1f972a7`
> Project: `6a242c9f2fe98e0879e0f199` (untitled-1)
> Environment: `6a242c9f95b39806d284aaa7` (production)
> Domain: `yjhkbkjb.zeabur.app` (status: ACTIVE)
> Pod: `service-6a242f96f1be9943f1f972a7-84d48c4859-dfjvc` (default namespace)
> Service port: 8080 (NodePort 32247)
> Pod IP: 10.42.0.55

## Accessing the API

Stalwart v0.11.8 does **NOT** ship with the WebAdmin UI bundle by default.
The `/admin`, `/admin/login`, and `/account` paths return 404.

Management is done via the REST API at `/api/*` (HTTP Basic auth):

```bash
# From the cluster
sudo kubectl exec -n environment-6a242c9f95b39806d284aaa7 \
    service-6a242f96f1be9943f1f972a7-84d48c4859-dfjvc -- \
    stalwart-cli -u http://localhost:8080 -c admin:$PASSWORD database purge

# From the cluster (curl)
sudo kubectl exec -n environment-6a242c9f95b39806d284aaa7 \
    service-6a242f96f1be9943f1f972a7-84d48c4859-dfjvc -- \
    wget -qO- -S http://localhost:8080/api/principal

# From the host (via ingress)
curl -u admin:$PASSWORD https://yjhkbkjb.zeabur.app/api/principal
```

## Credentials

| Field | Value | Source |
|-------|-------|--------|
| Admin user | `admin` | Default in fallback-admin config |
| Admin password | `biqEbPXFxB` | Container logs (first-start banner) |
| Service password | `k29C30HlVF7I4LaAD5Y6wviNKT8PGx1u` | Zeabur service settings |

The admin password is printed to the container stdout on the first
startup. If the data volume is preserved, the password persists across
restarts. If the data volume is reset, a new password is generated.

To get the current password from logs:

```bash
sudo kubectl logs -n environment-6a242c9f95b39806d284aaa7 \
    service-6a242f96f1be9943f1f972a7-84d48c4859-dfjvc | \
    grep -oE "password '[A-Za-z0-9]+'"
```

## API Endpoints

### Anonymous (rate-limited)

| Path | Method | Purpose |
|------|--------|---------|
| `/api/auth` | POST | Authentication / OAuth |
| `/api/discover/{email}` | GET | Email discovery (autoconfig) |

### Authenticated (admin)

| Path | Method | Purpose |
|------|--------|---------|
| `/api/principal` | GET/POST | List / create principals (accounts, groups, etc.) |
| `/api/principal/{id}` | GET/PATCH/DELETE | Single principal CRUD |
| `/api/settings/keys` | GET | List all settings by key |
| `/api/settings/group` | GET | List settings by group |
| `/api/settings/list` | GET | List settings (with prefix filter) |
| `/api/settings` | POST | Update settings (JMAP patch) |
| `/api/store/reindex` | GET | Trigger FTS reindex |
| `/api/update/webadmin` | GET | Trigger WebAdmin bundle download (requires auth) |
| `/api/account/crypto` | GET/POST | Encryption-at-rest settings |
| `/api/schema` | GET | Redirect to /api/schema/{hash} |
| `/api/schema/{hash}` | GET | Configuration schema (immutable) |

### JMAP (mailbox data)

| Path | Method | Purpose |
|------|--------|---------|
| `/jmap` | POST | JMAP over HTTP (mailbox, email, identity, etc.) |

JMAP is the primary API for mailbox data access. Server configuration
is NOT done via JMAP — use the management API above.

## Example Operations

### List all settings

```bash
curl -s -u admin:biqEbPXFxB \
    "https://yjhkbkjb.zeabur.app/api/settings/keys" | jq .
```

### List principals (accounts)

```bash
curl -s -u admin:biqEbPXFxB \
    "https://yjhkbkjb.zeabur.app/api/principal" | jq .
```

### List server settings (group)

```bash
curl -s -u admin:biqEbPXFxB \
    "https://yjhkbkjb.zeabur.app/api/settings/group?suffix=listener" | jq .
```

### Create a new account

```bash
curl -s -u admin:biqEbPXFxB \
    -X POST "https://yjhkbkjb.zeabur.app/api/principal" \
    -H "Content-Type: application/json" \
    -d '{
        "type": "individual",
        "name": "alice@example.com",
        "emails": ["alice@example.com"],
        "secrets": ["changeme"]
    }' | jq .
```

### Install the WebAdmin UI bundle

```bash
curl -s -u admin:biqEbPXFxB \
    "https://yjhkbkjb.zeabur.app/api/update/webadmin"
```

After this, the WebAdmin will be available at `/admin` and `/account`
(prefix routing determines which view).

## Listener Configuration (from /opt/stalwart-mail/etc/config.toml)

```toml
[server.listener.smtp]      bind = "[::]:25"   protocol = "smtp"
[server.listener.submission] bind = "[::]:587"  protocol = "smtp"
[server.listener.submissions] bind = "[::]:465"  protocol = "smtp"  tls.implicit = true
[server.listener.imap]       bind = "[::]:143"  protocol = "imap"
[server.listener.imaptls]    bind = "[::]:993"  protocol = "imap"  tls.implicit = true
[server.listener.pop3]       bind = "[::]:110"  protocol = "pop3"
[server.listener.pop3s]      bind = "[::]:995"  protocol = "pop3"  tls.implicit = true
[server.listener.sieve]      bind = "[::]:4190" protocol = "managesieve"
[server.listener.https]      bind = "[::]:443"  protocol = "http"  tls.implicit = true
[server.listener.http]       bind = "[::]:8080" protocol = "http"
```

Note: ports 25, 143, 587, etc. are NOT exposed via the Zeabur service
ingress (which only exposes 8080). Mail protocols require direct network
access or a separate ingress configuration. Currently the Stalwart
service is only accessible via HTTP(S) on 8080.

## Architecture

```
Internet
  → DNS: yjhkbkjb.zeabur.app → 172.29.155.146 (WSL eth0)
    → Tailscale mesh (optional, for mesh-only services)
      → k3s ingress controller (172.29.155.146:443)
        → HTTPS cert (Let's Encrypt, ACME on-demand)
          → Service service-6a242f96f1be9943f1f972a7:8080
            → Stalwart pod (10.42.0.55:8080)
              → /opt/stalwart-mail/data (rocksdb)
              → /opt/stalwart-mail/etc/config.toml
              → /opt/stalwart-mail/logs
```

## Caveats and Known Issues

1. **No WebAdmin by default.** Need to call `/api/update/webadmin` once
   to download the bundle.
2. **Mail ports not exposed.** SMTP/IMAP/POP3 are not accessible from
   outside the cluster via the current Zeabur service config.
3. **v0.11.8 is pre-1.0.** The 1.0+ release has different management
   API and WebUI mount points. Upgrading requires data migration.
4. **No TLS for SMTP/IMAP configured.** The `tls.implicit` flag is set
   but cert paths are not configured. Currently SMTP/IMAP would fail
   TLS handshake.
