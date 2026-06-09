#!/usr/bin/env bash
#
# scripts/domain/01-add-domain.sh
#
# Adds a new generated *.zeabur.app domain to a Zeabur service.
#
# Usage:
#   ./01-add-domain.sh <service-id> <env-id>
#   ZEABUR_TOKEN=... ./01-add-domain.sh 6a242f96f1be9943f1f972a7 environment-6a242c9f95b39806d284aaa7
#
# Outputs the new domain name. Note: the new domain is in PROVISIONING
# status until DNS and cert provisioning complete (~5-15 minutes).

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <service-id> <env-id>" >&2
    echo "Example: $0 6a242f96f1be9943f1f972a7 environment-6a242c9f95b39806d284aaa7" >&2
    exit 1
fi

SERVICE_ID="$1"
ENV_ID="$2"

if [ -z "${ZEABUR_TOKEN:-}" ]; then
    echo "ERROR: ZEABUR_TOKEN env var not set" >&2
    echo "Get a token at: https://zeabur.com/account/token" >&2
    exit 1
fi

WORKSPACE="${WORKSPACE:-personal}"

echo "Adding generated domain to service $SERVICE_ID in env $ENV_ID..."

# CLI call: zeabur domain generate
output="$(npx -y zeabur@latest domain generate \
    --id "$SERVICE_ID" \
    --env-id "$ENV_ID" \
    --workspace "$WORKSPACE" --json 2>&1)" || {
    echo "CLI failed: $output" >&2
    exit 1
}

echo "$output" | jq .

# Extract the new domain name
domain="$(echo "$output" | jq -r '.[0].domain // .domain // .data.domain // empty')"
if [ -z "$domain" ]; then
    echo "Could not extract domain from CLI output" >&2
    echo "Full output above" >&2
    exit 1
fi

echo
echo "==> New domain: $domain"
echo "Status: PROVISIONING (will be ACTIVE in 5-15 minutes)"
echo
echo "Next step: create a manual Ingress for this domain"
echo "  ./02-create-ingress.sh $SERVICE_ID $ENV_ID $domain"
