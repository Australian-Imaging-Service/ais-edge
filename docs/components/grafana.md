# Grafana

## Overview

[Grafana](https://grafana.com/) is the visualisation and alerting UI of
the observability stack. It connects to Prometheus and Loki as data
sources and renders dashboards, ad-hoc queries (Explore), and alert
silences.

## Role in this stack

The single web UI for operators. Queries metrics from Prometheus and
logs from Loki, hosts pre-built dashboards, lets engineers explore the
data interactively while triaging an incident.

## What Grafana has access to

- **Prometheus** — read-only datasource at the in-cluster Service URL
- **Loki** — read-only datasource at the in-cluster Service URL
- **Cluster API** via its ServiceAccount (only to read its own
  configuration ConfigMaps + the dashboard ConfigMaps with the
  `grafana_dashboard=1` label — sidecar pattern)
- **Persistent volume (5Gi)** for its embedded SQLite database (user
  prefs, dashboard versions, alert silences)
- **NO direct cluster mutation rights**

## Where it runs

- Cluster: management cluster only
- Namespace: `ais-mgmt` — the management release's own namespace. Grafana
  arrives as part of the `kube-prometheus-stack` subchart, so it inherits the
  parent's namespace; there is no `namespaceOverride`.
- Workload: Deployment `mgmt-grafana`. **Release-derived, not a literal.**
  `charts/mgmt/templates/observability.yaml` computes the Ingress backend as
  `printf "%s-grafana" .Release.Name` precisely so the two cannot drift.
- Service: `mgmt-grafana.ais-mgmt.svc:80`
- External: nginx-ingress route `https://grafana.aisedge.local:443`
  (TLS-terminated, signed by ais-edge-ca)

`observability` and `kube-prometheus-stack-grafana` were the **old shell
installer's** namespace and release name. Nothing installs under them now, and
a `kubectl` aimed there returns "No resources found" — which reads exactly like
a Grafana that failed to come up.

## Configuration

| File | Purpose |
|---|---|
| `charts/mgmt/values.yaml` (`kube-prometheus-stack:`) | helm values — datasources, sidecar, persistence, admin user from Secret |
| `charts/mgmt/files/dashboards/*.json` | pre-built dashboards (loaded as ConfigMaps with `grafana_dashboard=1`) |
| `charts/mgmt/templates/observability.yaml` | Ingress for `grafana.aisedge.local`, `grafana-tls` Certificate |
| `sites/<site>/values.yaml` | `hostnames.grafana` |
| `sites/<site>/secrets.enc.yaml` | the `grafana-admin-credentials` Secret — `admin-user`, `admin-password`; named by `observability.grafana.adminSecretRef` |

The dashboard sidecar pattern: a tiny container watches ConfigMaps with the
label `grafana_dashboard=1` and auto-loads/unloads them as Grafana JSON
dashboards. `searchNamespace` is **not set** in `charts/mgmt/values.yaml`
(only `sidecar.dashboards.label`, `labelValue` and `folderAnnotation` are), so
the sidecar falls back to its own namespace — `ais-mgmt`. That is the whole
scope: a labelled ConfigMap in any other namespace is invisible to it.

Dropping a new dashboard JSON into `charts/mgmt/files/dashboards/` and running
`helm upgrade` picks it up; no Grafana restart needed. The chart renders one
labelled ConfigMap per file, so adding the file is the whole change. There is
no `02d` script any more — `install.sh` steps 4 and 7 replaced it.

## Pre-built dashboards

| File | What it shows |
|---|---|
| `pipeline-overview.json` | files received / staged / uploaded / failed per hour, per edge |
| `session-timeline.json` | enter a session name → timeline of every related log event |
| `seaweedfs-health.json` | bucket size, S3 request rate by status, log tail |
| `edge-drilldown.json` | pick edge → CPU/mem, restart count, last upload, live log tail |

## Operations

```bash
# Pod state
kubectl -n ais-mgmt get pod -l app.kubernetes.io/name=grafana

# Read back the admin password. It is NOT an install-time environment
# variable — it comes from the `grafana-admin-credentials` Secret you wrote
# into sites/<site>/secrets.enc.yaml and applied with
# `scripts/site-secrets.sh apply <site>`. Keys: admin-user, admin-password.
kubectl -n ais-mgmt get secret grafana-admin-credentials \
  -o jsonpath='{.data.admin-password}' | base64 -d ; echo

# Browser access (assumes /etc/hosts has grafana.aisedge.local → MGMT_IP)
xdg-open https://grafana.aisedge.local

# Force reload of dashboards (the sidecar normally picks up changes
# within ~30s; restart it to short-circuit)
kubectl -n ais-mgmt rollout restart deployment/mgmt-grafana
```

The chart cross-checks the two halves of the credential wiring and refuses to
render if they disagree: `kube-prometheus-stack.grafana.admin.existingSecret`
must equal `observability.grafana.adminSecretRef`. Without that guard a typo
would let Grafana come up with the subchart's *generated random password*,
which nobody has and nothing reports.

## Benefits

- **The standard** — every site admin already knows Grafana; no training cost
- **Rich dashboard ecosystem** — community dashboards for Kubernetes,
  cert-manager, nginx-ingress already exist
- **Single UI for logs + metrics + traces** — one place for the whole
  observability story
- **Apache 2.0** — no licence concerns

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| Browser-side: self-signed CA | Browsers warn unless ais-edge-ca.crt installed in trust store | Distribute the CA cert to operators along with the kubeconfig |
| Default admin password unchanged | Anyone who reaches Grafana logs in as admin | Set `admin-password` to a strong value in the `grafana-admin-credentials` Secret in `sites/<site>/secrets.enc.yaml` **before install**, then `scripts/site-secrets.sh encrypt <site>` and `scripts/site-secrets.sh apply <site>`. The file is SOPS-encrypted at rest, so the strong value is safe to commit |
| Datasource credential leak | Read-only access to Prometheus/Loki — no privilege escalation possible from there | Limited blast radius. Both datasources are provisioned by the chart, so rotation is `helm upgrade`, not a script; there is no `02d` any more |
| Dashboard ConfigMap collision | Another team accidentally labels a CM `grafana_dashboard=1` | The sidecar watches **its own namespace only** — `searchNamespace` is unset, so it defaults to `ais-mgmt`. That is narrower than it looks: anything a workload in `ais-mgmt` labels this way is imported, and anything correctly labelled elsewhere is silently ignored |
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

- SSO via UQ's identity provider (OAuth/SAML) — Grafana supports both;
  drop the local admin
- Per-team folder ACLs once multiple teams use the dashboards
- Image renderer plugin so alerts include rendered graphs in the email body
- Link out from PrometheusRule alerts to a deep-linked Grafana panel
  (annotations field in the Rule)
