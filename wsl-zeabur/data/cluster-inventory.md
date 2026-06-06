# WSL k3s Cluster Inventory

> Generated: 2026-06-07
> Source: `kubectl get pods -A -o wide`

## Nodes

| Name | Status | Roles | Age | Version |
|------|--------|-------|-----|---------|
| 100.64.3.1 | Ready | control-plane | 12h | v1.35.5+k3s1 |

Single-node cluster. Control plane and workloads share the node.

## Pods by Namespace

### default (Zeabur-managed + system)

| Pod | Ready | Status | Restarts | Age | IP | Node |
|-----|-------|--------|----------|-----|----|------|
| cadvisor-swl65 | 1/1 | Running | 28 | 12h | 10.42.0.37 | 100.64.3.1 |
| fluent-bit-87fch | 1/1 | Running | 37 | 12h | host (172.29.155.146) | 100.64.3.1 |
| ingress-controller-sn5f6 | 1/1 | Running | 0 | 63m | host (172.29.155.146) | 100.64.3.1 |
| nats-0 | 2/2 | Running | 0 | 6m | host (172.29.155.146) | 100.64.3.1 |
| node-exporter-cxgw6 | 1/1 | Running | 29 | 12h | 10.42.0.39 | 100.64.3.1 |
| vector-aggregator-d5c7cc7d7-wd5tq | 1/1 | Running | 31 | 12h | 10.42.0.31 | 100.64.3.1 |
| zeabur-dns-74f856bb8c-rkwq2 | 1/1 | Running | 0 | 6m | 10.42.0.91 | 100.64.3.1 |
| zeabur-kube-watch-777bd9d455-92tfs | 1/1 | Running | 1 | 6m | 10.42.0.89 | 100.64.3.1 |
| zeabur-log-api-75b9ddf9c7-pnh5w | 1/1 | Running | 0 | 6m | 10.42.0.90 | 100.64.3.1 |

**Note:** `cadvisor` and `node-exporter` have ~28-37 restarts. This is the
k3s cgroup-driver issue (SEI-kubelet-cgroup). Workaround: cgroup
isolation is in `kubelet` config. Tracked separately.

### environment-6a242c9f95b39806d284aaa7 (Stalwart)

| Pod | Ready | Status | Restarts | Age | IP | Node |
|-----|-------|--------|----------|-----|----|------|
| service-6a242f96f1be9943f1f972a7-84d48c4859-dfjvc | 1/1 | Running | 0 | 91m | 10.42.0.55 | 100.64.3.1 |

Stalwart Mail Server v0.11.8. Image: `stalwartlabs/mail-server:v0.11.8`.
HTTP listener on :8080 (NodePort 32247).

### kube-system (k3s-managed)

| Pod | Ready | Status | Restarts | Age | IP |
|-----|-------|--------|----------|-----|----|
| coredns-5845bf65f7-478x6 | 1/1 | Running | 0 | 70m | 10.42.0.59 |
| crictl-image-prune-8vfkv | 1/1 | Running | 29 | 12h | host |
| local-path-provisioner-5d9d9885bc-dgjfb | 1/1 | Running | 25 | 12h | 10.42.0.41 |
| metrics-server-d7f949777-qnqw5 | 1/1 | Running | 25 | 12h | 10.42.0.44 |

## Services

| Service | Namespace | Type | ClusterIP | Ports |
|---------|-----------|------|-----------|-------|
| kubernetes | default | ClusterIP | 10.43.0.1 | 443/TCP |
| cadvisor | default | ClusterIP | 10.43.129.169 | 9090/TCP |
| fluent-bit | default | ClusterIP | 10.43.211.100 | 2020/TCP |
| nats | default | ClusterIP | 10.43.10.121 | 4222/TCP |
| node-exporter | default | ClusterIP | 10.43.82.122 | 9100/TCP |
| vector-aggregator | default | ClusterIP | 10.43.109.211 | 9000,8081,9090/TCP |
| zeabur-dns | default | ClusterIP | 10.43.0.20 | 53/UDP,53/TCP |
| zeabur-log-api | default | ClusterIP | 10.43.254.150 | 8080/TCP |
| service-6a242f96f1be9943f1f972a7 | environment-... | NodePort | 10.43.6.160 | 8080:32247/TCP |
| kube-dns | kube-system | ClusterIP | 10.43.0.10 | 53/UDP,53/TCP,9153/TCP |
| metrics-server | kube-system | ClusterIP | 10.43.63.150 | 443/TCP |

## Ingresses

| Name | Namespace | Host | Target |
|------|-----------|------|--------|
| cadvisor | default | cadvisor.6a23cdf424701a8493345c17.servers.onzeabur.com | cadvisor:9090 |
| node-exporter | default | node-exporter.6a23cdf424701a8493345c17.servers.onzeabur.com | node-exporter:9100 |
| zeabur-log-api | default | logs.6a23cdf424701a8493345c17.servers.onzeabur.com | zeabur-log-api:8080 |
| yjhkbkjb-zeabur-app | environment-... | yjhkbkjb.zeabur.app | service-...:8080 (manual) |

## PVCs

| PVC | Namespace | Status | Volume | Capacity | StorageClass |
|-----|-----------|--------|--------|----------|--------------|
| nats-data-nats-0 | default | Bound | pvc-d57d2028-... | 1Gi | local-path |

## TLS Secrets (managed by ingress-controller)

| Secret | Namespace | Type |
|--------|-----------|------|
| yjhkbkjb.zeabur.app | default | Opaque (cert + key) |
| cadvisor.6a23cdf...onzeabur.com | default | kubernetes.io/tls |
| logs.6a23cdf...onzeabur.com | default | kubernetes.io/tls |
| node-exporter.6a23cdf...onzeabur.com | default | kubernetes.io/tls |
| certmagic-acme-account | default | Opaque (ACME account key) |
| certmagic-misc | default | Opaque (certmagic state) |
| zeabur-api-token | default | Opaque (used by ingress-controller) |

## ConfigMaps

| ConfigMap | Namespace | Purpose |
|-----------|-----------|---------|
| coredns | kube-system | k3s-managed CoreDNS config (with our forward fix) |
| cluster-dns | kube-system | (unused legacy) |
| nats-config | default | NATS server config (with JetStream enabled) |
| zeabur-dns | default | Zeabur DNS sidecar config |
| fluent-bit | default | Fluent Bit log forwarder config |
| vector-aggregator | default | Vector log aggregator config |

## To regenerate this file

```bash
wsl -d wsl_test_server_001 -- bash -c "
  echo '## Pods'
  sudo /usr/local/bin/kubectl get pods -A -o wide
  echo '## Services'
  sudo /usr/local/bin/kubectl get svc -A
  echo '## Ingresses'
  sudo /usr/local/bin/kubectl get ingress -A
  echo '## PVCs'
  sudo /usr/local/bin/kubectl get pvc -A
  echo '## Secrets'
  sudo /usr/local/bin/kubectl get secret -A
  echo '## ConfigMaps'
  sudo /usr/local/bin/kubectl get cm -A
"
```
