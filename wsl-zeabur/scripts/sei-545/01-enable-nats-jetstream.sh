#!/usr/bin/env bash
#
# scripts/sei-545/01-enable-nats-jetstream.sh
#
# Patches the local NATS ConfigMap to enable JetStream. This is required
# because zeabur-kube-watch publishes events to JetStream, and the bundled
# NATS in WSL k3s has JetStream disabled by default.
#
# This is part of the SEI-545 fix. Re-running is idempotent.
#
# Usage:
#   sudo ./01-enable-nats-jetstream.sh
#
# After running, you also need to mount /data in the nats-0 pod:
#   sudo ./02-mount-nats-data.sh
#
# And then restart the nats-0 pod to pick up the new config:
#   sudo kubectl delete pod nats-0 -n default

set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
NATS_CM="nats-config"
NATS_STS="nats"

echo "== [1/4] Patching nats-config ConfigMap to enable JetStream =="

cm_json="$(sudo kubectl -n "$NAMESPACE" get cm "$NATS_CM" -o json)"
if [ -z "$cm_json" ]; then
    echo "ERROR: $NATS_CM ConfigMap not found" >&2
    exit 1
fi

# Detect the config key (Zeabur uses 'nats.conf')
cm_key=""
for k in nats.conf config.conf; do
    if echo "$cm_json" | jq -e ".data.\"$k\"" >/dev/null 2>&1; then
        cm_key="$k"
        break
    fi
done
if [ -z "$cm_key" ]; then
    echo "ERROR: no nats.conf or config.conf key in $NATS_CM" >&2
    exit 1
fi

cm_data="$(echo "$cm_json" | jq -r ".data.\"$cm_key\"")"

if echo "$cm_data" | grep -q "store_dir"; then
    echo "JetStream already enabled in $NATS_CM/$cm_key"
else
    echo "Enabling JetStream in $NATS_CM/$cm_key..."
    patched="$cm_data

jetstream {
  store_dir: \"/data/jetstream\"
  max_memory_store: 256MB
  max_file_store: 1GB
}"
    sudo kubectl -n "$NAMESPACE" patch cm "$NATS_CM" --type merge \
        -p "{\"data\":{\"$cm_key\":$(echo "$patched" | jq -Rs .)}}"
    echo "  done"
fi

echo
echo "== [2/4] Creating PVC nats-data-nats-0 (1Gi, local-path) =="

if sudo kubectl -n "$NAMESPACE" get pvc nats-data-nats-0 >/dev/null 2>&1; then
    echo "PVC nats-data-nats-0 already exists"
else
    sudo kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nats-data-nats-0
  namespace: $NAMESPACE
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: local-path
EOF
fi

echo
echo "== [3/4] Patching nats StatefulSet to mount nats-data at /data =="

sts_json="$(sudo kubectl -n "$NAMESPACE" get sts "$NATS_STS" -o json)"
if echo "$sts_json" | grep -q '"name": "nats-data"'; then
    echo "volume mount nats-data already present"
else
    sudo kubectl -n "$NAMESPACE" patch sts "$NATS_STS" --type json -p "$(cat <<'EOF'
[
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"nats-data","mountPath":"/data"}},
  {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"nats-data","persistentVolumeClaim":{"claimName":"nats-data-nats-0"}}}
]
EOF
)"
    echo "  done"
fi

echo
echo "== [4/4] Restarting nats-0 pod to pick up new config =="

sudo kubectl -n "$NAMESPACE" delete pod nats-0 --grace-period=30

echo
echo "==> JetStream enabled. Verify with:"
echo "    sudo kubectl -n $NAMESPACE exec nats-0 -- wget -qO- http://localhost:8222/jsz | jq .config"
echo
echo "Next: run 03-create-jetstream-stream.sh to create the KUBEWATCH stream"
