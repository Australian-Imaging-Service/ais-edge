# kube-state-metrics

## Overview

[kube-state-metrics](https://github.com/kubernetes/kube-state-metrics)
(KSM) is a small service that listens to the Kubernetes API and
exposes the state of configured built-in object kinds as Prometheus metrics.
It does not export arbitrary custom resources without additional configuration. Unlike
cAdvisor (which gives container-resource metrics) or kubelet (which
gives node metrics), KSM gives **object metrics** —
`kube_pod_status_phase`, `kube_deployment_status_replicas_ready`,
`kube_cronjob_status_last_successful_time`, `kube_node_status_condition`,
etc.

## Role in this stack

The source of truth for "is this thing in the right state?" Most of
our alerts depend on it:
- `ManagementNodeNotReady`: `kube_node_status_condition{job="kube-state-metrics",condition="Ready"}`,
  management nodes only
- `EdgeWorkerDisconnected`, `EdgeNodeStatusMissing`, `EdgeNodeStatusStale`: from the
  per-edge collectors (`job="edge-node-state"`), not from this KSM. See
  "Per-edge node collectors" below
- `SeaweedFSDown` — `kube_deployment_status_replicas_ready{deployment=~".*seaweedfs.*"}`
  (a REGEX, deliberately: the imperative installer made `Deployment/seaweedfs`,
  the chart makes `<release>-seaweedfs` in the release namespace, so an exact
  `deployment="seaweedfs"` matcher selects nothing the moment you install from
  the chart — the alert would simply stop firing and nothing would say so.
  `charts/mgmt/files/prometheus-rules/critical.yaml` is loaded with
  `.Files.Get` because it carries `{{ $labels }}` Helm must not touch, so it
  cannot be templated with the release name; the regex is what makes one rule
  cover both layouts)
- `CertificateExpiringSoon` uses `certmanager_certificate_expiration_timestamp_seconds`
  from cert-manager itself, not KSM. Its scrape and availability are separate.
- `ReclaimerNotSucceeding`: `kube_cronjob_status_last_successful_time` and
  `kube_cronjob_created` for each edge's `<release>-reclaim-<edge>` CronJob

Because so much reads it, `KubeStateMetricsDown` (warning) fires when KSM has
not been scraped successfully for 15 minutes: with its series gone, every
KSM-dependent alert above can lose its input and stay quiet. The certificate
expiry alert has a separate cert-manager input; KSM loss does not remove it.

**Historical measurements (August 2026; live counts not verified 2026-11-10).**
The observations below motivated the current rule design. The source review
confirms the management-only KSM topology and the removed invalid rules; use
the live diagnostic commands to establish current series counts:

- **KSM runs on the management cluster only**, and nothing federates or
  remote-writes child-cluster metrics back to it (see
  `docs/alerting-architecture.md` for why that path was rejected — edge
  signals arrive as logs through Loki instead). the historical `kube_node_info` query returned one management-node series.
  A current deployment can have more management nodes; this is not an edge
  census and must not be treated as a fixed cardinality. The per-edge node
  collectors (below) also run on the management cluster: they read each
  edge's API server, which runs here, not the edge's pod network.

  Two alerts that named child-cluster objects were deleted for exactly this
  reason, confirmed with zero series each: `EdgePodCrashLoop`
  (`namespace="xnat-ingest"`, a namespace that does not exist on this
  cluster at all) and `KonnectivityTunnelFlapping`
  (`pod=~"konnectivity-agent-.*"`, which runs on the edge's own kube-system,
  not the management one). `docs/TOUR.md` §9 has the measurement.

  `EdgeWorkerDisconnected` was a DIFFERENT case: it had
  `kube_node_status_condition` series, but only for the management node, so it
  fired, just not on the edge's behalf. That rule is now
  `ManagementNodeNotReady` (`job="kube-state-metrics"`), and
  `EdgeWorkerDisconnected` reads the per-edge collectors
  (`job="edge-node-state"`). Treat `scripts/check-alert-inputs.sh` as the
  authority on which inputs exist.

- **`*_info`, `*_labels` and `*_annotations` are join metrics, not gauges.**
  Their value is the constant 1 and every fact lives in a label. A new object
  appears as a **new series** at 1 — it never moves an existing value — so
  `changes()`, `delta()`, `rate()` and friends over one of them are
  identically 0. `NewEdgeJoined` was `changes(kube_node_info[10m]) > 0` and
  could not detect a new object by that value expression; it has been removed, and
  `scripts/ci/promtool.sh` now rejects the shape. To say anything about a join
  metric, work on the SERIES SET rather than the value: `unless on (...)`
  against another metric, as `CertSyncNeverSucceeded` first did
  (`kube_cronjob_info{...} unless on (namespace, cronjob)
  kube_cronjob_status_last_successful_time`, read as "a cronjob exists with
  no success recorded"), or against the same metric at an `offset` to spot one
  that has just appeared. Never look for a change in the value.

  That rule also shows the second half of the lesson: the series set has to
  mean the thing you are asking about. "Exists" was the wrong question there.
  A new edge's CronJob exists up to ~6h before its first run is due, so the
  rule paged critical at 2h on a healthy new edge that had simply not been
  scheduled yet (and whose manual seed had not succeeded). It now puts the
  same `unless on (namespace, cronjob)` against
  `kube_cronjob_status_last_schedule_time` (a run has been scheduled) or a
  `kube_cronjob_created` older than 24h (nothing was ever scheduled). Both
  are timestamps, not join metrics. The first has no series until a run has
  been scheduled; the second exists from creation, and the `> 86400`
  comparison is what keeps only CronJobs over a day old.

## What kube-state-metrics has access to

- **Cluster API** read-only via its ServiceAccount + ClusterRole
  (gets/lists/watches every K8s object kind it exports)
- **No filesystem access**, **no host network**
- Exposes `:8080/metrics` as a regular Service

## Where it runs

- Cluster: management cluster only
- Namespace: `ais-mgmt` — the management release's namespace
  (`install.sh`, management Helm release namespace). There is no `observability` namespace; that was the
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

## Per-edge node collectors

The KSM above lists management nodes only. Edge workers are nodes of the
k0smotron child clusters, so their Ready state comes from a second, small KSM
per edge (`charts/mgmt/templates/edge-node-state.yaml`, values `edgeNodeState`):

- It runs in the edge's namespace on the management cluster, as Deployment
  `<release>-node-state-<edge>`, with `--resources=nodes`.
- It reads the child API with `<edge>-kubeconfig`, the Secret k0smotron writes
  in that namespace, mounted read-only. CAUTION: that kubeconfig is
  cluster-admin for the child cluster, as for cert-sync. Nothing copies it.
- The init container `find-api` finds the k0smotron control-plane Service by
  label, as cert-sync does, and writes its address
  (`https://<service>.<edge namespace>.svc.cluster.local:<port>`) into a KSM
  options file. The CA and the client certificate still come from the
  kubeconfig, so TLS verification stays on. With no matching Service, or
  more than one, it fails and says so. Only this container gets the pod's
  ServiceAccount token, which can only list Services in that namespace.
- Its ServiceMonitor sets `job="edge-node-state"` and `cluster=<edge>` on
  every target, so `up` carries them too.

Alerts (`charts/mgmt/files/prometheus-rules/edge-nodes.yaml`):
`EdgeWorkerDisconnected` (a node not Ready for 5 minutes),
`EdgeNodeStatusMissing` (no Ready series for a configured edge for 10 minutes)
and `EdgeNodeStatusStale` (watch errors and no successful watch for 10
minutes).

Measured on v2.19.1 (2026-11-11, a local probe against the management API):
when its API goes away after start, the collector keeps serving its last
node state (Ready stayed 1), and only
`kube_state_metrics_watch_total{result="error"}` grows. That is why
`EdgeNodeStatusStale` exists. A healthy collector opened its next watch 7 to
8 minutes after the first.

```bash
# The collectors, on the management cluster
kubectl get pods -A -l app.kubernetes.io/component=edge-node-state
kubectl -n <edge namespace> logs deploy/<release>-node-state-<edge> -c find-api
# Edge node state as Prometheus sees it
#   kube_node_status_condition{job="edge-node-state",condition="Ready",status="true"}
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

- **Configured built-in kinds covered** by the rendered `--resources` list.
  CRD metrics need a separate custom-resource configuration.
- **Cheap** — single low-resource pod
- **Standard naming** — Prometheus + community dashboards expect these
  metric names
- **Read-only Kubernetes verbs.** This limits direct mutation but does not
  provide tenant isolation: the rendered ClusterRole can list and watch
  Secrets and ConfigMaps across the management cluster.

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| KSM down | Alerts that depend on its metrics stop firing | Auto-restarts; KPS scrapes regenerate state quickly |
| API rate-limited | Stale metrics | KSM uses informers (cached); rate-limiting unlikely at our scale |
| Cluster CRD added | Custom object state is absent from KSM by default | The rendered collector list contains built-in kinds. Configure custom-resource state metrics and matching RBAC explicitly. Certificate expiry in this stack comes from cert-manager's own exporter |
| Child API unreachable (per-edge collector) | The collector keeps serving its last node state, so `EdgeWorkerDisconnected` cannot fire for that edge | `EdgeNodeStatusStale` fires after 10 minutes of watch errors with no successful watch (plus its 5 minute `for`) |
| RBAC drift | KSM can't read some objects | KPS chart provides the right ClusterRole (`mgmt-kube-state-metrics`, cluster-scoped); verify with `kubectl auth can-i list pods --as=system:serviceaccount:ais-mgmt:mgmt-kube-state-metrics` |

## Replacements / future

- **kube-prometheus-stack** vendors and deploys KSM here. Its values and
  rendered RBAC are the configuration source; there is no separate
  prom-operator-pack dependency in this repository.
- **OpenCost / Kubecost** — adds cost-allocation metrics on top of
  KSM-style data; only useful in cloud
- **kube-aggregator-metrics** — alternative; rarely used. Stick with KSM

## Future enhancements

- Custom CRD scraping for k0smotron `Cluster` resources (KSM has a
  generic CRD scraper; would expose
  `cluster_status_ready{cluster="edge-dev"}` directly)
- Per-component metric enable/disable to reduce series count if
  cardinality becomes a problem (KSM is verbose by default)
