# Vector

The pipeline tool is accessionflow (called xnat-ingest before 0.18.0).

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
   accessionflow collate-orthanc + assign + s3-uploader + system pods, pushes
   to Loki via the management nginx-ingress on `https://loki.aisedge.local:443`.

Both shape the data identically before it hits Loki, with exactly two
transforms — there is no third stage:
- `add_cluster_label` — set `.cluster` (`mgmt`, or `${CLUSTER_LABEL}` on an
  edge, which the chart passes as an env var)
- `parse_json_messages` — if the line is JSON, parse it and merge keys into
  event as JSON fields. Only the eight explicitly configured sink fields become
  stream labels; `event` and `session` stay in the body. This lets the Loki ruler write
  `| json | event="upload_failed"` instead of regexing raw text
- Push to Loki — one `loki` sink, and nothing else. No metrics sink: see the
  Overview for why that path was removed rather than merely disabled

## What Vector has access to

The configured `cluster` value is a routing/query label, not proof of site
identity. The JSON merge can replace event fields, and Loki does not bind a
client certificate CN to the submitted stream label. Treat untrusted log text
and shared-tenant queries accordingly.

### Mgmt-side
- **hostPath read-only** mounts include `/var/log/pods`, `/var/log/containers`,
  `/var/log/`, `/var/lib/`, and host proc/sys paths in the rendered subchart.
- **hostPath read-write** `/var/lib/vector` supplies persistent file checkpoints.
  These checkpoints are source positions, not a durable queue of log events.
- **Cluster API** via its ServiceAccount (read-only on namespaces, pods,
  nodes — needed by `kubernetes_logs` source for metadata enrichment)
- **No hostNetwork** in this configuration. The checkpoint host path is writable.
- **Configured destinations**: the Kubernetes API and in-cluster Loki Service.
  No chart NetworkPolicy restricts the pod to those destinations.

### Edge-side
- Read-only host log mounts plus writable `/var/lib/vector` for checkpoints
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
| Mgmt | `ais-mgmt` | DaemonSet `mgmt-vector` (pinned subchart `charts/mgmt/charts/vector-0.57.0.tgz`) | `timberio/vector:0.57.0-distroless-libc` |
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
#   line may lose its expected stream label. A missing VRL field can instead
#   cause template_failed and a dropped event. Check Vector errors as well as
#   the rendered literal; escaping mistakes may also fail Helm rendering.

# Force-refresh config. Vector is a PINNED SUBCHART of charts/mgmt, not a
# separate release from an upstream repo, so it is upgraded with its parent:
helm upgrade mgmt charts/mgmt -n ais-mgmt -f sites/<site>/values.yaml
```

## Benefits

- **Single binary**: one collector handles this log path. Promtail and
  Grafana Agent are historical alternatives, not supported current choices.
- **Native JSON parsing**: structured lines can be queried as fields. Plain
  accessionflow messages still need the LogQL patterns in the ruler and dashboards.
- **VRL checks types at configuration load**. Fallible parsing still needs
  runtime handling; malformed or non-JSON lines follow the configured fallback.
- **Built-in `log_to_metric`** — Vector *can* derive Prometheus metrics from
  log lines without native instrumentation. We evaluated it and do not use
  it: the Loki ruler counts the same JSON events with `count_over_time`
  directly, so the metric would have been a second representation of data we
  already store, reachable only by standing up a scrape path from mgmt into
  each edge that konnectivity does not provide. Kept in this list as a
  capability worth knowing about, not as something running
- **Backpressure-aware**: the sink uses its default memory buffer here.
  Persistent checkpoints help restart the source; no disk event buffer is enabled.
- **Mozilla Public License 2.0**: the pinned Vector source uses MPL-2.0.
  Review that license and image dependencies for the site distribution policy.

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| `/var/log/pods` rotated mid-read | Skipped lines | `auto_partial_merge: true` + Vector's checkpointer; loss rate not verified (2026-11-10); partial-line merging does not prevent rotation loss |
| Loki unreachable | The default memory buffer fills and applies backpressure; a long outage can outlast kubelet log retention | No disk sink buffer, internal metrics source or VectorBufferGrowing alert is configured. Inspect Vector errors and Loki ingestion, and test the outage budget with the site log rotation settings. |
| Push credential leaked | An allowed client certificate permits access to the shared Loki tenant, including forged cluster labels and queries | The sink uses mTLS without a bearer or basic credential. The ingress checks CN admission, not per-edge label authorization. Renewing or deleting a Secret does not revoke the leaked certificate. Isolate its CN and assess the trust chain; normal 90-day certificates renew 30 days before expiry, with cert-sync delivering replacements. The earlier bearer/basic failures are historical, date not recorded, and fixed by the present mTLS wiring. |

| Host filesystem exposure | The pod reads host logs and writes source checkpoints; the chart does not enforce a non-root user or read-only root filesystem | Capabilities are dropped, privilege escalation is disabled and seccomp is RuntimeDefault. Review the actual image user and mounts; these controls do not eliminate hostPath risk. |
| Label cardinality explosion | Loki stream and index counts grow | Eight stream labels are configured. Session and event remain JSON fields; Vector does not export Prometheus series in this deployment. Bound the values of cluster, pod, app, component and level as well. |
| K8s API rate-limited | Pod metadata enrichment slows | Inspect source errors and API throttling; capacity at the site workload is not verified (2026-11-10) |

## Replacements / future

- **Promtail (historical)**: reached end of life on 2026-03-02. Do not start
  a new deployment with it; see the [official lifecycle notice](https://grafana.com/docs/loki/latest/send-data/promtail/).
- **Fluent Bit**: a possible collector replacement. Recheck its current plugins,
  transforms and operational requirements before planning a migration.
- **Grafana Alloy**: the current Grafana collector to evaluate for a combined
  logs, metrics and traces path. Grafana Agent reached end of life on 2025-11-01;
  see the [official Agent notice](https://grafana.com/docs/agent/latest/).
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

### Short-lived pods

The Kubernetes log source uses a one-second minimum interval between file
discovery scans. Scheduling and workload can make scans later. The pinned
Vector 0.49 source defaults to 60 seconds, which can miss a pod whose log file
is created and removed between scans. The shorter interval gives a pod that
runs for 5-10 seconds several discovery opportunities. This is best-effort
collection: unavailable pod metadata, node failures or files removed before
discovery can still lose logs.

The setting is `glob_minimum_cooldown_ms: 1000`. It increases local filesystem
scans and checkpoint work; it does not request an API relist every second.
Check Vector CPU and disk activity on nodes with many pod logs before raising
the workload. See the [pinned source configuration](https://github.com/vectordotdev/vector/blob/v0.49.0/src/sources/kubernetes_logs/mod.rs)
and [Kubernetes log source documentation](https://vector.dev/docs/reference/configuration/sources/kubernetes_logs/#glob_minimum_cooldown_ms).
