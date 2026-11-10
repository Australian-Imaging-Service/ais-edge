# Orthanc

The pipeline tool is accessionflow (called xnat-ingest before 0.18.0).

## Overview

[Orthanc](https://www.orthanc-server.com/) is a lightweight,
open-source DICOM server. In ais-edge it sits at the edge of each site,
acts as the **DICOM receiver** for local modalities, and runs the AIS
**Lua hook**, which writes the facility backup and labels stable studies
before accessionflow groups and stages the data. Under the default
`deid.engine: ingest` the hook does not de-identify: the accessionflow
`deidentify` stage does that later. The Lua
de-identification engine (`deid.engine: orthanc`) is deprecated. See
[deidentification.md](deidentification.md).

We use the [`jodogne/orthanc-plugins`](https://hub.docker.com/r/jodogne/orthanc-plugins)
image (pinned to a version ≥ 1.12.0 because the deid hook uses
**study-level labels**, introduced in 1.12.0).

## Role in this stack

Three jobs at each edge:

1. **DIMSE C-STORE SCP** on host port 4242 with `AET=AISEDGE`. Modalities
   on the local facility LAN push studies here.
2. **Lua `OnStoredInstance` hook** writes the ORIGINAL DICOM to
   `/facility-backup` (site-controlled retention). Under the default
   `deid.engine: ingest` it then returns, and the instance stays in Orthanc
   unchanged (`charts/edge/files/deidentify-and-forward.lua:167`). Only the deprecated
   `orthanc` engine runs `/instances/{id}/modify` to produce a de-identified
   copy, deletes the original and keeps the de-identified instance.
3. **Lua `OnStableStudy` hook** PUTs the `xnat-ingest-ready` label on each
   study once it's been quiescent for `StableAge` seconds. Under `ingest` no
   stage waits for it: `group-orthanc` pulls each study that has been quiet
   for `ingest.orthancGroup.waitPeriod`. Under the deprecated `orthanc` engine
   the label is the signal for `accessionflow collate-orthanc` to REST-pull the
   study. This callback has no `DeidEnabled` guard, so it also runs under
   `ingest` whenever the script is loaded. The label shows that a study is
   stable. It does not show that the recipe ran.

After `group-orthanc` hardlinks the instances into `/data/grouped/`, it
PUTs the `xnat-ingest-processed` label on the study so subsequent
`group-orthanc` cycles skip it. `accessionflow label xnat` then collates the
grouped session into `/data/assigned/`, and the `deidentify` stage writes the
de-identified copy to `/data/deidentified/`. That is the tree the edge
s3-uploader syncs to SeaweedFS (`/data/packaged/` with the optional package
stage). (There is no `staging/` directory on the edge;
"staged" refers to the S3 side. See [accessionflow.md](accessionflow.md).)

```
Modality ──C-STORE──► Orthanc :4242 (AET=AISEDGE)
                          │
                          ├─ OnStoredInstance:
                          │   1. backup → /facility-backup
                          │   2. deid.engine: ingest (default): stop here, the
                          │      instance stays in Orthanc unchanged
                          │   (deprecated orthanc engine only: /modify (deid;
                          │      UIDs kept) → new instance, same Study, then
                          │      delete ORIGINAL)
                          │
                          └─ OnStableStudy (after StableAge=30s silence):
                              PUT /studies/{id}/labels/xnat-ingest-ready
                                                      │
                                                      ▼
                                accessionflow collate-orthanc REST-pulls,
                                hardlinks, PUTs label xnat-ingest-processed
                                (under ingest it does not wait for the label)
```

A series that arrives after `group-orthanc` staged its study makes the study
unstable again. When it is stable, `OnStableStudy` removes the
`xnat-ingest-processed` label and applies `xnat-ingest-ready`, so the next
`group-orthanc` pass stages the whole study again. The log event is
`study_reopened`. Label writes do not change `LastUpdate`, so an unchanged
study is never re-staged.

The chart default image is upstream accessionflow 0.19.0
(`ingest.image` in `charts/edge/values.yaml`). It contains xnat-ingest PR #211,
which upstream merged on 2026-10-28 and released before this pin. An image without
it, such as upstream 0.16.2, writes no snapshot label. With such an image an
armed data policy keeps every Orthanc study (`reclaim_kept`, reason
`export_state_unknown`), and `/data/orthanc-storage` grows. With PR #211,
`group-orthanc` also writes a snapshot label,
`xnat-ingest-processed-<LastUpdate>-<digest>`, when it labels a study, and
re-stages any processed study whose `LastUpdate` no longer matches it. The data
policy (`dataPolicy.derived.orthancStorage`, backend `orthanc-rest`) deletes a
study only when that snapshot label matches what Orthanc holds now, and then
deletes exactly the instances the label covers. A study without a matching
snapshot label is kept and logged (`reclaim_kept`, `export_state_unknown`).
A dry run makes the same keep checks and logs the same `reclaim_kept` and
`reclaim_skipped` lines. Where an armed run
deletes, it logs `WOULD delete` (`reclaim_skipped`).

The delete is one `POST /tools/bulk-delete` with the instance ids of the study.
The engine sends that body from a file, so the size of the study does not
matter. The time limit of the delete is 30 s (the engine's `HTTP_TIMEOUT`) +
1 s per 100 instances: Orthanc took 34 s for 12,098 instances on the test edge
(2026-11-10). A delete that Orthanc does not confirm logs `reclaim_failed` with
`curl_exit`: 22 means that Orthanc answered 400 or more, 28 that it did not
answer in time. Before 2026-11-10 the body went on curl's command line, which
holds at most 128 KiB, so a study of more than about 2,780 instances was never
deleted (logged as `Orthanc refused the delete`).

## What Orthanc has access to

| Resource | Why |
|---|---|
| Host network port 4242 (`hostPort`) | Modality C-STORE inbound from local facility LAN |
| The shared pipeline PVC, mounted at `/data` (hostPath `/data/xnat-ingest`) | Orthanc writes its DICOM storage tree to `/data/orthanc-storage`. It is the **same claim every ingest stage mounts**, which is what guarantees `orthanc-storage/`, `grouped/` and `assigned/` share one filesystem — a hardlink cannot cross a filesystem boundary (EXDEV), and `hardlink_or_copy` would silently degrade to a full byte copy of every study |
| hostPath `/data/facility-backup` mounted as `/facility-backup` | Canonical local copy of every received original DICOM. Site-controlled retention. Independent of AIS lifecycle. |
| Three ConfigMaps, mounted at **two** paths | `orthanc-config` (orthanc.json) and `orthanc-scripts` (the Lua hook) under `/etc/orthanc/`; `orthanc-routing` — which carries **both** `routing.json` and `deidentification-profile.json` — under `/etc/ais-edge/`. The split is load-bearing, not tidiness: see "Configuration" below |
| One Secret env var | `AIS_DEID_HMAC_SALT`, the salt of the Lua hook. The script stops at load without it, so the pod needs it whenever the facility backup is on. Only the deprecated `orthanc` engine uses the value, for SubjectHash / SessionHash |
| One mounted Secret | `orthanc-credentials` → `/etc/orthanc/users.json` (one key, by `subPath`). It is a configuration fragment that Orthanc merges, because it scans `/etc/orthanc`. Orthanc has no `RegisteredUsersFile` option. The REST API can delete studies, so it is authenticated rather than protected only by being ClusterIP-only |
| No outbound network | Doesn't talk to XNAT, doesn't talk to other AIS pods. accessionflow collate-orthanc and the data-policy engine talk to it (in-cluster Service). |

## Where it runs

Single pod (`Recreate` strategy — hostPath isn't shareable across
replicas), one per edge worker. Deployed by the edge chart; template at
[`charts/edge/templates/orthanc-deployment.yaml`](../../charts/edge/templates/orthanc-deployment.yaml).

REST API exposed as a ClusterIP Service
`edge-orthanc.xnat-ingest.svc.cluster.local:8042` — every Orthanc object
is **release-prefixed** (`{{ include "edge.fullname" . }}-orthanc`), and
`install.sh` installs the edge chart as release `edge`, so the objects
are `deploy/edge-orthanc` and `svc/edge-orthanc`. That prefixed address
is exactly what the chart passes to `group-orthanc`; a site installed
under a different release name shifts both.

DICOM port 4242 is exposed via `hostPort` directly on the edge node IP
so modalities can reach it without an in-cluster Service. (The Service
flips to `NodePort` if `orthanc.expose.dicom` or `orthanc.expose.http`
asks for it — the default keeps the REST API in-cluster only.)

## Configuration

Nothing here is edited as a file. [`charts/edge/templates/orthanc-config.yaml`](../../charts/edge/templates/orthanc-config.yaml)
renders three ConfigMaps from `sites/<site>/values.yaml`, so the site file is
the only thing you change. (These used to be hand-edited copies under
`config/orthanc/`; that directory is gone — it fed nothing, and editing the
copy of the Lua script it held changed nothing at all.)

**Why the three ConfigMaps land on two paths.** Orthanc is started with
a *directory* as its configuration argument and merges every `*.json` in
it as server configuration — verified on a running edge:

```
Scanning folder "/etc/orthanc" for configuration files
Reading the configuration from: "/etc/orthanc/orthanc.json"
Reading the configuration from: "/etc/orthanc/deidentification-profile.json"
Reading the configuration from: "/etc/orthanc/routing.json"
```

So the old single-path layout had Orthanc ingesting our AET routing
table and our de-identification profile as *server settings*. It is
harmless today only by accident — none of `AETMap`, `Defaults`, `Keep`,
`Replace`, `Force`, `DeidMode` or `RemovePrivateTags` collides with a
real Orthanc setting — but the scan order is filesystem order, so a
future key that did collide would reconfigure the server silently and
non-deterministically. Hence: `/etc/orthanc/` holds **only**
`orthanc.json` plus `scripts/`, and `/etc/ais-edge/` holds
`routing.json` plus `deidentification-profile.json`, which our Lua hook
reads by path and Orthanc never scans.

| Rendered file | Built from | What it does |
|---|---|---|
| `orthanc.json` | `orthanc.*` and `dataPolicy.derived.orthancStorage.*` | Daemon config: AET, ports, storage path, `StableAge`, points at the Lua script |
| `deidentify-and-forward.lua` | `.Files.Get "files/deidentify-and-forward.lua"` | The backup + label hook, and the deprecated de-identification engine. **Identical across all AIS-Edge deployments**: no site-specific bits, which is why it is a chart file and not a value |
| `routing.json` | `orthanc.deid.aetMap` and `ingest.orthancGroup` | `Defaults`: the backup directory, `DeidEnabled` (false unless `deid.engine: orthanc`) and the label names. The AE-title map is read only under the deprecated `orthanc` engine: it maps called AE titles to XNAT projects, and an unmapped AE title is quarantined, not dropped. Mounted at `/etc/ais-edge/`, not `/etc/orthanc/` |
| `deidentification-profile.json` | `orthanc.deid.profile` | Deprecated engine only: Replace + Keep blocks following Orthanc's `/modify` API. Under `deid.engine: orthanc` the chart **refuses to render** an empty profile: it hands `/modify` nothing to change, so studies would reach XNAT with PHI intact and nothing would look wrong. Under `ingest` nothing reads it. Rendered into the same `orthanc-routing` ConfigMap as `routing.json` |

Two Secrets, both from `sites/<site>/secrets.enc.yaml`:

**`orthanc-deid-salt`** (`orthanc.deid.existingSaltSecret`, key
`AIS_DEID_HMAC_SALT`): the salt of the Lua hook. Generate it with
`openssl rand -hex 32`. The pod needs it whenever the facility backup is on,
because the script stops at load without it. Under the default
`deid.engine: ingest` nothing uses the value, so a rotation changes no XNAT
label. Restart Orthanc after a rotation. Under the deprecated `orthanc` engine
it is the pseudonym salt: a rotation gives the same patient a different
identity, so such a site keeps it.

**`orthanc-credentials`** (`orthanc.auth.existingSecret`): **three keys, not
two**, because three different things consume it:

| Key | Consumed by |
|---|---|
| `users.json` | Orthanc itself, mounted at `/etc/orthanc/users.json`. Orthanc merges every `.json` in `/etc/orthanc` as configuration. Shape: `{"RegisteredUsers":{"admin":"<password>"}}`. The password is **plaintext inside that JSON**, which is why this Secret belongs in the SOPS-encrypted site file |
| `orthanc-user`, `orthanc-password` | `accessionflow collate-orthanc`, which calls the REST API to list and label studies, and the data-policy engine, which reclaims the Orthanc store over the same API |

If those disagree with the user in `users.json`, Orthanc answers 401:
`group-orthanc` crash-loops with data sitting in Orthanc, and the store
reclaim finds nothing to do. A Secret built with only the last two keys
installs cleanly, and *then* Orthanc does not start, because the pod cannot
mount the `users.json` key. That is why the chart fails the render outright
when `orthanc.auth.enabled` names no Secret.

## Operations

```bash
# Pod state
kubectl --kubeconfig kubeconfig-<edge> get pods -n xnat-ingest -l app=orthanc

# Logs. Under ingest: instance_archived, study_labeled_ready, study_reopened.
# The deprecated orthanc engine also logs instance_deidentified.
# Object names are release-prefixed: `edge` is the release install.sh uses.
kubectl --kubeconfig kubeconfig-<edge> logs -n xnat-ingest deploy/edge-orthanc

# Orthanc Explorer UI (port-forward + browser). Auth is ON: log in with the
# user from the orthanc-credentials Secret's users.json.
kubectl --kubeconfig kubeconfig-<edge> port-forward -n xnat-ingest svc/edge-orthanc 8042:8042
# → http://localhost:8042/app/explorer.html

# DICOM endpoint smoke-test from a modality side or with dcmtk
storescu -aec AISEDGE -aet TEST_MOD <edge-ip> 4242 /path/to/study/*.dcm
```

## Known limitations

- **Orthanc storage is cleaned only by the data policy.** Under the default `deid.engine: ingest` Orthanc holds the instances as they arrived, identifiable. `dataPolicy.derived.orthancStorage` (backend `orthanc-rest`, `reclaim: onGrouped`, `minAge: 7d`) deletes a study after `group-orthanc` staged it and its snapshot label matches, and only when the policy is armed (`enabled: true`, `dryRun: false`). Until then Orthanc storage grows. See the snapshot label paragraph above.
- **Deprecated engine only: a pure-Lua salted hash instead of a true HMAC** for SubjectHash / SessionHash, because `jodogne/orthanc-plugins` doesn't expose `Compute*` crypto in Lua. Adequate for research deid; switch to `jodogne/orthanc-python` for HMAC-grade. Under `ingest` the hook makes no hash.
- **Recipe authoring is by hand.** Nothing checks that the tags in a recipe exist before deployment. What replaced the old `07c` prompt is a **render-time gate**: `deid.policyReviewed` (`charts/edge/values.yaml`, top level, not under `orthanc:`, because it gates every engine) has no safe default, and the chart refuses to install until a human sets it true. Under `ingest` that confirms the recipe in `ingest.deidentify.specs` (`charts/edge/templates/_helpers.tpl:243-247`). Under the deprecated `orthanc` engine it confirms the profile and the AET map, and the chart also fails an empty `aetMap` and an empty `profile` (`charts/edge/templates/_helpers.tpl:250-260`). It is a gate, not a validator: it confirms a human read the policy, not that the tags in it exist.
- **Hardlinks require a shared filesystem** — `orthanc-storage/`, `grouped/` and `assigned/` must live on one mount, or group-orthanc's `hardlink_or_copy` degrades to a full byte copy (and a true hardlink would fail with EXDEV). This is structurally guaranteed rather than left to the operator: every stage mounts the **same pipeline PVC** at `/data`, backed by `storage.pipeline.hostPath: /data/xnat-ingest`. Splitting them across volumes is the way to break it.
- **Deprecated engine only: modalities with unmapped CalledAETs are rejected for ingest, but not discarded.** Under the default `ingest` engine the script returns before this lookup (`charts/edge/files/deidentify-and-forward.lua:167`), so no AE title is rejected. Under `deid.engine: orthanc` the original instance is written to `<FacilityBackupDir>/__unmapped_aet__/<AET>/<PatientID>/<StudyUID>/<SOPUID>.dcm` and only then removed from Orthanc. If that quarantine write fails the instance is kept in Orthanc instead, and if no `FacilityBackupDir` is configured the hook aborts without deleting anything. A `REJECT: no project mapped for CalledAET <AET>` line is logged, which is what the `DICOMRejectedUnmappedAET` alert matches. Add the AET to `routing.json` AETMap and re-send to ingest the quarantined studies.
- **Deprecated engine only: `AIS_DEID_HMAC_SALT` rotation breaks subject linkage.** Under `deid.engine: orthanc`, rotating the salt produces a different SubjectHash for the same patient. Under `ingest` nothing uses the value, so a rotation changes no XNAT label.
