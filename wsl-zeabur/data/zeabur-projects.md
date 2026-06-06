# Zeabur Projects

> All projects in the current Zeabur workspace. User: `andriz.mitnick619sas`,
> Workspace: `personal`, Org: `Easy Rent Bali` (org context)

| # | Project ID | Name | Notes |
|---|-----------|------|-------|
| 1 | (TBD) | Paperclip | |
| 2 | (TBD) | Multica | |
| 3 | (TBD) | untitled-13 | |
| 4 | (TBD) | untitled-7 | |
| 5 | (TBD) | evolution-api-migrate | |
| 6 | (TBD) | chatwoot-migrate | |
| 7 | (TBD) | dify-migrate-mized | |
| 8 | (TBD) | VaultWarden | |
| 9 | (TBD) | untitled (omniroute) | |
| 10 | `6a242c9f2fe98e0879e0f199` | untitled-1 | **Stalwart** (the one we worked on) |

To list all projects:
```bash
npx -y zeabur@latest project list --workspace personal --json
```

## Active Project: untitled-1 (Stalwart)

- **Project ID:** `6a242c9f2fe98e0879e0f199`
- **Environment:** `6a242c9f95b39806d284aaa7` (production)
- **Service:** `6a242f96f1be9943f1f972a7` (stalwart, template: PREBUILT_V2)
- **Service password:** `k29C30HlVF7I4LaAD5Y6wviNKT8PGx1u`
- **Image:** `stalwartlabs/mail-server:v0.11.8`
- **Port mapping:** web:8080 (NodePort 32247)
- **Domain (current):** `yjhkbkjb.zeabur.app`
  - Domain ID: `6a2469b70d6e0588145e564e`
  - Status: ACTIVE
  - Created: 2026-06-07
  - isGenerated: true (Zeabur-generated domain)
- **Domain (deleted):** `ujj8886tghj8.zeabur.app`
  - Was resolving to 52.223.32.133 (AWS CloudFront) when public
  - Was used while ingress-controller was failing for ACME challenges

## Server

- **Server ID:** `server-6a23cdf424701a8493345c17` (dashboard: Online)
- **Tailscale Node ID:** 805, UserID 1245
- **Profile:** `adb4b8c0-9556-428d-8575-0d9b9739fdfe`
- **Tailscale IPs:** 100.64.3.1 (this WSL), 100.64.0.1 (Zeabur gateway)
- **WSL internal IPs:** 172.29.155.146 (eth0), 10.42.0.1 (cni0), 100.64.3.1 (tailscale0)

## Zeabur CLI Authentication

```bash
# Authenticate (token in env var)
export ZEABUR_TOKEN=sk-...   # get from https://zeabur.com/account/token
npx -y zeabur@latest profile info
```

Always pass `--workspace personal` to avoid the org context.

## Useful CLI Commands

```bash
# Profile
npx -y zeabur@latest profile info

# Projects
npx -y zeabur@latest project list --workspace personal --json

# Services in a project
npx -y zeabur@latest service list --project-id <PROJECT_ID> --json

# Service details
npx -y zeabur@latest service get --id <SERVICE_ID> --env-id environment-<ENV_ID> --json

# Domains
npx -y zeabur@latest domain list --id <SERVICE_ID> --env-id environment-<ENV_ID> --json
npx -y zeabur@latest domain generate --id <SERVICE_ID> --env-id environment-<ENV_ID> -y
npx -y zeabur@latest domain delete --id <SERVICE_ID> --domain <NAME> --env-id environment-<ENV_ID> -y

# Deployments
npx -y zeabur@latest deployment get --id <SERVICE_ID> --env-id environment-<ENV_ID> --json
npx -y zeabur@latest deployment list --id <SERVICE_ID> --env-id environment-<ENV_ID> --json
npx -y zeabur@latest deployment log --id <SERVICE_ID> --env-id environment-<ENV_ID> --deployment-id <DEP_ID>

# Service control
npx -y zeabur@latest service restart --id <SERVICE_ID> --env-id environment-<ENV_ID> -y
npx -y zeabur@latest service redeploy --id <SERVICE_ID> --env-id environment-<ENV_ID> -y  # FAILS for PREBUILT_V2
```

## GraphQL Endpoint (advanced)

For things not in the CLI, use the GraphQL API:

```bash
curl -X POST https://api.zeabur.com/graphql \
    -H "Authorization: Bearer $ZEABUR_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"query": "{ projects { _id name environments { _id name } } }"}'
```

Note: entities use `_id` not `id`. `Service` has `domains`, `ports(environmentID:)`,
`deployments`. `ServicePort` has `id` (not `_id`) and `port` (not `protocol`).
`Project.environments` does NOT have `services` (query separately).
GraphQL introspection is disabled.
