#!/bin/bash
#
# /usr/local/bin/start-tailscale.sh
# Single-instance Tailscale daemon launcher for WSL2.
#
# WHY THIS EXISTS
#   WSL2's init (/init) sends SIGTERM to *systemd-managed services* whenever
#   the network interface resets. If tailscaled runs as a systemd service it
#   gets killed every 30-60s -> the node never holds its mesh IP -> Zeabur
#   shows "disconnected". So tailscaled is launched DETACHED (nohup) from a
#   oneshot rc-local.service that uses RemainAfterExit=yes; its cgroup stays
#   alive and service-targeted SIGTERMs never reach the daemon. This is the
#   original, proven design (ran 28h fine).
#
# THE ONE REAL BUG THIS FIXES
#   The plain `pgrep` check in the old version was not atomic: if rc.local ran
#   twice close together (k3s restart re-triggers rc-local), TWO tailscaled
#   instances could start and fight over the same state file + socket, leaving
#   the CLI talking to a stuck instance (NoState, no IP). A flock(1) guard makes
#   startup atomic so exactly one daemon ever runs.
#
# Host-side note: Windows sleep (Modern Standby) and the WSL vmIdleTimeout are
# also configured to never suspend the VM, so no watchdog/resume logic is
# needed here.

STATE="/var/lib/tailscale/tailscaled.state"
SOCK="/run/tailscale/tailscaled.sock"
LOGFILE="/var/log/tailscaled.log"
LOCK="/run/lock/start-tailscale.lock"
PORT="41641"
TS_BIN="/usr/sbin/tailscaled"

mkdir -p /run/lock /run/tailscale 2>/dev/null || true

# --- Single-instance guard: only one launcher proceeds past here ----------
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "$(date -Is) another start-tailscale.sh holds the lock; exiting"
  exit 0
fi

# Already running? Then there is nothing to do.
if pgrep -x tailscaled >/dev/null 2>&1; then
  echo "$(date -Is) tailscaled already running"
  exit 0
fi

# Wait briefly for the network to settle on (re)start.
sleep 5

# Re-check under the lock in case another path started it during the sleep.
if pgrep -x tailscaled >/dev/null 2>&1; then
  echo "$(date -Is) tailscaled started by another path"
  exit 0
fi

# Start tailscaled detached. It auto-logs-in using the saved prefs
# (control server URL is persisted in the state file).
echo "$(date -Is) starting tailscaled (detached)"
nohup "$TS_BIN" \
  --state="$STATE" \
  --socket="$SOCK" \
  --port="$PORT" \
  >>"$LOGFILE" 2>&1 < /dev/null &

echo "$(date -Is) tailscaled started with PID $!"
