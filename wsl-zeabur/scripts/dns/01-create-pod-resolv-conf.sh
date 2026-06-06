#!/usr/bin/env bash
#
# scripts/dns/01-create-pod-resolv-conf.sh
#
# Creates /etc/k3s-pod-resolv.conf with cluster DNS as the primary resolver.
# This file is then passed to k3s via --resolv-conf flag (see
# /etc/systemd/system/k3s.service.d/override.conf).
#
# Without this, pods use the WSL host's /etc/resolv.conf (which has 1.1.1.1
# as the primary). The pod network (10.42.0.0/16) cannot reach 1.1.1.1
# because the WSL NAT doesn't support UDP for public DNS.
#
# Usage:
#   sudo ./01-create-pod-resolv-conf.sh

set -euo pipefail

POD_RESOLV="/etc/k3s-pod-resolv.conf"

if [ -f "$POD_RESOLV" ]; then
    echo "$POD_RESOLV already exists. Contents:"
    cat "$POD_RESOLV"
    exit 0
fi

cat > "$POD_RESOLV" <<'EOF'
# /etc/k3s-pod-resolv.conf
# Used by k3s via --resolv-conf flag.
# Cluster DNS first (10.43.0.10 = CoreDNS service IP), public resolvers as
# fallback for queries that CoreDNS cannot resolve (e.g., external domains).
nameserver 10.43.0.10
nameserver 8.8.8.8
nameserver 1.1.1.1
options edns0 trust-ad
search default.svc.cluster.local svc.cluster.local cluster.local
EOF

# Make immutable to prevent WSL from overwriting on next wsl.conf change
chattr +i "$POD_RESOLV" 2>/dev/null || true

echo "Created $POD_RESOLV"
echo
echo "Next: install the k3s drop-in to use this file:"
echo "  sudo mkdir -p /etc/systemd/system/k3s.service.d"
echo "  sudo cp persistence/k3s.service.d-override.conf /etc/systemd/system/k3s.service.d/"
echo "  sudo systemctl daemon-reload"
echo "  sudo systemctl restart k3s"
