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
our K8s-level alerts depend on it:
- `NodeNotReady` — `kube_node_status_condition{condition="Ready"}`
- `PodCrashLoop` — `kube_pod_container_status_restarts_total`
- `OrthancDown` / `UploadPodDown` — `kube_deployment_status_replicas_ready{...}`
- `PVCNearlyFull` — `kubelet_volume_stats_*` (kubelet, cross-referenced with KSM
  PVC state)

## What kube-state-metrics has access to

- **Cluster API** read-only via its ServiceAccount + ClusterRole
  (gets/lists/watches every K8s object kind it exports)
- **No filesystem access**, **no host network**
- Exposes `:8080/metrics` as a regular Service

## Where it runs

- Cluster: the single-node cluster
- Namespace: `observability`
- Workload: Deployment `kube-prometheus-stack-kube-state-metrics`
  (single replica)
- Image: from kube-prometheus-stack chart default
- Scraped by the bundled Prometheus via auto-generated ServiceMonitor

## Configuration

Lives entirely in the kube-prometheus-stack chart values
(`manifests/01-management/observability/kube-prometheus-stack-values.yaml.tpl`):

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
# Pod state
kubectl get pods -n observability -l app.kubernetes.io/name=kube-state-metrics

# Sample metrics
kubectl port-forward -n observability \
  svc/kube-prometheus-stack-kube-state-metrics 8080:8080 &
curl -s localhost:8080/metrics | grep "^kube_pod_status_phase" | head

# Verify Prometheus is scraping
kubectl port-forward -n observability \
  svc/kube-prometheus-stack-prometheus 9090:9090 &
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
| Cluster CRD added | New object kinds not exported | KSM has built-in support for popular CRDs; custom kinds need a CRD allow-list |
| RBAC drift | KSM can't read some objects | KPS chart provides the right ClusterRole; verify with `kubectl auth can-i list pods --as=system:serviceaccount:observability:kube-prometheus-stack-kube-state-metrics` |

## Replacements / future

- **prom-operator-pack** ships KSM by default; we let it manage
  the deployment for us
- **OpenCost / Kubecost** — adds cost-allocation metrics on top of
  KSM-style data; only useful in cloud
- **kube-aggregator-metrics** — alternative; rarely used. Stick with KSM

## Future enhancements

- Per-component metric enable/disable to reduce series count if
  cardinality becomes a problem (KSM is verbose by default)
