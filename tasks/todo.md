- [x] Restate goal + acceptance criteria
- [x] Locate existing implementation / patterns
- [x] Design: minimal approach + key decisions
- [x] Implement host-side SSH alias rename and client install cleanup
- [x] Update host docs and examples for Termux and other machines
- [x] Improve host tunnel verification in `scripts/check.sh`
- [x] Run the live host bootstrap and verify SSH tunnel readiness
- [x] Fix host verifier for root-owned hostname files and proxied Cloudflare DNS
- [x] Prevent Arch reruns from forcing a full system upgrade
- [x] Add a dedicated file with copy-paste connect commands for Termux and another computer
- [x] Run verification (syntax checks + checker)
- [x] Summarize changes + verification story

## 2026-06-10 Hermes Dashboard Recovery
- [x] Restate goal + acceptance criteria
- [x] Inspect public route, Zeabur network state, and runner process state
- [x] Identify root cause in runner bootstrap/supervisor config
- [x] Patch Hermes dashboard bind address for public Zeabur ingress
- [x] Restart service to load new supervisor command
- [x] Verify public dashboard URL and direct SSH path
- [x] Summarize changes + verification story

## Working Notes
- Scope is host-side SSH only.
- Canonical client alias for this device is `it01`.
- Keep password auth enabled.
- Keep tunnel-only access path with `websocat`; do not require Cloudflare Access.
- Live host bootstrap created tunnel `it01-ssh` with public hostname `6geczk4.easyrentbali.com`.
- `check.sh --profile host-ssh` should validate DNS reachability, not only raw CNAME output, because the record is proxied by Cloudflare.
- Hermes runner domain `runnerubu1hermes.zeabur.app` started returning 502 while SSH and internal service stayed healthy.
- Root cause: `/workspace/supervisord.conf` still launched `hermes dashboard --host 127.0.0.1 --port 9119`, which blocks Zeabur HTTP ingress.
- Persistent fix: wrapped `/workspace/pipx/venvs/hermes-agent/bin/hermes` so boot-time dashboard launches rewrite `--host 127.0.0.1` to `--host 0.0.0.0 --insecure`.
- Verified current pod serves dashboard HTML on both `https://runnerubu1hermes.zeabur.app/sessions` and `http://127.0.0.1:9119/sessions`.
