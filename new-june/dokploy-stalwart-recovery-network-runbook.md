---
meta:
  title: "How do I recover and verify the Stalwart service on Dokploy?"
  navLabel: "Recovering Stalwart on Dokploy"
  category: "Operations"
  contentType: "Troubleshooting"
status: "Current as of 2026-06-09"
---

<!-- markdownlint-disable MD013 MD025 -->

# How do I recover and verify the Stalwart service on Dokploy?

This runbook records the complete recovery and network-repair session for the Stalwart Mail Server deployment on Dokploy. It covers the initial process cleanup, account recovery, Dokploy API operations, Docker Compose correction, listener verification, unresolved certificate and Domain Name System (DNS) work, and security cleanup.

## Document plan

- **Goal**: recover Stalwart administrative access and expose every configured mail listener through Dokploy
- **Audience**: operators responsible for this Dokploy and Stalwart deployment
- **Scope**: actions performed from the first support request through the final listener tests on June 9, 2026
- **Excluded data**: live passwords, API keys, tokens, and embedded Git credentials
- **Open work**: rotate exposed credentials, correct mail DNS, issue trusted mail certificates, and verify the permanent administrator account

## Current result

The Stalwart service is running on Dokploy. SMTP, SMTPS, IMAPS, POP3S, ManageSieve, HTTPS, JMAP, and WebDAV are reachable on their intended public paths. The direct mail TLS ports still present a self-signed certificate because the configured mail hostnames do not resolve to this server.

| Component | Current state |
| --- | --- |
| Dokploy dashboard | Reachable at `http://107.173.29.47:3000` |
| Dokploy project | `A1` |
| Environment | `production` |
| Compose service | `Stalwart Minimal (SQLite)` |
| Compose ID | `OPSEGU3xOb5NXtpuRdiwR` |
| Application name | `a1-stalwartminimal-ngzuws` |
| Stalwart web administration | `https://stalwart-a1b-107-173-29-47.sslip.io/admin` |
| Public HTTPS certificate | Valid Let’s Encrypt certificate for the `sslip.io` hostname |
| Recovery administrator | Enabled as `admin`; password omitted and must be rotated |
| Permanent administrator | `admin@easyrentbali.com`; password reset was not independently verified |
| Storage | SQLite with persistent Docker volumes |

## Security notice

Several credentials appeared in the support conversation or local Git configuration. Treat each exposed value as compromised even if the conversation is private.

Rotate these credentials:

- Dokploy API key used during this session
- Stalwart recovery administrator password
- Any password assigned to `admin@easyrentbali.com` during the attempted reset
- GitHub personal access token embedded in the `origin` remote URL

Do not commit replacement credentials to this repository. Store them in a password manager or secret store.

## Session chronology

This section records each action in order, including failed or incomplete attempts.

### Stop all OpenCode processes

The first request was to stop every running `opencode` process. The initial process list contained several `opencode` processes and helper commands associated with OpenCode snapshots.

The broad termination command did not remove one remaining process. A PID-specific `SIGKILL` removed the last process, and an exact-name check returned no remaining `opencode` processes.

Use this sequence for the same cleanup:

```bash
pgrep -x opencode
pkill -f opencode || true
sleep 1
pgrep -x opencode || true
```

If one process remains, terminate only that process:

```bash
kill -9 process_id_here
pgrep -x opencode || true
```

### Investigate the initial login problem

The first login investigation opened the Dokploy dashboard and selected **Lost your password?**. That link opened Dokploy documentation rather than an email reset form.

Dokploy documents these host-side recovery commands:

```bash
docker ps
docker exec -it container_id_here bash -c "pnpm run reset-password"
```

Dokploy uses a separate command for two-factor authentication (2FA):

```bash
docker exec -it container_id_here bash -c "pnpm run reset-2fa"
```

These commands reset Dokploy itself. They do not reset a Stalwart account.

### Identify the Stalwart deployment through the Dokploy API

The request was clarified as a Stalwart administrator recovery using the Dokploy API. The supplied API key authenticated successfully through the `x-api-key` header.

The project query returned one project and one Compose deployment:

| Field | Value |
| --- | --- |
| Project | `A1` |
| Project ID | `0RQJON54J83O5VrU_yGKD` |
| Organization ID | `UgVG7Mw0VQBNVDNifIOt6` |
| Environment | `production` |
| Environment ID | `n09SjbOMelX1oL3CqJiVM` |
| Compose name | `Stalwart Minimal (SQLite)` |
| Compose ID | `OPSEGU3xOb5NXtpuRdiwR` |

Use an environment variable for the API key:

```bash
export DOKPLOY_URL='http://107.173.29.47:3000'
export DOKPLOY_API_KEY='your_dokploy_api_key_here'
```

List projects:

```bash
curl --fail --silent --show-error \
  --header "x-api-key: ${DOKPLOY_API_KEY}" \
  "${DOKPLOY_URL}/api/project.all"
```

Read the Stalwart Compose record:

```bash
curl --fail --silent --show-error \
  --header "x-api-key: ${DOKPLOY_API_KEY}" \
  "${DOKPLOY_URL}/api/compose.one?composeId=OPSEGU3xOb5NXtpuRdiwR"
```

### Add a Stalwart recovery administrator

The original Compose environment contained only these application settings:

```dotenv
STALWART_STORAGE_BACKEND=sqlite
STALWART_HOSTNAME=mail.defaultdomain.com
```

The Compose file did not pass a recovery administrator to the container. The recovery procedure generated a random password and added this secret environment variable:

```dotenv
STALWART_RECOVERY_ADMIN=admin:generated_password_here
```

The Compose service then passed the variable into the Stalwart container:

```yaml
environment:
  - STALWART_STORAGE_BACKEND=sqlite
  - STALWART_HOSTNAME=${STALWART_HOSTNAME-mail.defaultdomain.com}
  - STALWART_RECOVERY_ADMIN=${STALWART_RECOVERY_ADMIN}
```

The Dokploy `compose.update` call returned `200 OK`. The subsequent `compose.redeploy` call queued a rebuild, and deployment `x59kisIOkDw8GgfJjKFCs` finished with status `done` at `2026-06-09T08:46:06.069Z`.

### Verify recovery access

Basic authentication with the recovery administrator returned `200 OK` from Stalwart’s `/api/account` endpoint. The response included system administration permissions.

The browser login also succeeded and opened the Stalwart administration portal. The portal displayed the permanent account `admin@easyrentbali.com` with the description `System administrator`.

Verify recovery API access without placing the password in shell history:

```bash
read -rsp 'Stalwart recovery password: ' STALWART_PASSWORD
printf '\n'

curl --fail --silent --show-error \
  --user "admin:${STALWART_PASSWORD}" \
  'https://stalwart-a1b-107-173-29-47.sslip.io/api/account'

unset STALWART_PASSWORD
```

### Attempt to reset the permanent administrator

The Stalwart web interface opened the edit screen for `admin@easyrentbali.com`. The password field accepted the generated password after keyboard-level input enabled the **Save** button.

The browser observed successful JMAP requests, but an independent Basic authentication test for `admin@easyrentbali.com` returned `401 Unauthorized`. Therefore, this session did not prove that the permanent administrator password changed.

Do not rely on that attempted password reset. Log in with the recovery administrator and set a new permanent password through a verified account update. Confirm the result in a new browser session before removing recovery access.

## Diagnose listener exposure

The Stalwart settings page listed seven active listeners:

| Listener | Protocol | Container bind address | Intended public port |
| --- | --- | --- | --- |
| `http` | HTTP | `[::]:8080` | Reverse proxy only |
| `https` | HTTP over TLS | `[::]:443` | `443` through Dokploy |
| `sieve` | ManageSieve | `[::]:4190` | `4190` |
| `pop3s` | POP3 over TLS | `[::]:995` | `995` |
| `imaps` | IMAP over TLS | `[::]:993` | `993` |
| `submissions` | SMTP over implicit TLS | `[::]:465` | `465` |
| `smtp` | SMTP | `[::]:25` | `25` |

The original Compose file published only three container ports:

```yaml
ports:
  - "25"
  - "587"
  - "8080"
```

A bare container port such as `"25"` asks Docker to assign a random host port. It does not bind host port `25`. Port `587` also had no matching Stalwart listener.

Initial probes found only public port `443` reachable. Dokploy’s reverse proxy handled that port. Ports `25`, `465`, `587`, `993`, `995`, `4190`, and direct `8080` were closed or filtered.

## Correct the Docker Compose port mappings

The repair bound each direct mail protocol to the same host port. HTTP port `8080` remained available only to Dokploy’s reverse proxy.

The final sanitized Compose file is:

```yaml
services:
  stalwart:
    image: stalwartlabs/stalwart:latest
    ports:
      - "25:25"
      - "465:465"
      - "993:993"
      - "995:995"
      - "4190:4190"
      - "8080"
    volumes:
      - stalwart_data:/opt/stalwart/data
      - stalwart_config:/etc/stalwart
      - stalwart_state:/var/lib/stalwart
    environment:
      - STALWART_STORAGE_BACKEND=sqlite
      - STALWART_HOSTNAME=${STALWART_HOSTNAME-mail.defaultdomain.com}
      - STALWART_RECOVERY_ADMIN=${STALWART_RECOVERY_ADMIN}

volumes:
  stalwart_data:
  stalwart_config:
  stalwart_state:
```

The second `compose.update` call returned `200 OK`. Deployment `e9EwXKvxm_M7z-BciYvX2` finished with status `done` at `2026-06-09T10:30:47.002Z`.

Do not publish container port `443` directly while Dokploy or Traefik owns host port `443`. The existing Dokploy domain routes public HTTPS traffic to container port `8080` and supplies the trusted certificate.

## Verify every listener

The final tests checked TCP reachability, TLS negotiation, and application protocol responses.

### Final listener results

| Public endpoint | Result | Evidence |
| --- | --- | --- |
| `107.173.29.47:25` | Pass | `220 mx.easyrentbali.com Stalwart ESMTP at your service` |
| `107.173.29.47:465` | Pass with certificate warning | TLS 1.3 and SMTP `EHLO` response |
| `107.173.29.47:993` | Pass with certificate warning | TLS 1.3 and IMAP capability response |
| `107.173.29.47:995` | Pass with certificate warning | TLS 1.3 and POP3 capability response |
| `107.173.29.47:4190` | Pass | ManageSieve capability response and `STARTTLS` support |
| `stalwart-a1b-107-173-29-47.sslip.io:443` | Pass | HTTP `200`, valid Let’s Encrypt certificate |
| `/jmap/session` through HTTPS | Pass | HTTP `200` |
| WebDAV through HTTPS | Available through the HTTP service | Uses the same HTTPS listener and proxy route |
| `107.173.29.47:587` | Not configured | No Stalwart `587` listener exists |
| `107.173.29.47:8080` | Intentionally not public | Dokploy routes HTTPS to the container’s dynamic host mapping |

### Repeat TCP checks

```bash
for port in 25 443 465 993 995 4190; do
  if timeout 5 bash -c "</dev/tcp/107.173.29.47/${port}" 2>/dev/null; then
    printf '%s open\n' "${port}"
  else
    printf '%s closed_or_filtered\n' "${port}"
  fi
done
```

### Verify SMTP on port 25

```bash
timeout 7 bash -c \
  'exec 3<>/dev/tcp/107.173.29.47/25; head -n 1 <&3'
```

Expected prefix:

```text
220 mx.easyrentbali.com Stalwart ESMTP
```

### Verify SMTPS on port 465

```bash
printf 'EHLO test.local\r\nQUIT\r\n' | \
  timeout 8 openssl s_client \
    -quiet \
    -connect 107.173.29.47:465 \
    -servername mx.easyrentbali.com
```

A working listener returns SMTP capabilities. Certificate verification will fail until DNS and Stalwart certificate configuration are corrected.

### Verify IMAPS on port 993

```bash
printf 'a1 CAPABILITY\r\na2 LOGOUT\r\n' | \
  timeout 8 openssl s_client \
    -quiet \
    -connect 107.173.29.47:993 \
    -servername mx.easyrentbali.com
```

A working listener returns `IMAP4rev2`, `IMAP4rev1`, authentication methods, and a successful logout response.

### Verify POP3S on port 995

```bash
printf 'CAPA\r\nQUIT\r\n' | \
  timeout 8 openssl s_client \
    -quiet \
    -connect 107.173.29.47:995 \
    -servername mx.easyrentbali.com
```

A working listener starts with `+OK Stalwart POP3 at your service` and returns the capability list.

### Verify ManageSieve on port 4190

```bash
timeout 7 bash -c \
  'exec 3<>/dev/tcp/107.173.29.47/4190; head -n 8 <&3'
```

A working listener reports `Stalwart ManageSieve`, supported SASL methods, Sieve extensions, and `STARTTLS`.

### Verify HTTPS and JMAP

```bash
curl --fail --silent --show-error \
  --output /dev/null \
  --write-out 'admin_http=%{http_code} tls_verify=%{ssl_verify_result}\n' \
  'https://stalwart-a1b-107-173-29-47.sslip.io/admin/'

curl --fail --silent --show-error \
  --output /dev/null \
  --write-out 'jmap_http=%{http_code} tls_verify=%{ssl_verify_result}\n' \
  'https://stalwart-a1b-107-173-29-47.sslip.io/jmap/session'
```

Both requests returned HTTP `200` with TLS verification result `0`.

## Resolve the remaining TLS and DNS problem

Ports `465`, `993`, and `995` negotiate TLS 1.3 but present a self-signed certificate with subject `CN=rcgen self signed cert`. Standard mail clients will reject that certificate unless the operator disables verification, which is not an acceptable production configuration.

The HTTPS proxy certificate is valid only for:

```text
stalwart-a1b-107-173-29-47.sslip.io
```

The server identifies itself in SMTP as:

```text
mx.easyrentbali.com
```

DNS checks during the session returned these addresses:

| Hostname | Address on June 9, 2026 | Expected for this server |
| --- | --- | --- |
| `mx.easyrentbali.com` | `139.59.229.185` | `107.173.29.47` |
| `mail.easyrentbali.com` | `103.163.138.80` | `107.173.29.47` if used as the mail host |
| `mail.defaultdomain.com` | `54.243.117.197` | Do not use for this deployment |
| `stalwart-a1b-107-173-29-47.sslip.io` | `107.173.29.47` | Correct for temporary web access |

Choose one permanent mail hostname before requesting a certificate. `mx.easyrentbali.com` matches the current SMTP banner and is the least disruptive choice.

Complete these DNS and certificate steps:

1. Change the `A` record for `mx.easyrentbali.com` to `107.173.29.47`.
2. Confirm the domain’s `MX` record points to `mx.easyrentbali.com`.
3. Remove stale `AAAA` records unless this server has working public IPv6.
4. Configure reverse DNS for `107.173.29.47` as `mx.easyrentbali.com` through the hosting provider.
5. Configure Stalwart ACME for `mx.easyrentbali.com`.
6. Assign the trusted certificate to the `submissions`, `imaps`, and `pop3s` listeners.
7. Repeat the `openssl s_client` tests without suppressing certificate errors.
8. Publish SPF, DKIM, and DMARC records after the mail hostname and delivery path are final.

Do not use the `sslip.io` certificate for SMTP, IMAP, or POP unless clients also connect with that exact hostname. Certificate names and client hostnames must match.

## Manage the recovery administrator safely

The recovery administrator grants broad system permissions. Keep it only until the permanent administrator works in a clean session.

Follow this sequence:

1. Sign in with recovery username `admin`.
2. Open `admin@easyrentbali.com` in **Management > Accounts**.
3. Set a new unique password.
4. Sign out of the recovery session.
5. Open a private browser window.
6. Sign in as `admin@easyrentbali.com` with the new password.
7. Verify access to **Settings**, **Listeners**, and **Management**.
8. Remove `STALWART_RECOVERY_ADMIN` from the Dokploy environment and Compose service.
9. Redeploy Stalwart.
10. Confirm the permanent administrator still works.

Never reuse the recovery password disclosed during this session.

## Redeploy Stalwart through the Dokploy API

Use this request after a validated Compose update:

```bash
curl --fail --silent --show-error \
  --request POST \
  --header "x-api-key: ${DOKPLOY_API_KEY}" \
  --header 'Content-Type: application/json' \
  --data '{"composeId":"OPSEGU3xOb5NXtpuRdiwR"}' \
  "${DOKPLOY_URL}/api/compose.redeploy"
```

Read the Compose record again and confirm the newest deployment has `status: done` and no `errorMessage` before testing ports.

## Roll back the port change

Use this rollback only if a fixed host port conflicts with another service. First identify the conflict on the Dokploy host:

```bash
sudo ss -lntp
sudo docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

Remove only the conflicting host mapping from the Compose `ports` list, redeploy, and confirm the remaining listeners. Do not restore bare mappings for production mail ports because Docker will choose random host ports.

## Operational checklist

Use this checklist after every Stalwart configuration or Dokploy deployment change:

- [ ] Dokploy Compose status is `done`
- [ ] The newest deployment has no error message
- [ ] Stalwart administration returns HTTP `200`
- [ ] `/jmap/session` returns HTTP `200`
- [ ] SMTP port `25` returns the expected hostname
- [ ] SMTPS port `465` negotiates trusted TLS and returns SMTP capabilities
- [ ] IMAPS port `993` negotiates trusted TLS and returns IMAP capabilities
- [ ] POP3S port `995` negotiates trusted TLS and returns POP3 capabilities
- [ ] ManageSieve port `4190` returns capabilities and advertises `STARTTLS`
- [ ] DNS `A`, `MX`, PTR, SPF, DKIM, and DMARC records match the active server
- [ ] The permanent administrator works without the recovery administrator
- [ ] No secrets appear in Git history, shell scripts, or documentation

## Incident lessons

- A Dokploy password reset and a Stalwart account reset are separate procedures.
- Dokploy API keys use the `x-api-key` request header.
- A Docker Compose port value such as `"25"` does not publish host port `25`.
- Listener health requires protocol checks, not only successful TCP connections.
- A successful browser request does not prove that a password changed; verify with a clean authentication attempt.
- Reverse-proxy TLS protects HTTP services but does not automatically protect direct SMTP, IMAP, POP3, or ManageSieve listeners.
- Trusted mail TLS requires DNS names that resolve to the active mail server.
- Credentials pasted into chat or embedded in Git remotes require rotation.

## Source references

- [Dokploy password and 2FA reset](https://docs.dokploy.com/docs/core/reset-password)
- [Stalwart source and documentation](https://github.com/stalwartlabs/stalwart)
- [Stalwart documentation](https://stalw.art/docs/)
