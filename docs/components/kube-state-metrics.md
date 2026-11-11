# kube-state-metrics

## Overview

[kube-state-metrics](https://github.com/kubernetes/kube-state-metrics)
(KSM) is a small service that listens to the Kubernetes API and
exposes the **state of every object** as Prometheus metrics. Unlike
cAdvisor (which gives container-resource metrics) or kubelet (which
gives node and volume metrics), KSM gives **object metrics** —
`kube_pod_status_phase`, `kube_pod_container_status_waiting_reason`,
`kube_deployment_status_replicas_available`,
`kube_persistentvolumeclaim_access_mode`, `kube_node_status_condition`,
etc.

## Role in this stack

The source of truth for "is this thing in the right state?". It exists only
when `observability.stack.enabled: true` in `sites/<site>/values.yaml` — that
key gates the vendored `kube-prometheus-stack` dependency in
`charts/edge/Chart.yaml`, and KSM comes along inside it. Do not confuse it with
`observability.enabled`, which is a separate, older switch meaning only "run
Vector".

On tier-1 the pipeline pods expose **no `/metrics` endpoint at all** — Orthanc,
group-orthanc, assign, upload and data-policy report through the JSON event
stream Vector ships to Loki. So KSM supplies Kubernetes object state about the pipeline. Kubelet and
cAdvisor also supply container and volume metrics. KSM itself it sees the pipeline purely as Kubernetes object
state (Deployment replicas, container restart reasons, PVC phase), and
everything semantic — a session that failed to upload, a backlog, a disk
running low — is a LogQL rule in the Loki ruler instead. See
[`alerting-architecture.md`](../alerting-architecture.md) for the split.

**`charts/edge` now ships its own PrometheusRules** through
`templates/observability.yaml`, in addition to the upstream `ais-kps-*` rules.
The historical claim that none were shipped no longer applies (reviewed
2026-11-10). Custom rules include `NodeNotReady`, `IngestPodCrashLoop`,
`ReclaimerNotSucceeding` and uploader rules. Upstream rules still include:

- `KubeNodeNotReady` — `kube_node_status_condition{condition="Ready",status="true"} == 0`
- `KubePodCrashLooping` — `kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}`
- `KubePodNotReady` — `kube_pod_status_phase{phase=~"Pending|Unknown"}`
- `KubeDeploymentReplicasMismatch` — `kube_deployment_spec_replicas` vs
  `kube_deployment_status_replicas_available`; this is what actually fires when
  Orthanc or the upload Deployment is down
- `KubePersistentVolumeFillingUp` — `kubelet_volume_stats_*` from the kubelet,
  cross-referenced with `kube_persistentvolumeclaim_*` from KSM

Most listed Kubernetes-state expressions select `job="kube-state-metrics"`.
The volume rule also selects kubelet metrics and joins PVC metadata. The job
label comes from `jobLabel: app.kubernetes.io/name` on the ServiceMonitor.
Changing the Deployment name alone need not change it; changing the Service
label or scrape configuration can. Check the rendered selectors and live
`up` labels after an observability change.

## What kube-state-metrics has access to

- **Cluster API** read-only via ServiceAccount `<release>-kube-state-metrics`
  and a ClusterRole with `list`/`watch` on the object kinds it exports (pods,
  nodes, deployments, statefulsets, daemonsets, jobs, cronjobs, PVs, PVCs,
  services, endpointslices, namespaces, secrets, configmaps, storageclasses,
  webhook configurations, …). It never gets `create`, `update` or `delete`.
  Note that `secrets` and `configmaps` *are* in that list: KSM only ever emits
  metadata from them (`kube_secret_info`, type, labels, creation timestamp),
  but the grant is a full `list`/`watch`, so the credentials in `xnat-ingest`
  are inside its blast radius if the pod is ever compromised
- **No filesystem access** (`readOnlyRootFilesystem: true`, no volumes), **no
  hostNetwork**, `runAsNonRoot` as UID 65534, all capabilities dropped
- `automountServiceAccountToken: true`, unlike the chart's own workloads —
  `serviceAccounts.automountToken: false` in `charts/edge/values.yaml` applies
  to the ServiceAccounts this chart creates, not to a subchart that exists
  precisely to read the API
- Exposes `:8080/metrics` as a ClusterIP Service

## Where it runs

- Cluster: the single-node cluster
- Namespace: **`xnat-ingest`**, the same namespace as the pipeline. There is no
  separate `observability` namespace on tier-1: one node, one release, one
  namespace
- Workload: Deployment `<release>-kube-state-metrics` (single replica), where
  `<release>` is the site name — `install.sh` uses the site directory name as
  the Helm release name unless `AIS_RELEASE` overrides it
- Service: `<release>-kube-state-metrics.xnat-ingest.svc:8080` (ClusterIP)
- Image: `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.19.1`, from
  the `kube-state-metrics` 8.0.0 subchart inside the vendored
  [`charts/edge/charts/kube-prometheus-stack-87.19.2.tgz`](../../charts/edge/charts/).
  Pinned and vendored on purpose: a hospital appliance must not need a working
  path to `prometheus-community.github.io` in order to reinstall
- Scraped by `ais-kps-prometheus` via the ServiceMonitor the subchart generates

**KSM uses the release name rather than the `ais-kps-*` prefix.**
Grafana also uses the release name; Loki uses `ais-loki`. These are separate
subchart naming rules, not evidence of multiple installations.
`kube-prometheus-stack.fullnameOverride: ais-kps` renames the stack's own
objects, but `kube-state-metrics` is a subchart of a subchart with its own
fullname template, so it falls back to `<release>-kube-state-metrics`. Grafana
is the same (`<release>-grafana`). Expect `kubectl get deploy -n xnat-ingest`
to show both naming schemes; nothing is wrong.

## Configuration

KSM has no site-level surface of its own. It is on by default — the vendored
chart's `kubeStateMetrics.enabled` is `true` and `charts/edge/values.yaml`
does not override it, so enabling the stack enables KSM. Anything you need to
change goes in a `kube-prometheus-stack:` block, in `sites/<site>/values.yaml`
if it is site-specific (`install.sh` passes `-f sites/<site>/values.yaml` and
no `--set`, so the site file merges over the chart defaults like any Helm
values file):

```yaml
kube-prometheus-stack:
  kubeStateMetrics:
    enabled: true            # false removes KSM and its object-state inputs
  kube-state-metrics:        # the subchart's own values
    resources:
      requests: {cpu: 10m, memory: 32Mi}
      limits:   {cpu: 100m, memory: 128Mi}
    selfMonitor:
      enabled: false         # see the failure modes below
```

`resources` renders as `{}` by default — KSM runs **unbounded** on this node.
The rendered container has no chart request or limit, unless a site or
namespace policy supplies one. The reason for the upstream default and its
adequacy for a particular node are not verified (2026-11-10). Measure object
count and resource use before deciding whether to add explicit limits.

The exported object kinds are a fixed list rendered into `--resources=` from the
subchart's `collectors` key. **CRDs are not in it** — `ServiceMonitor`,
`PrometheusRule` and the `Prometheus`/`Alertmanager` objects have no `kube_*`
series. Custom kinds need `customResourceState.enabled: true` plus a config,
not just an entry in `collectors`.

## Operations

```bash
# Pod state
kubectl -n xnat-ingest get pod -l app.kubernetes.io/name=kube-state-metrics

# Sample metrics (release name = site name)
kubectl -n xnat-ingest port-forward svc/<release>-kube-state-metrics 8080:8080 &
curl -s localhost:8080/metrics | grep '^kube_pod_status_phase' | head

# Verify Prometheus is scraping it — the target must carry job="kube-state-metrics"
kubectl -n xnat-ingest port-forward svc/ais-kps-prometheus 9090:9090 &
xdg-open http://localhost:9090/targets
curl -s 'http://localhost:9090/api/v1/query?query=up{job="kube-state-metrics"}' | jq

# RBAC sanity check
kubectl auth can-i list pods \
  --as=system:serviceaccount:xnat-ingest:<release>-kube-state-metrics
```

## Benefits

- **Comprehensive** — every K8s object kind in the collector list, covered by
  one small pod
- **Cheap** — a single deployment, no per-node agent, no host access
- **Standard naming** — the kube-prometheus-stack rules and the community
  dashboards expect exactly these metric names, so they work unmodified
- **Read-only verbs** limit direct Kubernetes mutation, but do not make the
  grant safe by themselves. Its list/watch access to Secrets can disclose
  credentials if compromised. Review that access within the node trust model.

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| KSM down | KSM-dependent rules lose object-state inputs. Upstream `TargetDown` can detect failed existing scrape targets, but not every disappearance. Loki rules have a separate input path | `selfMonitor` is off by default, so internal KSM telemetry rules lack their `:8081` inputs. Enabling it adds telemetry, not a guarantee against total absence. Verify the scrape target, rule inputs and recovery after a controlled test; rebuild time is not verified (2026-11-10) |
| Someone renames the workload or drops `jobLabel` | The `job` label stops being `kube-state-metrics`, and every default rule that matches on it silently never fires while KSM itself looks perfectly healthy | Leave the subchart to name it. Check `up{job="kube-state-metrics"}` after any change to the `kube-prometheus-stack:` block |
| `kubeStateMetrics.enabled: false` | Loses the only Kubernetes-state signal on the node. Prometheus keeps scraping the kubelet and apiserver, so the dashboards still render and the loss is easy to miss | Do not disable it. If the goal is fewer series, use `metricDenylist` / `collectors` instead |
| Cardinality growth | RAM climbs with object count; `resources: {}` means nothing caps it | Trim `collectors`, or set `metricAllowlist`/`metricDenylist`. Avoid `metricLabelsAllowlist` with `*` — one wildcard on pods multiplies the series set |
| CRD state expected but absent | A dashboard or rule written against a custom kind returns no data and reads as "healthy" | KSM exports only the kinds in `collectors`; custom kinds need `customResourceState` |
| RBAC drift | KSM cannot read some kinds; those metrics vanish | The subchart owns the ClusterRole; verify with the `kubectl auth can-i` command above |

## Replacements / future

- **kube-prometheus-stack ships KSM by default**, and we let it manage the
  Deployment, the RBAC and the ServiceMonitor rather than running a second
  release — one fewer thing to keep in step with the Prometheus that scrapes it
- **OpenCost / Kubecost** — adds cost-allocation metrics on top of KSM-style
  data; only useful in cloud, and there is no cloud here
- **Node-exporter host metrics** are a separate gap: `nodeExporter` is
  disabled (see [`prometheus.md`](prometheus.md)). Kubelet and cAdvisor still
  supply container and some volume metrics. The data-policy reporter emits
  pipeline-disk observations as logs; KSM does not measure disk bytes.

## Future enhancements

- Set explicit `resources` on the subchart so a cardinality problem is bounded
  rather than an OOM on the node that also runs the pipeline
- Turn on `selfMonitor` so the four shipped `KubeStateMetrics*` alerts have
  series behind them — today they are loaded rules that can never fire
- Trim `collectors` to the kinds this appliance actually has, if series count
  ever becomes the constraint
