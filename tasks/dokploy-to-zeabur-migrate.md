# Evolution API Migration: Dokploy (vm_1) → Cloudflare R2 → Zeabur

**Date:** 2026-06-05
**Status:** Mostly Complete - external domain pending

## Overview

Migrate the Evolution API (PostgreSQL database + application volume) from Dokploy on vm_1 (192.168.122.50) to Zeabur on DigitalOcean server `server-6a1fa910cbf5edab5ff3d0a7`.

The originally referenced Zeabur service `6a1fb1a48197c9aa0ae31d35` was not present in any current Zeabur project. A new Zeabur project was created on the DigitalOcean server.

## Credentials

| Credential | Value | Purpose |
|-----------|-------|---------|
| Dokploy API Key | `QKGhxWx...pHmv` | Dokploy CLI auth |
| CF Account ID | `0369cdefda56cab0966bfe7cccb10bdd` | R2 bucket/creds creation |
| CF API Token | `cfat_Lm5p...d7b` | R2 API operations |
| Zeabur API Key | `sk-zhw6hjoambkyva6hudyt3twsijjmz` | Zeabur GraphQL API |
| SSH Password | `121212` | vm_1 SSH access (fallback) |
| Zeabur Project ID | `6a22231ff1be9943f1f8f617` | New target project |
| Zeabur Env ID | `6a22231f95b39806d284a6ee` | Production env |
| Zeabur API Service ID | `6a2223b6f1be9943f1f8f66d` | Evolution API service |
| Zeabur Postgres Service ID | `6a2223b6f1be9943f1f8f66e` | Restored database |
| Zeabur Redis Service ID | `6a2223b6f1be9943f1f8f692` | Redis cache |

## Phases

### Phase 0: Discovery & Setup
- [x] Query Dokploy API directly via `http://192.168.122.50:3000`
- [x] Discover Evolution API service/project IDs in Dokploy
- [x] Discover Evolution API Docker image, DB type, volume names
- [x] Query Zeabur projects/services/servers

### Phase 1: Create Cloudflare R2 Bucket + S3 Credentials
- [x] Create R2 bucket `server-backup-001` via CF API
- [ ] Create R2 S3 API credentials (blocked: CF API token route for R2 token creation returned `No route matches this url`)
- [x] Verify bucket exists

### Phase 2: Configure R2 as Dokploy Backup Destination
- [ ] Create S3 destination in Dokploy pointing to R2 (blocked until R2 S3 access key/secret are available)
- [ ] Test connection

### Phase 3: Backup Evolution API
- [x] Direct dump fallback: `pg_dump` from `test-evolution-api-lvablx-postgres-1`
- [x] Dump path: `/tmp/evolution-db-dump.sql`
- [x] Dump size: 1.6 MB raw, 324 KB gzipped
- [x] Verified filesystem instance folder exists but contains no files; actual instance data is in PostgreSQL

### Phase 4: Create Zeabur Target on DigitalOcean
- [x] Created project `evolution-api-migrate` on `server-6a1fa910cbf5edab5ff3d0a7`
- [x] Deployed official Zeabur Evolution API template `D4PHWO`
- [x] Created services: `api`, `postgres`, `redis-bions`

### Phase 5: Restore to Zeabur
- [x] Upload PostgreSQL dump to Zeabur `postgres` service
- [x] Create `postgres` DB role in target DB
- [x] Restore database via GraphQL `executeCommand`
- [x] Configure API env vars to use source API key and source DB password
- [x] Restart Zeabur services

### Phase 6: Verify
- [x] API service is running
- [x] Internal health endpoint returns `200` and Evolution API welcome response
- [x] Restored instance endpoint returns instance `85168932785`
- [x] Data verified: `Message=1241`, `Contact=738`, `Chat=307`
- [x] Instance connection status shown as `open`
- [ ] Attach external `*.zeabur.app` domain (blocked: Zeabur CLI/API returns `DOMAIN_UNAVAILABLE` for explicit names and invalid generated-domain request)
- [ ] Update chatwoot-dify-relay after public domain is attached

## Results

- Source Dokploy compose: `nvxe9AIGXsJjKAk41IxIM` / `test-evolution-api-lvablx`
- Source image: `evoapicloud/evolution-api:latest`
- Source Postgres: `postgres:16`, DB `evolution`, user `postgres`
- Target project: `evolution-api-migrate` (`6a22231ff1be9943f1f8f617`)
- Target services: `api`, `postgres`, `redis-bions`
- Restore command completed with exit code `0`
- Internal verification command:
  - `wget -qO- http://127.0.0.1:8080/`
  - `wget -qO- --header='apikey: ...' http://127.0.0.1:8080/instance/fetchInstances`

## Current Blocker

Public Zeabur domain is not attached yet. Attempts:

- `npx zeabur domain create --generated` -> `INVALID_DOMAIN_NAME`
- explicit `*.zeabur.app` names -> `DOMAIN_UNAVAILABLE`

The service is healthy internally on `api.zeabur.internal:8080`, but needs a valid public domain from Zeabur dashboard/API before dependent services can be pointed to it.

## Risks & Fallbacks

| Risk | Fallback |
|------|----------|
| Dokploy CLI backup commands fail | SSH into vm_1, use `docker exec pg_dump` + `docker cp` |
| Zeabur file upload 100MB limit | Split dumps or use WebSocket terminal |
| R2 S3 creds creation fails | Create manually in CF Dashboard |
| Volume mount path mismatch | Discover from Zeabur service config first |
