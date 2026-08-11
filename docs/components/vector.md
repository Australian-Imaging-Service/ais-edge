# Vector

## Overview

[Vector](https://vector.dev/) is a high-performance, single-binary
observability data router written in Rust. It collects logs, metrics,
and traces from multiple sources, transforms them with the Vector Remap
Language (VRL), and forwards to one or more sinks. In this stack it is
used for exactly one of those jobs: it is the **log shipper** (kubelet
log files → Loki), on both the management cluster and every edge.

It is **not** a metrics exporter here. Vector once ran a `log_to_metric`
transform and a `prometheus_exporter` sink publishing
`ais_pipeline_events_total` on `:9598`; both were deleted when
log-derived alerting moved to **Loki's own ruler**, which evaluates LogQL
against the same JSON events and needs no second metrics pipeline, no
per-edge scrape ingress and no Prometheus on the edges. The reasoning is
in [`alerting-architecture.md`](../alerting-architecture.md); the removal
list is in its "What we removed" section.

## Role in this stack

Two deployments, both DaemonSets:

1. **Mgmt-side** (`ais-mgmt` — the management release's own namespace, since
   Vector is a subchart of `charts/mgmt`; single replica on the mgmt node).
   Tails system + workload pod logs for the management cluster itself
   (cert-manager, ingress-nginx, k0smotron, seaweedfs, xnat-upload).
2. **Edge-side** (`xnat-ingest` on each child cluster — `.Values.namespace`,
   the same namespace as the pipeline it tails; one pod per worker). Tails
   xnat-ingest group-orthanc + assign + s3-uploader + system pods, pushes
   to Loki via the management nginx-ingress on `https://loki.aisedge.local:443`.

Both shape the data identically before it hits Loki, with exactly two
transforms — there is no third stage:
- `add_cluster_label` — set `.cluster` (`mgmt`, or `${CLUSTER_LABEL}` on an
  edge, which the chart passes as an env var)
- `parse_json_messages` — if the line is JSON, parse it and merge keys into
  the event so Loki indexes them as labels (`event`, `session`,
  `component`, …). This is what lets the Loki ruler write
  `| json | event="upload_failed"` instead of regexing raw text
- Push to Loki — one `loki` sink, and nothing else. No metrics sink: see the
  Overview for why that path was removed rather than merely disabled

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
- **Client certificate Secret** `loki-push-client-tls`, mounted at
  `/etc/ssl/loki-client/` and used as `tls.crt_file` / `tls.key_file` on the
  Loki sink. cert-manager issues it per edge (`CN=<edge name>`) from
  ais-edge-ca and cert-sync delivers it; there is no shared credential. It
  replaced a bearer token, then a Basic password, neither of which the push
  Ingress ever accepted — see docs/hardening-decisions.md §1.
- **hostAliases** → MGMT_NODE_IP for the management names an edge pod
  actually dials, so Vector can resolve `loki.aisedge.local` without an
  external DNS. The list is **two** names, built by `edge.hostAliases` in
  `charts/edge/templates/_helpers.tpl`: the SeaweedFS host, plus the Loki
  host when `observability.enabled`. Grafana is deliberately excluded —
  nothing on the edge connects to it, and a hostAlias for a host you never
  contact is a claim you cannot verify. The k0s API and konnectivity names
  are per-edge and are handled by the worker join, not by this chart. The
  entry that matters most is the one hardest to diagnose: with no hostAlias
  the pod gets NXDOMAIN, the uploader reads it as an endpoint failure and
  keeps the local copy, which looks like nothing at all from the management
  side while the edge quietly fills its disk

## Where it runs

Both names are release-derived, so they follow the release name rather than a
literal. With the release names `install.sh` uses (`mgmt` and `edge`):

| Side | Namespace | Workload | Image |
|---|---|---|---|
| Mgmt | `ais-mgmt` | DaemonSet `mgmt-vector` (pinned subchart `charts/mgmt/charts/vector-0.57.0.tgz`) | `timberio/vector` |
| Edge | `xnat-ingest` | DaemonSet `edge-vector`, pod label `app: vector` (hand-rolled in `charts/edge/templates/vector.yaml`) | `timberio/vector:0.49.0-distroless-libc` |

`observability` and `logging` were the **old shell installer's** namespaces and
appear nowhere in a current install. `logging` survives only as a stale default
in `charts/mgmt/values.yaml`'s cert-sync destinations; the real site files
(`sites/example-mgmt/values.yaml`) target `xnat-ingest`, which is where the edge
Vector expects to find its CA bundle and client certificate. Chase the wrong
namespace and every `kubectl` below returns "No resources found", which reads
identically to a broken deployment.

Why hand-rolled on edges: tighter control over `hostAliases`, security
context, and the client-certificate wiring than the helm chart supports
cleanly. It also sidesteps a templating trap the mgmt side has to work
around — the Vector chart runs `tpl` over `customConfig`, so mgmt's Vector
event templates need backtick escaping, whereas the edge config is loaded with
`.Files.Get` and Helm never touches it.

## Configuration

| File | Purpose |
|---|---|
| `charts/mgmt/values.yaml` (`vector:`) | mgmt-side subchart values + `customConfig`, the whole Vector config inline. Also `service: {enabled: false}` / `serviceMonitor: {enabled: false}` — mgmt Vector only pushes out and exposes nothing in-cluster |
| `charts/edge/templates/vector.yaml` | edge-side ServiceAccount, ClusterRole, ClusterRoleBinding, ConfigMap, DaemonSet. **No Service**: nothing scrapes or dials Vector, so there is nothing to expose |
| `charts/edge/files/vector.yaml` | the edge Vector config itself, mounted verbatim via `.Files.Get`. Site-specific values arrive as env vars (`${LOKI_ENDPOINT}`, `${CLUSTER_LABEL}`) precisely so this file never has to be templated |
| `install.sh` | installs the mgmt chart (Vector subchart) and the edge chart (first-party Vector) |
| cert-sync (CronJob) | pushes the CA bundle and this edge's Loki client cert into the edge cluster |

## Operations

```bash
# Mgmt-side state
kubectl -n ais-mgmt get pods -l app.kubernetes.io/name=vector

# Edge-side state — the edge DaemonSet labels its pods `app: vector`,
# NOT app.kubernetes.io/name; the chart's own labels sit alongside it.
KUBECONFIG=kubeconfig-edge-dev kubectl -n xnat-ingest get pods -l app=vector

# Tail Vector's own logs (look for sink errors, batch sizes)
KUBECONFIG=kubeconfig-edge-dev kubectl -n xnat-ingest logs -l app=vector -f

# Verify the config that actually landed. There is no :9598 to curl — Vector
# exports no metrics here (see Overview). What CAN silently break is the
# per-event label templates on the mgmt side, which Helm would resolve away:
kubectl -n ais-mgmt get cm mgmt-vector -o yaml | grep 'cluster:'
#   must print the LITERAL `{{ cluster }}`. An empty value means every log
#   line is arriving at Loki with no stream labels, which breaks every alert
#   rule and dashboard panel that selects on them — with no error anywhere.

# Force-refresh config. Vector is a PINNED SUBCHART of charts/mgmt, not a
# separate release from an upstream repo, so it is upgraded with its parent:
helm upgrade mgmt charts/mgmt -n ais-mgmt -f sites/<site>/values.yaml
```

## Benefits

- **Single binary** — replaces Promtail + Fluent Bit + Grafana Agent
- **Native JSON parsing** — no grok/regex configs to maintain
- **VRL is type-safe** — type errors caught at config load, not runtime
- **Built-in `log_to_metric`** — Vector *can* derive Prometheus metrics from
  log lines without native instrumentation. We evaluated it and do not use
  it: the Loki ruler counts the same JSON events with `count_over_time`
  directly, so the metric would have been a second representation of data we
  already store, reachable only by standing up a scrape path from mgmt into
  each edge that konnectivity does not provide. Kept in this list as a
  capability worth knowing about, not as something running
- **Backpressure-aware** — disk-backed buffers handle Loki outages
- **Apache 2.0** — no vendor lock-in

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| `/var/log/pods` rotated mid-read | Skipped lines | `auto_partial_merge: true` + Vector's checkpointer; in practice negligible at our log volumes |
| Loki unreachable | Vector buffers in memory then disk; will eventually drop oldest events | Vector exposes a `vector_buffer_byte_size` gauge; Alertmanager fires VectorBufferGrowing if it climbs |
| Push credential leaked | Attacker could push fake logs as that edge | There is no bearer token and no shared password — the edge sink has **no `auth:` block at all** and authenticates with an mTLS client certificate (`loki-push-client-tls`, `CN=<edge name>`), so a leak is scoped to one site. cert-manager issues it per edge with `rotationPolicy: Always` on a 90-day cert and the cert-sync CronJob delivers it, so rotation is automatic; to force one, delete the Certificate's Secret on mgmt and let cert-sync re-run. (The bearer and Basic paths this replaced never authenticated anything — the ends had drifted to different bytes and every push 401'd, silently, because the alerts that would have reported it are built from these very logs. See `docs/hardening-decisions.md` §1. The `02d`/`07b` scripts that used to do this by hand no longer exist; `install.sh` steps 4 and 7 replaced them.) |
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
