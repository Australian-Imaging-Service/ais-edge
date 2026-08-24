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
**engines** and rule **content** for both. What differs between them is where
that content comes from:

- **Prometheus** gets kube-prometheus-stack's own default rules — the
  `KubeNodeNotReady` / `KubePodCrashLooping` / `KubePersistentVolumeFillingUp` /
  `KubeletDown` families above all come from there — *plus* four
  `PrometheusRule`s that `charts/edge` renders itself.
  `charts/edge/templates/observability.yaml` globs
  `files/prometheus-rules/*.yaml` and emits one object per severity file:
  `ais-edge-critical` (`KubernetesAPIServerDown`, `NodeNotReady`),
  `ais-edge-warning` (`IngestPodCrashLoop`) and `ais-edge-info`
  (`NodeCountChanged`). Those objects deliberately carry **no** `release` label;
  instead the template `fail`s the render unless
  `kube-prometheus-stack.prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues`
  is `false`. While it is `true` the operator selects only rules labelled with
  its own release, so it would load none of these — silently, with nothing to
  see in any log.
- **The Loki ruler ships with a rule set.**
  `charts/edge/files/loki-ruler-rules.yaml` holds 11 LogQL alerts in four groups
  (`ais-edge-pipeline-critical` / `-warning` / `-info` / `ais-edge-data-policy`)
  — every Loki-ruler row in the table above, plus `XNATUploadSuccess`,
  `XNATAuthFailure`, `OrthancDeidLuaError`, `DeidentifyStageError` and
  `OrthancStorageGrowing`, which ship but are not tabulated.
  `charts/edge/templates/observability.yaml` renders the file into the ConfigMap
  `<release>-loki-rules` under the key `ais-edge-rules.yaml`, labelled
  `loki_rule: "true"` — the **label**, not the name and not the namespace, is
  what the Loki rules sidecar watches for. Two thresholds are substituted at
  render time from `dataPolicy.originals` (`__DP_MIN_FREE_DISK_PCT__`,
  `__DP_QUARANTINE_ALERT_AFTER_S__`), because LogQL cannot compare two extracted
  fields; left unreplaced they are a rule-load syntax error and Loki drops the
  whole group. The template `fail`s outright if the file is missing or empty. A
  site adds rules of its own by applying a *second* ConfigMap in the same
  namespace carrying the same label — not by editing this one (next section).
- **Alertmanager runs the chart's own configuration, not the subchart's.**
  `charts/edge/files/alertmanager-config.yaml` is loaded with `.Files.Get` and
  rendered into the Secret `alertmanager-aisedge-config` by
  `charts/edge/templates/observability.yaml`, and
  `kube-prometheus-stack.alertmanager.alertmanagerSpec.configSecret` in
  `charts/edge/values.yaml` points the operator at it. That pairing is guarded:
  the render `fail`s if `configSecret` is anything else, because without it the
  operator mounts the subchart's default `alertmanager.yaml` and routes every
  alert this chart raises to a `null` receiver — a healthy-looking stack that
  delivers nothing. The rendered config's root receiver is `email-primary`, with
  severity-based routes onto `email-no-resolved`, `email-upload-success`,
  `info-email`, and a deliberately empty `null-meta` for kube-prometheus-stack's
  own meta-alerts. `observability.stack.alerting.*` from the site file is
  substituted into it as `__SENTINEL__` tokens — a plain `replace`, never `tpl`,
  because that file is full of Alertmanager's own `{{ }}` notification
  templates, which Helm would evaluate against the *chart* context and render as
  empty strings. The SMTP **password** is not in the manifest at all: the config
  carries an `smtp_auth_password_file` pointing at
  `/etc/alertmanager/secrets/<observability.stack.alerting.existingSecret>/password`
  (default `alertmanager-smtp`), which the operator mounts from
  `alertmanagerSpec.secrets` — and a second guard `fail`s the render if that
  Secret is missing from the mount list. Setting
  `kube-prometheus-stack.alertmanager.config` in `sites/<site>/values.yaml` has
  **no effect**: it only writes the subchart's own
  `alertmanager-ais-kps-alertmanager` Secret, which nothing mounts once
  `configSecret` is set. To change the mail destination or SMTP server, set
  `observability.stack.alerting.*` in the site file; to change routes or
  receivers, edit `charts/edge/files/alertmanager-config.yaml`.

Scrape targets that do not exist on a single k0s node are switched off
deliberately — `nodeExporter`, `kubeControllerManager`, `kubeScheduler`,
`kubeProxy`, `kubeEtcd`. Left on, each contributes a permanently-firing
"target down" alert, and an Alertmanager that is always red trains operators to
ignore it. The cost is that the `Node*` rules from node-exporter's mixin are
present but never have series behind them.

## Where a LogQL rule has to land

The ruler's store is local, and it is a **pair** of paths that has to agree —
where the ruler reads, and where the sidecar writes. Both are already set in the
chart:

```yaml
# charts/edge/values.yaml — loki.loki.rulerConfig.storage
type: local
local: {directory: /rules}

# charts/edge/values.yaml — loki.sidecar.rules
folder: /rules/fake
```

`/rules` is where the Loki chart mounts `sc-rules-volume`, an emptyDir shared by
the `loki` and the `loki-sc-rules` containers. `fake` is the tenant
subdirectory the local rule store demands: Loki treats every subdirectory of
`storage.local.directory` as a tenant ID, and with `auth_enabled: false` the
only tenant is literally `fake`. A rules file dropped at the *top* level of
`/rules` is not an error — Loki finds no tenant directory, starts cleanly, and
evaluates nothing, which is indistinguishable from a healthy site.

`charts/edge/values.yaml` records why the ruler path is `/rules` and not the
more obvious `/etc/loki/rules`, because that was the first attempt and it was
measured: `/etc/loki` holds only read-only config and runtime-config mounts,
Loki mkdir's the ruler directory at startup, and the result was

```
mkdir /etc/loki/rules: read-only file system
error initialising module: ruler-storage
```

and a CrashLoop — no log storage, and, since every *pipeline* alert on this tier
is Loki-sourced, no pipeline alerts either. No render check could have caught
it: the path is wrong only relative to where the **subchart** mounts things,
which is invisible to `helm template`.

Two mechanisms exist in the Loki chart and only one of them applies here:

- `loki.ruler.directories` is the obvious knob, and it is inert: its ConfigMaps
  and their `/etc/loki/rules/<tenant>` mounts are rendered **only** in the
  distributed deployment mode, which has a separate ruler StatefulSet. Setting it
  on tier-1 produces no objects at all — it is the lever that looks right and
  moves nothing, so it is worth knowing about precisely so you do not reach for
  it.
- What the single binary does have is the `sidecar.rules` container (kiwigrid
  k8s-sidecar, on by default): it watches ConfigMaps labelled `loki_rule` and
  writes them into `/rules/fake`, inside that same emptyDir. That is how the
  chart's own `<release>-loki-rules` ConfigMap arrives, and it is the route a
  site's extra rules take too — apply another ConfigMap carrying the label.

Verify by reading Loki's own `/loki/api/v1/rules`, not by checking that the pod
is up: a ruler with nothing loaded looks identical from the outside to a healthy
one. `scripts/ci/promtool.sh` guards the neighbouring silent failure under its
"Loki ruler file matches rulefmt.RuleGroup" heading — a rule indented out of its
group is still valid YAML, but Loki then rejects the **entire** file
(`error parsing /rules/fake/ais-edge-rules.yaml: field alert not found in type
rulefmt.RuleGroup`) and all 12 alerts disappear together, not just the one that
was mis-indented.

[`alerting-diy.md`](alerting-diy.md) covers writing the rule expression itself.

If we ever need a pipeline-event metric *as a metric* (e.g. for a Grafana panel
that needs sliding windows LogQL can't deliver), the right path is a
`recording_rules` block in the ruler's rule set — that produces a
Prometheus-format metric from a LogQL query and exposes it on Loki's
`/prometheus/api/v1/...` endpoint. Loki then serves as both the log store and the
metrics engine for log-derived signals.
