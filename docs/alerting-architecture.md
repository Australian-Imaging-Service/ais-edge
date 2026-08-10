# Alerting architecture — Loki ruler for pipeline events, Prometheus for K8s state

## TL;DR

Pipeline-event alerts (upload failures, stalled sessions, XNAT backlog, DICOM
validation failures, edge disk) are evaluated by **Loki's built-in ruler**
running LogQL queries against the JSON event stream. K8s-level alerts (node
NotReady, pod crash-looping, PVC nearly full) stay in **Prometheus** as
`PrometheusRule` objects. Both fire into the one Alertmanager the
kube-prometheus-stack subchart installs, `ais-kps-alertmanager` in the release
namespace.

None of it exists unless `observability.stack.enabled: true` in
`sites/<site>/values.yaml`. That is a **different switch** from
`observability.enabled`, which only means "run Vector". On tier-1 you want both:
Vector to ship the logs, `stack` to give them somewhere to land and something to
evaluate rules against.

Everything runs on one node — there is no konnectivity boundary and no
cross-cluster scrape problem. The split below is about **which signal is the
natural source of truth for each alert**, not about network topology.

## Why two rule engines on one node?

Two kinds of signal, two natural homes:

1. **Pipeline events are JSON log lines.** `xnat-ingest group-orthanc`,
   `xnat-ingest assign`, the `xnat-ingest upload` pod and the data-policy
   reporter emit structured events (`{event: "upload_failed", session: "...",
   ...}`). The source of truth for "did an upload fail?" is the event itself, not
   a synthesised counter. Counting events in LogQL with `count_over_time` is the
   same operation the dashboards already perform, so the alert expressions sit
   close to the dashboard queries operators already trust. Loki's built-in
   `ruler` component runs these LogQL queries on a schedule and emits firing
   alerts to Alertmanager (v2 API).

2. **K8s object state is a metric.** "Is the node Ready?", "is a pod
   crash-looping?", "is the PVC nearly full?" are already Prometheus metrics
   (`kube_node_status_condition`, `kube_pod_container_status_restarts_total`,
   `kubelet_volume_stats_*`) exposed by kube-state-metrics / kubelet. There is no
   reason to route these through logs — a `PrometheusRule` is the right tool.

Because everything is on one node, Prometheus *could* in principle scrape a
metrics endpoint if xnat-ingest exposed one. It doesn't today (see the future
enhancements in [`components/xnat-ingest.md`](components/xnat-ingest.md)), and
even if it did, the JSON event is a richer, more direct source for
pipeline-event alerts. So we keep pipeline alerts in the Loki ruler.

## The names are pinned, and the ruler depends on it

Both subcharts carry a `fullnameOverride` in `charts/edge/values.yaml`, so the
objects are not named after the Helm release:

| Object | Name | Set by |
|--------|------|--------|
| Alertmanager Service | `ais-kps-alertmanager` | `kube-prometheus-stack.fullnameOverride: ais-kps` |
| Prometheus Service | `ais-kps-prometheus` | same |
| Loki Service + StatefulSet | `ais-loki` | `loki.fullnameOverride: ais-loki` |

Loki's ruler is pointed at the first of those:

```yaml
# charts/edge/values.yaml — loki.loki.rulerConfig
alertmanager_url: http://ais-kps-alertmanager.{{ .Release.Namespace }}.svc.cluster.local:9093
```

The `{{ .Release.Namespace }}` resolves because the Loki chart renders its whole
config through `tpl`; the Service name cannot, which is exactly why it is pinned
rather than derived.

**This coupling fails silently.** Point the ruler at a name that does not
resolve — which is what happens by default, since the un-overridden name would
be `<release>-kube-prometheus-stack-alertmanager` — and Loki stays healthy, the
rules stay loaded, the dashboards stay green, and no LogQL alert ever reaches
anybody. If you rename either subchart, move the ruler URL with it.

Vector's sink has the same property in the other direction: `ais-loki` is written
literally in `charts/edge/files/vector-local.yaml`, because that file is loaded
with `.Files.Get` and Helm never templates it.

## What lives where

| Signal | Engine | Why |
|------|--------|------|
| Upload failing / retry storm | Loki ruler | Derived from `event="upload_failed"` vs `event="upload_completed"` JSON events on the upload pod (`{component="upload"}`). |
| Session upload stalled | Loki ruler | `event="upload_started"` without a matching `event="upload_completed"` per session. |
| XNAT backlog growing | Loki ruler | Completed-upload rate drops while assign keeps producing — sessions piling up in `/data/assigned`. |
| DICOM validation failure spike | Loki ruler | Pattern match on assign-pod `ERROR` lines (`Invalid IDs found`), `{component="assign"}`. |
| `EdgeDiskLow` | Loki ruler | `stage_report.free_pct` from the data-policy DaemonSet, `{component="data-policy"}`. It is the only disk-exhaustion signal for the pipeline volumes. |
| `QuarantinedDataUnresolved` | Loki ruler | `stage_report.oldest_age_s` for the `__unmapped_aet__` subtree — an AE title nobody has mapped to a project yet. |
| `KubeNodeNotReady` | Prometheus | `kube_node_status_condition` from kube-state-metrics. |
| `KubePodCrashLooping` | Prometheus | Container restart count, kube-state-metrics. |
| `KubePodNotReady` | Prometheus | Covers Orthanc and the ingest Deployments; readiness is already a metric. |
| `KubePersistentVolumeFillingUp` | Prometheus | `kubelet_volume_stats_*` for the observability PVCs. |

The stream labels those LogQL selectors use — `cluster`, `namespace`, `pod`,
`component`, `level` — are built by Vector from **pod labels**, not from the
fields inside the JSON line (`charts/edge/files/vector-local.yaml`). A pod that
emits `"component":"data-policy"` in every line but carries no `component` pod
label produces a stream with an empty label, and every rule selecting on it
matches nothing and can never fire. That is not hypothetical: it is why
`charts/edge/templates/data-policy.yaml` sets the label explicitly.

## What the chart installs, and what it does not

With `observability.stack.enabled: true` the release contains both rule
**engines**, but not the same amount of rule **content**:

- **Prometheus** gets kube-prometheus-stack's own default rules — the
  `KubeNodeNotReady` / `KubePodCrashLooping` / `KubePersistentVolumeFillingUp` /
  `KubeletDown` families above all come from there. `charts/edge` adds no
  `PrometheusRule` of its own.
- **The Loki ruler starts with an empty rule set.** `charts/edge` ships no LogQL
  rule content, so every pipeline-event row in the table above is something a
  site adds (next section). The ruler is configured and running; it simply has
  nothing to evaluate until then.
- **Alertmanager runs kube-prometheus-stack's default configuration**, whose
  route ends at the `null` receiver. `observability.stack.alerting.*` in the site
  file and the `alertmanager-smtp` Secret are declared, but nothing in the chart
  renders them into an Alertmanager config yet — filling them in does **not** by
  itself send mail. To route mail today, set
  `kube-prometheus-stack.alertmanager.config` in `sites/<site>/values.yaml`; that
  is the values key that produces the `alertmanager-ais-kps-alertmanager` Secret.

Scrape targets that do not exist on a single k0s node are switched off
deliberately — `nodeExporter`, `kubeControllerManager`, `kubeScheduler`,
`kubeProxy`, `kubeEtcd`. Left on, each contributes a permanently-firing
"target down" alert, and an Alertmanager that is always red trains operators to
ignore it. The cost is that the `Node*` rules from node-exporter's mixin are
present but never have series behind them.

## Where a LogQL rule has to land

The ruler's store is local:

```yaml
# charts/edge/values.yaml — loki.loki.rulerConfig.storage
type: local
local: {directory: /etc/loki/rules}
```

On `deploymentMode: SingleBinary` — which is what tier-1 runs — **nothing is
mounted at `/etc/loki/rules`**. Two mechanisms exist in the Loki chart and only
one of them applies here:

- `loki.ruler.directories` is the obvious knob, and it is inert: its ConfigMaps
  and their `/etc/loki/rules/<tenant>` mounts are rendered **only** in the
  distributed deployment mode, which has a separate ruler StatefulSet. Setting it
  on tier-1 produces no objects at all.
- What the single binary does have is the `sidecar.rules` container (kiwigrid
  k8s-sidecar, on by default): it watches ConfigMaps labelled `loki_rule` and
  writes them into `/rules`, an emptyDir mounted into both containers.

So a rule ConfigMap reaches the pod and the ruler still never sees it, because
the two paths differ. Wiring it up means making them agree —
`loki.loki.rulerConfig.storage.local.directory` and `loki.sidecar.rules.folder`
— and giving the rules the per-tenant subdirectory the local store expects
(`/etc/loki/rules/<tenant>` is the shape `ruler.directories` builds; the tenant
is `fake` while `auth_enabled: false`). Verify by rendering, then by reading
Loki's own `/loki/api/v1/rules`: a ruler with no rules loaded looks identical to
a healthy one from the outside.

[`alerting-diy.md`](alerting-diy.md) covers writing the rule expression itself.

If we ever need a pipeline-event metric *as a metric* (e.g. for a Grafana panel
that needs sliding windows LogQL can't deliver), the right path is a
`recording_rules` block in the ruler's rule set — that produces a
Prometheus-format metric from a LogQL query and exposes it on Loki's
`/prometheus/api/v1/...` endpoint. Loki then serves as both the log store and the
metrics engine for log-derived signals.
