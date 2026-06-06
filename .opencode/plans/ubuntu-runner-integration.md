# Plan: Ubuntu Runner Container + Full Stack Integration

## Goal
Membuat Ubuntu Runner Container yang persistent dan menjadi integration hub untuk Multica, Paperclip, dan Hermes Agent.

## Arsitektur

```
                    ┌─────────────────────────────────────────────┐
                    │           Ubuntu Runner Container           │
                    │            (runner-test.easyrentbali.com)    │
                    │                                             │
                    │  ┌─────────┐  ┌─────────┐  ┌─────────────┐ │
                    │  │  Nginx  │  │  Rsync  │  │  Health     │ │
                    │  │ Gateway │  │  Server │  │  Aggregator │ │
                    │  └────┬────┘  └────┬────┘  └──────┬──────┘ │
                    │       │           │              │         │
                    │  ┌────┴───────────┴──────────────┴──────┐  │
                    │  │         Shared Volumes               │  │
                    │  │  /data/agent-workspaces              │  │
                    │  │  /data/files                         │  │
                    │  │  /data/logs                          │  │
                    │  │  /data/backups                       │  │
                    │  │  /data/config                        │  │
                    │  └──────────────────────────────────────┘  │
                    └──────────────────┬──────────────────────────┘
                                       │ dokploy-network
                    ┌──────────────────┼──────────────────────────┐
                    │                  │                          │
        ┌───────────┴──────┐  ┌───────┴────────┐  ┌─────────────┴──────┐
        │   Multica        │  │    Hermes      │  │    Paperclip       │
        │   Backend:8080   │  │   API:8642     │  │    API:3100        │
        │   Frontend:3000  │  │   Dash:9119    │  │                    │
        └──────────────────┘  └────────────────┘  └────────────────────┘
```

## Components

### 1. Ubuntu Runner Container
- **Image**: `ubuntu:22.04`
- **Services**: Nginx, rsync, health check script
- **Port**: 80 (nginx), 873 (rsync)
- **Network**: dokploy-network
- **RAM**: 512MB limit
- **Persistent**: `/data` volume

### 2. Shared Storage Volumes
| Volume | Purpose | Services |
|--------|---------|----------|
| `/data/agent-workspaces` | Agent SOUL.md, MEMORY.md, sessions | Hermes, Paperclip |
| `/data/files` | File uploads, attachments | Multica, Paperclip |
| `/data/logs` | Centralized logging | All |
| `/data/backups` | DB backups | All |
| `/data/config` | Shared configuration | All |

### 3. API Gateway (Nginx)
Routes:
| Path | Target | Auth |
|------|--------|------|
| `/multica/` | `multica-backend:8080` | JWT |
| `/hermes/` | `hermes:9119` | Bearer |
| `/hermes-api/` | `hermes:8642` | Bearer |
| `/paperclip/` | `code_paperclip:3100` | Better Auth |
| `/health` | Aggregated health | None |

### 4. Integration Configurations

#### A. Hermes → Paperclip (LLM Provider)
Paperclip configure `opencode_local` adapter pointing to Hermes API:
- Provider: `hermes`
- Base URL: `http://hermes:8642/v1`
- Model: `hermes-agent`
- API Key: `d35b66c67324144a95da470a9ab19d6b902decafbb18111cdfde2b75f540ad26`

#### B. Paperclip → Hermes (Agent Orchestration)
Paperclip create adapter to call Hermes gateway:
- Adapter type: `http`
- Endpoint: `http://hermes:8642/v1/chat/completions`
- Auth: Bearer token

#### C. Multica → Hermes (Task Triggers)
Configure Multica webhook to trigger Hermes agent runs:
- Multica creates issue → webhook triggers Hermes
- Hermes processes task → updates Multica via API

## Docker Compose

```yaml
services:
  runner:
    image: ubuntu:22.04
    container_name: runner
    restart: unless-stopped
    ports:
      - "8080:80"
      - "873:873"
    environment:
      - TZ=Asia/Makassar
    volumes:
      - runner_data:/data
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./scripts:/opt/scripts
    command: >
      sh -c "apt-get update &&
             apt-get install -y nginx rsync curl &&
             chmod +x /opt/scripts/* &&
             /opt/scripts/health-check.sh &
             nginx -g 'daemon off;'"
    deploy:
      resources:
        limits:
          memory: 512M
          cpus: "0.5"
    networks:
      - dokploy-network

volumes:
  runner_data:
    driver: local

networks:
  dokploy-network:
    external: true
```

## Implementation Steps

### Phase 1: Ubuntu Runner Container
1. Buat Docker Compose file
2. Buat nginx.conf untuk API gateway
3. Buat health check script
4. Deploy ke Dokploy
5. Verify akses

### Phase 2: Shared Storage
1. Setup volume mounts untuk agent workspaces
2. Setup file sharing untuk Multica
3. Setup log forwarding
4. Setup backup scripts

### Phase 3: Integration - Hermes ↔ Paperclip
1. Configure Paperclip adapter ke Hermes API
2. Configure Hermes adapter di Paperclip
3. Test LLM calls via Hermes

### Phase 4: Integration - Multica ↔ Hermes
1. Setup webhook di Multica
2. Configure Hermes to update Multica
3. Test task flow

### Phase 5: API Gateway
1. Configure nginx routes
2. Test all endpoints via gateway
3. Setup SSL/TLS (optional)

## Credentials (for reference)

| Service | Auth | Credential |
|---------|------|------------|
| Hermes API | Bearer | `d35b66c67324144a95da470a9ab19d6b902decafbb18111cdfde2b75f540ad26` |
| Hermes Dashboard | Session | `ZHc75DqHLMwPimxwS95vMYG2h3jxD3XtQl_RZnDD15A` |
| Multica Backend | JWT Secret | `b548582f36c1d77ac65b1d19d60a3f5749e1c075e690d9d1304c7b98a0ee959f` |
| Paperclip | Better Auth | `ee69913850307135544a856c5ca3871c921f5a37c0f517b0778d1899596f8444` |
| 9router | API Key | `sk-a9b71dfd70f092da-4kzkbh-0c9a7a5a` |

## Verification

1. Ubuntu Runner Container running and accessible
2. Nginx gateway routes all requests correctly
3. Shared volumes accessible from all containers
4. Hermes API callable from Paperclip
5. Multica webhook triggers Hermes agent
6. All health checks pass
7. Logs centralized in `/data/logs`

## Risk & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| RAM overflow | Container killed | Set resource limits (512MB runner) |
| Network conflict | Service unreachable | Use dokploy-network overlay |
| Auth token leak | Security breach | Store in Docker secrets |
| Volume corruption | Data loss | Regular backups to /data/backups |
