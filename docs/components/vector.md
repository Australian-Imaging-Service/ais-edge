# Vector

## Overview

[Vector](https://vector.dev/) is a high-performance, single-binary
observability data router written in Rust. It collects logs, transforms them with
the Vector Remap Language (VRL), and forwards to one or more sinks. In this stack
it is the **log shipper**: it tails kubelet pod-log files and pushes them to Loki.

It is a **hand-written DaemonSet**
([`charts/edge/templates/vector.yaml`](../../charts/edge/templates/vector.yaml)),
deliberately not the upstream Vector subchart. The subchart runs its
`customConfig` through `tpl`, so Helm evaluates Vector's own `{{ }}` event
templates and renders every Loki stream label as an **empty string** — after
which every alert rule and dashboard panel that selects on a label matches
nothing, and nothing looks broken. The config here is loaded with `.Files.Get`
and mounted verbatim, so Helm never touches it.

## Two switches, not one

| Key | Means |
|---|---|
| `observability.enabled` | **Run Vector.** Gates the whole of `templates/vector.yaml`. |
| `observability.stack.enabled` | **Host the log/metric store on this node** — the pinned kube-prometheus-stack and Loki subcharts. Also chooses which Vector config file is mounted and where `LOKI_ENDPOINT` points. |

They are orthogonal on purpose: "ship logs somewhere" and "host a log store" are
different decisions. `enabled: true` with `stack.enabled: false` is a site that
pushes off the box to someone else's Loki; a tier-1 appliance sets both true.

## Role in this stack

A single **DaemonSet** in the `xnat-ingest` namespace (`.Values.namespace`; one
pod, because there is one node). It tails every pod's stdout — Orthanc,
`xnat-ingest group-orthanc`, `xnat-ingest assign`, the upload pod, the
data-policy reporter, plus kube-system and the observability subcharts that
install alongside them — and pushes the lines to the in-cluster Loki Service.

Before pushing, it shapes the data:

- Set `.cluster` from `${CLUSTER_LABEL}` (the site's `clusterLabel`). This is
  what Grafana's `cluster` variable filters on.
- If the line is JSON, parse it and merge the keys into the event, so `event`,
  `session` and `component` become first-class fields. That is what lets the
  Loki ruler write `| json | event="..."` instead of regexing raw text.
- Drop `kubernetes`, `file`, `source_type`, `stream` and `tags` from the encoded
  payload — that metadata is already promoted to stream labels, so repeating it
  inside the body only inflates storage and clutters the Grafana live tail.
- Promote eight **stream labels**: `cluster`, `namespace`, `pod`, `container`,
  `node`, `app`, `component`, `level`. These are load-bearing. `component` in
  particular is how the orthanc, group, assign, upload and data-policy streams
  are told apart, and it comes from the **pod label** of the same name, not from
  the `component` field inside the JSON line.
- Push to `${LOKI_ENDPOINT}` — on tier-1
  `http://ais-loki.<namespace>.svc.cluster.local:3100`, an **in-cluster push with
  no 443 / SNI / TLS hop**, no client certificate and no `auth:` block. There is
  no ingress on tier-1 and nothing leaves the node, so there is no transport to
  protect.

`ais-loki` is the Loki subchart's `fullnameOverride`, pinned in
`charts/edge/values.yaml` for exactly this reason: the config file is never
templated, so the Service name is written **literally** and cannot follow
`.Release.Name`. A release named anything else would leave Vector retrying an
address that never resolves — and logs that silently never arrive look exactly
like a quiet site.

One matching trap: `LOKI_ENDPOINT` is derived from `.Release.Namespace` while
the DaemonSet itself is placed in `.Values.namespace`. `install.sh` reads the
namespace out of the site file and passes it to `helm -n`, so the two agree. Do
it by hand into a different `-n` and Vector runs in one namespace pushing at a
Service in another.

## Two config files, one deliberate difference

| File | Mounted when | Difference |
|---|---|---|
| [`charts/edge/files/vector.yaml`](../../charts/edge/files/vector.yaml) | `observability.stack.enabled: false` — pushing to a remote Loki | has the sink `tls:` block (client cert at `/etc/ssl/loki-client`, CA at `/etc/ssl/ais-edge-ca`) |
| [`charts/edge/files/vector-local.yaml`](../../charts/edge/files/vector-local.yaml) | `observability.stack.enabled: true` — tier-1 | **exactly that `tls:` block removed**, nothing else |

Two files rather than one file with a conditional, because Helm must never
evaluate either — a `{{ if }}` inside them would require Helm to render the
file, which is what destroys the stream labels. Tier-1's Loki is in this cluster
over plain http, so leaving the `tls:` block in would point Vector at
`/etc/ssl/loki-client/tls.crt`, which does not exist here, and every push would
fail at the handshake.

**Keep the two in step.** Any change to one that is not about TLS belongs in the
other. Nothing diffs them automatically; `scripts/ci/runtime-templates.sh` only
proves that the rendered `<release>-vector` ConfigMap still contains
`{{ cluster }}`, `{{ kubernetes.pod_name }}` and `{{ level }}` — that Helm has
not eaten the templates — not that the two variants agree.

The DaemonSet carries a `checksum/config` annotation over whichever file is
mounted, so editing it and re-running the release rolls the pod.

## What Vector has access to

- **hostPath read-only** mounts of `/var/log/pods` and `/var/log/containers`
- **hostPath read-write** `/var/lib/vector` (`/vector-data-dir` in the
  container) for the source checkpoints. hostPath, not emptyDir: with an
  emptyDir, every roll of the DaemonSet wiped the file positions, Vector
  re-tailed each pod log from offset 0, and Loki ingested duplicate copies of
  old events — which showed up as inflated counts on the dashboards.
- **Cluster API** via its own ServiceAccount: `get`/`list`/`watch` on
  namespaces, pods and nodes, needed by the `kubernetes_logs` source for
  metadata enrichment. Nothing else in the chart talks to the API at all.
- **NO hostNetwork.** All capabilities dropped, `allowPrivilegeEscalation:
  false`, seccomp `RuntimeDefault`. `readOnlyRootFilesystem` is deliberately
  *not* set — the checkpointer needs a writable `/vector-data-dir`.
- **Listens on nothing.** `api: enabled: false`, so there is no admin endpoint
  to reach or to expose; diagnose from Vector's own logs.
- **Outbound only** — the in-cluster Loki Service. No bearer token, no basic
  auth, no external endpoint.
- `tolerations: [{operator: Exists}]` — logs are shipped from every node,
  including tainted ones. A node whose logs you cannot see is a node you cannot
  debug.

## Where it runs

| Namespace | Workload | Image |
|---|---|---|
| `xnat-ingest` (`.Values.namespace`) | DaemonSet `<release>-vector`, pod label `app=vector` | `timberio/vector:0.49.0-distroless-libc` |

## Configuration

| File | Purpose |
|---|---|
| `charts/edge/templates/vector.yaml` | ServiceAccount, ClusterRole/Binding, ConfigMap and DaemonSet |
| `charts/edge/files/vector-local.yaml` | the config itself on tier-1 — sources, VRL transforms, Loki sink |
| `charts/edge/files/vector.yaml` | same, for a remote Loki over mTLS |

Set from `sites/<site>/values.yaml`; you never edit `charts/edge/values.yaml`,
which holds the defaults and the reasoning behind them.

| Values key | Effect |
|---|---|
| `observability.enabled` | run Vector at all |
| `observability.stack.enabled` | selects the config file, and derives `LOKI_ENDPOINT` to the local `ais-loki` |
| `clusterLabel` | `${CLUSTER_LABEL}`, the `cluster` stream label on every line |
| `observability.vector.image.{repository,tag,pullPolicy}` | the image |
| `observability.vector.resources` | requests/limits (defaults 100m/128Mi → 500m/512Mi) |
| `observability.loki.endpoint` | explicit push endpoint; overrides the derived one |
| `observability.loki.clientCertSecret` / `caBundleSecret` / `caBundleKey` | the mTLS material for a **remote** Loki. `clientCertSecret` also gates the cert mounts — a tier-1 site must set it to `""` (see below). |

## Operations

```bash
# Pod state
kubectl -n xnat-ingest get pods -l app=vector

# Tail Vector's own logs (look for sink errors, batch sizes)
kubectl -n xnat-ingest logs -l app=vector -f

# The config actually mounted
kubectl -n xnat-ingest get cm <release>-vector -o jsonpath='{.data.vector\.yaml}'

# Apply a config change: edit the file in the chart, then re-run the release
# (the release name is the site name unless AIS_RELEASE is set)
helm upgrade --install <site> charts/edge \
  -n xnat-ingest -f sites/<site>/values.yaml

# Is anything actually arriving?
kubectl -n xnat-ingest port-forward svc/ais-loki 3100:3100
curl -s http://localhost:3100/loki/api/v1/labels
```

## Benefits

- **Single binary** — replaces Promtail + Fluent Bit + Grafana Agent
- **Native JSON parsing** — no grok/regex configs to maintain
- **VRL is type-safe** — type errors caught at config load, not runtime
- **Backpressure-aware** — a short Loki outage stalls the tail rather than
  losing it
- **Apache 2.0** — no vendor lock-in

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| `observability.loki.clientCertSecret` left at the chart default on tier-1 | The DaemonSet mounts Secrets `loki-push-client-tls` and `ca-bundle`, which exist only on tier-2 where the management cert-sync writes them. Vector never starts. | Set `observability.loki.clientCertSecret: ""` in the site file. The mounts are non-optional on purpose: on tier-2 an optional mount would let Vector start with no client certificate, every push would be rejected at the handshake, and the site would look healthy while shipping nothing. |
| The two config files drift | A non-TLS change made to one variant only — a renamed label, a new transform — silently changes what one tier ships | Manual discipline; both file headers say so. Nothing diffs them |
| `/var/log/pods` rotated mid-read | Skipped lines | `auto_partial_merge: true` + Vector's checkpointer on a hostPath; negligible at our log volumes |
| Loki unreachable | No `buffer:` is configured, so the sink's default in-memory buffer applies backpressure to the source rather than dropping events. A long outage exposes you to the kubelet rotating a file out from under the stalled tail | Loki is in-cluster on the same node; outages are brief |
| Label cardinality explosion | Loki index size blows up | Vector explicitly does NOT label `session` (high cardinality); it stays a parsed field in the body, queryable with `| json` |
| K8s API rate-limited | Pod metadata enrichment slows | `kubernetes_logs` is well-mannered; default cache size is fine at our scale |
| hostPath escape | Theoretical | All capabilities dropped, `RuntimeDefault` seccomp, no hostNetwork, log mounts read-only; `/var/lib/vector` is the only writable host path. The chart sets no `runAsUser` — Vector runs as whatever the distroless image declares |

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
  Loki's retention window (`observability.stack.retentionDays`).
- Unit tests for the VRL transforms (`vector test`).
