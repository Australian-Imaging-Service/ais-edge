# kube-state-metrics

## Overview

[kube-state-metrics](https://github.com/kubernetes/kube-state-metrics)
(KSM) is a small service that listens to the Kubernetes API and
exposes the **state of every object** as Prometheus metrics. Unlike
cAdvisor (which gives container-resource metrics) or kubelet (which
gives node metrics), KSM gives **object metrics** —
`kube_pod_status_phase`, `kube_deployment_status_replicas_ready`,
`kube_certificate_renewal_timestamp_seconds`, `kube_node_status_condition`,
etc.

## Role in this stack

The source of truth for "is this thing in the right state?" Most of
our alerts depend on it:
- `EdgeWorkerDisconnected` — `kube_node_status_condition{condition="Ready"}`
- `SeaweedFSDown` — `kube_deployment_status_replicas_ready{deployment=~".*seaweedfs.*"}`
  (a REGEX, deliberately: the imperative installer made `Deployment/seaweedfs`,
  the chart makes `<release>-seaweedfs` in the release namespace, so an exact
  `deployment="seaweedfs"` matcher selects nothing the moment you install from
  the chart — the alert would simply stop firing and nothing would say so.
  `charts/mgmt/files/prometheus-rules/critical.yaml` is loaded with
  `.Files.Get` because it carries `{{ $labels }}` Helm must not touch, so it
  cannot be templated with the release name; the regex is what makes one rule
  cover both layouts)
- `CertificateExpiringSoon` — `certmanager_certificate_expiration_timestamp_seconds`

Two caveats on that list, both measured on the live management Prometheus
rather than assumed:

- **KSM runs on the management cluster only**, and nothing federates or
  remote-writes child-cluster metrics back to it (see
  `docs/alerting-architecture.md` for why that path was rejected — edge
  signals arrive as logs through Loki instead). `kube_node_info` has exactly
  one series and it is the management node.

  Two alerts that named child-cluster objects were deleted for exactly this
  reason, confirmed with zero series each: `EdgePodCrashLoop`
  (`namespace="xnat-ingest"`, a namespace that does not exist on this
  cluster at all) and `KonnectivityTunnelFlapping`
  (`pod=~"konnectivity-agent-.*"`, which runs on the edge's own kube-system,
  not the management one). `docs/TOUR.md` §9 has the measurement.

  `EdgeWorkerDisconnected` is a DIFFERENT case, still open: it does have
  `kube_node_status_condition` series, but only for the management node — it
  fires, just not on the edge's behalf, so it is a management-node alert
  wearing an edge name rather than a dead one. Treat
  `scripts/check-alert-inputs.sh` as the authority on which inputs exist.

- **`*_info`, `*_labels` and `*_annotations` are join metrics, not gauges.**
  Their value is the constant 1 and every fact lives in a label. A new object
  appears as a **new series** at 1 — it never moves an existing value — so
  `changes()`, `delta()`, `rate()` and friends over one of them are
  identically 0. `NewEdgeJoined` was `changes(kube_node_info[10m]) > 0` and
  never produced a sample in its life; it has been removed, and
  `scripts/ci/promtool.sh` now rejects the shape. To say anything about a join
  metric, work on the SERIES SET rather than the value: `unless on (...)`
  against another metric, as `CertSyncNeverSucceeded` does
  (`kube_cronjob_info{...} unless on (namespace, cronjob)
  kube_cronjob_status_last_successful_time` — "a cronjob exists with no
  success recorded"), or against the same metric at an `offset` to spot one
  that has just appeared. Never look for a change in the value.

## What kube-state-metrics has access to

- **Cluster API** read-only via its ServiceAccount + ClusterRole
  (gets/lists/watches every K8s object kind it exports)
- **No filesystem access**, **no host network**
- Exposes `:8080/metrics` as a regular Service

## Where it runs

- Cluster: management cluster only
- Namespace: `ais-mgmt` — the management release's namespace
  (`install.sh:121`). There is no `observability` namespace; that was the
  old imperative installer's layout, and everything in the stack now lands
  in the release namespace instead
- Workload: Deployment `mgmt-kube-state-metrics` (single replica). Note the
  name is `<release>-kube-state-metrics`, NOT
  `<release>-kube-prometheus-stack-kube-state-metrics` — KSM is a subchart of
  a subchart and is named for its own chart, unlike Prometheus itself, which
  renders as `mgmt-kube-prometheus-stack-prometheus`. Verified by rendering:
  `helm template mgmt charts/mgmt -n ais-mgmt -f sites/example-mgmt/values.yaml`
- Image: from kube-prometheus-stack chart default
- Scraped by the bundled Prometheus via auto-generated ServiceMonitor
  (`ServiceMonitor/mgmt-kube-state-metrics`, same namespace)

## Configuration

Lives entirely in the kube-prometheus-stack chart values
(`charts/mgmt/values.yaml`, under `kube-prometheus-stack:`):

```yaml
kubeStateMetrics:
  enabled: true
kube-state-metrics:
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits:   { cpu: 200m, memory: 256Mi }
```

## Operations

```bash
# Pod state  (release `mgmt` in namespace `ais-mgmt` throughout)
kubectl get pods -n ais-mgmt -l app.kubernetes.io/name=kube-state-metrics

# Sample metrics
kubectl port-forward -n ais-mgmt \
  svc/mgmt-kube-state-metrics 8080:8080 &
curl -s localhost:8080/metrics | grep "^kube_pod_status_phase" | head

# Verify Prometheus is scraping
kubectl port-forward -n ais-mgmt \
  svc/mgmt-kube-prometheus-stack-prometheus 9090:9090 &
xdg-open http://localhost:9090/targets   # look for "kube-state-metrics" target
```

## Benefits

- **Comprehensive** — every K8s object kind covered
- **Cheap** — single low-resource pod
- **Standard naming** — Prometheus + community dashboards expect these
  metric names
- **Multi-tenant safe** — read-only, can't mutate the cluster

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| KSM down | Alerts that depend on its metrics stop firing | Auto-restarts; KPS scrapes regenerate state quickly |
| API rate-limited | Stale metrics | KSM uses informers (cached); rate-limiting unlikely at our scale |
| Cluster CRD added | New object kinds not exported | KSM has built-in support for popular CRDs (cert-manager, k0smotron); custom kinds need a CRD allow-list |
| RBAC drift | KSM can't read some objects | KPS chart provides the right ClusterRole (`mgmt-kube-state-metrics`, cluster-scoped); verify with `kubectl auth can-i list pods --as=system:serviceaccount:ais-mgmt:mgmt-kube-state-metrics` |

## Replacements / future

- **prom-operator-pack** ships KSM by default; we let it manage
  the deployment for us
- **OpenCost / Kubecost** — adds cost-allocation metrics on top of
  KSM-style data; only useful in cloud
- **kube-aggregator-metrics** — alternative; rarely used. Stick with KSM

## Future enhancements

- Custom CRD scraping for k0smotron `Cluster` resources (KSM has a
  generic CRD scraper; would expose
  `cluster_status_ready{cluster="edge-dev"}` directly)
- Per-component metric enable/disable to reduce series count if
  cardinality becomes a problem (KSM is verbose by default)
