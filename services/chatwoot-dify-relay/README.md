# chatwoot-dify-relay

Service kecil yang menjembatani webhook Chatwoot dengan Evolution API agar
status percakapan di Chatwoot otomatis mereset / men-pause sesi Dify.

## Yang Dibutuhkan
- Chatwoot tidak bisa kirim payload custom + header `apikey` ke Evolution
  endpoint `/dify/changeStatus/{instance}`. Relay ini menerjemahkan webhook
  Chatwoot menjadi panggilan Evolution yang sesuai format.

## Mapping Event
| Chatwoot status | Evolution status | Efek di sisi WhatsApp |
| --- | --- | --- |
| `resolved` | `closed` | Sesi Dify dihapus, AI menjawab lagi pada pesan berikutnya |
| `open` (reopened) | `paused` | AI diam selama agent menangani percakapan |
| lainnya (`pending`, `snoozed`) | diabaikan | tidak ada perubahan |

## Endpoints
- `POST /chatwoot-hook` — endpoint untuk webhook Chatwoot
- `GET /healthz` — liveness probe

## Autentikasi
Shared secret. Salah satu dari:
- header `X-Hook-Token: <secret>`
- query string `?t=<secret>`

## Konfigurasi (env)
| Variabel | Wajib | Catatan |
| --- | --- | --- |
| `EVOLUTION_BASE_URL` | ya | `https://evolution-rengga-test.easyrentbali.com` |
| `EVOLUTION_INSTANCE` | ya | `85168932785` |
| `EVOLUTION_APIKEY` | ya | apikey instance Evolution |
| `CHATWOOT_HOOK_SECRET` | dianjurkan | `cw-relay-rengga-7b8e21c4` |
| `CHATWOOT_INBOX_IDS` | opsional | comma-separated, kosong = semua inbox |
| `PORT` | opsional | default `8085` |

## Deploy
File ada di server `192.168.122.50:/opt/chatwoot-dify-relay`.
```
cd /opt/chatwoot-dify-relay
sudo docker compose up -d --build
```
Compose meng-attach service ke `dokploy-network` dan mendaftarkan label
Traefik untuk host `chatwoot-hook-rengga-test.easyrentbali.com`.

## Webhook Chatwoot (sudah terdaftar)
- Account: `2`
- Webhook id: `1`
- URL: `https://chatwoot-hook-rengga-test.easyrentbali.com/chatwoot-hook?t=cw-relay-rengga-7b8e21c4`
- Subscriptions: `conversation_status_changed`

Re-register manual via API (jika perlu):
```
curl -H 'api_access_token: <chatwoot-token>' -H 'Content-Type: application/json' \
  -X POST https://chatwoot-rengga-test.easyrentbali.com/api/v1/accounts/2/webhooks \
  -d '{"url":"https://chatwoot-hook-rengga-test.easyrentbali.com/chatwoot-hook?t=cw-relay-rengga-7b8e21c4","subscriptions":["conversation_status_changed"]}'
```

## SOP Agent
- Saat selesai melayani: klik **Resolve** di Chatwoot. AI otomatis menjawab
  lagi saat pelanggan mengirim pesan berikutnya.
- Kalau perlu menangani manual: klik **Reopen**. AI diam selama
  percakapan masih `open`.
- Kalau agent lupa Resolve: jaring pengaman Evolution Dify `expire = 20`
  membuat status `paused` otomatis hilang setelah 20 menit hening, sehingga
  AI aktif kembali tanpa intervensi.

## Diagnosa
- log relay: `sudo docker logs --tail 50 chatwoot-dify-relay-relay-1`
- log Chatwoot delivery: `sudo docker logs --tail 200 test-chatwoot-tshwpg-chatwoot-sidekiq-1 | grep WebhookJob`
- session Dify saat ini:
  ```
  sudo docker exec -i test-evolution-api-lvablx-postgres-1 \
    sh -lc 'PGPASSWORD=<pwd> psql -U postgres -d evolution -c "select * from \"IntegrationSession\" order by \"updatedAt\" desc limit 10;"'
  ```
- reset manual via API (tanpa Chatwoot):
  ```
  curl -H 'apikey: <evolution-apikey>' -H 'Content-Type: application/json' \
    -X POST https://evolution-rengga-test.easyrentbali.com/dify/changeStatus/85168932785 \
    -d '{"remoteJid":"<digits>@s.whatsapp.net","status":"closed"}'
  ```

## Hasil Uji
- `POST /chatwoot-hook` payload simulasi `resolved` → Evolution HTTP 200, session dihapus.
- `POST /chatwoot-hook` payload simulasi `open` → Evolution HTTP 200, status `paused`.
- Token salah → HTTP 401.
- Status tak terkait (`pending`) → di-skip.
- Toggle status nyata via API Chatwoot account 2 conversation 2:
  - Resolve → relay menerima webhook, panggil Evolution `closed`, session terhapus.
  - Reopen → relay menerima webhook, panggil Evolution `paused`.
