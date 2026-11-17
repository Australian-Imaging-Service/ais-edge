# Grafana

## Overview

[Grafana](https://grafana.com/) is the visualisation and alerting UI of
the observability stack. It connects to Prometheus and Loki as data
sources and renders dashboards, ad-hoc queries (Explore), and alert
silences.

On tier-1 it exists only when `observability.stack.enabled: true` in
`sites/<site>/values.yaml`. It is not a release of its own: it comes from the
**vendored** kube-prometheus-stack subchart
[`charts/edge/charts/kube-prometheus-stack-87.19.2.tgz`](../../charts/edge/charts/)
(grafana subchart 12.8.1, Grafana 13.1.1), gated on that one key. No
`helm repo add`, no `helm dependency update` at install time.

**`observability.stack.enabled` is not `observability.enabled`.** The first
hosts the stack on this node — Prometheus, Alertmanager, Loki and Grafana. The
second only runs Vector. Turning on the stack without the shipper gives you a
Grafana with an empty Loki behind it and nothing that reads as an error.

## Role in this stack

The single web UI for operators. Queries metrics from Prometheus and
logs from Loki, hosts dashboards, lets engineers explore the data
interactively while triaging an incident.

It does **not** evaluate the alerts. The Alertmanager datasource is provisioned
with `handleGrafanaManagedAlerts: false`: the rules live in the Loki ruler
(LogQL pipeline alerts) and in Prometheus (K8s state), Alertmanager routes them,
and Grafana is where you read and silence them. Nothing breaks if Grafana is
down — alerting keeps working, you just cannot see it.

## What arrives provisioned, and what does not

The subchart provisions **two** datasources, in ConfigMap
`ais-kps-grafana-datasource` (label `grafana_datasource: "1"`):

| Datasource | URL |
|---|---|
| `Prometheus` (default, uid `prometheus`) | `http://ais-kps-prometheus.<namespace>:9090/` |
| `Alertmanager` (uid `alertmanager`) | `http://ais-kps-alertmanager.<namespace>:9093/` |

**Loki is still not provisioned as a datasource by this chart.** However,
`templates/observability.yaml` now ships three pipeline dashboard ConfigMaps:
`pipeline-overview`, `session-timeline` and `edge-drilldown`. They reference
the datasource UID `loki`. Add a Loki datasource with that exact UID, through
managed provisioning or the UI, at the address below. Merely creating a
datasource named Loki with another UID does not satisfy those references.

```
http://ais-loki.<namespace>.svc.cluster.local:3100
```

`ais-loki` is pinned by `loki.fullnameOverride` in `charts/edge/values.yaml`,
and it is the same address Vector pushes to — so a Vector that is shipping logs
has proved its own write path. Grafana still needs a configured datasource,
query access and working resolution from its Pod; Vector success alone does
not prove that separate read path.

What Grafana *does* arrive with is the kube-prometheus-stack's own Kubernetes
dashboards (`ais-kps-*` ConfigMaps): cluster/node/pod resources, kubelet,
apiserver, Prometheus and Alertmanager overviews. Useful for "is the node sick",
useless for "did that session reach XNAT".

## What Grafana has access to

- **Prometheus** and **Alertmanager** — read-only datasources at the in-cluster
  Service URLs above
- **Loki** — read-only, once you add it
- **Cluster API** via its ServiceAccount and ClusterRole
  `<release>-grafana-clusterrole`: `get`/`watch`/`list` on **configmaps and
  secrets, in every namespace**. That is the sidecar pattern's cost — the
  dashboard sidecar runs with `NAMESPACE=ALL` and `RESOURCE=both`, so it needs
  cluster-wide read. It is a broad grant. Other observability components, including KSM and the
  Prometheus operator, also have API access; the pipeline ServiceAccount
  token setting does not constrain those subchart accounts.
- **Persistent volume (5Gi, `local-path`)** for its embedded SQLite database
  (user preferences and locally saved dashboards), PVC `<release>-grafana`.
  Alertmanager silences use its separate storage
- **NO cluster mutation rights** — read verbs only

## Where it runs

- Cluster: the single-node cluster
- Namespace: the release namespace — **`xnat-ingest`** by default, the same
  namespace as the pipeline. There is no separate `observability` namespace.
- Workload: Deployment `<release>-grafana`, three containers —
  `grafana`, `grafana-sc-dashboard`, `grafana-sc-datasources`
- Service: `<release>-grafana` as a **NodePort** at
  `http://<nodeIP>:30030` for the local admin on the LAN. No ingress, no TLS
  termination, no CA — there is no cert-manager on a single node.

`<release>` is the site name (`./install.sh <site>`, overridable with
`AIS_RELEASE`). Note that it is **not** `ais-kps-grafana`: the
`fullnameOverride: ais-kps` in `charts/edge/values.yaml` names
kube-prometheus-stack's *own* objects — `ais-kps-prometheus`,
`ais-kps-alertmanager` — but the grafana subchart names itself from the release.

## Configuration

| File | Purpose |
|---|---|
| `sites/<site>/values.yaml` | `observability.stack.enabled` gates the stack. `kube-prometheus-stack.grafana.service.nodePort` configures the Service and the installer's printed port. |
| `sites/<site>/secrets.enc.yaml` | Secret `grafana-admin-credentials` (keys `admin-user`, `admin-password`), SOPS-encrypted, in the release namespace |
| `charts/edge/values.yaml`, block `kube-prometheus-stack.grafana` | what the subchart is actually given: `admin.existingSecret`, `service.type: NodePort` + `nodePort`, `persistence`, `initChownData` |
| `charts/edge/charts/kube-prometheus-stack-87.19.2.tgz` | the vendored chart itself — Grafana, its sidecars and the Kubernetes dashboards |

**The Service and installer use the same NodePort key.**
`install.sh` (`GRAFANA_PORT`) reads the site's
`kube-prometheus-stack.grafana.service.nodePort`, or falls back to that key
in `charts/edge/values.yaml` (default 30030). It no longer reads the removed
`observability.stack.grafana.nodePort` for the URL it prints. Configure the
subchart key, apply the site file, then compare the live Service and
`helm get notes` after the upgrade. Persistence and the credentials Secret
also belong under `kube-prometheus-stack.grafana`; old friendly parent keys
under `observability.stack.grafana` do not configure the subchart.

`initChownData` is disabled deliberately: it runs as root and fails under a
restricted PSS namespace, and the `local-path` PVC is already writable by
Grafana's UID (472).

The sidecar pattern, and its two different scopes:

- **dashboards** — watches ConfigMaps *and* Secrets in **every namespace** for
  the label `grafana_dashboard: "1"`, writes them to `/tmp/dashboards` and POSTs
  the provisioning reload API. No folder annotation is configured, so everything
  lands in the default folder.
- **datasources** — same mechanism, label `grafana_datasource: "1"`, but scoped
  to Grafana's **own namespace**. A datasource ConfigMap created anywhere else
  is never seen.

Either way the reload is an API call, not a restart: a new ConfigMap appears in
the UI after its watch/reload completes (latency not verified 2026-11-10) and Grafana does not bounce.

## Adding a dashboard

The chart already installs its three pipeline dashboards. The label is also
the mechanism for an additional site dashboard. Use a distinct ConfigMap name
so Helm retains ownership of the shipped dashboards:

```bash
kubectl -n xnat-ingest create configmap site-dashboard-pipeline-copy \
    --from-file=pipeline-overview.json --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 -o yaml \
  | kubectl apply -f -
```

[`docs/dashboards.md`](../dashboards.md) is the definition of what each pipeline
panel has to compute. Every query in it also runs as-is in **Explore**, which is
where to confirm one before wrapping it in a panel.

## Operations

```bash
# Pod state
kubectl -n xnat-ingest get pod -l app.kubernetes.io/name=grafana

# The admin login (what you put in sites/<site>/secrets.enc.yaml)
kubectl -n xnat-ingest get secret grafana-admin-credentials \
  -o jsonpath='{.data.admin-password}' | base64 -d ; echo

# Browser access (NodePort on the node's LAN IP; install.sh prints this)
xdg-open http://<nodeIP>:30030

# Which datasources are actually provisioned
kubectl -n xnat-ingest get cm ais-kps-grafana-datasource -o yaml

# Restart (the sidecars normally pick up ConfigMap changes after its watch/reload completes (latency not verified 2026-11-10);
# restart only to short-circuit that, or after changing the admin Secret)
kubectl -n xnat-ingest rollout restart deployment/<release>-grafana
```

## Benefits

- **Familiar interface** for many operators. Site staff still need an
  introduction to these dashboards, datasource selection and alert routing.
- **Rich dashboard ecosystem** — community dashboards for Kubernetes already exist
- **Single UI for logs + metrics** — one place for the whole observability story
- **Open-source Grafana uses AGPLv3.** The old Apache 2.0 description is
  historical (before the 2021 licence change). Review the deployed edition
  and [upstream licensing](https://grafana.com/licensing/) for its terms.

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| NodePort reachable on the LAN over plain HTTP | Anyone on the LAN who can reach the NodePort sees the login page | Keep the node on a trusted admin/LAN segment; set a strong admin password |
| Placeholder admin password shipped to site | Anyone who reaches Grafana logs in as admin | `admin-password` in `sites/<site>/secrets.enc.yaml` is `REPLACE_GRAFANA_PASSWORD` until you fill it; `install.sh` decrypts it to a pipe and refuses to run while any `REPLACE_` value survives (needs `sops` on PATH) |
| Admin password changed after first boot | The Secret seeds initial database state; an existing database can retain the old login | Use Grafana's supported admin-password reset workflow and reconcile the Secret used by the reload sidecars. Back up the database. Deleting the PVC discards dashboard and user state and is not routine password rotation |
| Sidecar reads Secrets cluster-wide | A Grafana compromise reads every Secret on the node, including `xnat-credentials` and `orthanc-deid-salt` | Inherent to `NAMESPACE=ALL`; the same trust boundary as the node itself, which is single-tenant. Treat Grafana access as node access. |
| Dashboard ConfigMap collision | Any ConfigMap anywhere labelled `grafana_dashboard=1` is loaded | Single-tenant node; nothing else labels ConfigMaps that way |
| No Loki datasource on a fresh install | Shipped LogQL panels cannot query their expected `loki` UID and can show a datasource error or no data | Provision that UID at the Loki URL above. Check a query from Grafana as well as Vector delivery; a missing datasource is not evidence of no logs |
| Datasource credential leak | Logs, metrics and alert state may be exposed. Alertmanager access can also permit silences, depending on the configured endpoint and permissions | Review actual endpoint permissions and network reachability. Grafana Pod compromise additionally exposes its cluster-wide Secret-read grant |
| Grafana PV lost | User preferences and locally saved dashboards can be lost. Provisioned dashboards reload from ConfigMaps; Alertmanager silences use its own PV | Back up each application's state separately if those customisations or silences matter |

## Replacements / future

- **Apache Superset** — alternative open-source viz; weaker for time-
  series, stronger for SQL analytics. Not relevant for our
  metrics-heavy use case
- **Kibana** — Grafana's nearest equivalent in the Elasticsearch world.
  Overkill if we stick with Loki
- **Hosted Grafana Cloud** — same UI, vendor-managed. Worth considering
  if compliance allows shipping aggregate metrics outside infra

## Future enhancements

- Pipeline dashboard provisioning is implemented in `templates/observability.yaml`
  as of this 2026-11-10 review. A chart-provisioned Loki datasource remains
  a gap; configure UID `loki` manually until that integration is added.
- Drive the Service's NodePort from one key instead of two
- Site identity-provider integration is a future option. Check the deployed
  Grafana edition and its supported authentication features before choosing
  OAuth or SAML. Keep a controlled recovery login during an SSO migration.
- Per-team folder ACLs once multiple teams use the dashboards
- Image renderer plugin so alerts include rendered graphs in the email body
- Link out from PrometheusRule alerts to a deep-linked Grafana panel
  (annotations field in the Rule)
