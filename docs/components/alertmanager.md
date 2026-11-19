# Alertmanager

## Overview

[Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/)
is the alert routing component that ships with the Prometheus operator.
Prometheus evaluates alert rules and posts firing alerts to Alertmanager,
which then deduplicates, groups, silences, and routes to receivers
(email, Slack, PagerDuty, webhooks, …).

## Role in this stack

**Review status (2026-11-10):** routing and storage claims below were checked against the branch templates and the rendered Alertmanager CR. Delivery through a site relay was not verified in this documentation review. A valid render does not prove a mounted password exists, a relay accepts it, or a message reaches an inbox.

The notification engine, and the single place both rule engines converge:
Prometheus posts K8s-state alerts from its `PrometheusRule` objects, and
Loki's ruler posts the LogQL pipeline alerts over the same v2 API. Alertmanager
deduplicates, groups, applies inhibition and silences, and hands what is left to
a receiver.

Alertmanager is not a release of its own. It is part of the **vendored
`kube-prometheus-stack` subchart of `charts/edge`** — 87.19.2, Alertmanager
v0.33.1, shipped as
[`charts/edge/charts/kube-prometheus-stack-87.19.2.tgz`](../../charts/edge/charts/)
and gated on `observability.stack.enabled`. There is no `helm repo add` and no
`helm dependency update` at install time.

**`observability.stack.enabled` is not `observability.enabled`.** The first
decides whether this node *hosts* Prometheus, Alertmanager, Loki and Grafana;
the second only decides whether Vector runs. Both default to false, and the
first must: Helm treats a dependency whose `condition:` path does not resolve as
ENABLED.

## What Alertmanager has access to

- **In-cluster network** — receives alerts from Prometheus (the Prometheus CR
  names `ais-kps-alertmanager`, port `http-web`, `apiVersion: v2`) and from
  Loki's ruler (`loki.loki.rulerConfig.alertmanager_url`,
  `enable_alertmanager_v2: true`)
- **A PersistentVolume (5Gi, `local-path`)** for silences and the notification
  log, so a pod restart does not re-notify everything or lose an active silence
- **Its config Secret** `alertmanager-aisedge-config` (key `alertmanager.yaml`),
  rendered by **this chart** in
  [`charts/edge/templates/observability.yaml`](../../charts/edge/templates/observability.yaml)
  and named to the operator through
  `kube-prometheus-stack.alertmanager.alertmanagerSpec.configSecret`. The
  subchart still renders its own `alertmanager-ais-kps-alertmanager` Secret —
  that is the operator's default name — but **nothing mounts it**: the rendered
  `Alertmanager` CR carries `configSecret: alertmanager-aisedge-config` and
  `secrets: [alertmanager-smtp]`. Decoding the subchart's leftover is the
  standard way to conclude that this release routes everything to a null
  receiver when it does not
- **Outbound SMTP — but only once the site fills in its mail facts.** The
  shipped config *does* define email receivers and an SMTP relay:
  `global.smtp_smarthost` is built from `observability.stack.alerting.smtpHost`
  and `smtpPort`, and every receiver mails
  `observability.stack.alerting.emailTo`. Both default to **empty**, which
  renders a smarthost of `:587` and a `to:` of `""` — the config loads, the
  routing tree works, and nothing is delivered. So the accurate statement is
  "no outbound network *until `emailTo` and `smtpHost` are set*", not "no
  receiver exists". The SMTP password reaches the pod only through the
  `alertmanager-smtp` Secret mount (below), never through the config

## Where it runs

- Cluster: the single-node cluster
- Namespace: the release namespace — **`xnat-ingest`**, the same namespace as
  the pipeline. There is no separate `observability` namespace; the whole
  appliance is one release in one namespace.
- Workload: Alertmanager CR `ais-kps-alertmanager` (1 replica); the
  prometheus-operator turns it into StatefulSet
  `alertmanager-ais-kps-alertmanager`
- Service: `ais-kps-alertmanager.xnat-ingest.svc.cluster.local:9093`
  (port name `http-web`; `8080`/`reloader-web` is the config-reloader sidecar)
- `retention: 120h` is the shipped notification-state retention. **Open mismatch
  (2026-11-10):** this is shorter than the 720h repeat intervals in the routes.
  Alertmanager can repeat after state retention expires; the 30-day interval
  is therefore not a 30-day guarantee on this tier. Main uses 744h. This review
  records the mismatch and does not change runtime retention
- No ingress on tier-1. Reach it through Grafana → Alerting
  (`http://<nodeIP>:30030`; kube-prometheus-stack provisions an `Alertmanager`
  datasource with `handleGrafanaManagedAlerts: false`, so what you see is this
  Alertmanager and not Grafana's own), or `kubectl port-forward` to 9093.

**`ais-kps-alertmanager` is a pinned name, not the release name.**
`kube-prometheus-stack.fullnameOverride: ais-kps` in
[`charts/edge/values.yaml`](../../charts/edge/values.yaml) is what makes it so,
and Loki's ruler names it *literally* — see
[`components/loki.md`](loki.md) and
[`alerting-architecture.md`](../alerting-architecture.md). Un-overridden it would
be `<release>-kube-prometheus-stack-alertmanager`, and pointing the ruler at a
name that does not resolve fails silently: Loki healthy, rules loaded, dashboards
green, no LogQL alert ever delivered.

## What the shipped configuration actually does

**Current event semantics:** accessionflow 0.20.0 emits upload success after new files were uploaded or a repair was attempted. An unchanged session no longer emits success on every loop. A success line is a file-level verdict; it does not prove header reconciliation or downstream pipelines. The long repeat interval and session grouping remain useful notification guards. Historical duplicate-mail measurements below describe the older emitter, not the current one.

`charts/edge` does **not** leave Alertmanager on the subchart default. It points
`kube-prometheus-stack.alertmanager.alertmanagerSpec.configSecret` at
`alertmanager-aisedge-config` and renders that Secret itself, in
`templates/observability.yaml`, from
[`charts/edge/files/alertmanager-config.yaml`](../../charts/edge/files/alertmanager-config.yaml).

That file is read with `.Files.Get` and is **never** run through `tpl`, on
purpose. It is full of Alertmanager's own `{{ }}` notification templates
(`{{ .CommonLabels.session }}`, `{{ range .Alerts }}`), and Helm's delimiters are
identical: evaluating them against the *chart* context finds no `.CommonLabels`,
can consume them incorrectly or fail the Helm render. Do not depend on a
particular failure shape; keep notification templates opaque to Helm. The values the installer does need to
inject are written as `__SENTINEL__` tokens and substituted with `replace`, a
blind string operation that cannot see, and cannot eat, a Go template.

The routing tree it installs:

```
route (group_by: [alertname, cluster, session], group_wait 30s,
       group_interval 5m, repeat_interval 12h, receiver: email-primary)
  ├─ alertname=~"Watchdog|InfoInhibitor"       → null-meta   ← FIRST in the list
  ├─ alertname=XNATUploaderRestarted          → email-no-resolved (repeat 24h)
  ├─ alertname=XNATUploaderMemoryGrowing      → email-primary (wait 2m, repeat 24h)
  ├─ alertname=DICOMRejectedUnmappedAET        → email-no-resolved
  ├─ alertname=XNATUploadSuccess               → email-upload-success
  │                                              (group_wait 10s, repeat 720h)
  ├─ alertname=XNATRepairAttempted             → email-xnat-repair
  │                                              (group_by [alertname, cluster],
  │                                               group_wait 2m, group_interval
  │                                               5m, repeat 720h)
  ├─ severity=info                             → info-email  (repeat 720h)
  ├─ alertname=SessionStagedNotConfirmedInXNAT → email-no-resolved (repeat 24h)
  ├─ severity=critical                         → email-primary
  ├─ severity=warning                          → email-primary
  │                                              (group_wait 2m, group_interval
  │                                               30m, repeat 24h)
  └─ anything unmatched                        → email-primary (root receiver)

receivers:
  email-primary         to: <emailTo>, send_resolved: true
  email-no-resolved     to: <emailTo>, send_resolved: false
  email-upload-success  to: <emailTo>, Subject "XNAT upload completed — <session>"
  email-xnat-repair     to: <emailTo>, send_resolved: false,
                        Subject "XNAT was missing files; <cluster> tried to re-send them"
  info-email            to: <emailTo>, Subject "AIS-Edge [info]: <alertname>"
  null-meta             no *_configs at all — Alertmanager's null sink

inhibit_rules:
  alertname=KubernetesAPIServerDown  inhibits  alertname=NodeNotReady
  alertname=ReclaimerRunUnavailable  inhibits  alertname=ReclaimerNotSucceeding
```

**`null-meta` is the only null receiver here, and it is deliberate.** `Watchdog`
and `InfoInhibitor` are meta-alerts. Watchdog is always firing; InfoInhibitor
fires only when its info-alert condition matches. Historical routing before the
null-meta fix mailed these alerts through the root receiver (incident date not
verified, reviewed 2026-11-10). The first route now sends them to an empty
receiver. Keep that intentional sink unless a tested heartbeat service replaces
it. Other routes use email integrations, whose delivery still needs verification.



**Two routes deliberately never send a `[RESOLVED]` follow-up**, because for them
"resolved" would be a lie. `DICOMRejectedUnmappedAET` clears when no *new*
rejection has been seen for five minutes. It is a legacy-engine event, not an
ingest routing signal. Retained quarantine data can remain after that window
expires. See the [deprecated reference](deidentification.md#deprecated-orthanc-lua-engine)
for existing sites; do not infer recovery from an alert clearing. `SessionStagedNotConfirmedInXNAT` clears when its window
slides past the last time the reclaimer saw the session, whether or not the data
ever arrived; a historical resolve mail on 2026-08-09 was recorded while a session was absent
from XNAT. That session's present state is not verified (2026-11-10). Loki
evaluates logs and Alertmanager receives alerts; neither directly inspects the
retained session files. A quiet event window is not evidence of recovery.

**The `severity=info` receiver is chosen by a sentinel, and on tier-1 it resolves
to `info-email`.** `templates/observability.yaml` substitutes Slack receivers
into the config only when a webhook Secret is configured; on this tier it
substitutes the empty string, so info alerts go to email rather than to a Slack
receiver that could not deliver. That failure mode is not hypothetical: the Slack
receivers used to be defined unconditionally with `api_url_file` pointing at a
Secret nothing created, and Alertmanager treats that ENOENT as unrecoverable at
send time — `severity=info` alerts were delivered *nowhere* and existed only as
an error line in the pod log.

Two inhibition rules ship. The first is the one worth having on one node: if the API server
is unreachable, node readiness cannot be evaluated at all — kube-state-metrics
reads it through that same API server — so `NodeNotReady` is a symptom of the
outage already being reported. The second keeps one reclaimer outage to one
alert rather than two. A reclaimer that cannot reach XNAT logs why and fails every run, so
`ReclaimerRunUnavailable` fires after its sustained log condition.
`ReclaimerNotSucceeding` uses the configured `alertAfter` since last success
(or CronJob creation), plus its own 15m pending period. It need not follow
within one hour. The broad single-node inhibition can delay a different failure
until the source alert clears. Exact recovery-mail timing is not verified
(2026-11-10); use the current expressions, polling periods, and retention.


 The subchart's severity-based inhibitions
(critical suppressing warning, and so on) are **not** in this config; this file
replaces `alertmanager.yaml` wholesale rather than merging with it.

> **Required site settings:** when both `observability.enabled` and `observability.stack.enabled` are true, the
> chart refuses empty `emailTo` or `smtpHost`. Set both in the site file and
> apply the SMTP Secret. A passing render checks configuration presence, not
> relay authentication or delivery. Confirm a real notification in the inbox.



`observability.stack.alerting.*` in `sites/<site>/values.yaml` and the
`alertmanager-smtp` Secret are not merely a place to *record* a site's mail
facts — they are **consumed**. `templates/observability.yaml` binds
`$alerting := .Values.observability.stack.alerting` and substitutes `emailTo`,
`emailFrom` (falling back to `emailTo`), `smtpHost`, `smtpPort`, `requireTLS`,
`smtpUsername` and an `existingSecret`-derived password *path* into the config's
`__SENTINEL__` tokens. These settings select the destination and transport; a working relay, mounted
password, network path, and recipient still have to be tested. The
render also refuses to proceed if `alerting.existingSecret` is not listed in
`alertmanagerSpec.secrets`, because the config would then read a password file
the operator never mounted and every notification would fail authentication long
after a green install.

## Configuration

Everything lives in `sites/<site>/values.yaml`; `install.sh` passes it with
`-f` and no `--set`, so anything not in that file is the chart default from
[`charts/edge/values.yaml`](../../charts/edge/values.yaml).

| Values path | What it does |
|---|---|
| `observability.stack.enabled` | Gates the whole `kube-prometheus-stack` dependency, Alertmanager included |
| `kube-prometheus-stack.alertmanager.alertmanagerSpec.configSecret` | **Which Secret is THE routing config.** Pinned to `alertmanager-aisedge-config`; `templates/observability.yaml` `fail`s the render if it is changed, so the operator consumes the chart-owned config. An alternate name would select another Secret, whose content or absence this chart cannot validate |
| `kube-prometheus-stack.alertmanager.alertmanagerSpec.secrets` | Mounts a Secret into the pod at `/etc/alertmanager/secrets/<name>/<key>`. Must include `alertmanager-smtp`, or `smtp_auth_password_file` points at nothing — the render `fail`s if it does not |
| `kube-prometheus-stack.alertmanager.alertmanagerSpec.storage` | The 5Gi `local-path` PVC for silence + notification state |
| `observability.stack.alerting.{emailTo,emailFrom,smtpHost,smtpPort,smtpUsername,requireTLS}` | The site's mail facts, **consumed** ; substituted into the shipped config as `__SENTINEL__` tokens. Both `emailTo` and `smtpHost` must be set when both observability switches are true; that guard rejects empty values. `emailFrom` falls back to `emailTo` |
| `observability.stack.alerting.existingSecret` | Names the Secret holding the SMTP password; the config reads `/etc/alertmanager/secrets/<name>/password`. Defaults to `alertmanager-smtp`, and must also appear in `alertmanagerSpec.secrets` above |
| Secret `alertmanager-smtp` (keys `username`, `password`) | In `sites/<site>/secrets.enc.yaml`, SOPS-encrypted, namespace `xnat-ingest`. Applied by `scripts/site-secrets.sh apply <site>` — step 2 of `./install.sh <site>`, deliberately before the workloads |

For a Google account used with password-based SMTP, follow the relay
provider's current policy. An app password requires 2-Step Verification and
may be unavailable under an organization policy. See [Google's app-password
guidance](https://support.google.com/mail/answer/185833?hl=en). Verify the
configured relay; an account password is not a reliable substitute.



To actually route mail, set `observability.stack.alerting.emailTo` and
`smtpHost` in the site file and put the password in the `alertmanager-smtp`
Secret; the routes and receivers already exist and the mount is already
declared. Do **not** reach for `kube-prometheus-stack.alertmanager.config` — that
subchart key produces the `alertmanager-ais-kps-alertmanager` Secret, which this
release does not mount, so editing it changes nothing while looking like it
should. To change the tree itself, edit
[`charts/edge/files/alertmanager-config.yaml`](../../charts/edge/files/alertmanager-config.yaml).
[`docs/alerting-diy.md`](../alerting-diy.md) carries the worked example,
including the `smtp_auth_password_file` path and the severity-based routing.

## Operations

```bash
# What the release ACTUALLY rendered — check this before believing an alert
# is deliverable. NOTE THE NAME: alertmanager-ais-kps-alertmanager also exists
# (the subchart renders it) but nothing mounts it, so reading that one shows a
# null receiver that is not what is running.
kubectl -n xnat-ingest get secret alertmanager-aisedge-config \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d

# Confirm which Secret the operator is actually mounting
kubectl -n xnat-ingest get alertmanager ais-kps-alertmanager \
  -o jsonpath='{.spec.configSecret}{"\n"}{.spec.secrets}{"\n"}'

# UI access (no ingress on tier-1)
kubectl -n xnat-ingest port-forward svc/ais-kps-alertmanager 9093:9093
xdg-open http://localhost:9093

# Loaded config as the running process sees it (passwords redacted by the API)
curl -s http://localhost:9093/api/v2/status | jq .config

# Active alerts — from both engines, Prometheus and the Loki ruler
curl -s http://localhost:9093/api/v2/alerts | jq

# Create a temporary silence (e.g. before maintenance)
amtool --alertmanager.url=http://localhost:9093 silence add \
  alertname=XNATBacklogGrowing --duration=30m --comment="planned XNAT maintenance"

# Change the mail facts: edit observability.stack.alerting.* in the site file.
# Change the tree itself: edit charts/edge/files/alertmanager-config.yaml.
# Either way, upgrade — the chart re-renders alertmanager-aisedge-config and the
# config-reloader sidecar picks it up without a restart.
helm upgrade --install <site> charts/edge -n xnat-ingest -f sites/<site>/values.yaml

# Rotate the SMTP credential: edit the encrypted file, re-apply, restart
scripts/site-secrets.sh edit <site>
scripts/site-secrets.sh apply <site>
kubectl -n xnat-ingest rollout restart statefulset/alertmanager-ais-kps-alertmanager
```

## Benefits

- **Native integration with Prometheus** — single source of truth for
  rules and routing, no glue layer
- **One sink for two rule engines** — the Loki ruler speaks the same v2 API, so
  pipeline-event alerts and K8s-state alerts share grouping, inhibition and
  silences instead of arriving through two unrelated channels
- **Inhibit / silence / group semantics** built in — avoids alert storms
- **Routing ships with the chart, and the site only supplies its own facts** —
  the tree, the receivers and the reasoning for every interval live in
  `charts/edge/files/alertmanager-config.yaml`, so a new site inherits a working
  configuration instead of writing one; `sites/<site>/values.yaml` contributes
  the addresses and the relay through `observability.stack.alerting.*`, and both
  halves reach the pod in one `helm upgrade`. Render-time guards keep the Secret
  name and the SMTP mount in step, so the two cannot drift apart silently
- **Multi-receiver support** — email, Slack, PagerDuty, OpsGenie,
  webhooks, …

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| `observability.stack.alerting.emailTo` left empty | With both observability switches true, Helm validation fails before deployment. Stack-only rendering bypasses this presence guard. A nonempty but wrong address still passes that presence check | Decode `alertmanager-aisedge-config` (see Operations) and confirm a real address. Treat "no alerts received" as unproven until a test alert lands in the inbox |
| `alertmanagerSpec.configSecret` overridden in a site file | The render fails the configSecret guard. If that guard were bypassed, the operator would select the other named Secret | `templates/observability.yaml` refuses to render unless it is `alertmanager-aisedge-config`, naming the value and the consequence in the failure text ; the guard exists because this failure is invisible at runtime |
| SMTP relay unreachable | Alerts queue and are eventually dropped | Add a second receiver on a different transport; Alertmanager's own metrics expose delivery failures and it is a Prometheus scrape target |
| SMTP Secret not mounted | `smtp_auth_password_file` reads a path that does not exist; authentication fails at notify time, long after a green install | `alertmanagerSpec.secrets` must name whatever `observability.stack.alerting.existingSecret` names ; `alertmanager-smtp` by default. The render `fail`s when the two disagree, but it does not check whether the named Secret exists or contains the password key |
| SMTP password leak | Attacker can send mail-as-us | Never in `values.yaml` — it lives SOPS-encrypted in `sites/<site>/secrets.enc.yaml`. Rotate with `scripts/site-secrets.sh edit` + `apply`, then restart the StatefulSet |
| `kube-prometheus-stack.alertmanager.config` edited, expecting it to change routing | It generates `alertmanager-ais-kps-alertmanager`, which this release does not mount. The edit renders cleanly, passes review, and has no effect | Routing lives in `charts/edge/files/alertmanager-config.yaml`; the site-level knobs are `observability.stack.alerting.*`. Verify with the `.spec.configSecret` command in Operations |
| Inhibit rule too broad | Real alerts hidden during an outage | Two rules ship. `KubernetesAPIServerDown` inhibits `NodeNotReady`, and only because node readiness is unknowable while the API server is down. `ReclaimerRunUnavailable` inhibits `ReclaimerNotSucceeding`, the same reclaimer failure seen from its log and from its CronJob; a different reclaimer fault that starts during an outage mails only once `ReclaimerRunUnavailable` clears, for the lifetime of the source alert; exact timing was not verified (2026-11-10). Neither carries an `equal:` clause: one node, one API server, one reclaimer, and the Loki-sourced alert carries a `cluster` label that the Prometheus-sourced one does not |
| Alertmanager pod restart | Brief delivery gap | Silences and the notification log survive on the PVC. 1 replica; HA needs peers, which a single node cannot provide |
| Alerts fire but Alertmanager is always red | Operators learn to ignore it | `nodeExporter`, `kubeControllerManager`, `kubeScheduler`, `kubeProxy` and `kubeEtcd` are disabled precisely because this chart does not expose or deploy all of those scrape targets. This does not mean that k0s lacks control-plane components; enable a target only with a verified endpoint |

## Replacements / future

- **PagerDuty / existing Opsgenie integrations:** external paging with on-call schedules.
  Receiver setup is separate from the shipped email routes. Opsgenie is a
  historical option for existing customers: new sales ended 2025-06-04 and
  support ends 2027-04-05. Plan migration before that date. See
  [Atlassian's lifecycle notice](https://www.atlassian.com/licensing/opsgenie).
- **Sentry / Honeybadger** — error-aggregation tools. Different focus
  (application errors vs operational alerts); can run alongside
- **Webhook to a custom internal alerting service** — for sites that
  already have their own incident pipeline. See
  [`docs/observability-integration.md`](../observability-integration.md) for
  swapping the whole stack out
- **Grafana-managed alerting** — the provisioned datasource sets
  `handleGrafanaManagedAlerts: false`. Changing it permits Grafana-managed
  alerts to be sent to this Alertmanager; it does not migrate existing
  PrometheusRule or Loki rule ownership. Such migration needs separate work

## Future enhancements

- ~~Render the routing tree from `observability.stack.alerting.*`~~ — **done.**
  The mail facts in the site file are substituted into the shipped config, and
  the guards in `templates/observability.yaml` keep the Secret name and the SMTP
  mount in step. What is *not* yet site-driven is the shape of the tree itself:
  receivers, matchers and intervals live in
  `charts/edge/files/alertmanager-config.yaml` and changing them means editing
  the chart, which is deliberate for now — the reasoning behind each interval is
  in that file's comments and would be lost as a values key
- Slack on tier-1: the receiver fragment and the sentinel plumbing already exist
  (`charts/edge/files/alertmanager-slack-receivers.yaml`), but this tier renders
  the sentinel empty, so `severity=info` falls back to `info-email`. Wiring a
  webhook Secret through would light it up without touching the routing tree
- Image-render attachments in Slack messages (a Grafana panel
  thumbnail next to the alert text)
- `amtool` integration into ops runbooks for one-line silence creation
- Route the subchart's `Watchdog` alert somewhere real — it fires constantly by
  design and currently goes to `null-meta`, so pointing it at a
  dead-man's-switch service would test the whole receiver chain continuously
  instead of merely keeping it out of the inbox
