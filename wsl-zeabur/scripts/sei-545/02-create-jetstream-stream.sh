#!/usr/bin/env bash
#
# scripts/sei-545/02-create-jetstream-stream.sh
#
# Creates the JetStream stream KUBEWATCH and the durable consumer
# zeabur-control-plane. This is required for zeabur-kube-watch to publish
# events to NATS, and for the Zeabur control plane to consume them.
#
# Subjects: events.>, kube.>, pods.>, events
# Retention: limits (keep all messages until limits reached)
# Storage: file (on local-path PVC nats-data-nats-0)
#
# Usage:
#   sudo ./02-create-jetstream-stream.sh
#
# Requires the nats CLI on the WSL host. Install with:
#   sudo /opt/zeabur-fixes/install-nats-cli.sh

set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
NATS_CLUSTER_IP="10.43.10.121"
NATS_PORT="4222"
NATS_URL="nats://${NATS_CLUSTER_IP}:${NATS_PORT}"
STREAM_NAME="KUBEWATCH"
CONSUMER_NAME="zeabur-control-plane"

if ! command -v nats >/dev/null 2>&1; then
    echo "ERROR: nats CLI not installed. Run: sudo /opt/zeabur-fixes/install-nats-cli.sh" >&2
    exit 1
fi

# Quick reachability check
if ! nats stream ls -s "$NATS_URL" >/dev/null 2>&1; then
    echo "WARN: cannot reach NATS at $NATS_URL, falling back to port-forward"
    sudo kubectl -n "$NAMESPACE" port-forward nats-0 30222:4222 >/dev/null 2>&1 &
    pf_pid=$!
    sleep 3
    if ! nats stream ls -s nats://127.0.0.1:30222 >/dev/null 2>&1; then
        kill "$pf_pid" 2>/dev/null || true
        echo "ERROR: cannot reach NATS" >&2
        exit 1
    fi
    NATS_URL="nats://127.0.0.1:30222"
fi

echo "Using NATS URL: $NATS_URL"

# Create the stream
if nats stream ls -s "$NATS_URL" | grep -q "$STREAM_NAME"; then
    echo "Stream $STREAM_NAME already exists"
else
    echo "Creating stream $STREAM_NAME..."
    nats stream add "$STREAM_NAME" \
        --subjects="events.>,kube.>,pods.>,events" \
        --retention=limits --storage=file --replicas=1 \
        --max-msgs=-1 --max-bytes=-1 --max-age=-1 \
        --server="$NATS_URL"
fi

# Create the consumer
if nats consumer ls "$STREAM_NAME" -s "$NATS_URL" | grep -q "$CONSUMER_NAME"; then
    echo "Consumer $CONSUMER_NAME already exists"
else
    echo "Creating consumer $CONSUMER_NAME..."
    nats consumer add "$STREAM_NAME" "$CONSUMER_NAME" \
        --durable --filter="events.>" --ack=explicit \
        --server="$NATS_URL"
fi

echo
echo "==> Stream and consumer created. Verify with:"
echo "    nats stream info $STREAM_NAME -s $NATS_URL"
echo "    nats consumer info $STREAM_NAME $CONSUMER_NAME -s $NATS_URL"
