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
- Namespace: `observability`
- Workload: Deployment `kube-prometheus-stack-grafana`
- Service: `kube-prometheus-stack-grafana.observability.svc:80`
- External: nginx-ingress route `https://grafana.aisedge.local:443`
  (TLS-terminated, signed by ais-edge-ca)

## Configuration

| File | Purpose |
|---|---|
| `manifests/01-management/observability/kube-prometheus-stack-values.yaml.tpl` | helm values — datasources, sidecar, persistence, admin user from Secret |
| `manifests/01-management/observability/dashboards/*.json` | pre-built dashboards (loaded as ConfigMaps with `grafana_dashboard=1`) |
| `manifests/01-management/observability/observability-ingress.yaml.tpl` | nginx Ingress for `grafana.aisedge.local` |
| `manifests/01-management/observability/tls-certs.yaml.tpl` | `grafana-tls` Certificate |
| `config/management.env` | `GRAFANA_HOSTNAME`, `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD` |

The dashboard sidecar pattern: a tiny container watches all ConfigMaps
in the `observability` namespace with label `grafana_dashboard=1`, and
auto-loads/unloads them as Grafana JSON dashboards. Dropping a new
dashboard JSON in `dashboards/` and re-running 02d picks it up; no
Grafana restart needed.

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
kubectl -n observability get pod -l app.kubernetes.io/name=grafana

# Get the admin password (set at install from GRAFANA_ADMIN_PASSWORD)
kubectl -n observability get secret grafana-admin-credentials \
  -o jsonpath='{.data.admin-password}' | base64 -d ; echo

# Browser access (assumes /etc/hosts has grafana.aisedge.local → MGMT_IP)
xdg-open https://grafana.aisedge.local

# Force reload of dashboards (the sidecar normally picks up changes
# within ~30s; restart it to short-circuit)
kubectl -n observability rollout restart deployment/kube-prometheus-stack-grafana
```

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
| Default admin password unchanged | Anyone who reaches Grafana logs in as admin | Set `GRAFANA_ADMIN_PASSWORD` in `config/management.env` to a strong value before install |
| Datasource credential leak | Read-only access to Prometheus/Loki — no privilege escalation possible from there | Limited blast radius; rotate by re-running 02d |
| Dashboard ConfigMap collision | Another team accidentally labels a CM `grafana_dashboard=1` | Sidecar `searchNamespace` is scoped to `observability` only |
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
