# De-identification engines: two architectures

Two engines can de-identify studies. They are built for different pipelines, and
the difference is where the **routing identifiers** — the XNAT project, subject
and session a study belongs to — come from.

For configuration of either, see
[components/deidentification.md](components/deidentification.md).

## What routing identifiers are

`assign` files a study into XNAT using three DICOM tags:

```
ClinicalTrialProtocolID    -> project
ClinicalTrialSubjectID     -> subject
ClinicalTrialTimePointID   -> session
```

Every pipeline needs those three populated before `assign` runs. Whether they
arrive in the data or are manufactured on the way in is what separates the two
architectures below.

---

## Architecture A — studies arrive unidentified

The scanner sends a study identified only by its **AE title**. The DICOM carries
a patient name and hospital ID, but nothing that says which XNAT project,
subject or session it belongs to.

Something has to manufacture that. The **Orthanc Lua hook** does, at the moment
each instance arrives:

| step | what happens |
|---|---|
| project | the calling AE title is looked up in `orthanc.deid.aetMap` |
| subject / session | the patient identifier is hashed with a per-site secret salt (salted djb2, NOT an HMAC) |
| routing tags | those values are written into the three `ClinicalTrial*` tags |
| PHI | stripped per the JSON profile passed to Orthanc `/modify` |
| label | the study is tagged `xnat-ingest-ready` for `group-orthanc` |

**Requires:** `orthanc.deid.aetMap`, a de-identification `profile`, and
`existingSaltSecret`.

**Properties**

* De-identification happens at the door. Every later stage only ever sees
  stripped data.
* Pseudonyms are stable across visits — the same patient always hashes to the
  same subject, so a follow-up scan joins the existing XNAT subject.
* One-way. No mapping back to the original identifiers is kept, so a study
  cannot be re-identified later by any means.

This is the architecture every site in this repo currently runs.

---

## Architecture B — studies arrive already identified

The study already carries its `ClinicalTrial*` tags, populated by a modality
worklist, a scanner protocol, or whatever produced the export. `assign` reads
them directly, so **no AE-title map is involved and none is needed** — the
routing question is already answered before the data arrives.

De-identification is then the only remaining job, and the **xnat-ingest
`deidentify` stage** does it, running between `assign` and `upload`:

| step | what happens |
|---|---|
| PHI | tags named in a pydicom `deid` recipe are removed, one recipe per project |
| `PatientID` | replaced with a deterministic SHA-256 pseudonym |
| `AccessionNumber` | hashed separately, so it cannot be used to re-link |
| reid mapping | every original value is recorded to `/data/reid`, one file per session, optionally encrypted |

**Requires:** `ClinicalTrial*` tags present in the incoming data, and
`ingest.deidentify.specs` recipes.

**Properties**

* Reversible. The reid mapping is a route back to the original identifiers,
  which is what a clinical follow-up needs to locate a scan. The Lua hook has no
  equivalent.
* Pseudonyms are stable across visits, on the same input.
* De-identification happens later in the pipeline, so identifiable data passes
  through `group` and `assign` and is present on the pipeline volume until the
  stage runs.
* The salt is currently disabled upstream — see the caveat below.

This is the architecture upstream xnat-ingest is written for.

---

## Which applies to a given site

```
Do the studies arriving carry ClinicalTrialProtocolID,
ClinicalTrialSubjectID and ClinicalTrialTimePointID?

├─ no  ─→ Architecture A. The Lua hook manufactures them from the AE title.
│         Without it, assign has nothing to route on and every study is
│         placed in /data/assigned/__invalid__.
│
└─ yes ─→ Either architecture works. A still applies if you want cleaning at
          the door; B applies if you want the reid mapping. The choice rests
          on whether re-identification is a requirement at your site.
```

Checking which case applies, on a study a modality actually sends:

```bash
dcmdump file.dcm | grep -E 'ClinicalTrial(ProtocolID|SubjectID|TimePointID)'
```

Measured on a live pipeline with the Lua hook disabled, same run:

```
study WITH the tags     -> test_project.PRETAG_SUBJ_008.PRETAG_SESS_008
study WITHOUT the tags  -> __invalid__/INVALID_MISSING_CLINICALTRIALPROTOCOLID_...
```

`assign` does not distinguish who wrote the tags, only whether they are present.

## Side by side

| | A — Orthanc Lua hook | B — xnat-ingest deidentify |
|---|---|---|
| values key | `orthanc.deid.enabled` | `ingest.deidentify.enabled` |
| chart default | on | off |
| runs | inside Orthanc, per instance on arrival | own stage, between `assign` and `upload` |
| source of routing identifiers | derives them from the AE title | expects them in the incoming data |
| needs an AE-title map | yes | no |
| strips PHI | yes, JSON profile | yes, pydicom `deid` recipe per project |
| pseudonymises | yes, before anything downstream sees the data (salted djb2, not an HMAC, see *Pseudonym strength*) | **no, not by default** — see *What the recipe does not do* |
| re-identification possible | no | yes, via the reid mapping |
| identifiable data on the pipeline volume | no | yes, until the stage runs |
| applies the ready label | yes | no — clear `toProcessLabel` when switching |

## Upstream caveats affecting Architecture B

**`deidentify` output cannot yet be consumed by `upload`.** It is written one
directory level deeper than `assign` produces, so `upload` reports
`Found 0 sessions`. Tracked as
[xnat-ingest#144](https://github.com/Australian-Imaging-Service/xnat-ingest/issues/144).
Until it is fixed, the stage runs and de-identifies correctly but data stops
there.

**The pseudonym salt is disabled.** `ais_deid` implements per-site salted
hashing; the code is commented out in the shipped package:

```python
#_SALT: str | None = os.environ.get("DEID_SALT")
# NOTE: Salting is currently disabled. The hash is computed without a salt,
# meaning the same input always produces the same output regardless of site.
```

Unsalted, a hospital MRN is a small search space, so a pseudonym is recoverable
by brute force, and two sites produce identical codes for the same patient.
Setting `DEID_SALT` has no effect today because the reader itself is commented
out; enabling it requires an upstream change — tracked as
[xnat-ingest#143](https://github.com/Australian-Imaging-Service/xnat-ingest/issues/143). Architecture A is unaffected — it
HMACs with a site secret.

## Where the data enters

Orthanc is the only DICOM **network** receiver in this stack. xnat-ingest ships
no DICOM network stack — `pynetdicom` is not installed and no subcommand listens
on a port — so a scanner performing a C-STORE association has nothing else to
talk to.

Orthanc is not the only way in, though. `ingest.fileDrop` runs `xnat-ingest
group` over a filesystem glob, so data arriving as *files* — a share, a vendor
export, an rsync — reaches the pipeline without Orthanc's REST pull. Either
de-identification architecture can sit behind that path.

## See also

* [components/deidentification.md](components/deidentification.md) — configuring either engine
* [components/orthanc.md](components/orthanc.md) — the receiver
* [components/xnat-ingest.md](components/xnat-ingest.md) — the pipeline stages
