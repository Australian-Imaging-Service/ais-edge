# Alerting architecture — why Loki ruler, not Prometheus remote-write

## TL;DR

Pipeline-event alerts (upload_failed spikes, stalled sessions, sessions staged
but never confirmed in XNAT, reclaimer outages, DICOM validation failures) are
evaluated by **Loki's built-in ruler** running LogQL queries against the JSON
event stream. XNAT *backlog* is deliberately NOT among them: `XNATBacklogGrowing`
was measured and deleted, because the log string it matched could not
distinguish a new arrival from a static backlog. See "What lives where" below
for the current inventory — 13 Loki-ruler alerts and 9 Prometheus alerts — and
"What we removed" for the four that went. K8s/cert-manager-derived alerts
(node NotReady, certificate expiry, cert-sync staleness, SeaweedFS down) stay in
**Prometheus** as `PrometheusRule` objects. Both fire into the existing
**kube-prometheus-stack Alertmanager**, which routes via the
`observability.alerting.*` in `sites/<site>/values.yaml` (the SMTP password and any Slack webhook come from Secrets in `sites/<site>/secrets.enc.yaml`).

## Why not just Prometheus for everything?

The pipeline emits structured JSON events from pods that run on **edge child
clusters** (managed by k0smotron). The mgmt-cluster Prometheus cannot scrape
those pods directly — k0smotron's konnectivity tunnel is one-way (worker →
control plane), so there is no path from mgmt Prometheus back into a child
cluster's pod network.

There are two options that work unattended:

1. **Edge Prometheus → mgmt remote-write.** Stand up a Vector
   `prometheus_exporter` sink on each edge, expose it through the edge's
   `nginx-ingress` on a new SNI hostname (e.g. `prom-edge.aisedge.local`),
   issue+rotate a bearer token per edge, enable `--web.enable-remote-write-receiver`
   on mgmt Prometheus, and configure remote-write on the edge Prometheus.
   This is real infrastructure: an additional ingress endpoint per edge, two
   moving Prometheuses to keep healthy, separate auth surface, and another
   thing to monitor.

2. **Loki ruler.** Loki already receives every JSON event from every edge
   (Vector → Loki over the existing `loki.aisedge.local` ingress on :443).
   The Loki binary has a built-in `ruler` component that runs LogQL queries
   on a schedule and emits firing alerts to any Alertmanager that speaks
   the Alertmanager v2 API. No new ingress, no new auth, no new Prometheus.

We chose **option 2.** The source of truth for these alerts is the JSON
event itself (`{event: "upload_failed", session: "...", duration_s: ...}`),
not a synthesised counter. Counting events in LogQL with `count_over_time`
is the same operation we already perform for the dashboards, so the alert
expressions sit close to the dashboard queries that operators already trust.

## What lives where

This table is the full shipped inventory, not a sample: **13** alerts in
`charts/mgmt/files/loki-ruler-rules.yaml` and **9** across the four files in
`charts/mgmt/files/prometheus-rules/`. If you add one, add a row — an alert
missing from here reads as coverage nobody knows about, and an alert listed
here that no longer ships reads as coverage that does not exist.

| Alert | Source | Why |
|------|--------|------|
| `XNATUploadFailingForAllSessions` | Loki ruler | Derived from `event="upload_failed"` and `event="upload_completed"` JSON events on the edge (`component="s3-uploader"`), joined `unless on (cluster)`. |
| `S3UploaderRetryStorm` | Loki ruler | `event="upload_failed"` count over a window, per cluster. |
| `SessionUploadStalled` | Loki ruler | `event="upload_started"` without matching `event="upload_completed"` per session. |
| `SessionStagedNotConfirmedInXNAT` | Loki ruler | The absence alert: an `event=~"reclaim_.*"` for a session in a 24h window `offset 48h`, with no `reclaim_confirmed` since. Its staged half is why the reclaimer must keep speaking through an outage — see the last section. |
| `ReclaimerRunUnavailable` | Loki ruler | `event="reclaim_unavailable"` with `session=""` (the run-level line) and no `reclaim_finished` in the last 70m. This is what an operator acts on. |
| `DICOMValidationFailureSpike` | Loki ruler | Pattern match on assign-pod log lines (`component="assign"`). |
| `DICOMRejectedUnmappedAET` | Loki ruler | Orthanc's `REJECT: no project mapped for CalledAET`, with the AET pulled out by `regexp` so the mail names the misconfigured modality. |
| `EdgeDiskLow` | Loki ruler | `event="stage_report"` from the data-policy pod with `free_pct` under the site's threshold — the threshold is substituted into the rule at render time. |
| `QuarantinedDataUnresolved` | Loki ruler | `stage="originals.quarantine"` whose `oldest_age_s` exceeds the site's alert-after window; quarantined data nobody triaged is data that never reaches XNAT. |
| `XNATUploadSuccess` | Loki ruler | `info`-severity receipt: `Successfully uploaded all files in '<session>'`, grouped by session. Range `[10m]`, deliberately wider than the uploader's ~62s loop — see the duplicate-mail section. |
| `XNATAuthFailure` | Loki ruler | 401/403 patterns in the `xnat-upload` namespace, with `!= "it/s"` to drop progress-bar lines that happen to contain the digits. |
| `OrthancDeidLuaError` | Loki ruler | Lua traceback in the Orthanc log — the de-identification script failing open is a PHI risk, not a cosmetic one. |
| `DeidentifyStageError` | Loki ruler | error or traceback from `component="deidentify"` in 10m — the counterpart for the xnat-ingest engine, so a de-identification failure is visible whichever engine the site runs |
| `S3UploaderRestartedRecently` | Loki ruler | `refusing to start upload loop` / `alias_failed` / `endpoint_failed` — the uploader's own pre-flight refusals, which otherwise look like silence. |
| `ManagementClusterDown` | Prometheus | `up{job="apiserver"}` — only meaningful from mgmt Prometheus. |
| `EdgeWorkerDisconnected` | Prometheus | `kube_node_status_condition` — fires, but only ever for the management node; see `docs/components/kube-state-metrics.md`. |
| `SeaweedFSDown` | Prometheus | Deployment readiness, scraped from mgmt KSM. |
| `SeaweedFSDiskFull` | Prometheus | `SeaweedFS_volumeServer_resource` from SeaweedFS's own exporter (capitalised exactly so — PromQL is case-sensitive). |
| `CertificateExpiringSoon` | Prometheus | `certmanager_certificate_expiration_timestamp_seconds` from mgmt cert-manager. |
| `CertSyncStale` | Prometheus | `kube_cronjob_status_last_successful_time` for any `*-cert-sync-*` CronJob older than 24h — an edge whose Loki client cert stopped being refreshed. |
| `CertSyncNeverSucceeded` | Prometheus | `kube_cronjob_info` `unless on (namespace, cronjob)` a last-success timestamp — catches a site whose Secrets were never delivered at all, which "stale" cannot see. |
| `CARotationDue` | Prometheus | `ais-edge-ca` inside a year of expiry. Fleet-wide reissue is a planned job, not an incident, so it is `info`. |
| `CertificateRenewed` | Prometheus | `changes(certmanager_certificate_renewal_timestamp_seconds[1h])` — an `info` receipt that rotation is actually happening. |

`kube-prometheus-stack`'s own rule pack is **not** part of that count:
`defaultRules.create: false` (`charts/mgmt/values.yaml`), so every Prometheus
alert in this stack is one of the nine above. There is no `KubePodCrashLooping`
or `KubeletDown` quietly backing us up.

Four alerts that used to be in this table are not, all removed after
measurement showed they could never fire — `docs/TOUR.md` §9 has the
evidence for each: `OrthancStorageGrowing` and `XNATBacklogGrowing` (Loki,
matched a log string that either does not exist or cannot distinguish new
arrivals from static backlog), `EdgePodCrashLoop` and
`KonnectivityTunnelFlapping` (Prometheus, named child-cluster objects mgmt
cannot scrape — zero series, confirmed live).

If we ever need a pipeline-event metric *as a metric* (e.g. for a Grafana
panel that needs ms-resolution sliding windows that LogQL can't deliver),
the right path forward is to add a `recording_rules` block to Loki's ruler
config — that produces a Prometheus-format metric from a LogQL query and
exposes it on Loki's `/prometheus/api/v1/...` endpoint. Loki then becomes
both the storage and the metrics engine for log-derived signals; mgmt
Prometheus does NOT need to scrape the edges.

## What we removed

- Vector `log_to_metric` transform on both mgmt and edge configs.
- Vector `prometheus_exporter` sink on both.
- Vector `Service` and `:9598` port on the edge DaemonSet.
- Hand-rolled `vector-servicemonitor.yaml` (the Vector helm chart's
  `serviceMonitor.enabled` was silently broken at chart 0.52.0 — it ships
  `templates/podmonitor.yaml` but no ServiceMonitor template — and our
  hand-rolled replacement existed only to make the dead Prom path scrape).

The result is one less metric pipeline, one less ingress hostname per edge
that we'd otherwise need, and one source of truth for pipeline alerts.

---

## Troubleshooting: repeated "XNAT upload completed" emails

**Symptom.** `XNATUploadSuccess` re-fires for the *same* session indefinitely
and the inbox fills with identical "upload completed" mails — typically one
every few minutes, continuing for days after the drop.

**Cause.** `xnat-ingest upload` has **no S3 retention**. It rebuilds its work
list from a live listing of `s3://<bucket>/staged` on every `--loop` pass and
never deletes what it uploaded, so a session lingers and is re-processed
forever. The failure becomes *permanent* if the staging prefix contains
**empty directory entries**: the uploader lists each one as a session,
"uploads" its zero resources, and still logs

```
Successfully uploaded all files in '<session>'
```

which is exactly the string the `XNATUploadSuccess` rule matches — so a
0-byte prefix generates a fresh alert every 60 s forever.

**Where the empty prefixes come from.** Cleaning up staging with the obvious
command:

```bash
mc rm --recursive --force edge/ingest-bucket/staged/     # ← DO NOT
```

On SeaweedFS this deletes the **objects** but leaves the **directory entries**
as 0-byte prefixes. `mc ls` then shows N prefixes with 0 files — the exact
state that produces the bogus successes.

**Fix / correct cleanup.** Remove the empty directory entries at the filer
level (only the filer can delete a directory entry), then restart the uploader:

```bash
bash scripts/clear-staged-s3.sh <site>            # SAFE: removes ONLY empty prefixes
bash scripts/clear-staged-s3.sh <site> <edge>     # a fleet: name the edge
```

`<site>` is the directory under `sites/` that `install.sh` takes. The script
reads it to find the edge, its bucket (`ingest-<edge>` when `perSiteBuckets` is
on), and then discovers the filer and both uploaders **by label**
(`component=seaweedfs`, `component=upload,edge=<name>`, `component=s3-uploader`)
rather than by hardcoded name.

> It used to take no arguments and address `seaweedfs/seaweedfs`,
> `xnat-ingest-upload` and a fleet-wide `ingest-bucket` — all pre-consolidation
> names — while counting objects with `mc`, which the current uploader image
> does not contain. Every call was `|| true` or `2>/dev/null`, so it printed its
> normal output, reported "removed 0 empty prefixes" and changed nothing. If you
> ran it before and the alerts continued, that is why: re-run it now.

> **Production safety.** The default mode deletes **only 0-byte prefixes** and
> deliberately **keeps any session that still contains objects** — a staged
> session may not have reached XNAT yet (XNAT down, bad credentials, backlog),
> and deleting it would lose undelivered data. The script prints which
> sessions it kept and why.
>
> `scripts/clear-staged-s3.sh <site> [edge] --all` wipes the whole staging
> prefix including undelivered sessions. It prompts for confirmation and is
> intended for resetting demo/test environments only — never point it at
> production.
>
> **A failed listing is no longer read as an empty bucket.** `aws s3 ls` exits 1
> with no output for an empty prefix but 255 with an error for a broken call,
> and `kubectl exec` adds a line of its own on any non-zero exit — so the three
> cases are told apart explicitly. If the listing cannot be read the script
> aborts rather than reporting "nothing to do".

**Verify it is quiet:**

```bash
# Management side. The uploader renders once PER EDGE, as mgmt-upload-<edge>
# in xnat-upload — there is no single fleet-wide uploader to look at.
kubectl -n xnat-upload logs deploy/mgmt-upload-<edge> --since=3m \
  | grep -E 'Found [0-9]+ sessions'      # expect: Found 0 sessions

# Edge side. Lists the staging prefix with the AWS CLI the uploader image
# actually carries, against this site's own bucket (ingest-<edge>, the default
# under seaweedfs.perSiteBuckets). AWS_ENDPOINT_URL is already set on the pod.
kubectl --kubeconfig=kubeconfig-<edge> -n xnat-ingest exec deploy/edge-s3-uploader -- \
  sh -c 'aws --endpoint-url "$AWS_ENDPOINT_URL" s3 ls s3://ingest-<edge>/staged/'
                                         # expect: no output
```

> These names matter more than they look. `aws s3 ls` **exits 1 with no output
> on an empty prefix**, so "no output" is the success case here — but so is a
> wrong Deployment name, a wrong bucket, or a missing binary. `mc` is not in
> the uploader image at all (it runs `amazon/aws-cli`), and a fleet-wide
> `ingest-bucket` only exists when `seaweedfs.perSiteBuckets` is turned off.
> Get any of them wrong and the check reports the same quiet nothing as a
> healthy system — the identical failure mode the note above describes for the
> script itself. `scripts/clear-staged-s3.sh` prints the exact management-side
> command for the site you ran it against; prefer copying it from there.

Any `Successfully uploaded all files in '<same session>'` repeating on a ~60 s
cadence means staged sessions (or empty prefixes) are still present.

**A second, independent cause of duplicate mail: range shorter than the
emitter's loop period.** The uploader re-scans staging every ~62s and logs
the success string on EVERY pass — including passes where it finds the
session already delivered and skips it. That string is a LEVEL re-asserted
for as long as the session sits in staging, not a one-off event. A rule
range shorter than that ~62s loop lets the series go empty between passes:
the alert resolves and re-fires every loop, and `group_by` cannot suppress
that because it only collapses alerts firing at the same time, not a
resolve/re-fire cycle. Fixed by widening the range past the loop period
(`XNATUploadSuccess` now uses `[10m]`); `scripts/ci/promtool.sh` holds that
range above a 5m floor so it cannot be narrowed back by accident.

> **The CI gate is an allowlist, not a detector — read it before you trust
> it.** `scripts/ci/promtool.sh` carries a hardcoded set,
> `LOOPING = {"XNATUploadSuccess", "XNATAuthFailure",
> "S3UploaderRestartedRecently"}`, and range-checks only those three against
> the 5m floor. It cannot tell that some *new* rule reads a looping emitter's
> output, so a new rule written against one gets no protection and CI stays
> green — which is exactly how this bug got in. The check does fail if a name
> in the set disappears from the ruleset, so the list cannot rot silently; it
> just cannot grow by itself. **If you add a rule whose source line is
> re-emitted by a poll rather than fired once per real event, add its name to
> `LOOPING` in the same commit.** Whether a rule belongs there is a property of
> the emitter, not of the expression, so no static check can infer it.

**Related alert-suppression gotcha.** `XNATUploadSuccess` is grouped by
`session`, and Alertmanager records what it has already sent in
`/alertmanager/nflog` — which lives on a **PVC and survives pod restarts**.
Its route sets `repeat_interval: 720h` deliberately: a success notification
carries no new information on repeat, so re-dropping a file that hashes to
the same session ID fires the alert but sends **no email** for a long time.
To force a fresh notification (e.g. between demo takes) the nflog must be
wiped:

```bash
kubectl -n ais-mgmt scale statefulset/alertmanager-mgmt-kube-prometheus-stack-alertmanager --replicas=0
kubectl -n ais-mgmt delete pvc alertmanager-mgmt-kube-prometheus-stack-alertmanager-db-alertmanager-mgmt-kube-prometheus-stack-alertmanager-0 --wait=false
kubectl -n ais-mgmt patch pvc alertmanager-mgmt-kube-prometheus-stack-alertmanager-db-alertmanager-mgmt-kube-prometheus-stack-alertmanager-0 \
  -p '{"metadata":{"finalizers":null}}' --type=merge     # plain delete hangs on pvc-protection
kubectl -n ais-mgmt scale statefulset/alertmanager-mgmt-kube-prometheus-stack-alertmanager --replicas=1
```

## The reclaimer's pre-flight abort: two log lines, not one

`charts/mgmt/files/reclaim-staged.sh` aborts if its XNAT auth probe fails —
observed twice in 24h, both `HTTP 000`. A plain `log ; exit 1` would be a
silent failure dressed as a safe one: nothing deleted, and nothing said,
because `SessionStagedNotConfirmedInXNAT` builds its "staged" half from
`{component="s3-reclaimer"} | json | event=~"reclaim_.*" | session != ""`,
and a `session=""` abort line is dropped by that filter.

**An isolated failure does not silence the alert** — its staged half is a
24h count and one missed hour is absorbed by the other 23. The real risk is
a **sustained** pre-flight failure across a whole 24h window, which would
leave every session staged in that window invisible to the absence alert
until the window slides past it — 48h after recovery, or never if it never
recovers. That is exactly the state "staged and never confirmed" most needs
to catch.

So the script emits two things on abort: one run-level `reclaim_unavailable`
with a machine-readable `reason` (`ReclaimerRunUnavailable` pages on this
within the hour — what an operator actually acts on), and, best-effort, one
`reclaim_unavailable` per staged session (capped, to avoid tripping a Loki
ingestion limit and restoring the exact silence this exists to prevent) so
the absence alert keeps getting a staged signal through an outage of any
length. It must never emit `reclaim_finished` — a healthy no-op run and an
aborted run must not look identical in the log.
