# Diagnostic Logs

Sample logs captured during troubleshooting of the WSL2 + Zeabur Wonder Mesh setup.

These logs are provided as **reference for what the issues look like** and what
the **final, fixed state** looks like. They are NOT live logs.

## Folders

- `diagnostics/` - Logs from read-only diagnostic scripts showing broken state
- `fixes/` - Logs from fix scripts showing what changed
- `before-after/` - Side-by-side comparisons of key services before/after fixes

## Captured Issues

| Issue | Where Captured | Fix |
|-------|----------------|-----|
| Tailscale restart loop (SIGTERM every 30s) | `diagnostics/tailscaled-journal-broken.log` | `fixes/tailscale-fix-output.log` |
| CoreDNS rewrite missing (kube-watch DNS timeout) | `diagnostics/kube-watch-errors.log` | `fixes/coredns-rewrite-output.log` |
| NATS authentication failure | `diagnostics/nats-auth-error.log` | `fixes/nats-noauth-config.log` |
| Server "Offline" in dashboard | `before-after/server-status.txt` | `fixes/verify-online.log` |
| ImagePullBackOff due to DNS | `diagnostics/registry-pull-error.log` | `fixes/dns-resolv-conf.log` |

## Reading These Logs

Each log file starts with a header block:

```bash
# ============================================
# Issue: <issue name>
# Captured: <YYYY-MM-DD HH:MM>
# Source: <which script or command>
# Severity: <error|warn|info>
# ============================================
```

Then the actual output. If the log is from a script, the script name is in
the source field. If it's from a journalctl or kubectl, the command is shown.

## Why Are These Logs Useful?

1. **Pattern recognition** - When debugging a new issue, compare your output to these samples
2. **Regression detection** - If you see the same patterns reappearing, the fix has reverted
3. **Documentation** - The troubleshooting.md doc references these logs by name
4. **Onboarding** - Anyone joining the project can see what "broken" looked like

## Note on Privacy

These logs are **sanitized**: API tokens, hostnames, IPs, and user names are
replaced with placeholders like `<TOKEN>`, `<HOSTNAME>`, `<IP>`, etc.

For the original live logs, see `C:\Users\Sandria\AppData\Local\Temp\opencode\`
(ephemeral, only available during the troubleshooting session).
