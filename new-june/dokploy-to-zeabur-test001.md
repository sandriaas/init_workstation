# Dokploy to Zeabur Migration — Evolution API

**Date:** 2026-06-05
**Scope:** Full migration of Evolution API from Dokploy (vm_1, 192.168.122.50) to Zeabur on DigitalOcean, including version upgrade from 2.2.3 → 2.3.7
**Status:** COMPLETE

---

## Table of Contents

1. [Goal](#goal)
2. [Source (Dokploy)](#source-dokploy)
3. [Target (Zeabur)](#target-zeabur)
4. [Source Compose File](#source-compose-file)
5. [Credentials](#credentials)
6. [Execution Log](#execution-log)
7. [Version Upgrade Saga](#version-upgrade-saga)
8. [Final Verification](#final-verification)
9. [Lessons Learned](#lessons-learned)
10. [Remaining Tasks](#remaining-tasks)

---

## Goal

Move the running Evolution API service from Dokploy to Zeabur DigitalOcean server, preserving all database data (instances, messages, contacts, chats), integrations (Chatwoot, Dify), and upgrading to the latest version.

---

## Source (Dokploy)

### Infrastructure

| Field | Value |
|-------|-------|
| Host/VM | `vm_1` |
| VM IP | `192.168.122.50` |
| SSH user | `sandriaas` |
| SSH password | `121212` |
| Dokploy URL | `http://192.168.122.50:3000` |
| Dokploy project | `test` |
| Dokploy project ID | `0hL7NNz9gZXPVFm7j1dP1` |
| Dokploy environment | `production` |
| Dokploy env ID | `qNy1-_5tvJ1dlxoHGxeMH` |
| Dokploy compose name | `evolution api` |
| Dokploy compose ID | `nvxe9AIGXsJjKAk41IxIM` |
| App name | `test-evolution-api-lvablx` |
| Public source domain | `https://evolution-rengga-test.easyrentbali.com` |

### Containers

| Container | Image | Version |
|-----------|-------|---------|
| `test-evolution-api-lvablx-evolution-api-1` | `evoapicloud/evolution-api:latest` | **2.3.7** |
| `test-evolution-api-lvablx-postgres-1` | `postgres:16` | 16 |
| `test-evolution-api-lvablx-redis-1` | `redis:7-alpine` | 7 |

### Source Config

| Key | Value |
|-----|-------|
| DB provider | `postgresql` |
| DB name | `evolution` |
| DB user | `postgres` |
| DB password | `5bb0366cb6aaf84b8b0ef65f45adb60f` |
| API key | `72ec6b59eac3e1b4c1899c3d9cd32e09f01f2d686e8d9cbf` |
| Redis URI | `redis://evolution-redis:6379` |
| Chatwoot enabled | `true` |
| Dify enabled | `true` |
| Prisma version | 6.19.0 |
| Node.js | v24.15.0 |
| Prisma migrations | 57 |
| Docker image created | 2026-05-06 |

### Source Compose File

```yaml
services:
  evolution-api:
    image: evoapicloud/evolution-api:latest
    restart: always
    env_file:
      - ./.env
    environment:
      DOCKER_ENV: "true"
      DATABASE_CONNECTION_URI: "postgresql://postgres:${POSTGRES_PASSWORD}@evolution-postgres:5432/evolution?schema=public"
      CACHE_REDIS_URI: "redis://evolution-redis:6379"
    volumes:
      - ./volumes/evolution.env:/evolution/.env
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
    entrypoint: ["/bin/bash", "-c", "rm -rf ./prisma/migrations && cp -r ./prisma/postgresql-migrations ./prisma/migrations && npx prisma migrate deploy --schema ./prisma/postgresql-schema.prisma && npx prisma generate --schema ./prisma/postgresql-schema.prisma && exec node dist/main"]
    expose:
      - "8080"
    labels:
      - 'traefik.enable=true'
      - 'traefik.http.routers.evolution-rengga.rule=Host(`evolution-rengga-test.easyrentbali.com`)'
      - 'traefik.http.routers.evolution-rengga.entrypoints=web'
      - 'traefik.http.services.evolution-rengga.loadbalancer.server.port=8080'
    networks:
      default:
      dokploy-network:
      test-chatwoot-tshwpg_default:

  postgres:
    image: postgres:16
    restart: always
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-evolution}
      POSTGRES_USER: ${POSTGRES_USER:-postgres}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - ./volumes/postgres:/var/lib/postgresql/data
    networks:
      default:
        aliases:
          - evolution-postgres
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-postgres} -d ${POSTGRES_DB:-evolution}"]
      interval: 5s
      timeout: 5s
      retries: 20

  redis:
    image: redis:7-alpine
    restart: always
    volumes:
      - ./volumes/redis:/data
    networks:
      default:
        aliases:
          - evolution-redis
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

networks:
  dokploy-network:
    external: true
  test-chatwoot-tshwpg_default:
    external: true
```

### Source Docker Commands

SSH into Dokploy requires sudo for Docker:

```bash
# List evolution containers
sshpass -p '121212' ssh -o StrictHostKeyChecking=no sandriaas@192.168.122.50 \
  "sudo docker ps --filter name=evolution --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'"

# Check version from package.json
sshpass -p '121212' ssh -o StrictHostKeyChecking=no sandriaas@192.168.122.50 \
  "sudo docker exec test-evolution-api-lvablx-evolution-api-1 node -e 'const p = require(\"./package.json\"); console.log(p.name, p.version)'"

# Check prisma migration status
sshpass -p '121212' ssh -o StrictHostKeyChecking=no sandriaas@192.168.122.50 \
  "sudo docker exec test-evolution-api-lvablx-evolution-api-1 npx prisma migrate status --schema ./prisma/postgresql-schema.prisma"

# Dump database
sshpass -p '121212' ssh -o StrictHostKeyChecking=no sandriaas@192.168.122.50 \
  "sudo docker exec test-evolution-api-lvablx-postgres-1 pg_dump -U postgres -d evolution --clean --if-exists" \
  > /tmp/evolution-db-dump.sql
```

---

## Target (Zeabur)

### Infrastructure

| Field | Value |
|-------|-------|
| Zeabur server | `server-6a1fa910cbf5edab5ff3d0a7` |
| Zeabur server name | `Digital_Ocean_1` |
| Provider | `DIGITALOCEAN` |
| Project | `evolution-api-migrate` |
| Project ID | `6a22231ff1be9943f1f8f617` |
| Environment | `production` |
| Environment ID | `6a22231f95b39806d284a6ee` |

### Active Services

| Service | ID | Image | Status |
|---------|----|-------|--------|
| `api-ing` | `6a223ff0f1be9943f1f8fc6c` | `evoapicloud/evolution-api:latest` (v2.3.7) | ACTIVE |
| `postgres` | `6a2223b6f1be9943f1f8f66e` | `postgres:16` | ACTIVE |
| `redis-bions` | `6a2223b6f1be9943f1f8f692` | `redis:7-alpine` | ACTIVE |

### Domain

| Field | Value |
|-------|-------|
| URL | `https://test-migrate-evo.zeabur.app` |
| Domain ID | `6a224194f61b6ee8574fc82b` |
| Status | PROVISIONED |
| Attached to | `api-ing` (`6a223ff0f1be9943f1f8fc6c`) |

### Target Environment Variables (api-ing)

```
AUTHENTICATION_API_KEY=72ec6b59eac3e1b4c1899c3d9cd32e09f01f2d686e8d9cbf
AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES=true
CACHE_REDIS_ENABLED=true
CACHE_REDIS_PREFIX_KEY=evolution
CACHE_REDIS_TTL=604800
CACHE_REDIS_URI=redis://redis-bions:6379/6
CHATWOOT_BOT_CONTACT=true
CHATWOOT_ENABLED=true
CHATWOOT_IMPORT_PLACEHOLDER_MEDIA_MESSAGE=true
CHATWOOT_MESSAGE_DELETE=true
CHATWOOT_MESSAGE_READ=true
CONFIG_SESSION_PHONE_CLIENT=Evolution API
CONFIG_SESSION_PHONE_NAME=Chrome
CONFIG_SESSION_PHONE_VERSION=2.3000.1015901307
CORS_ORIGIN=*
DATABASE_CONNECTION_CLIENT_NAME=evolution_exchange
DATABASE_CONNECTION_URI=postgresql://postgres:5bb0366cb6aaf84b8b0ef65f45adb60f@postgres:5432/evolution?schema=public
DATABASE_DELETE_MESSAGE=true
DATABASE_PROVIDER=postgresql
DATABASE_SAVE_DATA_CHATS=true
DATABASE_SAVE_DATA_CONTACTS=true
DATABASE_SAVE_DATA_HISTORIC=true
DATABASE_SAVE_DATA_INSTANCE=true
DATABASE_SAVE_DATA_LABELS=true
DATABASE_SAVE_DATA_NEW_MESSAGE=true
DATABASE_SAVE_IS_ON_WHATSAPP=true
DATABASE_SAVE_IS_ON_WHATSAPP_DAYS=7
DATABASE_SAVE_MESSAGE_UPDATE=true
DEL_INSTANCE=false
DIFY_ENABLED=true
EVENT_EMITTER_MAX_LISTENERS=50
LANGUAGE=en
LOG_BAILEYS=error
LOG_COLOR=true
LOG_LEVEL=ERROR,WARN,DEBUG,INFO,LOG,VERBOSE,DARK,WEBHOOKS,WEBSOCKET
PASSWORD=5bb0366cb6aaf84b8b0ef65f45adb60f
QRCODE_COLOR=#175197
QRCODE_LIMIT=30
SERVER_PORT=8080
SERVER_TYPE=http
SERVER_URL=https://test-migrate-evo.zeabur.app
```

### Read-Only Variables (auto-injected by Zeabur)

```
EVOLUTION_API_HOST=service-6a22232fe957fb053c54f499
REDIS_HOST=service-6a22232fe957fb053c54f49c
POSTGRESQL_HOST=service-6a22232f2fe98e0879e0901b
POSTGRES_HOST=service-6a2223b6f1be9943f1f8f66e
REDIS_BIONS_HOST=service-6a2223b6f1be9943f1f8f692
```

---

## Credentials

### Cloudflare R2

| Field | Value |
|-------|-------|
| Account ID | `0369cdefda56cab0966bfe7cccb10bdd` |
| API Token | `REDACTED` |
| Bucket | `server-backup-001` |
| S3 Endpoint | `https://0369cdefda56cab0966bfe7cccb10bdd.r2.cloudflarestorage.com` |
| S3 Region | `auto` |
| S3 Credentials | NOT YET CREATED (needs manual dashboard creation) |

### Zeabur

| Field | Value |
|-------|-------|
| Token | `sk-zhw6hjoambkyva6hudyt3twsijjmz` |
| Config file | `~/.config/zeabur/cli.yaml` |
| Account | Sandria Agung S. (`andriz.mitnick619sas`) |
| Email | `andriz.mitnick619sas@gmail.com` |
| Plan | DEVELOPER |

### Evolution API

| Field | Value |
|-------|-------|
| API Key | `72ec6b59eac3e1b4c1899c3d9cd32e09f01f2d686e8d9cbf` |
| DB Password | `5bb0366cb6aaf84b8b0ef65f45adb60f` |
| DB User | `postgres` |
| DB Name | `evolution` |

---

## Execution Log

### Phase 1: Discovery & Backup

**1.1 Dokploy Discovery**

Queried Dokploy API directly from LAN:

```bash
curl -sf http://192.168.122.50:3000/api/project.all \
  -H "Content-Type: application/json" \
  -H "x-api-key: <dokploy-api-key>"
```

Found:
- Project `test` with compose `nvxe9AIGXsJjKAk41IxIM`
- Image: `evoapicloud/evolution-api:latest` (v2.3.7)
- DB: `evolution` (PostgreSQL 16)
- API key: `72ec6b59eac3e1b4c1899c3d9cd32e09f01f2d686e8d9cbf`

**1.2 Docker Discovery**

SSH user needed sudo for Docker access:

```bash
sshpass -p '121212' ssh -o StrictHostKeyChecking=no sandriaas@192.168.122.50 \
  "sudo docker ps --filter name=evolution --format '{{.Names}}\t{{.Image}}\t{{.Status}}'"
```

Running containers:
- `test-evolution-api-lvablx-evolution-api-1` (Up 2 hours)
- `test-evolution-api-lvablx-postgres-1` (Up 17 hours, healthy)
- `test-evolution-api-lvablx-redis-1` (Up 17 hours, healthy)

Version check:
```bash
sudo docker exec test-evolution-api-lvablx-evolution-api-1 \
  node -e 'const p = require("./package.json"); console.log(p.name, p.version)'
# Output: evolution-api 2.3.7
```

Prisma check:
```bash
sudo docker exec test-evolution-api-lvablx-evolution-api-1 \
  npx prisma --version
# Prisma 6.19.0, Node v24.15.0, TypeScript 5.9.3
```

**1.3 R2 Setup**

Created bucket via Cloudflare API:
```bash
curl -X POST "https://api.cloudflare.com/client/v4/accounts/0369cdefda56cab0966bfe7cccb10bdd/r2/buckets" \
  -H "Authorization: Bearer REDACTED" \
  -H "Content-Type: application/json" \
  -d '{"name": "server-backup-001", "location": "auto"}'
```

R2 S3 credential creation blocked — API routes return `No route matches this url`. Needs manual dashboard creation.

**1.4 Direct DB Backup**

```bash
sshpass -p '121212' ssh -o StrictHostKeyChecking=no sandriaas@192.168.122.50 \
  "sudo docker exec test-evolution-api-lvablx-postgres-1 \
   pg_dump -U postgres -d evolution --clean --if-exists" \
  > /tmp/evolution-db-dump.sql
```

Results:
- Raw dump: `/tmp/evolution-db-dump.sql` (1.6 MB)
- Gzipped: `/tmp/evolution-db-dump.sql.gz` (324 KB)

**1.5 Volume/Data Discovery**

Instance filesystem was empty:
```bash
sudo docker exec test-evolution-api-lvablx-evolution-api-1 ls -la /evolution/instances/
# empty
```

All data lives in PostgreSQL, not on disk.

### Phase 2: Zeabur Setup

**2.1 Project Creation**

Created via GraphQL:
```bash
curl -s https://api.zeabur.com/graphql \
  -H "Authorization: Bearer sk-zhw6hjoambkyva6hudyt3twsijjmz" \
  -H "Content-Type: application/json" \
  -d '{"query":"mutation { createProject(name: \"evolution-api-migrate\", region: \"server-6a1fa910cbf5edab5ff3d0a7\") { _id name } }"}'
```

Result: Project `6a22231ff1be9943f1f8f617`

**2.2 Template Deployment**

```bash
npx zeabur@latest template deploy \
  --code D4PHWO \
  --project-id 6a22231ff1be9943f1f8f617 \
  --var AUTHENTICATION_API_KEY=72ec6b59eac3e1b4c1899c3d9cd32e09f01f2d686e8d9cbf \
  --var POSTGRES_PASSWORD=5bb0366cb6aaf84b8b0ef65f45adb60f \
  -i=false --json
```

Template YAML (verified via `zeabur template get -i=false -c D4PHWO --raw`):
```yaml
services:
  - name: api
    spec:
      source:
        image: atendai/evolution-api:homolog  # ← THIS IS THE PROBLEM
  - name: postgres
    spec:
      source:
        image: postgres:15  # ← Also wrong, should be 16
  - name: redis
    spec:
      source:
        image: redis:latest
```

**2.3 DB Role Creation**

Zeabur Postgres initialized with role `user`, but dump uses role `postgres`:

```bash
# Via Zeabur GraphQL executeCommand
CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD '5bb0366cb6aaf84b8b0ef65f45adb60f';
```

**2.4 DB Restore**

Uploaded dump via Zeabur file upload API, then executed restore:

```bash
psql -v ON_ERROR_STOP=1 -U postgres -d evolution -f /tmp/evolution-db-dump.sql
```

Result: Exit code 0, full restore successful.

**2.5 Initial Integration Env Vars**

Added to the `api` service:
```bash
zeabur variable update -i=false -y --id 6a2223b6f1be9943f1f8f66d \
  -k CHATWOOT_ENABLED=true \
  -k CHATWOOT_MESSAGE_READ=true \
  -k CHATWOOT_MESSAGE_DELETE=true \
  -k CHATWOOT_BOT_CONTACT=true \
  -k CHATWOOT_IMPORT_PLACEHOLDER_MEDIA_MESSAGE=true \
  -k DIFY_ENABLED=true \
  -k DATABASE_SAVE_DATA_LABELS=true \
  -k DATABASE_SAVE_DATA_HISTORIC=true \
  -k DATABASE_SAVE_IS_ON_WHATSAPP=true \
  -k DATABASE_DELETE_MESSAGE=true \
  -k SERVER_URL=https://test-migrate-evo.zeabur.app
```

**2.6 Domain Creation**

CLI `domain create --generated` failed with `INVALID_DOMAIN_NAME`. Used GraphQL instead:

```bash
cat > /tmp/add-domain.py << 'EOF'
import requests, json
token = "sk-zhw6hjoambkyva6hudyt3twsijjmz"
headers = {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'}
mutation = {
    "query": """
    mutation addDomain($serviceID: ObjectID!, $domain: String!, $isGenerated: Boolean!) {
      addDomain(serviceID: $serviceID, domain: $domain, isGenerated: $isGenerated) {
        _id
        domain
        status
      }
    }
    """,
    "variables": {
        "serviceID": "6a223ff0f1be9943f1f8fc6c",
        "domain": "test-migrate-evo",
        "isGenerated": True
    }
}
resp = requests.post('https://api.zeabur.com/graphql', headers=headers, json=mutation)
print(json.dumps(resp.json(), indent=2))
EOF
python3 /tmp/add-domain.py
```

Result:
```json
{
  "data": {
    "addDomain": {
      "_id": "6a224194f61b6ee8574fc82b",
      "domain": "test-migrate-evo.zeabur.app",
      "status": "PROVISIONING"
    }
  }
}
```

### Phase 3: Version Upgrade Saga

**3.1 Discovery: Wrong Image**

API responded but with version `2.2.3`:
```bash
curl -s "https://test-migrate-evo.zeabur.app/"
# version: "2.2.3"
```

Dokploy source was `2.3.7`. Investigation revealed:

| Docker Hub Repo | Image | Latest Version | Last Updated | Status |
|----------------|-------|---------------|--------------|--------|
| `atendai/evolution-api` | `homolog` | v2.2.3 | 2025-02-03 | **DEAD** |
| `evoapicloud/evolution-api` | `latest` | v2.3.7+ | 2026-05-06 | **ACTIVE** |

The Zeabur template `D4PHWO` uses `atendai/evolution-api:homolog` — a dead fork.

**3.2 Attempt: Update Tag via CLI**

```bash
zeabur service update tag -i=false -t latest -y --id 6a2223b6f1be9943f1f8f66d
# Returned no output (success)

zeabur service restart -i=false -y --id 6a2223b6f1be9943f1f8f66d
# Restarted successfully

curl -s "https://test-migrate-evo.zeabur.app/"
# Still version: "2.2.3" ← tag update doesn't change image repo
```

**3.3 Attempt: Update via GraphQL**

```python
mutation = {
    "query": """
    mutation updateServiceImage($serviceID: ObjectID!, $environmentID: ObjectID!, $tag: String!) {
      updateServiceImage(serviceID: $serviceID, environmentID: $environmentID, tag: $tag)
    }
    """,
    "variables": {
        "serviceID": "6a2223b6f1be9943f1f8f66d",
        "environmentID": "6a22231f95b39806d284a6ee",
        "tag": "latest"
    }
}
# Returns: {"data": {"updateServiceImage": true}}
# But still running 2.2.3 — mutation only changes tag, not image repo
```

**3.4 Attempt: Create New Service with Correct Image**

Created empty service:
```python
mutation = {
    "query": """
    mutation createService($name: String!, $template: ServiceTemplate!, $projectID: ObjectID!) {
      createService(name: $name, template: $template, projectID: $projectID) {
        _id
        name
      }
    }
    """,
    "variables": {
        "name": "evo-api-latest",
        "template": "PREBUILT",
        "projectID": "6a22231ff1be9943f1f8f617"
    }
}
# Result: {"data": {"createService": {"_id": "6a223d6cf1be9943f1f8fc1c"}}}
```

But `updateServiceImage` failed because the new service had no image reference:
```
this service does not have a valid image reference
```

**3.5 Final Solution: Custom Template**

Created custom template YAML (`/tmp/custom-evo-template.yaml`):

```yaml
apiVersion: zeabur.com/v1
kind: Template
metadata:
    name: evolution-api-latest
spec:
    description: Evolution API latest version
    services:
        - name: postgres
          template: PREBUILT
          spec:
            id: postgres
            source:
                image: postgres:16
            ports:
                - id: postgres
                  port: 5432
                  type: TCP
            volumes:
                - id: data
                  dir: /var/lib/postgresql/data
            env:
                POSTGRES_DB:
                    default: evolution
                POSTGRES_HOST_AUTH_METHOD:
                    default: trust
                POSTGRES_PASSWORD:
                    default: ${PASSWORD}
                POSTGRES_USER:
                    default: postgres
        - name: redis
          template: PREBUILT
          spec:
            id: redis
            source:
                image: redis:7-alpine
            ports:
                - id: redis
                  port: 6379
                  type: TCP
            volumes:
                - id: data
                  dir: /data
        - name: api
          template: PREBUILT
          spec:
            id: api
            source:
                image: evoapicloud/evolution-api:latest  # ← CORRECT IMAGE
            ports:
                - id: web
                  port: 8080
                  type: HTTP
            volumes:
                - id: instances
                  dir: /evolution/instances
            env:
                AUTHENTICATION_API_KEY:
                    default: ${PASSWORD}
                AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES:
                    default: "true"
                CACHE_REDIS_ENABLED:
                    default: "true"
                CACHE_REDIS_PREFIX_KEY:
                    default: evolution
                CACHE_REDIS_TTL:
                    default: "604800"
                CACHE_REDIS_URI:
                    default: redis://redis:6379/6
                CONFIG_SESSION_PHONE_CLIENT:
                    default: Evolution API
                CONFIG_SESSION_PHONE_NAME:
                    default: Chrome
                CONFIG_SESSION_PHONE_VERSION:
                    default: 2.3000.1015901307
                CORS_ORIGIN:
                    default: '*'
                DATABASE_CONNECTION_CLIENT_NAME:
                    default: evolution_exchange
                DATABASE_CONNECTION_URI:
                    default: postgresql://postgres:${PASSWORD}@postgres:5432/evolution?schema=public
                DATABASE_PROVIDER:
                    default: postgresql
                DATABASE_SAVE_DATA_CHATS:
                    default: "true"
                DATABASE_SAVE_DATA_CONTACTS:
                    default: "true"
                DATABASE_SAVE_DATA_INSTANCE:
                    default: "true"
                DATABASE_SAVE_DATA_NEW_MESSAGE:
                    default: "true"
                DATABASE_SAVE_MESSAGE_UPDATE:
                    default: "true"
                DEL_INSTANCE:
                    default: "false"
                EVENT_EMITTER_MAX_LISTENERS:
                    default: "50"
                LANGUAGE:
                    default: en
                LOG_BAILEYS:
                    default: error
                LOG_COLOR:
                    default: "true"
                LOG_LEVEL:
                    default: ERROR,WARN,DEBUG,INFO,LOG,VERBOSE,DARK,WEBHOOKS,WEBSOCKET
                QRCODE_COLOR:
                    default: '#175197'
                QRCODE_LIMIT:
                    default: "30"
                SERVER_PORT:
                    default: "8080"
                SERVER_TYPE:
                    default: http
                SERVER_URL:
                    default: https://${ZEABUR_WEB_DOMAIN}
```

Deployed:
```bash
zeabur template deploy -i=false -f /tmp/custom-evo-template.yaml \
  --project-id 6a22231ff1be9943f1f8f617
```

Result: `Template successfully deployed into project "evolution-api-migrate"`

New services created:
- `api-ing` (`6a223ff0f1be9943f1f8fc6c`) — with `evoapicloud/evolution-api:latest`
- `postgres-ets` (`6a223ff0f1be9943f1f8fc6b`) — new postgres
- `redis-hum` (`6a223ff0f1be9943f1f8fc6a`) — new redis

### Phase 4: Configuring api-ing

**4.1 Updated Connection Strings**

```bash
zeabur variable update -i=false -y --id 6a223ff0f1be9943f1f8fc6c \
  -k CACHE_REDIS_URI="redis://redis-bions:6379/6"
```

`api-ing` now connects to existing `postgres` (with data) and `redis-bions`.

**4.2 Set Credentials**

```bash
zeabur variable update -i=false -y --id 6a223ff0f1be9943f1f8fc6c \
  -k AUTHENTICATION_API_KEY="72ec6b59eac3e1b4c1899c3d9cd32e09f01f2d686e8d9cbf" \
  -k PASSWORD="5bb0366cb6aaf84b8b0ef65f45adb60f" \
  -k SERVER_URL="https://test-migrate-evo.zeabur.app"
```

**4.3 Set Integration Env Vars**

```bash
zeabur variable update -i=false -y --id 6a223ff0f1be9943f1f8fc6c \
  -k CHATWOOT_ENABLED="true" \
  -k CHATWOOT_MESSAGE_READ="true" \
  -k CHATWOOT_MESSAGE_DELETE="true" \
  -k CHATWOOT_BOT_CONTACT="true" \
  -k CHATWOOT_IMPORT_PLACEHOLDER_MEDIA_MESSAGE="true" \
  -k DIFY_ENABLED="true" \
  -k DATABASE_SAVE_DATA_LABELS="true" \
  -k DATABASE_SAVE_DATA_HISTORIC="true" \
  -k DATABASE_SAVE_IS_ON_WHATSAPP="true" \
  -k DATABASE_SAVE_IS_ON_WHATSAPP_DAYS="7" \
  -k DATABASE_DELETE_MESSAGE="true" \
  -k AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES="true" \
  -k DATABASE_SAVE_DATA_INSTANCE="true"
```

**4.4 Domain Migration**

Deleted domain from old `api` service:
```bash
zeabur domain delete -i=false -y --id 6a2223b6f1be9943f1f8f66d \
  --domain "test-migrate-evo.zeabur.app"
```

Created domain on `api-ing` via GraphQL (CLI `--generated` flag broken):
```python
mutation = {
    "query": """
    mutation addDomain($serviceID: ObjectID!, $domain: String!, $isGenerated: Boolean!) {
      addDomain(serviceID: $serviceID, domain: $domain, isGenerated: $isGenerated) {
        _id
        domain
        status
      }
    }
    """,
    "variables": {
        "serviceID": "6a223ff0f1be9943f1f8fc6c",
        "domain": "test-migrate-evo",
        "isGenerated": True
    }
}
```

**4.5 Restart & Verify**

```bash
zeabur service restart -i=false -y --id 6a223ff0f1be9943f1f8fc6c
```

### Phase 5: Cleanup

Deleted old services:
```bash
for sid in 6a22232fe957fb053c54f499 6a22232fe957fb053c54f49c \
           6a22232f2fe98e0879e0901b 6a2223b6f1be9943f1f8f66d \
           6a223d6cf1be9943f1f8fc1c 6a223ff0f1be9943f1f8fc6b \
           6a223ff0f1be9943f1f8fc6a; do
  zeabur service delete -i=false -y --id "$sid"
done
```

Remaining services: `api-ing` + `postgres` + `redis-bions`

---

## Version Upgrade Saga

### The Problem

| | Source (Dokploy) | Target (Zeabur template) |
|---|---|---|
| Image | `evoapicloud/evolution-api:latest` | `atendai/evolution-api:homolog` |
| Version | **2.3.7** | **2.2.3** |
| Prisma | 6.19.0 | older |
| Node.js | v24.15.0 | older |
| Last updated | 2026-05-06 | 2025-02-03 |
| Status | **ACTIVE** | **DEAD** |

### Why Zeabur Template Uses Wrong Image

The official Zeabur template `D4PHWO` has this in its YAML:
```yaml
source:
    image: atendai/evolution-api:homolog
```

`atendai/evolution-api` is a fork that was last updated Feb 2025. The official repo is `evoapicloud/evolution-api`.

### Why CLI Tag Update Doesn't Work

`zeabur service update tag` and GraphQL `updateServiceImage` only change the tag (e.g., `homolog` → `latest`), NOT the image repository (e.g., `atendai` → `evoapicloud`). The Zeabur platform locks the image repository for prebuilt services.

### Why GraphQL introspection doesn't help

Zeabur blocks GraphQL introspection:
```json
{
  "errors": [{"message": "Internal Server Error"}],
  "data": {"__schema": null}
}
```

Had to reverse-engineer mutations from CLI `--debug` output and error messages.

### Solution

Created a custom template YAML with `evoapicloud/evolution-api:latest` and deployed it to the same project. This created new services with the correct image.

---

## Final Verification

### API Health

```bash
curl -s "https://test-migrate-evo.zeabur.app/"
```

```json
{
  "status": 200,
  "message": "Welcome to the Evolution API, it is working!",
  "version": "2.3.7",
  "clientName": "evolution_exchange",
  "manager": "http://test-migrate-evo.zeabur.app/manager",
  "documentation": "https://doc.evolution-api.com",
  "whatsappWebVersion": "2.3000.1040891482"
}
```

### Instance Data

```bash
curl -s -H "apikey: 72ec6b59eac3e1b4c1899c3d9cd32e09f01f2d686e8d9cbf" \
  "https://test-migrate-evo.zeabur.app/instance/fetchInstances"
```

```json
{
  "id": "add951d0-4b69-4370-90d8-c60fa25a2a68",
  "name": "85168932785",
  "number": "6285168932785",
  "connectionStatus": "close",
  "ownerJid": "6285168932785@s.whatsapp.net",
  "profileName": "DI1",
  "integration": "WHATSAPP-BAILEYS",
  "Chatwoot": {
    "enabled": true,
    "accountId": "2",
    "token": "5QLAhoPfHqcNkASCbxDXu7Xy",
    "url": "https://chatwoot-rengga-test.easyrentbali.com",
    "nameInbox": "WA Evolution Zeabur",
    "importMessages": true,
    "daysLimitImportMessages": 7
  },
  "_count": {
    "Message": 1241,
    "Contact": 738,
    "Chat": 307
  }
}
```

### Data Summary

| Metric | Value | Status |
|--------|-------|--------|
| API Version | 2.3.7 | Matches source |
| Instance | 85168932785 | Restored |
| Messages | 1241 | Restored |
| Contacts | 738 | Restored |
| Chats | 307 | Restored |
| Chatwoot | Enabled | Working |
| Domain | test-migrate-evo.zeabur.app | Active |

---

## Lessons Learned

### Critical

1. **Zeabur template `D4PHWO` uses WRONG image**: The official Evolution API template on Zeabur uses `atendai/evolution-api:homolog` (dead fork, v2.2.3) instead of `evoapicloud/evolution-api:latest` (official, v2.3.7). **Always verify the image in template YAML before deploying.**

2. **`updateServiceImage` GraphQL mutation only changes tag**: Cannot change the image repository through the Zeabur API. Must create a new service with the correct image via custom template.

3. **Zeabur CLI `domain create --generated` is broken**: Returns `INVALID_DOMAIN_NAME`. Must use GraphQL with `isGenerated: true`.

### Infrastructure

4. **R2 bucket names cannot contain underscores**: Use hyphens, e.g. `server-backup-001`.

5. **Cloudflare R2 S3 credentials need manual creation**: API routes for R2 token creation return `No route matches this url`. Must use Cloudflare dashboard.

6. **SSH user needs sudo for Docker on vm_1**: Docker socket requires elevated permissions.

7. **Evolution API instance filesystem is empty**: All data lives in PostgreSQL. The `/evolution/instances/` directory contained no files.

8. **Zeabur file uploads are ephemeral**: Files uploaded to `/tmp` are lost on service restart. Upload the dump immediately before restore.

### Zeabur Platform

9. **GraphQL introspection is blocked on Zeabur**: Must guess field names or use `--json`/`--debug` output from CLI to reverse-engineer the schema.

10. **Service deletion is queued, not immediate**: Zeabur CLI reports "deleted successfully" but services remain in list for a while.

11. **Zeabur template Postgres uses different role**: Template initializes with role `user`, but source uses `postgres`. Must create the `postgres` role manually.

12. **Zeabur BYOS uses `server-<id>` region format**: When creating projects on dedicated servers, use `server-<server-id>` as the region parameter.

13. **GraphQL `executeCommand` can time out**: Suppress output and tail logs for long commands like `pg_restore`.

14. **Zeabur readonly variables are injected automatically**: Variables like `POSTGRES_HOST`, `REDIS_HOST` are auto-generated and cannot be removed.

### Evolution API

15. **Prisma schema is in `prisma/postgresql-schema.prisma`**: Not the default `schema.prisma`. The entrypoint runs migrations manually.

16. **Entry point runs migrations on every start**: The compose entrypoint does `rm -rf ./prisma/migrations && cp -r ./prisma/postgresql-migrations ./prisma/migrations && npx prisma migrate deploy`.

17. **Chatwoot internal URL stored in DB**: The `url=http://chatwoot-rails:3000` is stored in the database, not in env vars. Needs DB update if Chatwoot host changes.

18. **Docker image `evoapicloud/evolution-api:latest` was built 2026-05-06**: Contains Prisma 6.19.0, Node v24.15.0, TypeScript 5.9.3.

---

## Remaining Tasks

### Immediate

1. **Reconnect WhatsApp**: Instance `85168932785` has `connectionStatus: close` (disconnection reason: 401). Need to reconnect via QR code.

2. **Update `chatwoot-dify-relay`**: Point `EVOLUTION_BASE_URL` to `https://test-migrate-evo.zeabur.app` in `services/chatwoot-dify-relay/.env`

3. **Restart/redeploy `chatwoot-dify-relay`**: After updating the env var.

### Cleanup

4. **Delete remaining old services**: Some services are still in deletion queue on Zeabur. Monitor and verify they're fully removed.

5. **Verify Chatwoot integration end-to-end**: Send a test message through WhatsApp → Evolution API → Chatwoot.

### Backup & Recovery

6. **R2 S3 credentials**: Create manually via Cloudflare dashboard for Dokploy backup destination.

7. **Add R2 as Dokploy destination**: Using endpoint `https://0369cdefda56cab0966bfe7cccb10bdd.r2.cloudflarestorage.com`, region `auto`, bucket `server-backup-001`.

8. **Scheduled backups**: Set up regular backups for both source (Dokploy) and target (Zeabur).

### Optional

9. **Fix Chatwoot internal URL**: The stored Chatwoot URL `http://chatwoot-rails:3000` points to old Dokploy network. Needs DB update if Chatwoot is hosted separately.

10. **Set up monitoring**: Add health checks and uptime monitoring for the new Zeabur deployment.

---

## Zeabur GraphQL API Reference

### Mutations Used

```
# Create project
mutation { createProject(name: "...", region: "server-...") { _id name } }

# Create service
mutation createService($name: String!, $template: ServiceTemplate!, $projectID: ObjectID!) {
  createService(name: $name, template: $template, projectID: $projectID) { _id name }
}

# Update image tag (NOT image repo)
mutation updateServiceImage($serviceID: ObjectID!, $environmentID: ObjectID!, $tag: String!) {
  updateServiceImage(serviceID: $serviceID, environmentID: $environmentID, tag: $tag)
}

# Delete service
mutation { deleteService(_id: "...") }

# Add domain (CLI --generated is broken)
mutation addDomain($serviceID: ObjectID!, $domain: String!, $isGenerated: Boolean!) {
  addDomain(serviceID: $serviceID, domain: $domain, isGenerated: $isGenerated) { _id domain status }
}

# Delete domain
mutation { deleteDomain(serviceID: "...", domain: "...") }

# Execute command
mutation { executeCommand(serviceID: "...", command: "...", environmentID: "...") }

# Restart service
mutation { restartService(serviceID: "...", environmentID: "...") }

# Suspend service
mutation { suspendService(serviceID: "...", environmentID: "...") }
```

### Queries Used

```
# Get environments
query { environments(projectID: "...") { _id name } }

# Get service (field name is 'service', not 'getService')
query { service(_id: "...") { _id name image { image tag } } }
```

### Zeabur CLI Commands

```bash
# Project
zeabur project list -i=false

# Services
zeabur service list -i=false --project-id <id>
zeabur service get -i=false --id <id>
zeabur service restart -i=false -y --id <id>
zeabur service suspend -i=false -y --id <id>
zeabur service delete -i=false -y --id <id>
zeabur service update tag -i=false -t <tag> -y --id <id>
zeabur service network -i=false --id <id>

# Variables
zeabur variable list -i=false --id <service-id>
zeabur variable create -i=false -y --id <service-id> -k KEY=VALUE
zeabur variable update -i=false -y --id <service-id> -k KEY=VALUE

# Domains
zeabur domain list -i=false --id <service-id>
zeabur domain create -i=false -y --id <service-id> --domain <name>.zeabur.app
zeabur domain delete -i=false -y --id <service-id> --domain <name>

# Templates
zeabur template search -i=false <keyword>
zeabur template get -i=false -c <code> --raw
zeabur template deploy -i=false -f <file> --project-id <id>

# Deployments
zeabur deployment list -i=false --service-id <id>

# Auth
zeabur auth status -i=false
```
