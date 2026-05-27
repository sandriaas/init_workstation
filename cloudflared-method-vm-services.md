# cloudflared: Expose VM services through host tunnel

## Endpoint

```
https://31208-vm_2-minipc-local.easyrentbali.com
```

Routes to: `http://192.168.122.51:31208` (VM-2 on libvirt NAT bridge)

## What was done

### 1. Config entry added

File: `~/.cloudflared/config-minipc-local.yml`

Inserted before the catch-all `http_status:404`:

```yaml
  - hostname: 31208-vm_2-minipc-local.easyrentbali.com
    service: http://192.168.122.51:31208
```

### 2. DNS CNAME updated

Updated existing record to point to the `minipc-local` tunnel (`587b853d`):

```
31208-vm_2-minipc-local.easyrentbali.com → 587b853d-f751-4cd5-a12f-fdb6b8f8243e.cfargotunnel.com
```

API token extracted from `~/.cloudflared/cert.pem`, zone ID: `34fecda54c7edfb5f99c39386ec6066c`.

### 3. Service restarted

```bash
sudo systemctl restart cloudflared-minipc-local
```

## Verification

```bash
curl -s -o /dev/null -w "%{http_code}" https://31208-vm_2-minipc-local.easyrentbali.com
# → 302 (tunnel working, service responding)
```

## Add more VM-2 ports

To add another port (e.g. 31209), follow the same pattern:

```bash
# 1. Edit config
vim ~/.cloudflared/config-minipc-local.yml
# Add before http_status:404:
#   - hostname: 31209-vm_2-minipc-local.easyrentbali.com
#     service: http://192.168.122.51:31209

# 2. Create DNS CNAME
ZONE_ID="34fecda54c7edfb5f99c39386ec6066c"
API_TOKEN=$(python3 -c "import sys,json; print(json.load(sys.stdin)['apiToken'])" < <(cat ~/.cloudflared/cert.pem | grep -v "^-----" | base64 -d))

curl -s -X POST \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"type":"CNAME","name":"31209-vm_2-minipc-local.easyrentbali.com","content":"587b853d-f751-4cd5-a12f-fdb6b8f8243e.cfargotunnel.com","proxied":true}' \
  "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records"

# 3. Restart
sudo systemctl restart cloudflared-minipc-local
```

## Tunnel details

| Field | Value |
|-------|-------|
| Tunnel name | `minipc-local` |
| Tunnel ID | `587b853d-f751-4cd5-a12f-fdb6b8f8243e` |
| Config file | `~/.cloudflared/config-minipc-local.yml` |
| Service name | `cloudflared-minipc-local` |
| Domain | `easyrentbali.com` |
| Zone ID | `34fecda54c7edfb5f99c39386ec6066c` |
| VM-2 IP | `192.168.122.51` |
