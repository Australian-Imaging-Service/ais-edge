# Vector

## Overview

[Vector](https://vector.dev/) is a high-performance, single-binary
observability data router written in Rust. It collects logs, transforms them with
the Vector Remap Language (VRL), and forwards to one or more sinks. In this stack
it is the **log shipper**: it tails kubelet pod-log files and pushes them to Loki.

## Role in this stack

A single **DaemonSet** in the `observability` namespace (one pod on the single
node). It tails every pod's stdout — Orthanc, `xnat-ingest sort`, the upload pod,
and the kube-system / observability components — and pushes the lines to the
in-cluster Loki Service.

Before pushing, it shapes the data:
- Add a `cluster` label
- If the line is JSON, parse it and merge keys into the event so Loki indexes them
  as labels (extracts `event`, `session`, `component`, `level`, …)
- Push to `http://loki.observability.svc.cluster.local:3100` — an **in-cluster
  push, with no 443 / SNI / TLS hop** (there is no ingress in tier-1)

## What Vector has access to

- **hostPath read-only** mount of `/var/log/pods` and `/var/log/containers`
- **Cluster API** via its ServiceAccount (read-only on namespaces, pods, nodes —
  needed by the `kubernetes_logs` source for metadata enrichment)
- **NO hostNetwork**, **NO write access** anywhere on the host
- **Outbound only** — talks to the in-cluster Loki Service. No bearer token, no
  CA bundle, no external endpoint.

## Where it runs

| Namespace | Workload | Image |
|---|---|---|
| `observability` | DaemonSet `vector-mgmt-vector` (helm chart) | `timberio/vector` |

## Configuration

| File | Purpose |
|---|---|
| `manifests/01-management/observability/vector-mgmt-values.yaml.tpl` | helm values + custom Vector config (sources, VRL transform, Loki sink) |
| `scripts/02d-install-observability.sh` | helm-installs Vector |

## Operations

```bash
# Pod state
kubectl -n observability get pods -l app.kubernetes.io/name=vector

# Tail Vector's own logs (look for sink errors, batch sizes)
kubectl -n observability logs -l app.kubernetes.io/name=vector -f

# Force-refresh config (helm-managed)
helm upgrade vector-mgmt vector/vector -n observability \
  -f /tmp/<rendered-values>.yaml
```

## Benefits

- **Single binary** — replaces Promtail + Fluent Bit + Grafana Agent
- **Native JSON parsing** — no grok/regex configs to maintain
- **VRL is type-safe** — type errors caught at config load, not runtime
- **Backpressure-aware** — buffers handle short Loki outages
- **Apache 2.0** — no vendor lock-in

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| `/var/log/pods` rotated mid-read | Skipped lines | `auto_partial_merge: true` + Vector's checkpointer; negligible at our log volumes |
| Loki unreachable | Vector buffers, then eventually drops oldest events | Loki is in-cluster on the same node; outages are brief |
| hostPath read-only escape | Theoretical; Vector runs as non-root in a read-only rootfs | We drop ALL capabilities + seccomp RuntimeDefault |
| Label cardinality explosion | Loki index size blows up | Vector explicitly does NOT label `session` (high cardinality); only structured event-type labels |
| K8s API rate-limited | Pod metadata enrichment slows | `kubernetes_logs` source is well-mannered; default cache size is fine at our scale |

## Replacements / future

- **Promtail** — Grafana's purpose-built Loki shipper. Functional subset of
  Vector; we picked Vector for the ergonomic VRL and JSON handling.
- **Fluent Bit** — older, more popular, but the config language is awkward.
- **Grafana Agent / Grafana Alloy** — broader scope (logs + metrics + traces);
  worth revisiting if we later add tracing.
- **OpenTelemetry Collector** — vendor-neutral standard; worth migrating to if the
  OTel ecosystem matures faster than Vector's.

## Future enhancements

- VRL transforms to redact PHI / PII fields if any leak into log lines (we avoid
  logging DICOM payload data, but defence-in-depth).
- A second Vector sink to a long-term archive for compliance retention beyond
  Loki's retention window.
- Unit tests for the VRL transforms (`vector test`).
