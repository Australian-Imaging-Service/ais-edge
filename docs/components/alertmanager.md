# Alertmanager

## Overview

[Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/)
is the alert routing component that ships with the Prometheus operator.
Prometheus evaluates alert rules and posts firing alerts to Alertmanager,
which then deduplicates, groups, silences, and routes to receivers
(email, Slack, PagerDuty, webhooks, …).

## Role in this stack

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
- `retention: 120h` — how long Alertmanager keeps its own notification state,
  not how long alerts are stored anywhere
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

`charts/edge` does **not** leave Alertmanager on the subchart default. It points
`kube-prometheus-stack.alertmanager.alertmanagerSpec.configSecret` at
`alertmanager-aisedge-config` and renders that Secret itself, in
`templates/observability.yaml`, from
[`charts/edge/files/alertmanager-config.yaml`](../../charts/edge/files/alertmanager-config.yaml).

That file is read with `.Files.Get` and is **never** run through `tpl`, on
purpose. It is full of Alertmanager's own `{{ }}` notification templates
(`{{ .CommonLabels.session }}`, `{{ range .Alerts }}`), and Helm's delimiters are
identical: evaluating them against the *chart* context finds no `.CommonLabels`,
renders them as empty strings, and every alert arrives with a blank subject and
an empty body — with no error anywhere. The values the installer does need to
inject are written as `__SENTINEL__` tokens and substituted with `replace`, a
blind string operation that cannot see, and cannot eat, a Go template.

The routing tree it installs:

```
route (group_by: [alertname, cluster, session], group_wait 30s,
       group_interval 5m, repeat_interval 12h, receiver: email-primary)
  ├─ alertname=~"Watchdog|InfoInhibitor"       → null-meta   ← FIRST in the list
  ├─ alertname=DICOMRejectedUnmappedAET        → email-no-resolved
  ├─ alertname=XNATUploadSuccess               → email-upload-success
  │                                              (group_wait 10s, repeat 720h)
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
  info-email            to: <emailTo>, Subject "AIS-Edge [info]: <alertname>"
  null-meta             no *_configs at all — Alertmanager's null sink

inhibit_rules:
  alertname=KubernetesAPIServerDown  inhibits  alertname=NodeNotReady
```

**`null-meta` is the only null receiver here, and it is deliberate.** `Watchdog`
and `InfoInhibitor` are kube-prometheus-stack's own permanently-firing
meta-alerts — one is a heartbeat, the other exists solely as an inhibition
source. Both carry `severity="none"`, which matched no route, so both fell
through to the *root* receiver and mailed the operator forever: two active alerts
in the inbox that no action could ever clear, observed on the live deployment.
Their route is first in the list precisely so they can never reach the tree
below. Every other branch ends at a real email receiver. Do not "fix" `null-meta`
by giving it an `email_configs` block.

**Two routes deliberately never send a `[RESOLVED]` follow-up**, because for them
"resolved" would be a lie. `DICOMRejectedUnmappedAET` clears when no *new*
rejection has been seen for five minutes — the quarantined studies are still
sitting in `<FacilityBackupDir>/__unmapped_aet__/<AET>/` until someone maps the
AET and re-sends them. `SessionStagedNotConfirmedInXNAT` clears when its window
slides past the last time the reclaimer saw the session, whether or not the data
ever arrived; a resolve mail went out for a session that was, and remains, absent
from XNAT. Alertmanager and the Loki ruler only ever see logs, never the
filesystem, so neither condition can be resolved honestly.

**The `severity=info` receiver is chosen by a sentinel, and on tier-1 it resolves
to `info-email`.** `templates/observability.yaml` substitutes Slack receivers
into the config only when a webhook Secret is configured; on this tier it
substitutes the empty string, so info alerts go to email rather than to a Slack
receiver that could not deliver. That failure mode is not hypothetical: the Slack
receivers used to be defined unconditionally with `api_url_file` pointing at a
Secret nothing created, and Alertmanager treats that ENOENT as unrecoverable at
send time — `severity=info` alerts were delivered *nowhere* and existed only as
an error line in the pod log.

The single inhibition rule is the one worth having on one node: if the API server
is unreachable, node readiness cannot be evaluated at all — kube-state-metrics
reads it through that same API server — so `NodeNotReady` is a symptom of the
outage already being reported. The subchart's severity-based inhibitions
(critical suppressing warning, and so on) are **not** in this config; this file
replaces `alertmanager.yaml` wholesale rather than merging with it.

> CAUTION: what stops mail on a default install is not a null receiver, it is an
> empty address. `observability.stack.alerting.emailTo` defaults to `""`, and
> every receiver above renders `to: ""`. Alertmanager loads that config happily,
> the routing tree runs, the alert shows as firing, the Grafana panel goes red —
> and the inbox stays empty. **Set `emailTo` and `smtpHost` in
> `sites/<site>/values.yaml`, then prove it with a real alert.**

`observability.stack.alerting.*` in `sites/<site>/values.yaml` and the
`alertmanager-smtp` Secret are not merely a place to *record* a site's mail
facts — they are **consumed**. `templates/observability.yaml` binds
`$alerting := .Values.observability.stack.alerting` and substitutes `emailTo`,
`emailFrom` (falling back to `emailTo`), `smtpHost`, `smtpPort`, `requireTLS`,
`smtpUsername` and an `existingSecret`-derived password *path* into the config's
`__SENTINEL__` tokens. Filling them in is exactly what makes mail flow. The
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
| `kube-prometheus-stack.alertmanager.alertmanagerSpec.configSecret` | **Which Secret is THE routing config.** Pinned to `alertmanager-aisedge-config`; `templates/observability.yaml` `fail`s the render if it is changed, because any other value silently hands Alertmanager the subchart's default and every alert this chart raises goes to a null receiver |
| `kube-prometheus-stack.alertmanager.alertmanagerSpec.secrets` | Mounts a Secret into the pod at `/etc/alertmanager/secrets/<name>/<key>`. Must include `alertmanager-smtp`, or `smtp_auth_password_file` points at nothing — the render `fail`s if it does not |
| `kube-prometheus-stack.alertmanager.alertmanagerSpec.storage` | The 5Gi `local-path` PVC for silence + notification state |
| `observability.stack.alerting.{emailTo,emailFrom,smtpHost,smtpPort,smtpUsername,requireTLS}` | The site's mail facts, **consumed** — substituted into the shipped config as `__SENTINEL__` tokens. `emailTo` is the one that must be set: empty renders `to: ""` and nothing is delivered. `emailFrom` falls back to `emailTo` |
| `observability.stack.alerting.existingSecret` | Names the Secret holding the SMTP password; the config reads `/etc/alertmanager/secrets/<name>/password`. Defaults to `alertmanager-smtp`, and must also appear in `alertmanagerSpec.secrets` above |
| Secret `alertmanager-smtp` (keys `username`, `password`) | In `sites/<site>/secrets.enc.yaml`, SOPS-encrypted, namespace `xnat-ingest`. Applied by `scripts/site-secrets.sh apply <site>` — step 2 of `./install.sh <site>`, deliberately before the workloads |

For Gmail the password must be an **App Password**: a 2FA account rejects the
account password with `535 BadCredentials`, and the only symptom is alerts that
never arrive.

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
| `observability.stack.alerting.emailTo` left empty | Every receiver renders `to: ""`. Alerts fire, group, inhibit — and are delivered to nobody. The config is valid, so there is no error anywhere | Decode `alertmanager-aisedge-config` (see Operations) and confirm a real address. Treat "no alerts received" as unproven until a test alert lands in the inbox |
| `alertmanagerSpec.configSecret` overridden in a site file | Alertmanager falls back to the subchart's default `null` receiver and this chart's whole routing tree is silently discarded | `templates/observability.yaml` refuses to render unless it is `alertmanager-aisedge-config`, naming the value and the consequence in the failure text — the guard exists because this failure is invisible at runtime |
| SMTP relay unreachable | Alerts queue and are eventually dropped | Add a second receiver on a different transport; Alertmanager's own metrics expose delivery failures and it is a Prometheus scrape target |
| SMTP Secret not mounted | `smtp_auth_password_file` reads a path that does not exist; authentication fails at notify time, long after a green install | `alertmanagerSpec.secrets` must name whatever `observability.stack.alerting.existingSecret` names — `alertmanager-smtp` by default. The render `fail`s when the two disagree, so this one cannot reach a cluster |
| SMTP password leak | Attacker can send mail-as-us | Never in `values.yaml` — it lives SOPS-encrypted in `sites/<site>/secrets.enc.yaml`. Rotate with `scripts/site-secrets.sh edit` + `apply`, then restart the StatefulSet |
| `kube-prometheus-stack.alertmanager.config` edited, expecting it to change routing | It generates `alertmanager-ais-kps-alertmanager`, which this release does not mount. The edit renders cleanly, passes review, and has no effect | Routing lives in `charts/edge/files/alertmanager-config.yaml`; the site-level knobs are `observability.stack.alerting.*`. Verify with the `.spec.configSecret` command in Operations |
| Inhibit rule too broad | Real alerts hidden during an outage | Only one rule ships: `KubernetesAPIServerDown` inhibits `NodeNotReady`, and only because node readiness is unknowable while the API server is down. It carries no `equal:` clause — with one node and one API server there is nothing to disambiguate |
| Alertmanager pod restart | Brief delivery gap | Silences and the notification log survive on the PVC. 1 replica; HA needs peers, which a single node cannot provide |
| Alerts fire but Alertmanager is always red | Operators learn to ignore it | `nodeExporter`, `kubeControllerManager`, `kubeScheduler`, `kubeProxy` and `kubeEtcd` are disabled precisely because those targets do not exist on a single k0s node and would each contribute a permanent "target down" |

## Replacements / future

- **PagerDuty / Opsgenie** — proper paging with on-call schedules.
  Receivers can be added to Alertmanager without replacing it
- **Sentry / Honeybadger** — error-aggregation tools. Different focus
  (application errors vs operational alerts); can run alongside
- **Webhook to a custom internal alerting service** — for sites that
  already have their own incident pipeline. See
  [`docs/observability-integration.md`](../observability-integration.md) for
  swapping the whole stack out
- **Grafana-managed alerting** — the provisioned datasource sets
  `handleGrafanaManagedAlerts: false`; flipping it moves rule ownership into
  Grafana and away from the two-engine split

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
