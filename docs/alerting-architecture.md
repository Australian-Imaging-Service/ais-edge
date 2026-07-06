# Alerting architecture — Loki ruler for pipeline events, Prometheus for K8s state

## TL;DR

Pipeline-event alerts (upload failures, stalled sessions, XNAT backlog, DICOM
validation failures) are evaluated by **Loki's built-in ruler** running LogQL
queries against the JSON event stream. K8s-level alerts (node NotReady, pod
crash-looping, PVC nearly full) stay in **Prometheus** as `PrometheusRule`
objects. Both fire into the same **kube-prometheus-stack Alertmanager**, which
routes via the `ALERT_*` env vars in `config/management.env`.

Everything runs on one node — there is no konnectivity boundary and no
cross-cluster scrape problem. The split below is about **which signal is the
natural source of truth for each alert**, not about network topology.

## Why two rule engines on one node?

Two kinds of signal, two natural homes:

1. **Pipeline events are JSON log lines.** `xnat-ingest sort` and the `xnat-ingest
   upload` pod emit structured events (`{event: "upload_failed", session: "...",
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

## What lives where

| Alert | Source | Why |
|------|--------|------|
| `XNATUploadFailing` | Loki ruler | Derived from `event="upload_failed"` vs `event="upload_completed"` JSON events on the upload pod. |
| `SessionUploadStalled` | Loki ruler | `event="upload_started"` without a matching `event="upload_completed"` per session. |
| `XNATBacklogGrowing` | Loki ruler | Completed-upload rate drops while sort keeps staging — sessions piling up in `/data/staging`. |
| `DICOMValidationFailureSpike` | Loki ruler | Pattern match on sort-pod `ERROR` lines (`Invalid IDs found`). |
| `NodeNotReady` | Prometheus | `kube_node_status_condition` from kube-state-metrics. |
| `PodCrashLoop` | Prometheus | Container restart count, kube-state-metrics. |
| `OrthancDown` / `UploadPodDown` | Prometheus | Deployment readiness, kube-state-metrics. |
| `PVCNearlyFull` | Prometheus | `kubelet_volume_stats_*` from the kubelet scrape (Loki / Prometheus PVCs, and `/data` if mounted). |

If we ever need a pipeline-event metric *as a metric* (e.g. for a Grafana panel
that needs sliding windows LogQL can't deliver), the right path is to add a
`recording_rules` block to Loki's ruler config — that produces a Prometheus-format
metric from a LogQL query and exposes it on Loki's `/prometheus/api/v1/...`
endpoint. Loki then serves as both the log store and the metrics engine for
log-derived signals.
