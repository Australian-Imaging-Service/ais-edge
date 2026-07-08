# Vector

## Overview

[Vector](https://vector.dev/) is a high-performance, single-binary
observability data router written in Rust. It collects logs, metrics,
and traces from multiple sources, transforms them with the Vector Remap
Language (VRL), and forwards to one or more sinks. In this stack it
acts as both a **log shipper** (kubelet log files → Loki) and a
**log-to-metric exporter** (counts pipeline events into Prometheus
counters).

## Role in this stack

Two deployments, both DaemonSets:

1. **Mgmt-side** (`observability` namespace, single replica on the mgmt
   node). Tails system + workload pod logs for the management cluster
   itself (cert-manager, ingress-nginx, k0smotron, seaweedfs, xnat-upload).
2. **Edge-side** (`logging` namespace on each child cluster, one pod per
   worker). Tails xnat-ingest group-orthanc + assign + s3-uploader + system pods, pushes
   to Loki via the management nginx-ingress on `https://loki.aisedge.local:443`.

Both shape the data identically before it hits Loki:
- Add a `cluster` label (`mgmt` or the edge name)
- If the line is JSON, parse it and merge keys into the event so Loki
  indexes them as labels (extracts `event`, `session`, `component`, …)
- Run a `log_to_metric` transform that counts events by
  `event/cluster/component`, exposing `ais_pipeline_events_total` on
  Vector's own `:9598/metrics`
- Push to Loki

## What Vector has access to

### Mgmt-side
- **hostPath read-only** mount of `/var/log/pods` and `/var/log/containers`
- **Cluster API** via its ServiceAccount (read-only on namespaces, pods,
  nodes — needed by `kubernetes_logs` source for metadata enrichment)
- **NO hostNetwork**, **NO write access** anywhere on the host
- **Outbound** only — talks to in-cluster Loki Service

### Edge-side
- Same hostPath read-only mount
- ClusterRole `vector` (get/list/watch on namespaces, pods, nodes)
- **CA bundle Secret** mounted at `/etc/ssl/ais-edge-ca/ca.crt` to verify
  the Loki server cert (signed by ais-edge-ca)
- **Bearer-token Secret** `loki-push-credentials` (each edge has its
  own token, generated at install by 02d)
- **hostAliases** for the five `aisedge.local` names → MGMT_NODE_IP,
  so Vector can resolve `loki.aisedge.local` without an external DNS

## Where it runs

| Side | Namespace | Workload | Image |
|---|---|---|---|
| Mgmt | `observability` | DaemonSet `vector-mgmt-vector` (helm chart) | `timberio/vector` |
| Edge | `logging` | DaemonSet `vector` (hand-rolled manifest) | `timberio/vector:0.49.0-distroless-libc` |

Why hand-rolled on edges: tighter control over `hostAliases`, security
context, and the bearer-auth wiring than the helm chart supports cleanly.

## Configuration

| File | Purpose |
|---|---|
| `manifests/01-management/observability/vector-mgmt-values.yaml.tpl` | mgmt-side helm values + custom Vector config |
| `manifests/02-edge/vector.yaml.tpl` | edge-side full DaemonSet manifest including ServiceAccount + ClusterRole + ConfigMap + Service |
| `scripts/02d-install-observability.sh` | helm-installs mgmt-side Vector |
| `scripts/07b-deploy-edge-observability.sh` | applies edge-side manifest, pushes auth + CA Secrets |

## Operations

```bash
# Mgmt-side state
kubectl -n observability get pods -l app.kubernetes.io/name=vector

# Edge-side state
KUBECONFIG=kubeconfig-edge-dev kubectl -n logging get pods -l app.kubernetes.io/name=vector

# Tail Vector's own logs (look for sink errors, batch sizes)
KUBECONFIG=kubeconfig-edge-dev kubectl -n logging logs -l app.kubernetes.io/name=vector -f

# Inspect Vector's exported metrics
KUBECONFIG=kubeconfig-edge-dev kubectl -n logging port-forward svc/vector 9598:9598 &
curl -s localhost:9598/metrics | grep ais_pipeline_events_total

# Force-refresh config (helm-managed mgmt side)
helm upgrade vector-mgmt vector/vector -n observability \
  -f /tmp/<rendered-values>.yaml
```

## Benefits

- **Single binary** — replaces Promtail + Fluent Bit + Grafana Agent
- **Native JSON parsing** — no grok/regex configs to maintain
- **VRL is type-safe** — type errors caught at config load, not runtime
- **Built-in `log_to_metric`** — derive Prometheus metrics from log
  lines without needing native instrumentation in the application code.
  This is how we get `ais_pipeline_events_total` without modifying
  xnat-ingest beyond the JsonFormatter
- **Backpressure-aware** — disk-backed buffers handle Loki outages
- **Apache 2.0** — no vendor lock-in

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| `/var/log/pods` rotated mid-read | Skipped lines | `auto_partial_merge: true` + Vector's checkpointer; in practice negligible at our log volumes |
| Loki unreachable | Vector buffers in memory then disk; will eventually drop oldest events | Vector exposes a `vector_buffer_byte_size` gauge; Alertmanager fires VectorBufferGrowing if it climbs |
| Bearer token leaked | Attacker could push fake logs | Tokens are per-edge; rotate by deleting Secret + re-running 02d/07b |
| hostPath read-only escape | Theoretical; Vector pod runs as non-root in read-only rootfs | We drop ALL capabilities + seccomp RuntimeDefault |
| Label cardinality explosion | Loki index size + Prometheus series count blow up | Vector explicitly does NOT label `session` (high cardinality); only structured event-type labels |
| K8s API rate-limited | Pod metadata enrichment slows | `kubernetes_logs` source is well-mannered; default cache size is fine for our scale |

## Replacements / future

- **Promtail** — Grafana's purpose-built Loki shipper. Functional subset
  of Vector. We picked Vector for the unified logs+metrics story
- **Fluent Bit** — older, more popular, but no native log_to_metric and
  config language is awkward (TOML-like). Vector's VRL is more ergonomic
- **Grafana Agent** — successor to Promtail with broader scope (logs +
  metrics + traces). Heavier than Vector, similar feature set. If we
  later add Tempo for tracing, we'd consider a unified Grafana Agent
- **OpenTelemetry Collector** — vendor-neutral standard. Worth migrating
  to if the OTel ecosystem matures faster than Vector's

## Future enhancements

- A Vector source that scrapes the SeaweedFS S3 access log and turns
  every PUT/GET into a structured event (currently we get this via the
  pod-stdout path, which is sufficient but indirect)
- VRL transforms to redact PHI / PII fields if any leak into log lines
  (we avoid logging DICOM payload data, but defence-in-depth)
- A second Vector sink to a long-term archive (e.g. Glacier) for
  compliance retention beyond Loki's 30-day window
- Unit tests for the VRL transforms (Vector has a `vector test` runner)
