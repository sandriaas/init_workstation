#!/usr/bin/env bash
#
# scripts/domain/03-delete-domain.sh
#
# Deletes a domain from a Zeabur service.
#
# Usage:
#   ./03-delete-domain.sh <service-id> <env-id> <domain>
#   ./03-delete-domain.sh 6a242f96f1be9943f1f972a7 environment-6a242c9f95b39806d284aaa7 olddomain.zeabur.app
#
# Note: CLI --id is the SERVICE ID (not the domain ID). The domain name
# is passed via --domain. The env-id must include the 'environment-' prefix.

set -euo pipefail

if [ $# -lt 3 ]; then
    echo "Usage: $0 <service-id> <env-id> <domain>" >&2
    exit 1
fi

SERVICE_ID="$1"
ENV_ID="$2"
DOMAIN="$3"

if [ -z "${ZEABUR_TOKEN:-}" ]; then
    echo "ERROR: ZEABUR_TOKEN env var not set" >&2
    exit 1
fi

WORKSPACE="${WORKSPACE:-personal}"

echo "Deleting domain $DOMAIN from service $SERVICE_ID..."

npx -y zeabur@latest domain delete \
    --id "$SERVICE_ID" \
    --domain "$DOMAIN" \
    --env-id "$ENV_ID" \
    --workspace "$WORKSPACE" \
    -y

echo "Deleted."
