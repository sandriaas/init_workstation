#!/usr/bin/env bash
#
# /opt/zeabur-fixes/install-nats-cli.sh
#
# Installs the `nats` CLI tool. Required by apply-fixes.sh to manage
# JetStream streams and consumers.
#
# Run once:
#   sudo bash /opt/zeabur-fixes/install-nats-cli.sh
#
# Or copy the bundled nats binary directly:
#   sudo cp persistence/bin/nats /usr/local/bin/nats
#   sudo chmod +x /usr/local/bin/nats

set -euo pipefail

NATS_VERSION="0.4.0"
TMPDIR="$(mktemp -d)"

echo "Installing nats CLI v${NATS_VERSION}..."

if command -v nats >/dev/null 2>&1; then
    echo "nats CLI already installed: $(nats --version)"
    exit 0
fi

cd "$TMPDIR"

# Try the binaries.nats.dev installer first
if curl -sf https://binaries.nats.dev/nats-io/natscli@latest -o install.sh 2>/dev/null; then
    bash install.sh
    if command -v nats >/dev/null 2>&1; then
        echo "Installed: $(nats --version)"
        exit 0
    fi
fi

# Fallback: GitHub release
echo "Falling back to GitHub release..."
curl -sLO "https://github.com/nats-io/natscli/releases/download/v${NATS_VERSION}/nats-${NATS_VERSION}-linux-amd64.zip"
if [ ! -s "nats-${NATS_VERSION}-linux-amd64.zip" ]; then
    echo "ERROR: download failed" >&2
    exit 1
fi
apt-get install -y unzip
unzip -o "nats-${NATS_VERSION}-linux-amd64.zip"
install -m 0755 "nats-${NATS_VERSION}-linux-amd64/nats" /usr/local/bin/nats
echo "Installed: $(nats --version)"
