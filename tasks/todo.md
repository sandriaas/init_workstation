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

## Working Notes
- Scope is host-side SSH only.
- Canonical client alias for this device is `it01`.
- Keep password auth enabled.
- Keep tunnel-only access path with `websocat`; do not require Cloudflare Access.
- Live host bootstrap created tunnel `it01-ssh` with public hostname `6geczk4.easyrentbali.com`.
- `check.sh --profile host-ssh` should validate DNS reachability, not only raw CNAME output, because the record is proxied by Cloudflare.
