# Alertmanager

## Overview

[Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/)
is the alert routing component that ships with the Prometheus operator.
Prometheus evaluates alert rules and posts firing alerts to Alertmanager,
which then deduplicates, groups, silences, and routes to receivers
(email, Slack, PagerDuty, webhooks, …).

## Role in this stack

The notification engine. Receives alerts from Prometheus when our
PrometheusRule files fire, applies the routing tree (severity-based:
critical → email + Slack, warning → email, info → Slack), and sends
the appropriate message to each configured receiver.

## What Alertmanager has access to

- **In-cluster network** — receives webhook posts from Prometheus
- **Outbound SMTP** to the `ALERT_SMTP_HOST` configured in
  `config/management.env`
- **Outbound HTTPS** to `ALERT_SLACK_WEBHOOK` if Slack is enabled
- **Persistent volume (2Gi)** for silence/notification state
- **A Secret** `alertmanager-aisedge-config` containing the rendered
  configuration (referenced by `alertmanagerSpec.configSecret`)

## Where it runs

- Cluster: management cluster only
- Namespace: `observability`
- Workload: StatefulSet `alertmanager-kube-prometheus-stack-alertmanager`
- Service: `kube-prometheus-stack-alertmanager.observability.svc:9093`
- UI access via Grafana → Alerts, or `kubectl port-forward` to port 9093

## Routing tree (configured in alertmanager-config.yaml.tpl)

```
default route ───► email-primary           (every unhandled alert)
                   └─ to: ${ALERT_EMAIL_TO}

severity=critical ─► email-and-slack       (paging severity)
                     ├─ to: ${ALERT_EMAIL_TO}
                     └─ slack: ${ALERT_SLACK_WEBHOOK}

severity=info     ─► slack-only            (lowest noise; skip email)
                     └─ slack: ${ALERT_SLACK_WEBHOOK}
```

Inhibit rules: when `ManagementClusterDown` fires, downstream
warning/info alerts on the same cluster are suppressed (no point
paging about pods being NotReady when the whole cluster is gone).

## Configuration

| File | Purpose |
|---|---|
| `manifests/01-management/observability/alertmanager-config.yaml.tpl` | rendered into the config Secret at install |
| `config/management.env` | `ALERT_EMAIL_TO`, `ALERT_EMAIL_FROM`, `ALERT_SMTP_*`, `ALERT_SLACK_WEBHOOK` |
| `manifests/01-management/observability/kube-prometheus-stack-values.yaml.tpl` | `alertmanagerSpec.configSecret = alertmanager-aisedge-config` |
| `manifests/01-management/observability/alerts/*.yaml` | the PrometheusRule files that produce the alerts (see `prometheus.md`) |

## Operations

```bash
# UI access
kubectl -n observability port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
xdg-open http://localhost:9093

# View loaded config (sanitised — passwords redacted in API)
curl -s http://localhost:9093/api/v2/status | jq .config

# View active alerts
curl -s http://localhost:9093/api/v2/alerts | jq

# Create a temporary silence (e.g. before maintenance)
amtool --alertmanager.url=http://localhost:9093 silence add \
  alertname=SeaweedFSDown --duration=30m --comment="planned restart"

# Rotate config (after editing the template or env vars)
bash scripts/02d-install-observability.sh   # recreates the Secret
kubectl -n observability rollout restart statefulset/alertmanager-kube-prometheus-stack-alertmanager
```

## Benefits

- **Native integration with Prometheus** — single source of truth for
  rules and routing, no glue layer
- **Inhibit / silence / group semantics** built in — avoids alert storms
- **Stateless config** — rotate by recreating the Secret + bouncing the pod
- **Multi-receiver support** — email, Slack, PagerDuty, OpsGenie,
  webhooks, …

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| SMTP relay unreachable | Alerts queue up; eventually drop after `notify.deadline` | Configure a fallback receiver (Slack); monitor Alertmanager's own metrics for delivery failures |
| Slack webhook revoked | Slack notifications silently drop | Alertmanager logs the error; rotate the webhook in `config/management.env` and re-run 02d |
| SMTP password leak | Attacker can send mail-as-us | Stored as Secret; rotate by editing config and re-running 02d |
| Inhibit rule too broad | Real alerts get hidden during an outage | Test rules in staging; the existing rule only inhibits when `ManagementClusterDown` is firing |
| Alertmanager pod restart | Brief delivery gap | StatefulSet replicas: 1 today; bump to 3 with peer config for HA |

## Replacements / future

- **PagerDuty / Opsgenie** — proper paging with on-call schedules.
  Receivers can be added to Alertmanager without replacing it
- **Sentry / Honeybadger** — error-aggregation tools. Different focus
  (application errors vs operational alerts); can run alongside
- **Webhook to a custom internal alerting service** — for sites that
  already have their own incident pipeline

## Future enhancements

- HA: 3 replicas with `alertmanagerSpec.replicas: 3` and gossip via
  the Service — only after the management cluster itself is HA
- Image-render attachments in Slack messages (a Grafana panel
  thumbnail next to the alert text)
- `amtool` integration into ops runbooks for one-line silence creation
- A periodic synthetic `Watchdog` alert that fires constantly so the
  receiver chain (SMTP → inbox) is tested continuously
