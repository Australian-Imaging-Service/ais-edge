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

**Loki is not among them, and the dashboards in
[`docs/dashboards.md`](../dashboards.md) are not shipped either.** Every query in
that document is LogQL, so a fresh install renders empty panels until you add
Loki by hand — in the UI, or as a ConfigMap in the release namespace labelled
`grafana_datasource: "1"`:

```
http://ais-loki.<namespace>.svc.cluster.local:3100
```

`ais-loki` is pinned by `loki.fullnameOverride` in `charts/edge/values.yaml`,
and it is the same address Vector pushes to — so a Vector that is shipping logs
has already proved the URL.

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
  cluster-wide read. It is the broadest grant in this chart; everything else
  runs with `automountToken: false` and no API access at all.
- **Persistent volume (5Gi, `local-path`)** for its embedded SQLite database
  (user prefs, dashboard versions, alert silences), PVC `<release>-grafana`
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
| `sites/<site>/values.yaml` | `observability.stack.enabled` — the gate. `observability.stack.grafana.nodePort` — the port `install.sh` prints. |
| `sites/<site>/secrets.enc.yaml` | Secret `grafana-admin-credentials` (keys `admin-user`, `admin-password`), SOPS-encrypted, in the release namespace |
| `charts/edge/values.yaml`, block `kube-prometheus-stack.grafana` | what the subchart is actually given: `admin.existingSecret`, `service.type: NodePort` + `nodePort`, `persistence`, `initChownData` |
| `charts/edge/charts/kube-prometheus-stack-87.19.2.tgz` | the vendored chart itself — Grafana, its sidecars and the Kubernetes dashboards |

**The port is stated in two places and only one of them opens it.**
`observability.stack.grafana.nodePort` is read by `install.sh` (to print the
URL) and by nothing in the chart; the Service's port comes from
`kube-prometheus-stack.grafana.service.nodePort`. Both ship as `30030`. Change
one and the installer's URL and the open port disagree, with no error from
either. The same is true of `observability.stack.grafana.persistence` and
`.existingSecret`: the values that reach Grafana are the ones under
`kube-prometheus-stack.grafana`.

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
the UI within ~30s and Grafana does not bounce.

## Adding a dashboard

The label is the whole mechanism:

```bash
kubectl -n xnat-ingest create configmap ais-dashboard-pipeline-overview \
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

# Restart (the sidecars normally pick up ConfigMap changes within ~30s;
# restart only to short-circuit that, or after changing the admin Secret)
kubectl -n xnat-ingest rollout restart deployment/<release>-grafana
```

## Benefits

- **The standard** — every site admin already knows Grafana; no training cost
- **Rich dashboard ecosystem** — community dashboards for Kubernetes already exist
- **Single UI for logs + metrics** — one place for the whole observability story
- **Apache 2.0** — no licence concerns

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| NodePort reachable on the LAN over plain HTTP | Anyone on the LAN who can reach the NodePort sees the login page | Keep the node on a trusted admin/LAN segment; set a strong admin password |
| Placeholder admin password shipped to site | Anyone who reaches Grafana logs in as admin | `admin-password` in `sites/<site>/secrets.enc.yaml` is `REPLACE_GRAFANA_PASSWORD` until you fill it; `install.sh` decrypts it to a pipe and refuses to run while any `REPLACE_` value survives (needs `sops` on PATH) |
| Admin password changed after first boot | Grafana keeps serving the old one — the Secret seeds the admin user when the SQLite DB is created, not on every start | Reset inside the pod (`grafana cli admin reset-admin-password`), or delete the PVC and let it re-initialise |
| Sidecar reads Secrets cluster-wide | A Grafana compromise reads every Secret on the node, including `xnat-credentials` and `orthanc-deid-salt` | Inherent to `NAMESPACE=ALL`; the same trust boundary as the node itself, which is single-tenant. Treat Grafana access as node access. |
| Dashboard ConfigMap collision | Any ConfigMap anywhere labelled `grafana_dashboard=1` is loaded | Single-tenant node; nothing else labels ConfigMaps that way |
| No Loki datasource on a fresh install | Every LogQL panel is empty, and it reads as "no logs" rather than "no datasource" | Add it (above), and confirm against Vector: same URL |
| Datasource credential leak | Read-only access to Prometheus/Loki/Alertmanager — no privilege escalation from there | Limited blast radius |
| PV lost | User prefs + alert silences gone, dashboards survive (they reload from ConfigMaps) | Backup PV if customisations matter |

## Replacements / future

- **Apache Superset** — alternative open-source viz; weaker for time-
  series, stronger for SQL analytics. Not relevant for our
  metrics-heavy use case
- **Kibana** — Grafana's nearest equivalent in the Elasticsearch world.
  Overkill if we stick with Loki
- **Hosted Grafana Cloud** — same UI, vendor-managed. Worth considering
  if compliance allows shipping aggregate metrics outside infra

## Future enhancements

- Ship the Loki datasource and the pipeline dashboards from `charts/edge` as
  labelled ConfigMaps, so a site gets them without a manual step
- Drive the Service's NodePort from one key instead of two
- SSO via UQ's identity provider (OAuth/SAML) — Grafana supports both;
  drop the local admin
- Per-team folder ACLs once multiple teams use the dashboards
- Image renderer plugin so alerts include rendered graphs in the email body
- Link out from PrometheusRule alerts to a deep-linked Grafana panel
  (annotations field in the Rule)
