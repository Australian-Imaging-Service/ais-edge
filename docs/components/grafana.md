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
- **Cluster API** via its ServiceAccount and ClusterRole. The rendered
  role grants `get`, `watch` and `list` on ConfigMaps and Secrets across
  the cluster. Label filtering in a sidecar does not narrow those RBAC grants.
- **Persistent volume (5Gi)** for its embedded SQLite database (user
  preferences and dashboard state). Alertmanager owns its own silences
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

The dashboard sidecar watches objects labelled `grafana_dashboard=1`. The
parent chart does not set `searchNamespace`, but the vendored stack supplies
`ALL`. The rendered container has `NAMESPACE=ALL` and `RESOURCE=both`, so it
reads labelled ConfigMaps and Secrets in every namespace. The datasource
sidecar has no `NAMESPACE` override and watches its own namespace. Both share
the same broader ClusterRole. Verify the rendered Pod and RBAC after a chart
upgrade instead of inferring scope from an omitted parent value.

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
# after its watch/reload completes (latency not verified 2026-11-10); restart it to short-circuit)
kubectl -n ais-mgmt rollout restart deployment/mgmt-grafana
```

The chart cross-checks the two halves of the credential wiring and refuses to
render if they disagree: `kube-prometheus-stack.grafana.admin.existingSecret`
must equal `observability.grafana.adminSecretRef`. Without that guard a typo
would let Grafana come up with the subchart's *generated random password*,
which nobody has and nothing reports.

## Benefits

- **Familiar interface** for many operators. Site staff still need an
  introduction to these dashboards, datasource selection and alert routing.
- **Rich dashboard ecosystem** — community dashboards for Kubernetes,
  cert-manager, nginx-ingress already exist
- **Single UI for logs and metrics.** These datasources are provisioned here;
  the chart does not configure a trace backend. Do not expect trace panels
  to work without a separate reviewed integration.
- **Open-source Grafana uses AGPLv3.** The old Apache 2.0 description is
  historical (before the 2021 licence change). Review the deployed edition
  and [upstream licensing](https://grafana.com/licensing/) for its terms.

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| Browser-side: self-signed CA | Browsers warn unless ais-edge-ca.crt installed in trust store | Distribute the CA cert to operators along with the kubeconfig |
| Default admin password unchanged | Anyone who reaches Grafana logs in as admin | Set `admin-password` to a strong value in the `grafana-admin-credentials` Secret in `sites/<site>/secrets.enc.yaml` **before install**, then `scripts/site-secrets.sh encrypt <site>` and `scripts/site-secrets.sh apply <site>`. The file is SOPS-encrypted at rest, so the strong value is safe to commit |
| Datasource or Grafana compromise | Logs and metrics can contain sensitive values. The Grafana ServiceAccount can also read Secrets cluster-wide | Inspect datasource access and the rendered ClusterRole separately. Reconcile chart-managed datasource settings with Helm; rotate any affected credentials through their owning Secrets and restart the consumers that cache them |
| Dashboard ConfigMap collision | A labelled ConfigMap or Secret in any namespace can be loaded | The rendered dashboard sidecar watches `ALL` namespaces and both resource kinds. Control who can create these objects. Namespace placement alone does not isolate dashboard content from this Grafana instance |
| Grafana PV lost | User preferences and locally saved dashboards can be lost. Provisioned dashboards reload from ConfigMaps; Alertmanager silences belong to its separate storage | Back up Grafana state if local customisations matter, and back up Alertmanager state separately |

## Replacements / future

- **Apache Superset** — alternative open-source viz; weaker for time-
  series, stronger for SQL analytics. Not relevant for our
  metrics-heavy use case
- **Kibana** — Grafana's nearest equivalent in the Elasticsearch world.
  Overkill if we stick with Loki
- **Hosted Grafana Cloud** — same UI, vendor-managed. Worth considering
  if compliance allows shipping aggregate metrics outside infra

## Future enhancements

- Site identity-provider integration is a future option. Check the deployed
  Grafana edition and its supported authentication features before choosing
  OAuth or SAML. Keep a controlled recovery login during an SSO migration.
- Per-team folder ACLs once multiple teams use the dashboards
- Image renderer plugin so alerts include rendered graphs in the email body
- Link out from PrometheusRule alerts to a deep-linked Grafana panel
  (annotations field in the Rule)
