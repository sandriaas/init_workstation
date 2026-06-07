# config/cloudflared/

Cloudflare Tunnel configuration files for exposing WSL k3s services to
the public internet.

## Files

- `config.yml` — cloudflared tunnel config. Specifies the tunnel ID,
  credentials path, and ingress rules (one-level wildcard
  `*.cfworkers.dpdns.org` → WSL ingress-controller at 172.29.155.146:443).
- `credentials.json` — tunnel credentials (mode 0600). Contains the
  account tag, tunnel ID, and tunnel secret.

## Deployed location

These files are deployed to `/etc/cloudflared/` on the WSL distro
by `persistence/deploy.sh`. cloudflared runs as a systemd service
(see `config/systemd/cloudflared.service`).

## Cloudflare account

- **Account ID**: `96d55ad87e6bb93a52d0d2728f0f093d`
- **Zone**: `cfworkers.dpdns.org` (zone ID `6c187494fcd18ba458c0a88e29f55ddf`)
- **Tunnel ID**: `d1534e02-b697-4e99-bb0d-cf04c79199a9` (`wsl-fx506-stalwart`)

## DNS setup (one-time in Cloudflare dashboard)

Create a wildcard CNAME record:

- Type: `CNAME`
- Name: `*`
- Target: `d1534e02-b697-4e99-bb0d-cf04c79199a9.cfargotunnel.com`
- Proxy: ON (orange cloud)
- TTL: Auto

## Why one-level wildcard only?

Cloudflare Universal SSL on the Free plan covers:
- The apex domain
- A single-level wildcard (`*.example.com`)

It does NOT cover sub-subdomain wildcards (`*.sub.example.com`). For
that you need Advanced Certificate Manager. So we use the one-level
pattern and put per-service hostnames at the first level (e.g.
`stalwart.cfworkers.dpdns.org`, `mail.cfworkers.dpdns.org`, etc.).

## Tunnel management

```bash
# Check status
sudo systemctl status cloudflared

# View recent logs
sudo journalctl -u cloudflared -n 50

# Restart
sudo systemctl restart cloudflared

# Inspect connections (lists Cloudflare edge POPs)
sudo journalctl -u cloudflared -f | grep "connection="
```

## Per-service exposure

Once the tunnel is up, expose a service by creating a Kubernetes
Ingress for a hostname under `cfworkers.dpdns.org`:

```bash
sudo /opt/zeabur-fixes/expose-service.sh \
    <subdomain> \
    <namespace> \
    <k8s-service-name> \
    <port>
```

The wildcard DNS is already in place, so the new hostname is routable
the moment the Ingress is created — no DNS changes needed.
