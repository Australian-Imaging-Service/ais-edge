# Alertmanager

## Overview

[Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/)
is the alert routing component that ships with the Prometheus operator.
Prometheus evaluates alert rules and posts firing alerts to Alertmanager,
which then deduplicates, groups, silences, and routes to receivers
(email, Slack, PagerDuty, webhooks, …).

## Role in this stack

The notification engine. Receives alerts from Prometheus when our
PrometheusRule files fire — and from Loki's ruler, which posts its
LogQL-derived alerts to the same Alertmanager — applies the routing
tree (a severity spine: critical → email + Slack, warning → email,
info → Slack, with per-alertname overrides sitting *above* it), and
sends the appropriate message to each configured receiver.

## What Alertmanager has access to

- **In-cluster network** — receives webhook posts from Prometheus, and from
  Loki's ruler, which is pointed at this same Service by
  `loki.rulerConfig.alertmanager_url` in `charts/mgmt/values.yaml`
- **Outbound SMTP** to `observability.alerting.smtpHost` / `.smtpPort`, set in
  `sites/<site>/values.yaml`. Those are *not* environment variables: the
  config file ships with `__ALERT_SMTP_HOST__`-shaped sentinels and
  `charts/mgmt/templates/observability.yaml` substitutes the site's values in
  with `replace` at render time. The old shell installer's `ALERT_SMTP_HOST` /
  `ALERT_EMAIL_TO` env vars no longer exist anywhere
- **Outbound HTTPS** to Slack when `observability.alerting.slackWebhookSecretRef`
  names a Secret. The webhook URL is never a value in the config — it is a
  *path*, `/etc/alertmanager/secrets/<secretRef>/webhook-url`, read from the
  mounted Secret at send time via `api_url_file`
- **The mounted `alertmanager-smtp` Secret** (`observability.alerting.smtpSecretRef`)
  at `/etc/alertmanager/secrets/alertmanager-smtp/password`, read through
  `smtp_auth_password_file` so the relay password is never templated into a
  manifest. Alertmanager has no `_username_file` equivalent, which is why
  `observability.alerting.smtpUsername` is a plain value in the site file
- **Persistent volume (2Gi)** for silence/notification state
- **A Secret** `alertmanager-aisedge-config` containing the rendered
  configuration (referenced by `alertmanagerSpec.configSecret`)

## Where it runs

- Cluster: management cluster only
- Namespace: `ais-mgmt` — the release namespace. kube-prometheus-stack is a
  **subchart** of `charts/mgmt` (release `mgmt`, namespace `ais-mgmt`, both
  set in `install.sh`), so its objects are release-prefixed and land beside
  the rest of the stack. There is no `observability` namespace any more; it
  was the old shell installer's layout and `scripts/uninstall.sh` now treats
  it as legacy to garbage-collect
- Workload: StatefulSet `alertmanager-mgmt-kube-prometheus-stack-alertmanager`
  — the operator names the StatefulSet `alertmanager-<Alertmanager CR>`, and
  the CR is `mgmt-kube-prometheus-stack-alertmanager`
- Service: `mgmt-kube-prometheus-stack-alertmanager.ais-mgmt.svc:9093`
- Every name above carries the release name. Install under a different release
  and the prefix changes with it
- UI access via Grafana → Alerts, or `kubectl port-forward` to port 9093

## Routing tree (configured in `charts/mgmt/files/alertmanager-config.yaml`)

Alertmanager takes the **first matching route**, top to bottom, so the order
below is load-bearing rather than presentational — the config says so at the
`SessionStagedNotConfirmedInXNAT` branch, which has to sit above
`severity=critical` because that alert *is* critical and would otherwise never
reach its own receiver.

```
route (root) ──► email-primary             every alert no branch below claims
   group_by: [alertname, cluster, session]     group_wait 30s
   └─ to: observability.alerting.emailTo       group_interval 5m / repeat 12h

 ├─ alertname =~ "Watchdog|InfoInhibitor" ──► null-meta
 │     kube-prometheus-stack's own meta-alerts. Both fire permanently by
 │     design and carry severity="none", which matches no severity route, so
 │     before this branch existed they fell through to the ROOT receiver and
 │     mailed the operator forever. `null-meta` is a receiver with a name and
 │     no *_configs — Alertmanager's null sink. FIRST on purpose.
 ├─ alertname = "DICOMRejectedUnmappedAET" ──► email-no-resolved
 │     firing mail, never a "[RESOLVED]" one: the expression only measures
 │     "no new rejections in 5m", while the rejected studies sit in the
 │     quarantine directory until an operator maps the AET.
 ├─ alertname = "XNATUploadSuccess" ────────► email-upload-success
 │     group_by session, group_wait 10s, repeat_interval 720h. One mail per
 │     session that lands in XNAT; the uploader re-logs success on every
 │     --loop pass, so any shorter repeat is just mail about an upload that
 │     already worked.
 ├─ severity = "info" ──────────────────────► slack-only   (Slack configured)
 │                                            info-email   (no Slack)
 │     repeat_interval 720h. CARotationDue trips at T-365d and stays firing
 │     until the CA is rotated, so the inherited 12h meant ~730 notifications
 │     about one unchanged fact.
 ├─ alertname = "SessionStagedNotConfirmedInXNAT" ──► email-no-resolved
 │     grouped per session, repeat 24h. MUST PRECEDE the critical route.
 │     Firing-only for the same reason as DICOMRejectedUnmappedAET: its
 │     series stops existing 72h after the reclaimer last saw the session,
 │     so "resolved" would mean "the window slid", not "the data arrived".
 ├─ severity = "critical" ──────────────────► email-and-slack (Slack configured)
 │                                            email-primary   (no Slack)
 └─ severity = "warning" ───────────────────► email-primary
       group_wait 2m / group_interval 30m / repeat_interval 24h. Warnings had
       no route of their own and inherited the root's 30s/5m/12h with
       send_resolved: true, so a self-healing transient cost two mails and
       warning volume could not be tuned without changing critical behaviour.
```

**Slack is optional, which is why two of those branches name two receivers.**
With `observability.alerting.slackWebhookSecretRef` empty, the Helm chart does
not render the Slack receivers at all and both routes fall back to email:

```
severity=critical ─► email-primary
severity=info     ─► info-email            (send_resolved: false,
                     └─ to: emailTo              repeat_interval: 720h)
```

The receiver *names* in the routes and the receiver *definitions* come from
the same `if` in `charts/mgmt/templates/observability.yaml`: the Slack
receivers are spliced in from `charts/mgmt/files/alertmanager-slack-receivers.yaml`
at a sentinel, and two more sentinels choose which receiver the info and
critical routes name. Deriving all three from one condition is the point — a
route naming an absent receiver is rejected by Alertmanager at config load,
so the two cannot drift apart.

This is not cosmetic. Until it was fixed, the Slack receivers were rendered
unconditionally with `api_url_file` pointing at a Secret nothing creates.
Alertmanager reads that file at send time and treats ENOENT as *unrecoverable*
— one attempt, no retry, no fallback — so on a site without Slack every
`severity=info` alert (`CARotationDue`, `CertificateRenewed`, and at the time
`NewEdgeJoined`) was discarded, leaving only an `ERROR` line in the
Alertmanager pod log:

```
msg="Notify for alerts failed" err="slack-only/slack[0]: notify retry canceled
due to unrecoverable error after 1 attempts: open
/etc/alertmanager/secrets/slack-not-configured/webhook-url: no such file or
directory"
```

`severity=critical` kept working because integrations within a receiver fan out
independently, so the email half still sent — but every critical notification
was also recorded as failed, which is the wrong reading for
`alertmanager_notifications_failed_total`.

The rule the config now holds to: **no route may name a receiver that cannot
deliver.** Falling back to email rather than to a null receiver is chosen
because losing a CA-rotation warning is not recoverable and an extra message a
month is; the volume that motivated splitting info off email is handled by the
fallback receiver's shape (no resolved mail, 720h repeat) rather than by
dropping the alert.

(`NewEdgeJoined` has since been deleted from the rules — `changes()` over
kube-state-metrics' constant-valued `kube_node_info` is always 0, so it could
never fire. The `REMOVED` block in `charts/mgmt/files/prometheus-rules/info.yaml`
and `kube-state-metrics.md` carry the measurement. The two surviving info
alerts are the ones that were really at stake.)

Inhibit rules: when `ManagementClusterDown` fires, four named mgmt-plane
alerts are suppressed — `SeaweedFSDiskFull`, `CertificateExpiringSoon`,
`CARotationDue`, `CertificateRenewed` (no point reporting cert-manager or
SeaweedFS symptoms when the cluster they both run on is gone).

That list is exhaustive **by alertname on purpose**, and the shape matters as
much as the contents. It used to be `severity =~ "warning|info"` scoped by
`equal: ["cluster"]`, which only ever worked by accident: nothing in this stack
sets a `cluster` label on either side of that comparison — the Prometheus rules
here never set one statically and none of the underlying metrics (KSM,
cert-manager, SeaweedFS) carry one — and Alertmanager treats an absent label as
the empty string, so both sides compared `"" == ""`. It would have silently
stopped inhibiting the day either side gained a real cluster label. Matching
explicit alertnames also stops the rule reaching into a Loki-sourced
`severity=info` alert about an *edge* (`XNATUploadSuccess`) just because a
severity regex happened to match. The cost is upkeep: a new mgmt-plane
warning/info alert has to be added to the list by hand, because there is no
longer a pattern to fall back on.

## Configuration

| File | Purpose |
|---|---|
| `charts/mgmt/files/alertmanager-config.yaml` | the whole config, sentinels and all; rendered into the config Secret at install |
| `charts/mgmt/files/alertmanager-slack-receivers.yaml` | the two Slack receivers, spliced into the file above only when a webhook Secret is named |
| `charts/mgmt/templates/observability.yaml` | loads both files with `.Files.Get`, substitutes the `__ALERT_*__` sentinels from the site values, and emits Secret `alertmanager-aisedge-config` |
| `sites/<site>/values.yaml` | `observability.alerting.emailTo`, `.emailFrom`, `.smtpHost`, `.smtpPort`, `.smtpUsername`, `.smtpRequireTLS`, `.slackWebhookSecretRef` |
| `sites/<site>/secrets.enc.yaml` | the `alertmanager-smtp` Secret (`username`, `password`) named by `.smtpSecretRef`, and a Slack webhook Secret (key `webhook-url`) named by `.slackWebhookSecretRef` |
| `charts/mgmt/values.yaml` (`kube-prometheus-stack:`) | `alertmanagerSpec.configSecret = alertmanager-aisedge-config`, `alertmanagerSpec.secrets` (which Secrets get mounted under `/etc/alertmanager/secrets/`), and `retention: 744h` — which must exceed the longest `repeat_interval` in the config |
| `charts/mgmt/files/prometheus-rules/*.yaml` | the PrometheusRule files that produce the alerts (see `prometheus.md`) |
| `charts/mgmt/files/loki-ruler-rules.yaml` | the log-derived alerts (`DICOMRejectedUnmappedAET`, `XNATUploadSuccess`, `SessionStagedNotConfirmedInXNAT`) that Loki's ruler posts to this same Alertmanager |

## Operations

Every object below is release-prefixed and lives in the release namespace,
because kube-prometheus-stack is a subchart of `charts/mgmt`. Substitute your
own release name if it is not `mgmt`.

```bash
# UI access
kubectl -n ais-mgmt port-forward svc/mgmt-kube-prometheus-stack-alertmanager 9093:9093
xdg-open http://localhost:9093

# View loaded config (sanitised — passwords redacted in API)
curl -s http://localhost:9093/api/v2/status | jq .config

# View active alerts
curl -s http://localhost:9093/api/v2/alerts | jq

# Create a temporary silence (e.g. before maintenance)
amtool --alertmanager.url=http://localhost:9093 silence add \
  alertname=SeaweedFSDown --duration=30m --comment="planned restart"

# Rotate config (after editing files/alertmanager-config.yaml or the site's
# observability.alerting.* values)
helm upgrade mgmt charts/mgmt -n ais-mgmt -f sites/<site>/values.yaml   # recreates the Secret
kubectl -n ais-mgmt rollout restart statefulset/alertmanager-mgmt-kube-prometheus-stack-alertmanager

# Rotate a CREDENTIAL (SMTP password, Slack webhook) — the Secrets are applied
# from SOPS, not by Helm, so the chart upgrade above does not carry them
scripts/site-secrets.sh edit <site>     # decrypt to $EDITOR, re-encrypt on save
scripts/site-secrets.sh apply <site>    # decrypt straight into the cluster
kubectl -n ais-mgmt rollout restart statefulset/alertmanager-mgmt-kube-prometheus-stack-alertmanager

# Check the config the pod actually loaded, including which receiver won the
# info/critical sentinels on this site
kubectl -n ais-mgmt get secret alertmanager-aisedge-config \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | grep -n 'receiver:'
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
| Slack webhook revoked | Slack notifications silently drop | Alertmanager logs the error; rotate the webhook Secret named by `observability.alerting.slackWebhookSecretRef` in `sites/<site>/secrets.enc.yaml`, re-apply it with `scripts/site-secrets.sh apply <site>`, then restart the StatefulSet. There is no `02d` script any more — steps 3 (site Secrets) and 4 (management chart) of `install.sh` replaced it |
| SMTP password leak | Attacker can send mail-as-us | Stored in the `alertmanager-smtp` Secret and mounted at `/etc/alertmanager/secrets/`, never templated into a manifest; rotate at the relay, then `scripts/site-secrets.sh edit <site>` + `apply <site>` and restart the StatefulSet |
| Inhibit rule too broad | Real alerts get hidden during an outage | Test rules in staging; the existing rule only inhibits when `ManagementClusterDown` is firing, and only the four alertnames it names — it cannot widen by itself the way the old `severity =~ "warning\|info"` form could |
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
