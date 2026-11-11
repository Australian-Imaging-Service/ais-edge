# Alertmanager

## Overview

[Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/)
is the alert routing component that ships with the Prometheus operator.
Prometheus evaluates alert rules and posts firing alerts to Alertmanager,
which then deduplicates, groups, silences, and routes to receivers
(email, Slack, PagerDuty, webhooks, …).

## Role in this stack

**Review status (2026-11-10):** routing and storage claims below were checked against the branch templates and the rendered Alertmanager CR. Delivery through a site relay was not verified in this documentation review. A valid render does not prove a mounted password exists, a relay accepts it, or a message reaches an inbox.

The notification engine. Receives alerts from Prometheus when our
PrometheusRule files fire — and from Loki's ruler, which posts its
LogQL-derived alerts to the same Alertmanager — applies the routing
tree (a severity spine: critical → email + Slack, warning → email,
info → Slack when configured, otherwise email, with per-alertname overrides above it), and
sends the appropriate message to each configured receiver.

## What Alertmanager has access to

- **In-cluster network** — receives webhook posts from Prometheus, and from
  Loki's ruler, which is pointed at this same Service by
  `loki.loki.rulerConfig.alertmanager_url` in `charts/mgmt/values.yaml`
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
- The operator workload and Service names include the release name. The config
  Secret remains `alertmanager-aisedge-config`; it is explicitly named by this chart.
  Check the rendered CR before substituting names for another release
- UI access via Grafana → Alerts, or `kubectl port-forward` to port 9093

## Routing tree (configured in `charts/mgmt/files/alertmanager-config.yaml`)

**Current event semantics:** accessionflow 0.20.0 emits upload success after new files were uploaded or a repair was attempted. An unchanged session no longer emits success on every loop. A success line is a file-level verdict; it does not prove header reconciliation or downstream pipelines. The long repeat interval and session grouping remain useful notification guards. Historical duplicate-mail measurements below describe the older emitter, not the current one.

These sibling routes use the default or explicit `continue: false`. Alertmanager
stops at the first matching sibling, so their order matters. The config explains this at the
`SessionStagedNotConfirmedInXNAT` branch, which has to sit above
`severity=critical` because that alert *is* critical and would otherwise never
reach its own receiver.

```
route (root) ──► email-primary             every alert no branch below claims
   group_by: [alertname, cluster, session]     group_wait 30s
   └─ to: observability.alerting.emailTo       group_interval 5m / repeat 12h

 ├─ alertname =~ "Watchdog|InfoInhibitor" ──► null-meta
 │     Watchdog is always firing. InfoInhibitor fires when its info-alert
 │     condition matches; it is not a permanent heartbeat. Both are routed
 │     to null-meta, which has no notification integration. Historical
 │     routing before this branch mailed these meta-alerts; the incident
 │     date is not verified (2026-11-10). FIRST on purpose.
 ├─ alertname = "XNATUploaderRestarted" ──► email-no-resolved (repeat 24h)
 ├─ alertname = "XNATUploaderMemoryGrowing" ► email-primary (wait 2m, repeat 24h)
 ├─ alertname = "DICOMRejectedUnmappedAET" ──► email-no-resolved
 │     firing mail, never a "[RESOLVED]" one: the expression only measures
 │     "no new rejections in 5m", while the rejected studies sit in the
 │     quarantine directory until an operator maps the AET. Only the
 │     deprecated deid.engine: orthanc rejects; under ingest it never fires.
 ├─ alertname = "XNATUploadSuccess" ────────► email-upload-success
 │     group_by session, group_wait 10s, repeat_interval 720h. One mail per
 │     session event group while it remains firing. Version 0.20.0 suppresses
 │     unchanged-session success logs. The repeat guard does not promise
 │     exactly-once mail across a resolve/refire, state loss, or repair.
 ├─ alertname = "XNATRepairAttempted" ──────► email-xnat-repair
 │     group_by [alertname, cluster], group_wait 2m, group_interval 5m,
 │     repeat_interval 720h. XNAT was missing files and the uploader tried to
 │     re-send them. One firing-only mail per edge, because one XNAT restart
 │     repairs many sessions at once; 5m keeps a session repaired after the
 │     first mail inside the next one, before its ~10m alert resolves.
 ├─ alertname = "XNATResourceIncompleteAndStuck" ► email-primary (repeat 24h)
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

**Historical incident (date not verified, reviewed 2026-11-10):** before the
conditional-receiver fix, the Slack receivers were rendered
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

The chart derives route names and optional receiver definitions from the same
condition. This prevents a missing receiver definition; it cannot prove delivery.
When Slack is configured, its info route has no automatic email fallback if Slack
fails. The critical receiver sends to both integrations independently. Without
Slack configured, the chart selects email at render time. Keep a tested transport
and monitor notification failures; a valid receiver name alone is not sufficient.



(`NewEdgeJoined` has since been deleted from the rules — `changes()` over
kube-state-metrics' constant-valued `kube_node_info` is always 0, so it could
never fire. The `REMOVED` block in `charts/mgmt/files/prometheus-rules/info.yaml`
and `kube-state-metrics.md` carry the measurement. The two surviving info
alerts are the ones that were really at stake.)

Inhibit rules: when `ManagementClusterDown` fires, six named mgmt-plane
alerts are suppressed: `SeaweedFSDiskFull`, `CertificateExpiringSoon`,
`CARotationDue`, `CertificateRenewed`, `ReclaimerNotSucceeding` and
`KubeStateMetricsDown` (no point reporting cert-manager, SeaweedFS,
reclaimer or kube-state-metrics symptoms when the cluster they all run on is
gone).

A second rule holds `ReclaimerNotSucceeding` back while
`ReclaimerRunUnavailable` fires **for the same edge**. A reclaimer that cannot
reach XNAT logs why and fails every run, so both would otherwise fire for one
cause. This one does use `equal: ["cluster"]`, and unlike the old form below it
compares real values: `ReclaimerRunUnavailable` carries the edge's Loki stream
label, and `ReclaimerNotSucceeding` takes the edge from its CronJob name with
`label_replace`. Without the `equal`, one edge's outage would hide another
edge's silent failure. `scripts/ci/promtool.sh` fails if it goes, and if the
two labels stop agreeing on any rendered edge.

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
| `charts/mgmt/files/loki-ruler-rules.yaml` | the log-derived alerts (`DICOMRejectedUnmappedAET`, `XNATUploadSuccess`, `XNATRepairAttempted`, `SessionStagedNotConfirmedInXNAT`) that Loki's ruler posts to this same Alertmanager |

## Operations

The operator workloads below include the release name and use its namespace.
The chart-owned config Secret has the fixed name `alertmanager-aisedge-config`.
Substitute your release and namespace, then confirm names in the rendered CR.

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
- **Declarative config:** Helm updates the config Secret and the operator
  config-reloader applies it. Check the loaded config and reload success. Silence
  and notification state remain persistent and separate from that config
- **Multi-receiver support** — email, Slack, PagerDuty, OpsGenie,
  webhooks, …

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| SMTP relay unreachable | Notifications retry within the notification context; delivery is not durable queue storage | Configure and test an independent integration if required; Slack fan-out is not automatic failover. Monitor delivery-failure metrics |
| Slack webhook revoked | Slack notifications silently drop | Alertmanager logs the error; rotate the webhook Secret named by `observability.alerting.slackWebhookSecretRef` in `sites/<site>/secrets.enc.yaml`, re-apply it with `scripts/site-secrets.sh apply <site>`, then restart the StatefulSet. There is no `02d` script any more — steps 3 (site Secrets) and 4 (management chart) of `install.sh` replaced it |
| SMTP password leak | Attacker can send mail-as-us | Stored in the `alertmanager-smtp` Secret and mounted at `/etc/alertmanager/secrets/`, never templated into a manifest; rotate at the relay, then `scripts/site-secrets.sh edit <site>` + `apply <site>` and restart the StatefulSet |
| Inhibit rule too broad | Real alerts get hidden during an outage | Test rules in staging; the `ManagementClusterDown` rule only inhibits while it fires, and only the six alertnames it names, so it cannot widen by itself the way the old `severity =~ "warning\|info"` form could. The reclaimer rule matches per edge (`equal: ["cluster"]`), so one edge's outage never hides another's |
| Alertmanager pod restart | Brief delivery gap | StatefulSet replicas: 1 today; bump to 3 with peer config for HA |

## Replacements / future

- **PagerDuty / existing Opsgenie integrations:** external paging with on-call schedules.
  Receiver setup is separate from the shipped email routes. Opsgenie is a
  historical option for existing customers: new sales ended 2025-06-04 and
  support ends 2027-04-05. Plan migration before that date. See
  [Atlassian's lifecycle notice](https://www.atlassian.com/licensing/opsgenie).
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
- Route the existing always-firing `Watchdog` alert to a separate heartbeat
  receiver. It currently goes to `null-meta`, so its existence does not test
  SMTP delivery or prove that an operator received a message
