# Alerting architecture — why Loki ruler, not Prometheus remote-write

The pipeline tool is accessionflow (called xnat-ingest before 0.18.0).

## TL;DR

Pipeline-event alerts (upload_failed spikes, stalled sessions, sessions staged
but never confirmed in XNAT, reclaimer outages, DICOM validation failures) are
evaluated by **Loki's built-in ruler** running LogQL queries against the JSON
event stream. XNAT *backlog* is deliberately NOT among them: `XNATBacklogGrowing`
was measured and deleted, because the log string it matched could not
distinguish a new arrival from a static backlog. See "What lives where" below
for the current inventory of 23 Loki-ruler alerts and 13 Prometheus alerts, and
"What we removed" for the four that went. K8s/cert-manager-derived alerts
(node NotReady, certificate expiry, cert-sync staleness, SeaweedFS down) stay in
**Prometheus** as `PrometheusRule` objects. Both fire into the existing
**kube-prometheus-stack Alertmanager**, which routes via the
`observability.alerting.*` in `sites/<site>/values.yaml` (the SMTP password and any Slack webhook come from Secrets in `sites/<site>/secrets.enc.yaml`).

## Why not just Prometheus for everything?

The pipeline emits structured JSON events from pods that run on **edge child
clusters** (managed by k0smotron). The mgmt-cluster Prometheus cannot scrape
those pods directly through the stock monitoring configuration. Konnectivity
connections are initiated by workers, but carry API-server-to-worker traffic
back through the tunnel. They do not give an ordinary Prometheus pod general
routing into every child cluster's pod network. Explicit networking or a
push-based telemetry transport is needed; outbound initiation alone does not
mean that the tunnel carries traffic in only one direction.

There are two options that work unattended:

1. **Edge Prometheus → mgmt remote-write.** Run an exporter and a local
   scraper on each edge, then send samples to an authenticated management-side
   remote-write receiver. A local exporter does not need its own public SNI
   hostname: the edge scraper reaches it locally. Management needs a reachable
   receiver endpoint, credentials, rotation, buffering, and outage monitoring.
   This introduces an additional metric conversion and collection path whose
   cardinality and delivery behavior must be tested alongside the log path.

2. **Loki ruler.** Loki already receives JSON events from the configured edges
   (Vector → Loki over the existing `loki.aisedge.local` ingress on :443).
   The Loki binary has a built-in `ruler` component that runs LogQL queries
   on a schedule and emits firing alerts to any Alertmanager that speaks
   the Alertmanager v2 API. No new ingress, no new auth, no new Prometheus.

Vector delivery is best-effort with the configured memory sink buffers; neither option establishes loss-free event delivery merely by being enabled.

We chose **option 2.** The source of truth for these alerts is the JSON
event itself (`{event: "upload_failed", session: "...", duration_s: ...}`),
not a synthesised counter. Counting events in LogQL with `count_over_time`
is the same operation we already perform for the dashboards, so the alert
expressions sit close to the dashboard queries that operators already trust.

## What lives where

This table is the full shipped inventory, not a sample: **23** alerts in
`charts/mgmt/files/loki-ruler-rules.yaml` and **13** across the six files in
`charts/mgmt/files/prometheus-rules/`. If you add one, add a row — an alert
missing from here reads as coverage nobody knows about, and an alert listed
here that no longer ships reads as coverage that does not exist.

| Alert | Source | Why |
|------|--------|------|
| `XNATUploadFailingForAllSessions` | Loki ruler | Derived from `event="upload_failed"` and `event="upload_completed"` JSON events on the edge (`component="s3-uploader"`), joined `unless on (cluster)`. |
| `S3UploaderRetryStorm` | Loki ruler | `event="upload_failed"` count over a window, per cluster. |
| `SessionUploadStalled` | Loki ruler | `event="upload_started"` without matching `event="upload_completed"` per session. |
| `SessionStagedNotConfirmedInXNAT` | Loki ruler | The absence alert: an `event=~"reclaim_.*"` for a session in a 24h window `offset 48h`, with no `reclaim_confirmed` since. Its staged half is why the reclaimer must keep speaking through an outage — see the last section. Under `upload.mode: s3` the edge's own reclaimer (namespace `xnat-ingest`) proves against the bucket, not XNAT: its lines carry `proof=s3` and its `reclaim_confirmed` is kept out of the confirming half, so a session the edge saw and XNAT never confirmed still fires. |
| `ReclaimerRunUnavailable` | Loki ruler | `event="reclaim_unavailable"` with `session=""` (the run-level line) and no `reclaim_finished` in the last 70m, per cluster and namespace: under `upload.mode: s3` the edge's reclaimer (`xnat-ingest`) and the management one (`xnat-upload`) are judged apart, so one finishing cannot hide the other's aborts. This is what an operator acts on. |
| `RecopyLoop` | Loki ruler | `event="recopy_done"` from the edge's s3-uploader, more than 3 for one session in 24h: completed re-copies, not claimed requests, because an uploader that cannot copy claims the same request on every pass and that failure is `SessionUploadStalled`'s and `S3UploaderRestartedRecently`'s. The edge's staged-reclaimer keeps asking for the same session: a local file is not in the bucket as it is on disk, and after each copy it is gone again, which is the management reclaimer removing the bucket copy before the edge has proven its own against it (the two clocks crossing). The alert does not prove that all copies are intact, and bucket changes or failed copies can also cause repeated recopy requests. Inspect file proofs and deletion logs before changing the clocks: `dataPolicy.derived.s3Staged.minAge` must exceed `stagedReclaimer.minAge` plus its interval by a wide margin. |
| `XNATUploaderRestarted` | Prometheus | A restart-counter increase in 15 minutes for this release's accessionflow store xnat container. Reports the last termination reason, including `OOMKilled`, and still fires after recovery. A retained reason alone cannot keep it firing. Uses firing-only email and separate groups per uploader. |
| `XNATUploaderMemoryGrowing` | Prometheus | RSS grows faster than 32 MiB per six hours across both six-hour and fifteen-minute trends, exceeds 25% of its configured memory limit, and the container has run for six hours. Held for one more hour. Excludes filesystem cache and brief upload peaks; growth merits investigation but does not prove a leak. Missing or unlimited memory limits do not trigger this rule. |
| `ReclaimerNotSucceeding` | Prometheus | `kube_cronjob_status_last_successful_time` for each edge's `<release>-reclaim-<edge>` CronJob: no successful run for `dataPolicy.derived.s3Staged.alertAfter` (3h), or since creation if it never has. It sees the failures that log nothing (deadline kill, OOM, crash, image pull, never scheduled), which `ReclaimerRunUnavailable` cannot. `cluster=<edge>` is taken from the CronJob name, and an inhibit rule with `equal: [cluster]` holds it back while `ReclaimerRunUnavailable` fires for the same edge, so one outage raises one alert per edge rather than two. |
| `KubeStateMetricsDown` | Prometheus | `absent(up{job="kube-state-metrics"} == 1)` for 15m. Every CronJob alert here (`CertSyncStale`, `CertSyncNeverSucceeded`, `ReclaimerNotSucceeding`) reads kube-state-metrics, so without it they have nothing to evaluate and stay quiet; `defaultRules` is off, so nothing upstream covers it. |
| `InvalidSessionAssigned` | Loki ruler | One assign ERROR for missing routing IDs in 10m, held for 1m. Check `assigned/__invalid__` and retain the files for review. Alert expiry does not prove recovery. |
| `DICOMValidationFailureSpike` | Loki ruler | Pattern match on assign-pod log lines (`component="assign"`). |
| `DICOMRejectedUnmappedAET` | Loki ruler | Orthanc's `REJECT: no project mapped for CalledAET`, with the AET pulled out by `regexp` so the mail names the misconfigured modality. Only the deprecated `deid.engine: orthanc` logs that line. Under `ingest`, the default, the Lua script returns before its AE-title lookup, so this alert does not fire. |
| `EdgeDiskLow` | Loki ruler | `event="stage_report"` from the data-policy pod with `free_pct` under the site's threshold — the threshold is substituted into the rule at render time. |
| `QuarantinedDataUnresolved` | Loki ruler | `stage="originals.quarantine"` whose `oldest_age_s` exceeds the site's alert-after window; quarantined data nobody triaged is data that never reaches XNAT. Only the deprecated `deid.engine: orthanc` writes the quarantine, so under `ingest` no new unknown-AET entries are created. Retained historical quarantine content can still trigger this alert. |
| `StageBacklogAgeing` | Loki ruler | `event="stage_report"` from the data-policy pod with `oldest_age_s` above `stageAgeAlertAfter`, which is substituted into the rule at render time. Stages with policy `forever` are not checked. Nothing is deleted because of it: it says that a stage does not drain. |
| `PipelineSessionStuck` | Loki ruler | `event="stage_stuck"` from the data-policy pod, per edge and stage: one session has failed its reclaim condition for longer than it should. |
| `DataPolicyReporterSilent` | Loki ruler | One series per edge in `edges` (minus any with `dataPolicyReporter: false`), dropped by `unless` for each edge that sent a `stage_report` within `dataPolicy.reporterSilentAfter` (30m). Keyed on the configuration, so an edge that never reported fires too. `EdgeDiskLow`, `StageBacklogAgeing` and `QuarantinedDataUnresolved` read only those lines, so this is what says they have gone blind for that edge. It cannot see its own evaluator: with this Loki down, nothing fires. |
| `XNATUploadSuccess` | Loki ruler | `info`-severity receipt: `Successfully uploaded all files in '<session>'`, grouped by session. Range `[10m]`, retained from the historical ~62s emitter loop ; see the duplicate-mail section. Sessions with a `Repaired` line in the last 20m are left out: those are `XNATRepairAttempted`. |
| `XNATResourceIncompleteAndStuck` | Loki ruler | accessionflow's `already exists on XNAT with different checksums` ERROR from the management uploader, counted per session over 60m above the configured threshold, for 15m. XNAT reports files that conflict with staging. An add-only upload cannot resolve every conflict; preserve both versions and establish authority before recovery. |
| `XNATRepairAttempted` | Loki ruler | accessionflow's `Repaired N incomplete resource(s)` line in the `xnat-upload` namespace: XNAT already held the session with files missing, and the uploader tried to re-send them from staging. Logged whether or not that worked, so it claims only the attempt; a session that stays incomplete is never confirmed, and `SessionStagedNotConfirmedInXNAT` follows. Seen on 2026-09-23 and 2026-09-28 after XNAT restarts. One firing-only mail per edge per burst. |
| `XNATAuthFailure` | Loki ruler | 401/403 patterns in the `xnat-upload` namespace, with `!= "it/s"` retained as defense if progress output is re-enabled. `TQDM_DISABLE=1` has disabled it since 2026-10-28; the guard is not evidence of current progress lines. |
| `XNATUploadRetryStorm` | Loki ruler | More than 2 ERROR or traceback records from the management uploader (`component="upload"` in `xnat-upload`) in 10 minutes, for 10 minutes. The different-checksums phrase is excluded, as in tier-1's rule of the same name; `XNATResourceIncompleteAndStuck` covers that conflict per session. |
| `OrthancDeidLuaError` | Loki ruler | Lua traceback in the Orthanc log. Under `ingest`, the default, the script writes the facility backup, so an error can leave an original out of the archive. Under the deprecated `orthanc` engine the script also de-identifies, so an error there is a PHI risk, not a cosmetic one. |
| `IngestStageError` | Loki ruler | ERROR/CRITICAL stream severity or a decoded Python traceback from `group`, `group-fs`, `assign`, or `package`, grouped by edge and stage. Uses existing Vector logs; no remote-edge Kubernetes metrics are assumed. The 0.20.0 missing-ID diagnostic is covered by `InvalidSessionAssigned`; the older `DICOMValidationFailureSpike` text filter is not equivalent; redundant assign summaries are suppressed. |
| `DeidentifyStageError` | Loki ruler | ERROR/CRITICAL stream severity or the existing error/traceback text from `deidentify` in 10m. Keeps the same alert name for accessionflow de-identification. |
| `S3UploaderRestartedRecently` | Loki ruler | `refusing to start upload loop` / `alias_failed` / `endpoint_failed` / `dependency_missing` / `lock_failed` — the uploader's own refusals and stops (the pre-flight probe, a tool the image lacks, a writer lock that cannot be opened or taken), which otherwise look like silence. |
| `ManagementClusterDown` | Prometheus | `up{job="apiserver"} == 0` from management Prometheus. A failed scrape is the signal, not proof the entire cluster is down; missing series or a failed evaluator cannot fire this expression. |
| `EdgeWorkerDisconnected` | Prometheus | `kube_node_status_condition` — fires, but only ever for the management node; see `docs/components/kube-state-metrics.md`. |
| `SeaweedFSDown` | Prometheus | Deployment readiness, scraped from mgmt KSM. |
| `SeaweedFSDiskFull` | Prometheus | `SeaweedFS_volumeServer_resource` from SeaweedFS's own exporter (capitalised exactly so — PromQL is case-sensitive). |
| `CertificateExpiringSoon` | Prometheus | cert-manager's own metrics: fires when a certificate is more than a day past its renewal time (`certmanager_certificate_renewal_timestamp_seconds`, i.e. `notAfter - renewBefore`) or within 14 days of expiry. It used to fire at 60 days left, which every healthy 90-day certificate reaches 30 days before cert-manager renews it, so it mailed daily with nothing wrong. |
| `CertSyncStale` | Prometheus | `kube_cronjob_status_last_successful_time` for any `*-cert-sync-*` CronJob older than 24h — an edge whose Loki client cert stopped being refreshed. |
| `CertSyncNeverSucceeded` | Prometheus | A `*-cert-sync-*` CronJob that has had a scheduled run (`kube_cronjob_status_last_schedule_time`), or has existed 24h without one (`kube_cronjob_created`), `unless on (namespace, cronjob)` a last-success timestamp, held for 30m. Catches a site whose Secrets were never delivered at all, which "stale" cannot see. It waits for the first scheduled run because on a new edge that can be ~6h away; the old `kube_cronjob_info` form paged critical 2h after creation if nothing had succeeded yet, whether or not a run had been due. |
| `CARotationDue` | Prometheus | `ais-edge-ca` inside a year of expiry. Fleet-wide reissue is a planned job, not an incident, so it is `info`. |
| `CertificateRenewed` | Prometheus | `changes(certmanager_certificate_renewal_timestamp_seconds[1h])` — an `info` receipt that rotation is actually happening. |

The stage-error rules use a 10-minute lookback and a 1-minute hold. A single
error can fire; repeated errors are not required. Resolution means that the
matching log left the window, not that the stage recovered. The new group and
assign rule reads Vector's JSON log envelope and its `level` stream label.
`ingest.logFormat: json` supplies that severity for handled errors. A plain
Python traceback still matches through its decoded message. A malformed JSON
record is excluded from the message parser, and an absent severity field does
not turn an ordinary message containing "ERROR" into an error event.

These rules do not close OOM, CrashLoopBackOff, image-pull, or scheduling gaps
when the process emits no log. Tier-2 management kube-state-metrics reads only
the management cluster, so it cannot establish remote-edge pod health. Add an
explicit edge status/event transport before adding such remote-edge alerts;
this needs exporter/RBAC, transport, and telemetry-loss coverage. Tier-1 has
local kube-state-metrics and existing pod crash-loop/readiness alerts. Recovered
stage OOM attribution and firing, recovery, and notification-delivery drills
remain a separate follow-up. The existing backlog and reporter-silence alerts are useful symptoms, not proof
that each stage is alive. These log rules need no new exporter or permissions.

`kube-prometheus-stack`'s own rule pack is **not** part of that count:
`defaultRules.create: false` (`charts/mgmt/values.yaml`), so every Prometheus
alert in this stack is one of the thirteen above. There is no `KubePodCrashLooping`
or `KubeletDown` quietly backing us up.

Four alerts that used to be in this table are not, all removed after
measurement showed they could never fire — `docs/TOUR.md` §9 has the
evidence for each: `OrthancStorageGrowing` and `XNATBacklogGrowing` (Loki,
matched a log string that either does not exist or cannot distinguish new
arrivals from static backlog), `EdgePodCrashLoop` and
`KonnectivityTunnelFlapping` (Prometheus, named child-cluster objects mgmt
cannot scrape — zero series, confirmed live).

If a log-derived metric needs precomputation, add a recording rule to a
ruler rule group and configure its remote-write client to a Prometheus-compatible
metrics backend. Loki's rule-management APIs are not a time-series storage
backend for those samples. The destination, authentication, ruler WAL storage,
and delivery monitoring need their own configuration and validation. This is
an unimplemented extension, not a hidden capability already enabled here.
See [Loki recording rules](https://grafana.com/docs/loki/latest/operations/recording-rules/).
LogQL already supports sliding-window metric queries; precomputation is a cost
and reuse decision rather than a requirement for ordinary dashboard windows.

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

**Historical cause (2026-07-29 incident, before accessionflow 0.19.0).** The old uploader had **no S3 retention**. It rebuilds its work
list from a live listing of `s3://<bucket>/staged` on every `--loop` pass and
never deletes what it uploaded, so a session could linger and be re-processed
repeatedly by that implementation. The historical failure became *persistent* if the staging prefix contains
**empty directory entries**: the uploader lists each one as a session,
"uploads" its zero resources, and still logs

```
Successfully uploaded all files in '<session>'
```

which is exactly the string the `XNATUploadSuccess` rule matches — so a
0-byte prefix could generate a fresh success line every loop in that older implementation. The current `iterate_s3_sessions` skips directory-marker keys and the complete-session path returns before emitting success.

**Where the empty prefixes come from.** Cleaning up staging with the obvious
command:

```bash
mc rm --recursive --force edge/ingest-bucket/staged/     # ← DO NOT
```

On SeaweedFS this deletes the **objects** but leaves the **directory entries**
as 0-byte prefixes. `mc ls` then shows N prefixes with 0 files — the exact
state that produces the bogus successes.

**Historical cleanup, not a current recovery recommendation.** Filer directory deletion was used for the old incident. Current empty markers are harmless to session discovery. The helper has no writer fence, so even an initially empty prefix can receive a new object between its count and recursive deletion. Do not use it to diagnose duplicate mail on a live bucket:

```text
Historical helper interface, retained for identification only:
  scripts/clear-staged-s3.sh <site> [edge]
This is not an approved live-bucket cleanup procedure.
```

`<site>` is the directory under `sites/` that `install.sh` takes. The script
reads it to find the edge, a derived bucket name (`ingest-<edge>` when `perSiteBuckets` is
on; it does not honor every per-edge bucket override or bucket-prefix value), and then discovers the filer and both uploaders **by label**
(`component=seaweedfs`, `component=upload,edge=<name>`, `component=s3-uploader`)
rather than by hardcoded name.

> **What changed since.** The pinned uploader is accessionflow 0.20.0 (`helpers/remotes.py`, `iterate_s3_sessions`)
> builds its session list from the object keys and skips a key that ends in
> `/`, so an empty folder is not a session to it, and `mgmt-reclaim-<edge>`
> leaves the session folder behind on purpose: it deletes the objects one by
> one with `If-Match`, because a filer folder delete can drop a child written
> meanwhile (measured on 4.34; `docs/components/seaweedfs.md`, "Deleting
> staged objects"). The 0-byte prefixes this script removes are therefore
> harmless to delivery now. The script still deletes them through the filer,
> without a concurrency guard. The former advice to scale the uploader to zero
> also conflicts with the helper: it executes rclone inside that running pod. A
> separately designed maintenance job, checked bucket identity and writer fence
> would be needed before safely reusing this mechanism. This review does not
> authorize or execute any cleanup.

> It used to take no arguments and address `seaweedfs/seaweedfs`,
> `xnat-ingest-upload` and a fleet-wide `ingest-bucket` — all pre-consolidation
> names — while counting objects with `mc`, which the current uploader image
> does not contain. Every call was `|| true` or `2>/dev/null`, so it printed its
> normal output, reported "removed 0 empty prefixes" and changed nothing. That explains why an old invocation could report no change; it is not a
> reason to re-run the current helper. Diagnose the emitter and receiver first.

> **Historical intended safety check, insufficient under concurrent writes.** The
> default mode counts objects and intends to keep nonempty sessions ; a staged
> session may not have reached XNAT yet (XNAT down, bad credentials, backlog),
> and deleting it would lose undelivered data. The script prints which
> sessions it kept and why.
>
> `scripts/clear-staged-s3.sh <site> [edge] --all` wipes the whole staging
> prefix including undelivered sessions. It prompts for confirmation and is
> intended for resetting demo/test environments only — never point it at
> production.
>
> **Listing behavior changed.** The current helper uses rclone, not AWS CLI. It
> distinguishes a listing failure from empty output using the command status.
> The older AWS exit-code discussion does not describe this script anymore. If the listing cannot be read the script
> aborts rather than reporting "nothing to do".

**Verify it is quiet:**

```bash
# Management side. The uploader renders once PER EDGE, as mgmt-upload-<edge>
# in xnat-upload — there is no single fleet-wide uploader to look at.
kubectl -n xnat-upload logs deploy/mgmt-upload-<edge> --since=3m \
  | grep -E 'Successfully uploaded|Repaired|ERROR|Traceback'
# Read the log-command exit status separately; no matches is not proof of health.

# Edge side. Lists the staging prefix with the rclone binary the uploader pod
# actually carries (the initContainer stages it in /opt/rclone; the `sw:`
# remote comes from the pod's RCLONE_CONFIG_SW_* environment), against this
# site's own bucket (ingest-<edge>, the default under seaweedfs.perSiteBuckets).
kubectl --kubeconfig=kubeconfig-<edge> -n xnat-ingest exec deploy/edge-s3-uploader -- \
  /opt/rclone/rclone lsd sw:ingest-<edge>/staged/ --log-level ERROR
                                         # directory markers may remain harmlessly
```

> These names matter more than they look. `rclone lsd` **prints nothing on an
> empty prefix**, so "no output" is the success case here — but so is a wrong
> Deployment name or a wrong bucket (those exit non-zero: read the exit code,
> not only the output). Neither `mc` nor `aws` is in the uploader image at all
> (it runs a plain Ubuntu, `upload.s3.shell.image`, with rclone staged in), and
> a fleet-wide `ingest-bucket` only exists when `seaweedfs.perSiteBuckets` is
> turned off.
> Get any of them wrong and the check reports the same quiet nothing as a
> healthy system — the identical failure mode the note above describes for the
> script itself. `scripts/clear-staged-s3.sh` prints the exact management-side
> command for the site you ran it against; verify names and the resolved bucket against rendered manifests before using any diagnostic command.

Repeated success for the same session in 0.20.0 needs investigation of new writes, repair attempts, image identity, and multiple workers. Empty prefixes alone no longer explain it. Read-only listings do not prove that content reached XNAT; use the reclaimer proof and file inventory for that determination.

The following explanation records older uploader behavior. In accessionflow
0.20.0 a complete-session skip bypasses the success line, and the loop waits
for the remainder of its interval. The existing alert window remains in
place; the old measurements explain its origin.

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
For a fresh notification drill, use a distinct test alert identity in an
isolated nonproduction receiver and inspect Alertmanager's route, silence,
inhibition, and notification log state. A pod restart should preserve that
state; retention is 744h on this branch, longer than the 720h route interval.
Repeat suppression also depends on whether a prior alert resolved and whether
the notification group changed, so it is not an exactly-once delivery promise.

The former demo procedure deleted Alertmanager's PVC and stripped its
protection finalizer. Those executable commands are intentionally withdrawn:
they discard silences and notification history for unrelated alerts and can
race mounted storage. A test notification does not require resetting the
production database. If an isolated test installation is intentionally rebuilt,
its storage lifecycle and loss of notification state should be handled as part
of that separately approved environment teardown, not as a routine alert fix.

For duplicate reports, correlate four timestamps: the underlying uploader
record, the ruler's firing/resolved transition, Alertmanager's group update,
and the receiver delivery. Preserve the session and alert labels in that
comparison while avoiding patient-identifying values in shared reports. A mail
retry can duplicate delivery without a new pipeline event; a new alert
fingerprint can create a new group despite the same display title. Confirm the
actual image digest and rule loaded by the evaluator before comparing a live
incident to the historical behavior recorded above.



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
after its 75-minute pending period, subject to evaluation and notification delays), and, best-effort, one
`reclaim_unavailable` per staged session (capped, to avoid tripping a Loki
ingestion limit and restoring the exact silence this exists to prevent) so
the absence alert can retain a staged signal during an outage. Enumeration
failures, the cap, or log loss can still leave individual sessions uncovered. It must never emit `reclaim_finished` ; a healthy no-op run and an
aborted run must not look identical in the log.
