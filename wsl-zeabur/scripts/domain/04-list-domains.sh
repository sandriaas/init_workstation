#!/usr/bin/env bash
#
# scripts/domain/04-list-domains.sh
#
# Lists all domains for a Zeabur service.
#
# Usage:
#   ./04-list-domains.sh <service-id> <env-id>
#   ./04-list-domains.sh 6a242f96f1be9943f1f972a7 environment-6a242c9f95b39806d284aaa7

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <service-id> <env-id>" >&2
    exit 1
fi

SERVICE_ID="$1"
ENV_ID="$2"

if [ -z "${ZEABUR_TOKEN:-}" ]; then
    echo "ERROR: ZEABUR_TOKEN env var not set" >&2
    exit 1
fi

WORKSPACE="${WORKSPACE:-personal}"

npx -y zeabur@latest domain list \
    --id "$SERVICE_ID" \
    --env-id "$ENV_ID" \
    --workspace "$WORKSPACE" --json | jq .
