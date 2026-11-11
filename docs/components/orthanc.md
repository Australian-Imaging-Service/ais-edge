# Orthanc

The pipeline tool is accessionflow (called xnat-ingest before 0.18.0).

## Overview

[Orthanc](https://www.orthanc-server.com/) is a lightweight,
open-source DICOM server. In this tier-1 single-node appliance it acts as the
**DICOM receiver** for local modalities. Under the default ingest engine it
stores original instances. The enabled backup callback writes a separate copy;
accessionflow de-identifies later, after assignment.

We use the [`jodogne/orthanc-plugins`](https://hub.docker.com/r/jodogne/orthanc-plugins)
image, pinned in `orthanc.image.tag` (currently `1.12.11`). It must stay
at or above 1.12.0 for the **study-level labels** used by grouping and cleanup.
Labels record processing state; they are not a de-identification certificate.

## Role in this stack

The backup callback immediately returns unless `origin.RequestOrigin` is
`DicomProtocol`. A REST POST to Orthanc can test storage and downstream stages,
but it does **not** test facility-backup creation. File drops also bypass that
callback. Use a synthetic C-STORE send and inspect the archived file when
validating the backup path. A successful receive does not prove the backup,
assignment or de-identification succeeded.

Three jobs apply to the default ingest pipeline:

1. **Receive DICOM.** Orthanc runs the DIMSE C-STORE SCP on host port 4242 with
   called AET `AISEDGE` by default. Modalities send to the node's reachable LAN
   address. The shipped `DicomAlwaysAllowStore` and empty modalities map allow
   calling AE titles; enforce sender restrictions at the network boundary.
2. **Store and back up the original.** Orthanc keeps the input in its own
   storage directory. When `storage.facilityBackup.enabled` is true, the Lua
   `OnStoredInstance` callback writes a byte copy to `/facility-backup`.
   With `DeidEnabled=false`, it returns before the AET lookup and `/modify`.
   There is no unknown-AET quarantine or project routing in ingest mode.
3. **Provide the grouping source.** group-orthanc reads the REST API and the
   shared storage tree. It waits for stable input, publishes grouped studies,
   and records processed labels and an export snapshot. The chart clears the
   effective ready-label filter under ingest, so selection does not depend on
   the Lua ready label. When the backup feature loads the script, its separate
   `OnStableStudy` callback can still apply that label and clear an existing
   processed label. This callback has no `DeidEnabled` guard. The label does
   not mean the ingest recipe has run.

```
Modality --C-STORE--> Orthanc :4242 (called AET=AISEDGE)
                          |
                          +-- original instances -> /data/orthanc-storage
                          |
                          +-- enabled backup callback -> /facility-backup
                          |   then return; no routing or header modification
                          |
                          +-- REST API :8042, inside the cluster
                                      |
                                      v
                               group-orthanc
                               stable-study selection
                               hardlink -> /data/grouped
                               processed + snapshot labels
                                      |
                                      v
                               assign -> deidentify -> upload
```

A backup failure is logged and the callback returns without modifying the
instance. The original is still in Orthanc, but the error does not become an
AET quarantine entry. Investigate backup capacity, permissions and storage.
Do not treat a successful C-STORE response as proof that a separate backup copy
exists, that a study was assigned, or that de-identification succeeded.

The group stage uses processed state to avoid exporting unchanged input on every
pass. The pinned `ghcr.io/australian-imaging-service/accessionflow:0.20.0` image includes
snapshot support. It writes a label of the form
`xnat-ingest-processed-<LastUpdate>-<digest>`. A processed study whose update
state changed can be staged again. This is important when a later series arrives
for a study that was already exported. A stable interval is a waiting rule,
not a guarantee that no more instances will arrive.

The data-policy `orthanc-rest` backend uses that snapshot before deletion. It
requires the processed label, unchanged update state, and a digest matching the
current instance list. It deletes only the covered instances. Missing or
unreadable snapshot state causes a keep decision with
`reclaim_kept`, reason `export_state_unknown`. An older image without snapshot
support can therefore leave all studies in Orthanc even with cleanup enabled.
Do not remove the keep check to clear a disk alert; identify the image and the
unconfirmed export first.

With a dry run, the same keep checks apply. A would-delete decision is logged
as `reclaim_skipped`; it is not a deletion receipt. Check the configured engine,
image, data policy and current source state together before interpreting a
cleanup log. The filesystem path is useful for capacity reporting, but deleting
UUID-named files directly would bypass Orthanc's index and the export checks.

The delete is one `POST /tools/bulk-delete` with the instance ids of the study.
The engine sends that body from a file, so the size of the study does not
matter. The time limit of the delete is 30 s (the engine's `HTTP_TIMEOUT`) +
1 s per 100 instances: Orthanc took 34 s for 12,098 instances on the test edge
(2026-11-10). A delete that Orthanc does not confirm logs `reclaim_failed` with
`curl_exit`: 22 means that Orthanc answered 400 or more, 28 that it did not
answer in time. Before 2026-11-10 the body went on curl's command line, which
holds at most 128 KiB, so a study of more than about 2,780 instances was never
deleted (logged as `Orthanc refused the delete`).

The deprecated Lua de-identification mode is documented only in
[Deprecated Orthanc Lua engine](deidentification.md#deprecated-orthanc-lua-engine).
Its project map, hash and quarantine path do not run in the ingest
`OnStoredInstance` callback. The stable-study label callback is shared when
the script is loaded. Keep ingest for new sites.

## What Orthanc has access to

| Resource | Why |
|---|---|
| Node port 4242 (`hostPort`, from `orthanc.expose.dicom`) | Modality C-STORE inbound from local facility LAN. The port can be bound only once per node; scheduling and PV placement choose the node, while Recreate avoids overlapping receiver pods |
| PVC `<release>-pipeline` mounted at `/data` | Backed by a hostPath PV at `storage.pipeline.hostPath` (`/data/xnat-ingest`). Holds `orthanc-storage/`, `grouped/`, `assigned/`. **One pipeline PVC for all stages** so hardlinks work (cross-fs hardlink fails with EXDEV) |
| PVC `<release>-facility-backup` mounted at `/facility-backup` | Backed by hostPath `storage.facilityBackup.hostPath`. Byte copy of successfully archived DICOM-protocol input, written as `<PatientID>/<StudyUID>/<SeriesUID>/<SOPUID>.dcm`. Site-controlled retention. Kept by default; the original-expiry policy can remove patient directories only when its explicit enable/expiry gates are armed. |
| Three ConfigMaps at TWO paths | `<release>-orthanc-config` → `/etc/orthanc/orthanc.json`, `<release>-orthanc-scripts` → `/etc/orthanc/scripts/`, `<release>-orthanc-routing` → `/etc/ais-edge/` (routing.json + deidentification-profile.json). See Configuration for why the second path exists |
| One Secret env var | `AIS_DEID_HMAC_SALT` from `orthanc.deid.existingSaltSecret` (`orthanc-deid-salt`); required when the backup script loads; its value is unused for ingest labels or recipe output |
| Optionally Secret `orthanc-credentials` | Only when `orthanc.auth.enabled` is true; mounted as `/etc/orthanc/users.json`. The tier-1 example leaves auth off; ClusterIP does not authenticate callers. **Enabling it: see the step-by-step in [TOUR.md](../TOUR.md) (section 3) or the README's *Orthanc REST API Authentication* section; the Secret needs THREE keys (`users.json`, `orthanc-user`, `orthanc-password`), and a Secret with only the last two installs cleanly and then stops Orthanc from starting.** |
| No application forwarding configured | Orthanc is the receiver; downstream stages call its REST API. The chart does not enforce an egress NetworkPolicy, so this is not a network isolation guarantee. |

## Where it runs

Single pod (`Recreate` strategy — the hostPath-backed index isn't shareable
across replicas, and two Orthancs cannot share one SQLite index) on the single
node. Rendered by
[`charts/edge/templates/orthanc-deployment.yaml`](../../charts/edge/templates/orthanc-deployment.yaml)
and installed by step 3 of `./install.sh <site>`.

REST API exposed as a ClusterIP Service
`<release>-orthanc.xnat-ingest.svc.cluster.local:8042` (this is how
`accessionflow collate orthanc` queries metadata and updates labels; it reads
DICOM bytes from the shared local store). `<release>` is the site name unless
`AIS_RELEASE` overrides it. DICOM port 4242 is exposed via `hostPort` directly
on the node's IP so modalities can reach it without an in-cluster Service —
`orthanc.expose.dicom` can be switched to `nodePort` or `both` instead.

## Configuration

Receiver settings live under `orthanc:` in `sites/<site>/values.yaml`.
Assignment and recipe settings live under `ingest:`. The policy gate is the
top-level `deid.policyReviewed` key. There is no separate site config directory
or env file. The chart renders receiver configuration and mounts ingest recipes
from the site values. The table separates these responsibilities.

| Values key | What it does |
|---|---|
| `orthanc.aet`, `orthanc.dicomPort`, `orthanc.httpPort` | Identity and ports of the SCP |
| `orthanc.stableAge` | Seconds of silence before Orthanc marks a study stable. Ingest grouping also has its own wait period. Its effective ready-label filter is cleared by the chart; no Lua ready label is required. |
| `orthanc.expose.dicom` / `.http` | `hostPort` \| `nodePort` \| `both` for DICOM; `ClusterIP` \| `nodePort` for the REST API. Do not expose HTTP without `orthanc.auth.enabled` — the REST API can delete studies |
| `ingest.assign.tagMapping` / `constantProjectId` | XNAT placement is configured at assignment, not at the receiver. Defaults select StudyID, PatientID and AccessionNumber. Review the values before receiving patient input. |
| `ingest.deidentify.specs` | The ingest recipe map is the policy that changes headers. Legacy `orthanc.deid.profile` and `aetMap` values can still be rendered, but are not used for de-identification or routing in ingest mode. See the deprecated reference for existing sites. |
| `deid.policyReviewed` | **Not under `orthanc.`** (moved; the old path now fails the render). Render-time gate, no safe default, and it covers every `deid.engine` rather than just the Lua hook. The chart refuses to template while this is false |
| `orthanc.image.tag` | Pinned Orthanc version |

The Lua hook itself,
[`charts/edge/files/deidentify-and-forward.lua`](../../charts/edge/files/deidentify-and-forward.lua),
is **shared chart source across sites using this chart revision** ; no site-specific bits. It is
loaded with `.Files.Get` rather than inlined so it stays lintable and diffable.

**Why routing.json and the profile are NOT under `/etc/orthanc`.** Orthanc is
started with a directory argument and reads *every* `*.json` in it as server
configuration. A historical live observation, date not recorded, showed
`routing.json` and `deidentification-profile.json` being read as settings. That
observation was not replayed on 2026-11-10. Even if no key currently collides, the
scan order is filesystem order, so a future key that does collide would silently
reconfigure the server. So `/etc/orthanc/` holds only `orthanc.json` and
`scripts/`, plus optional `users.json` when authentication is enabled. The hook reads its own inputs from `/etc/ais-edge/` via
`AIS_ROUTING_FILE`.

**The pod rolls itself when the config changes.** The Deployment carries a
`checksum/config` annotation over the rendered ConfigMaps, so a changed AET map,
profile or Lua hook restarts Orthanc on `helm upgrade`. Editing a ConfigMap by
hand still does nothing until the pod restarts.

The backup script still needs Secret `orthanc-deid-salt`, key
`AIS_DEID_HMAC_SALT`, unless `orthanc.deid.existingSaltSecret` names another one.
Generate a value with `openssl rand -hex 32` and keep it in the site's encrypted
secrets file. Install rejects `REPLACE_` placeholders. The live verifier also
checks the placeholder and hexadecimal form. The chart checks the required
Secret name, but a template render cannot check the live value.

Under ingest the callback returns before using that value in a hash. Rotation
does not change ingest XNAT labels. Do not confuse it with the optional ingest
transform salt sidecar, which the chart does not wire as a Secret, or with the
reid-map encryption key, which has its own setting. A missing variable still
causes a script-load error, so the startup prerequisite must remain configured.

Render-time gates cover policy review, required Secret names and the engine's
actual recipe source. Ingest does not need a non-empty AET map or Lua profile.
The `deidentify` stage does need inline specs or a valid external ConfigMap
mapping. The chart also derives the ready-label filter and upload source from
the engine selector. Read a validation error at its named key rather than
copying a legacy engine's settings into the site.

After changing receiver settings, render the chart and inspect the ConfigMaps,
ports and Secret references before deployment. The checksum annotation causes
an Orthanc rollout when its rendered configuration changes. The hostPort and
SQLite storage mean only one receiver instance can own this node's endpoint.
Coordinate any live rollout with the modality operators so interrupted sends
can be retried and the post-rollout receive test is meaningful.

## Operations

```bash
# Pod state  (RELEASE is the site name unless AIS_RELEASE was set)
kubectl get pods -n xnat-ingest -l app=orthanc

# Logs: receiver, backup failures and script startup errors
kubectl logs -n xnat-ingest deploy/<release>-orthanc

# Orthanc Explorer UI (port-forward + browser)
kubectl port-forward -n xnat-ingest svc/<release>-orthanc 8042:8042
# → http://localhost:8042/app/explorer.html

# DICOM endpoint smoke-test from a modality or with dcmtk. -aec is the CALLED
# AET from orthanc.aet, not an XNAT project selector. Use a synthetic study.
storescu -aec AISEDGE -aet TEST_MOD <nodeIP> 4242 /path/to/study/*.dcm
```

## Known limitations

- **The Service exposure switches share one Service.** If either DICOM or
  HTTP selects `nodePort`, the Service type becomes NodePort for both ports.
  Kubernetes can allocate an HTTP node port even when `.http` is `ClusterIP`,
  because that value merely omits an explicit nodePort number in this template.
  Inspect the rendered and live Service and restrict access; do not use the
  HTTP selector alone as proof that port 8042 is internal.
- **One receiver Deployment per release.** It has one replica and uses Recreate.
  A hostPort prevents two pods using the same host port on one node, but does
  not itself bind the pod to a named node or create one receiver per worker.
  Review scheduling rules and the node-local PV placement on multi-node edges.

- **Original data remains in Orthanc.** Ingest de-identifies downstream. Treat
  the receiver store, grouped and assigned trees as identifying data. The
  backup is another original copy, and reid maps retain sensitive metadata.
  Restrict access to all of them, not only to `/facility-backup`.
- **The receiver is not an AET allowlist.** Ingest does not consult the legacy
  project map or quarantine unknown AETs. A reachable sender can supply input
  for assignment. Restrict network access and review the source labels.
- **Cleanup is off on a fresh install.** `dataPolicy.enabled: false` and
  `dryRun: true` keep the policy reporter from deleting receiver instances.
  Once enabled, `onGrouped`, minimum age and a matching export snapshot are
  still required. Lack of snapshot evidence keeps a study regardless of age.
- **A backup is not automatic for every input path.** File drops bypass the
  receiver callback. Keep their original files separately. With facility
  backup disabled, the callback cannot provide that retained copy for C-STORE
  input either. Verify the configured paths and a real synthetic receive.
- **Hardlinks need one pipeline filesystem.** Keep receiver storage and the
  grouped/assigned directories under the shared pipeline volume. A separate
  facility-backup disk is allowed because the backup uses byte copies.
  Cross-filesystem pipeline copies can need much more disk and time.
- **REST authentication is separate from network placement.** ClusterIP limits
  exposure but is not a per-client authorization control. Pods that can reach
  an unauthenticated API can read or delete data. Follow the documented
  authentication setup and keep port 8042 off public interfaces.
- **Labels do not prove data policy.** Processed and snapshot labels describe
  export state. They do not prove that downstream labels, headers or pixels
  meet the site's de-identification requirements. Verify the recipe output and
  destination metadata separately.
- **The salt name can mislead operators.** Its value is not an ingest hash key.
  It remains a load-time requirement of the backup script. A valid placeholder
  replacement proves only that startup prerequisite, not pseudonym strength.

Use the component logs to locate the failing boundary. A receiver error belongs
at receive/backup; a group error belongs at study assembly; an invalid label
belongs at assignment; and a recipe error belongs at deidentify. Keep originals
while diagnosing the issue. Do not use an API delete or a filesystem removal as
a substitute for finding why the export or de-identification proof is missing.
