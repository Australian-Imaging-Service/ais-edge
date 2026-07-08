# Alerting architecture — why Loki ruler, not Prometheus remote-write

## TL;DR

Pipeline-event alerts (upload_failed spikes, stalled sessions, XNAT backlog,
DICOM validation failures) are evaluated by **Loki's built-in ruler** running
LogQL queries against the JSON event stream. K8s/cert-manager-derived alerts
(node NotReady, pod crashlooping, certificate expiry, SeaweedFS down) stay in
**Prometheus** as `PrometheusRule` objects. Both fire into the existing
**kube-prometheus-stack Alertmanager**, which routes via the
`ALERT_*` env vars in `config/management.env`.

## Why not just Prometheus for everything?

The pipeline emits structured JSON events from pods that run on **edge child
clusters** (managed by k0smotron). The mgmt-cluster Prometheus cannot scrape
those pods directly — k0smotron's konnectivity tunnel is one-way (worker →
control plane), so there is no path from mgmt Prometheus back into a child
cluster's pod network.

There are two production-grade options:

1. **Edge Prometheus → mgmt remote-write.** Stand up a Vector
   `prometheus_exporter` sink on each edge, expose it through the edge's
   `nginx-ingress` on a new SNI hostname (e.g. `prom-edge.aisedge.local`),
   issue+rotate a bearer token per edge, enable `--web.enable-remote-write-receiver`
   on mgmt Prometheus, and configure remote-write on the edge Prometheus.
   This is real infrastructure: an additional ingress endpoint per edge, two
   moving Prometheuses to keep healthy, separate auth surface, and another
   thing to monitor.

2. **Loki ruler.** Loki already receives every JSON event from every edge
   (Vector → Loki over the existing `loki.aisedge.local` ingress on :443).
   The Loki binary has a built-in `ruler` component that runs LogQL queries
   on a schedule and emits firing alerts to any Alertmanager that speaks
   the Alertmanager v2 API. No new ingress, no new auth, no new Prometheus.

We chose **option 2.** The source of truth for these alerts is the JSON
event itself (`{event: "upload_failed", session: "...", duration_s: ...}`),
not a synthesised counter. Counting events in LogQL with `count_over_time`
is the same operation we already perform for the dashboards, so the alert
expressions sit close to the dashboard queries that operators already trust.

## What lives where

| Alert | Source | Why |
|------|--------|------|
| `XNATUploadFailingForAllSessions` | Loki ruler | Derived from `event="upload_failed"` and `event="upload_completed"` JSON events on the edge. |
| `S3UploaderRetryStorm` | Loki ruler | `event="upload_failed"` count over a window, per cluster. |
| `SessionUploadStalled` | Loki ruler | `event="upload_started"` without matching `event="upload_completed"` per session. |
| `XNATBacklogGrowing` | Loki ruler | Difference between mgmt-side `xnat_upload_completed` and edge-side `upload_completed`. |
| `DICOMValidationFailureSpike` | Loki ruler | Pattern match on assign-pod log lines. |
| `ManagementClusterDown` | Prometheus | `up{job="apiserver"}` — only meaningful from mgmt Prometheus. |
| `EdgeWorkerDisconnected` | Prometheus | `kube_node_status_condition` — kube-state-metrics on each edge child. |
| `SeaweedFSDown` | Prometheus | Deployment readiness, scraped from mgmt KSM. |
| `KonnectivityTunnelFlapping` | Prometheus | Container restart count, KSM. |
| `EdgePodCrashLoop` | Prometheus | Container restart count, KSM. |
| `SeaweedFSDiskFull` | Prometheus | `kubelet_volume_stats_*` from mgmt kubelet scrape. |
| `CertificateExpiringSoon` | Prometheus | `certmanager_certificate_*` from mgmt cert-manager. |

If we ever need a pipeline-event metric *as a metric* (e.g. for a Grafana
panel that needs ms-resolution sliding windows that LogQL can't deliver),
the right path forward is to add a `recording_rules` block to Loki's ruler
config — that produces a Prometheus-format metric from a LogQL query and
exposes it on Loki's `/prometheus/api/v1/...` endpoint. Loki then becomes
both the storage and the metrics engine for log-derived signals; mgmt
Prometheus does NOT need to scrape the edges.

## What we removed

- Vector `log_to_metric` transform on both mgmt and edge configs.
- Vector `prometheus_exporter` sink on both.
- Vector `Service` and `:9598` port on the edge DaemonSet.
- Hand-rolled `vector-servicemonitor.yaml` (the Vector helm chart's
  `serviceMonitor.enabled` was silently broken at chart 0.52.0 — it ships
  `templates/podmonitor.yaml` but no ServiceMonitor template — and our
  hand-rolled replacement existed only to make the dead Prom path scrape).

The result is one less metric pipeline, one less ingress hostname per edge
that we'd otherwise need, and one source of truth for pipeline alerts.
