# De-identification engines: two architectures

Two engines can de-identify studies. **Use `deid.engine: ingest`.** It is the
default (key `deid.engine` in `charts/edge/values.yaml`), and it is the only
engine for a new site. The Orthanc Lua engine, `deid.engine: orthanc`, is
deprecated. This page keeps both architectures for reference, and it says why
new sites use `ingest`.

The two engines differ in where the **routing identifiers** come from. Those
are the XNAT project, subject and session of a study.

For configuration, see
[components/deidentification.md](components/deidentification.md). The
reference material for the deprecated engine is in one section of that page.

## What routing identifiers are

`assign` files a study into XNAT under three ids. It reads each id from one
DICOM tag, and `ingest.assign.tagMapping` names the three tags. When you leave
it empty, the chart sets it from the engine
(`charts/edge/templates/_helpers.tpl:850-857`):

```
                 ingest (default)    orthanc (deprecated)
project    <-    StudyID             ClinicalTrialProtocolID
subject    <-    PatientID           ClinicalTrialSubjectID
session    <-    AccessionNumber     ClinicalTrialTimePointID
```

`ingest.assign.constantProjectId` puts every session in one project. `assign`
then does not read a project tag.

Every pipeline needs those ids before `assign` runs. The two architectures
below differ in one thing: the ids arrive in the data, or something makes them
on the way in.

---

## Architecture A — studies arrive unidentified

> **Deprecated.** This is the architecture of the Orthanc Lua engine. Do not
> use it for a new site.

The scanner sends a study that only its **AE title** identifies. The DICOM
carries a patient name and hospital ID, but nothing that says which XNAT
project, subject or session it belongs to.

Something has to make those ids. The **Orthanc Lua hook** makes them when each
instance arrives:

| step | what happens |
|---|---|
| project | the hook looks up the **called** AE title (the AE title that the modality sends to) in `orthanc.deid.aetMap` |
| subject / session | the hook hashes the patient identifier with a per-site secret salt (salted djb2, NOT an HMAC) |
| routing tags | the profile writes those values into the three `ClinicalTrial*` tags |
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

Sites used this architecture while `orthanc` was the default. Two site files
in this repository still select it: `sites/edge-dev` and `sites/cloud-edge`.
A new site does not use it.

---

## Architecture B — studies arrive already identified

This is the architecture of the default engine, `deid.engine: ingest`.

The study already carries its routing ids in tags. A modality worklist, a
scanner protocol or the operator at the console puts them there. `assign` reads
the tags that `tagMapping` names, so **no AE-title map is involved and none is
needed**. The routing question has its answer before the data arrives.

Then de-identification is the only job that stays. The **xnat-ingest
`deidentify` stage** does it, between `assign` and `upload`:

| step | what happens |
|---|---|
| PHI | the stage removes or changes the tags that a pydicom `deid` recipe names, one recipe per project |
| `PatientID` | the shipped recipe removes it (`REMOVE PatientID`). The XNAT subject label is still the tag value that `assign` read before this stage |
| `AccessionNumber` | the shipped recipe removes it (`REMOVE AccessionNumber`) |
| reid mapping | the stage records each changed value in `/data/reid`, one file per session. It encrypts the file when `ingest.deidentify.reidEncryptKeySecret` is set |

**Requires:** the tags that `tagMapping` names, present in the incoming data
(or `constantProjectId` for the project), and recipes in
`ingest.deidentify.specs`.

**Properties**

* Reversible. The reid mapping is a route back to the original identifiers. A
  clinical follow-up needs that route to find a scan. The Lua hook has no
  equivalent.
* The XNAT labels are the tag values, verbatim. They are pseudonyms only if the
  modality writes pseudonyms into those tags. They are stable across visits
  only if the tags are.
* De-identification happens later in the pipeline, so identifiable data passes
  through `group` and `assign` and is present on the pipeline volume until the
  stage runs.
* The pinned image does not use `ais_deid`, so the old salt caveat below does
  not apply. A recipe hash can use a `<format>.salt` side-car file, which the
  chart does not supply.

This is the architecture upstream xnat-ingest is written for, and it is the
default here.

**Why new sites use it:**

* It carries data all the way to XNAT. The layout defect that stopped it is
  fixed in the pinned image (see the caveats below).
* It de-identifies the file-drop path too. The Lua hook does not (see "Where
  the data enters").
* It keeps a reid mapping, so a study can be re-identified when that is
  required.
* The recipe language can do more than the Orthanc profile, for example
  `JITTER` on dates.

---

## Which applies to a given site

Use `ingest`. Then decide where each id comes from:

```
Do the studies carry the project, subject and session in tags?

├─ yes ──→ Point ingest.assign.tagMapping at those tags. Choose tags
│          that hold pseudonyms: the values become the XNAT labels.
│
├─ no project tag ──→ Set ingest.assign.constantProjectId. Every session
│                     from this edge then goes to that one project.
│
└─ no subject or session tag ──→ Make the modality or the operator write
                                 one. Without it, assign puts every
                                 study in /data/assigned/__invalid__.
```

Do not choose the deprecated Lua engine to make the ids. A new site does not
use it.

Check which tags a modality actually sends, on a real study:

```bash
dcmdump file.dcm | grep -E 'StudyID|PatientID|AccessionNumber'
```

Measured on a live pipeline with the Lua hook disabled and `tagMapping` still
set to the `ClinicalTrial*` tags, same run:

```
study WITH the tags     -> test_project.PRETAG_SUBJ_008.PRETAG_SESS_008
study WITHOUT the tags  -> __invalid__/INVALID_MISSING_CLINICALTRIALPROTOCOLID_...
```

Under the default `ingest` mapping, the name shows the missing tag in the same
way, for example `INVALID_MISSING_STUDYID_...`. The chart now refuses the
`ClinicalTrial*` mapping under `ingest`.

`assign` does not distinguish who wrote the tags, only whether they are present.

## Side by side

| | A: Orthanc Lua hook (deprecated) | B: xnat-ingest deidentify |
|---|---|---|
| values key | `deid.engine: orthanc` | `deid.engine: ingest` |
| chart default | no, deprecated | **yes** |
| runs | inside Orthanc, per instance on arrival | own stage, between `assign` and `upload` |
| source of routing identifiers | derives them from the called AE title and the patient ID | expects them in the incoming data, or `constantProjectId` |
| needs an AE-title map | yes | no |
| strips PHI | yes, JSON profile | yes, pydicom `deid` recipe per project |
| pseudonymises the XNAT labels | yes, before anything downstream sees the data (salted djb2, not an HMAC, see the deprecated section of [components/deidentification.md](components/deidentification.md)) | **no**, the labels are the tag values. See *What the recipe does not do* |
| re-identification possible | no | yes, via the reid mapping |
| identifiable data on the pipeline volume | no | yes, until the stage runs |
| de-identifies the file-drop path | no | yes |
| `group-orthanc` waits for the ready label | yes | no. The chart derives this from `deid.engine`, so there is nothing to clear by hand |

## Upstream caveats affecting Architecture B

**The layout defect is fixed.** xnat-ingest 0.13.1 wrote the `deidentify`
output one directory level deeper than `assign` does. So `upload` reported
`Found 0 sessions` and data stopped there. That was
[xnat-ingest#144](https://github.com/Australian-Imaging-Service/xnat-ingest/issues/144),
closed on 2026-08-31. The pinned image,
`ghcr.io/akshitbeniwal/xnat-ingest:0.16.2.post1`, writes the same layout as
`assign` (`xnat_ingest/api/deidentify_api.py:542` at `v0.16.2.post1`). Data
now goes all the way to XNAT.

**The `ais_deid` salt caveat does not apply to the pinned image.** Older
images de-identified through the `ais_deid` package. Its per-site salt was
commented out in the shipped package:

```python
#_SALT: str | None = os.environ.get("DEID_SALT")
# NOTE: Salting is currently disabled. The hash is computed without a salt,
# meaning the same input always produces the same output regardless of site.
```

Unsalted, a hospital MRN is a small search space, so a pseudonym is recoverable
by brute force, and two sites produce identical codes for the same patient.
That is
[xnat-ingest#143](https://github.com/Australian-Imaging-Service/xnat-ingest/issues/143),
still open upstream. The pinned image does not depend on `ais_deid` (see
`pyproject.toml` at `v0.16.2.post1`). Its recipes change only the tags that
they name, and the shipped recipe removes the identifiers. It does not hash
them.

**What stays.** The XNAT labels are the tag values, verbatim, because `assign`
reads them before `deidentify` runs. If a recipe hashes a value, the key comes
from a `<format>.salt` side-car file, and the chart does not supply one. The
`AIS_DEID_HMAC_SALT` Secret serves only the deprecated Lua engine.

## Where the data enters

Orthanc is the only DICOM **network** receiver in this stack. xnat-ingest ships
no DICOM network stack — `pynetdicom` is not installed and no subcommand listens
on a port — so a scanner performing a C-STORE association has nothing else to
talk to.

Orthanc is not the only way in, though. `ingest.fileDrop` runs `xnat-ingest
group` over a filesystem glob. So data that arrives as *files* gets into the
pipeline without Orthanc's REST pull: a share, a vendor export or an rsync.

Only the `ingest` engine de-identifies that path. A dropped file goes from
`group` to `assign`, and under `ingest` then to `deidentify`. The Lua hook runs
only on instances that Orthanc receives over DICOM
(`charts/edge/files/deidentify-and-forward.lua:130`). Under the deprecated
engine the uploader reads `/data/assigned`
(`charts/edge/templates/_helpers.tpl:867-870`), so a dropped file goes to XNAT
without de-identification.

## See also

* [components/deidentification.md](components/deidentification.md): how to configure the `ingest` engine, and the reference for the deprecated one
* [components/orthanc.md](components/orthanc.md) — the receiver
* [components/xnat-ingest.md](components/xnat-ingest.md) — the pipeline stages
