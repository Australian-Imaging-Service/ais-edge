# Orthanc

## Overview

[Orthanc](https://www.orthanc-server.com/) is a lightweight,
open-source DICOM server. In ais-edge it sits at the edge of each site,
acts as the **DICOM receiver** for local modalities, and runs the AIS
**deidentification Lua hook** before xnat-ingest groups and stages the data.

We use the [`jodogne/orthanc-plugins`](https://hub.docker.com/r/jodogne/orthanc-plugins)
image (pinned to a version ≥ 1.12.0 because the deid hook uses
**study-level labels**, introduced in 1.12.0).

## Role in this stack

Three jobs at each edge:

1. **DIMSE C-STORE SCP** on host port 4242 with `AET=AISEDGE`. Modalities
   on the local facility LAN push studies here.
2. **Lua `OnStoredInstance` hook** writes the ORIGINAL DICOM to
   `/facility-backup` (site-controlled retention) and runs
   `/instances/{id}/modify` to produce a deidentified copy. The
   original is deleted from Orthanc; the deid'd instance is kept.
3. **Lua `OnStableStudy` hook** PUTs the `xnat-ingest-ready` label on each
   study once it's been quiescent for `StableAge` seconds. This is the
   signal for `xnat-ingest group-orthanc` to REST-pull the study.

After `group-orthanc` hardlinks the instances into `/data/grouped/`, it
PUTs the `xnat-ingest-processed` label on the study so subsequent
`group-orthanc` cycles skip it. `xnat-ingest assign` then collates the
grouped session into `/data/staging/`.

```
Modality ──C-STORE──► Orthanc :4242 (AET=AISEDGE)
                          │
                          ├─ OnStoredInstance:
                          │   1. backup → /facility-backup
                          │   2. /modify (deid; UIDs kept) → new instance, same Study
                          │   3. delete ORIGINAL
                          │
                          └─ OnStableStudy (after StableAge=30s silence):
                              PUT /studies/{id}/labels/xnat-ingest-ready
                                                      │
                                                      ▼
                                xnat-ingest group-orthanc REST-pulls,
                                hardlinks, PUTs label xnat-ingest-processed
```

## What Orthanc has access to

| Resource | Why |
|---|---|
| Host network port 4242 (`hostPort`) | Modality C-STORE inbound from local facility LAN |
| hostPath `/data/xnat-ingest/orthanc-storage` mounted as `/data/orthanc-storage` | Orthanc's DICOM storage tree. **Must be on the same filesystem as xnat-ingest staging** so hardlinks work (cross-fs hardlink fails with EXDEV) |
| hostPath `/data/facility-backup` mounted as `/facility-backup` | Canonical local copy of every received original DICOM. Site-controlled retention. Independent of AIS lifecycle. |
| Four ConfigMaps mounted under `/etc/orthanc/` | `orthanc-config` (orthanc.json), `orthanc-scripts` (Lua), `orthanc-routing` (routing.json), `orthanc-deidentification-profile` (deid profile) |
| One Secret env var | `AIS_DEID_HMAC_SALT` — per-deployment salt for SubjectHash / SessionHash derivation in the Lua hook |
| No outbound network | Doesn't talk to XNAT, doesn't talk to other AIS pods. xnat-ingest group-orthanc talks to it (in-cluster Service). |

## Where it runs

Single pod (`Recreate` strategy — hostPath isn't shareable across
replicas), one per edge worker. Deployed by the edge chart; template at
[`charts/edge/templates/orthanc-deployment.yaml`](../../charts/edge/templates/orthanc-deployment.yaml).

REST API exposed as a ClusterIP Service `orthanc.xnat-ingest.svc.cluster.local:8042`.
DICOM port 4242 is exposed via `hostPort` directly on the edge node IP
so modalities can reach it without an in-cluster Service.

## Configuration

Nothing here is edited as a file. [`charts/edge/templates/orthanc-config.yaml`](../../charts/edge/templates/orthanc-config.yaml)
renders three ConfigMaps from `sites/<site>/values.yaml`, so the site file is
the only thing you change. (These used to be hand-edited copies under
`config/orthanc/`; that directory is gone — it fed nothing, and editing the
copy of the Lua script it held changed nothing at all.)

| Rendered file | Built from | What it does |
|---|---|---|
| `orthanc.json` | `orthanc.*` and `dataPolicy.derived.orthancStorage.*` | Daemon config: AET, ports, storage path, `StableAge`, points at the Lua script |
| `deidentify-and-forward.lua` | `.Files.Get "files/deidentify-and-forward.lua"` | The deid + label hook. **Identical across all AIS-Edge deployments** — no site-specific bits, which is why it is a chart file and not a value |
| `routing.json` | `orthanc.deid.aetMap` | **Per-site**: maps modality AETs → XNAT project. Set one entry per modality; an unmapped AET is quarantined, not dropped |
| `deidentification-profile.json` | The site's deid contract. Replace + Keep blocks following Orthanc's `/modify` API. Ships as `.template`; gitignored after copy. Applied to every accepted study |

The single per-deployment Secret is `AIS_DEID_HMAC_SALT`, set in
the edge site's `orthanc-deid-salt` Secret in `sites/<site>/secrets.enc.yaml`. Generate with `openssl rand -hex 32`.
Rotating it means a different deid'd identity for the same patient,
so only rotate deliberately.

## Operations

```bash
# Pod state
kubectl --kubeconfig kubeconfig-edge-<site> get pods -n xnat-ingest -l app=orthanc

# Logs (deid events: instance_deidentified, study_labeled_ready)
kubectl --kubeconfig kubeconfig-edge-<site> logs -n xnat-ingest deploy/orthanc

# Orthanc Explorer UI (port-forward + browser)
kubectl --kubeconfig kubeconfig-edge-<site> port-forward -n xnat-ingest svc/orthanc 8042:8042
# → http://localhost:8042/app/explorer.html

# DICOM endpoint smoke-test from a modality side or with dcmtk
storescu -aec AISEDGE -aet TEST_MOD <edge-ip> 4242 /path/to/study/*.dcm
```

## Known limitations

- **No automatic cleanup** of deid'd instances in Orthanc storage after upload to XNAT. Manual or scripted cleanup needed for production (e.g. delete studies labelled `xnat-ingest-processed` once confirmed in XNAT).
- **Pure-Lua salted hash instead of true HMAC** for SubjectHash / SessionHash, because `jodogne/orthanc-plugins` doesn't expose `Compute*` crypto in Lua. Adequate for research deid; switch to `jodogne/orthanc-python` for HMAC-grade.
- **Profile authoring is by hand** — no validation that referenced DICOM tags exist in Orthanc's dictionary before deployment. `07c` prompts the site admin for explicit confirmation of the AETMap + profile before applying.
- **Hardlinks require shared filesystem** — `/data/xnat-ingest/orthanc-storage` and `/data/xnat-ingest/staging` must live on the same physical mount, or group-orthanc fails with EXDEV.
- **Modalities with unmapped CalledAETs are rejected for ingest, but not discarded** — the original instance is written to `<FacilityBackupDir>/__unmapped_aet__/<AET>/<PatientID>/<StudyUID>/<SOPUID>.dcm` and only then removed from Orthanc. If that quarantine write fails the instance is kept in Orthanc instead, and if no `FacilityBackupDir` is configured the hook aborts without deleting anything. A `REJECT: no project mapped for CalledAET <AET>` line is logged, which is what the `DICOMRejectedUnmappedAET` alert matches. Add the AET to `routing.json` AETMap and re-send to ingest the quarantined studies.
- **`AIS_DEID_HMAC_SALT` rotation breaks subject linkage** — rotating the salt produces a different SubjectHash for the same patient. Rotate only deliberately.
