# Orthanc

## Overview

[Orthanc](https://www.orthanc-server.com/) is a lightweight,
open-source DICOM server. In this tier-1 single-node appliance it acts as the
**DICOM receiver** for local modalities and runs the AIS **deidentification Lua
hook** before xnat-ingest groups and stages the data.

We use the [`jodogne/orthanc-plugins`](https://hub.docker.com/r/jodogne/orthanc-plugins)
image, pinned in `orthanc.image.tag` (currently `1.12.11`). It must stay
≥ 1.12.0 because the deid hook uses **study-level labels**, introduced in
1.12.0.

## Role in this stack

Three jobs on the node:

1. **DIMSE C-STORE SCP** on host port 4242 with `AET=AISEDGE`. Modalities
   on the local facility LAN push studies here.
2. **Lua `OnStoredInstance` hook** writes the ORIGINAL DICOM to
   `/facility-backup` (site-controlled retention) and runs
   `/instances/{id}/modify` against the profile. `/modify` RETURNS the
   modified bytes and does not store them, so the hook deletes the original
   first (or the UID collides) and POSTs the bytes back to `/instances`.
   The deid'd instance is what stays in Orthanc.
3. **Lua `OnStableStudy` hook** PUTs the `xnat-ingest-ready` label on each
   study once it's been quiescent for `StableAge` seconds. This is the
   signal for `xnat-ingest group-orthanc` to REST-pull the study.

After `group-orthanc` hardlinks the instances into `/data/grouped/`, it PUTs the
`xnat-ingest-processed` label on the study so subsequent cycles skip it.

```
Modality ──C-STORE──► Orthanc :4242 (AET=AISEDGE)
                          │
                          ├─ OnStoredInstance:
                          │   0. CalledAET not in AETMap? → quarantine, see below
                          │   1. backup original → /facility-backup
                          │   2. /modify (deid; UIDs kept) → bytes
                          │   3. delete ORIGINAL, POST bytes back → new instance,
                          │      same Study
                          │
                          └─ OnStableStudy (after StableAge=30s silence):
                              PUT /studies/{id}/labels/xnat-ingest-ready
                                                      │
                                                      ▼
                                xnat-ingest group-orthanc REST-pulls,
                                hardlinks to /data/grouped, PUTs label
                                xnat-ingest-processed
```

Every step aborts and KEEPS the instance rather than losing it: if the facility
backup write fails, nothing is modified and nothing is deleted; if `/modify` or
the re-POST fails, the study simply never gets labelled and stalls visibly.

## What Orthanc has access to

| Resource | Why |
|---|---|
| Node port 4242 (`hostPort`, from `orthanc.expose.dicom`) | Modality C-STORE inbound from local facility LAN. Binding the real port pins the pod to the node — which is why the Deployment strategy is `Recreate` |
| PVC `<release>-pipeline` mounted at `/data` | Backed by a hostPath PV at `storage.pipeline.hostPath` (`/data/xnat-ingest`). Holds `orthanc-storage/`, `grouped/`, `assigned/`. **One filesystem for all stages** so hardlinks work (cross-fs hardlink fails with EXDEV) |
| PVC `<release>-facility-backup` mounted at `/facility-backup` | Backed by hostPath `storage.facilityBackup.hostPath`. Canonical local copy of every received original DICOM, written as `<PatientID>/<StudyUID>/<SeriesUID>/<SOPUID>.dcm`. Site-controlled retention. Independent of AIS lifecycle |
| Three ConfigMaps at TWO paths | `<release>-orthanc-config` → `/etc/orthanc/orthanc.json`, `<release>-orthanc-scripts` → `/etc/orthanc/scripts/`, `<release>-orthanc-routing` → `/etc/ais-edge/` (routing.json + deidentification-profile.json). See Configuration for why the second path exists |
| One Secret env var | `AIS_DEID_HMAC_SALT` from `orthanc.deid.existingSaltSecret` (`orthanc-deid-salt`) — per-deployment salt for SubjectHash / SessionHash derivation in the Lua hook |
| Optionally Secret `orthanc-credentials` | Only when `orthanc.auth.enabled` is true; mounted as `/etc/orthanc-credentials/users.json`. The tier-1 example site leaves auth off because the REST API is ClusterIP-only |
| No outbound network | Doesn't talk to XNAT, doesn't talk to other AIS pods. Traffic is inbound only: `group-orthanc` REST-pulls over the in-cluster Service, and the data-policy reporter queries it when `dataPolicy.derived.orthancStorage.backend` is `orthanc-rest` |

## Where it runs

Single pod (`Recreate` strategy — the hostPath-backed index isn't shareable
across replicas, and two Orthancs cannot share one SQLite index) on the single
node. Rendered by
[`charts/edge/templates/orthanc-deployment.yaml`](../../charts/edge/templates/orthanc-deployment.yaml)
and installed by step 3 of `./install.sh <site>`.

REST API exposed as a ClusterIP Service
`<release>-orthanc.xnat-ingest.svc.cluster.local:8042` (this is how
`xnat-ingest group-orthanc` REST-pulls; `<release>` is the site name unless
`AIS_RELEASE` overrides it). DICOM port 4242 is exposed via `hostPort` directly
on the node's IP so modalities can reach it without an in-cluster Service —
`orthanc.expose.dicom` can be switched to `nodePort` or `both` instead.

## Configuration

Everything non-secret lives under `orthanc:` in
`sites/<site>/values.yaml`. There is no separate config directory and no env
file; the chart renders `orthanc.json`, `routing.json` and the deid profile from
those values.

| Values key | What it does |
|---|---|
| `orthanc.aet`, `orthanc.dicomPort`, `orthanc.httpPort` | Identity and ports of the SCP |
| `orthanc.stableAge` | Seconds of silence before `OnStableStudy` fires. **LOAD-BEARING**: with no StableAge the `xnat-ingest-ready` label is never applied, `group-orthanc` filters everything out, and the pipeline stalls with data sitting in Orthanc and no error anywhere |
| `orthanc.expose.dicom` / `.http` | `hostPort` \| `nodePort` \| `both` for DICOM; `ClusterIP` \| `nodePort` for the REST API. Do not expose HTTP without `orthanc.auth.enabled` — the REST API can delete studies |
| `orthanc.deid.aetMap` | **Per-site**: each modality's Called-AET → XNAT project. THE routing table. Rendered into `routing.json`'s `AETMap`. Keep project IDs within `[A-Za-z0-9_]`; `assign` normalises to that set |
| `orthanc.deid.profile` | The site's deid contract, passed verbatim to Orthanc `/modify` (`Keep` / `Replace` / `Force` / `RemovePrivateTags`, plus the AIS-only `DeidMode`). A single profile is applied to every accepted study. Start from [`charts/edge/files/deidentification-profile.example.json`](../../charts/edge/files/deidentification-profile.example.json) |
| `orthanc.deid.policyReviewed` | Render-time gate, no safe default. The chart refuses to template while deid is on and this is false |
| `orthanc.image.tag` | Pinned Orthanc version |

The Lua hook itself,
[`charts/edge/files/deidentify-and-forward.lua`](../../charts/edge/files/deidentify-and-forward.lua),
is **identical across all AIS-Edge deployments** — no site-specific bits. It is
loaded with `.Files.Get` rather than inlined so it stays lintable and diffable.

**Why routing.json and the profile are NOT under `/etc/orthanc`.** Orthanc is
started with a directory argument and reads *every* `*.json` in it as server
configuration — verified on a running edge, it happily read `routing.json` and
`deidentification-profile.json` as settings. Nothing collides today, but the
scan order is filesystem order, so a future key that does collide would silently
reconfigure the server. So `/etc/orthanc/` holds only `orthanc.json` and
`scripts/`, and the hook reads its own inputs from `/etc/ais-edge/` via
`AIS_ROUTING_FILE`.

**The pod rolls itself when the config changes.** The Deployment carries a
`checksum/config` annotation over the rendered ConfigMaps, so a changed AET map,
profile or Lua hook restarts Orthanc on `helm upgrade`. Editing a ConfigMap by
hand still does nothing until the pod restarts.

The single per-deployment Secret is `orthanc-deid-salt`, key
`AIS_DEID_HMAC_SALT`, declared in `sites/<site>/secrets.enc.yaml` and applied
with `scripts/site-secrets.sh apply <site>`. Generate with `openssl rand -hex
32`. Rotating it means a different deid'd identity for the same patient, so only
rotate deliberately. Nothing validates its CONTENTS — a site installed with the
shipped placeholder starts cleanly and derives every pseudonym from a string
published in this repository.

Render-time gates that exist because each of these fails **silently** at
runtime (all in `charts/edge/templates/_helpers.tpl`):

- `orthanc.deid.policyReviewed` must be true;
- `orthanc.deid.aetMap` must be non-empty, or every modality is quarantined;
- `orthanc.deid.profile` must be non-empty, or `/modify` is given nothing to
  change and studies reach XNAT with PHI intact while nothing looks wrong;
- `storage.facilityBackup.enabled` must be true when deid is on — the hook
  writes originals there before modifying them, and quarantines unmapped-AET
  studies under it;
- `ingest.orthancGroup.toProcessLabel` must be empty when deid is off, since
  nothing else applies that label.

## Operations

```bash
# Pod state  (RELEASE is the site name unless AIS_RELEASE was set)
kubectl get pods -n xnat-ingest -l app=orthanc

# Logs (deid events: instance_deidentified, study_labeled_ready)
kubectl logs -n xnat-ingest deploy/<release>-orthanc

# Orthanc Explorer UI (port-forward + browser)
kubectl port-forward -n xnat-ingest svc/<release>-orthanc 8042:8042
# → http://localhost:8042/app/explorer.html

# DICOM endpoint smoke-test from a modality or with dcmtk. -aec is the CALLED
# AET and must be a key of orthanc.deid.aetMap in sites/<site>/values.yaml.
storescu -aec <AET-from-aetMap> -aet TEST_MOD <nodeIP> 4242 /path/to/study/*.dcm
```

## Known limitations

- **Cleanup of deid'd instances is off by default.** `dataPolicy.derived.orthancStorage` reclaims them (`backend: orthanc-rest`, `reclaim: onGrouped`, plus `minAge`) by asking Orthanc for studies carrying `ingest.orthancGroup.processedLabel` and deleting them through its API — a directory walk cannot, because Orthanc names files by UUID. But `dataPolicy.enabled` is false and `dryRun` is true on a fresh install, so nothing is removed until a site turns them on.
- **Pure-Lua salted hash instead of true HMAC** for SubjectHash / SessionHash — a salted djb2, not a cryptographic hash, because `jodogne/orthanc-plugins` doesn't expose `Compute*` crypto in Lua. Adequate for research deid; switch to `jodogne/orthanc-python` for HMAC-grade.
- **Profile authoring is by hand** — no validation that referenced DICOM tags exist in Orthanc's dictionary before deployment. `orthanc.deid.policyReviewed` forces an explicit human confirmation of the AET map and profile, but it confirms intent, not correctness.
- **Hardlinks require shared filesystem** — `/data/orthanc-storage`, `/data/grouped` and `/data/assigned` are all under the one `<release>-pipeline` PVC for this reason. Split them across mounts and `group-orthanc` degrades to a full copy (EXDEV).
- **Modalities with unmapped CalledAETs are quarantined, not dropped.** The modality has already been given a C-STORE SUCCESS and will never retry, so discarding would be permanent silent data loss. The original bytes — identifiers intact — are written to `/facility-backup/__unmapped_aet__/<AET>/<PatientID>/<StudyUID>/<SOPUID>.dcm` and only then removed from Orthanc; if that write fails the instance stays in Orthanc. Add the AET to `orthanc.deid.aetMap` and re-send. The log line keeps the wording `REJECT: no project mapped for CalledAET <AET>` because the unmapped-AET alert rule matches on it, and `dataPolicy.originals.quarantine.alertAfter` nags while the tree is non-empty.
- **`AIS_DEID_HMAC_SALT` rotation breaks subject linkage** — rotating the salt produces a different SubjectHash for the same patient, and nothing detects it because both old and new look valid. Rotate only deliberately, and back the salt up alongside the age key.
