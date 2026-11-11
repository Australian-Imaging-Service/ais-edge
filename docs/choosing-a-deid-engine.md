# De-identification engines: two architectures

The pipeline tool is accessionflow (called xnat-ingest before 0.18.0).

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
(`charts/edge/templates/_helpers.tpl`, helper `edge.assignTagMapping`):

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

* The hook changes only the fields covered by its profile. This does not
  prove that private fields, pixels or every identifier are safe. Orthanc and
  the facility backup can still hold original identifiable instances.
* The same patient identifier and salt produce the same subject hash. This
  depends on stable source identifiers and salt. The truncated djb2 hash has
  no collision-free or cryptographic privacy guarantee.
* The hook writes no explicit re-identification map. That does not make the
  data irreversible: source copies, retained fields and enumeration with the
  salt can link it to original identifiers. Treat this as a deprecated design.

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

Then de-identification is the only job that stays. The **accessionflow
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

* The reid mapping records changed metadata values. It can support approved
  linkage, but it cannot restore every removed file or pixel. Keep the
  facility backup separately. The Lua hook has no equivalent mapping file.
* The XNAT labels derive from the tag values. IDSpec preserves letters,
  digits, underscores and hyphens; other character runs become underscores.
  This normalization does not create pseudonyms. Labels are pseudonyms only
  if the modality supplies them, and stable only if the source values are.
* De-identification happens later in the pipeline, so identifiable data passes
  through `group` and `assign` and is present on the pipeline volume until the
  stage runs.
* The pinned image does not use `ais_deid`, so the old salt caveat below does
  not apply. A recipe hash can use a `<format>.salt` side-car file, which the
  chart does not supply.

This is the architecture upstream accessionflow is written for, and it is the
default here.

**Why new sites use it:**

* Its layout can be consumed by the XNAT uploader. The older layout defect
  is fixed in the pinned image (see the caveats below). Delivery still needs
  valid labels, credentials, network access and destination file checks.
* It de-identifies the file-drop path too. The Lua hook does not (see "Where
  the data enters").
* It keeps a reid mapping of changed metadata for approved re-identification
  workflows. Encrypt and retain that sensitive output under the site policy;
  it is not a substitute for the original study archive.
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

**Historical measurement (run date not recorded; reviewed 2026-11-10):** the
following run disabled the Lua hook while `tagMapping` still selected the
`ClinicalTrial*` tags. Its original run evidence is not verified (2026-11-10).
The current chart rejects that combination, so this is not an installation
example. It illustrates why assignment needs populated source fields:

```
study WITH the tags     -> test_project.PRETAG_SUBJ_008.PRETAG_SESS_008
study WITHOUT the tags  -> __invalid__/INVALID_MISSING_CLINICALTRIALPROTOCOLID_...
```

Under the default `ingest` mapping, the name shows the missing tag in the same
way, for example `INVALID_MISSING_STUDYID_...`. The chart now refuses the
`ClinicalTrial*` mapping under `ingest`.

`assign` does not distinguish who wrote the tags, only whether they are present.

## Side by side

| | A: Orthanc Lua hook (deprecated) | B: accessionflow deidentify |
|---|---|---|
| values key | `deid.engine: orthanc` | `deid.engine: ingest` |
| chart default | no, deprecated | **yes** |
| runs | inside Orthanc, per instance on arrival | own stage, between `assign` and `upload` |
| source of routing identifiers | derives them from the called AE title and the patient ID | expects them in the incoming data, or `constantProjectId` |
| needs an AE-title map | yes | no |
| strips PHI | yes, JSON profile | yes, pydicom `deid` recipe per project |
| pseudonymises the XNAT labels | yes, before anything downstream sees the data (salted djb2, not an HMAC, see the deprecated section of [components/deidentification.md](components/deidentification.md)) | **no**, the labels derive from normalized tag values. See *What stays* below |
| re-identification possible | no explicit map; source copies and weak hashes can still permit linkage | changed metadata can be linked via the sensitive reid mapping |
| identifiable data on the pipeline volume | original Orthanc/backup data and fields outside the profile can remain | yes before deidentify; originals and reid maps remain subject to retention |
| de-identifies the file-drop path | no | yes |
| `group-orthanc` waits for the ready label | yes | no. The chart derives this from `deid.engine`, so there is nothing to clear by hand |

## Upstream caveats affecting Architecture B

**The layout defect is fixed.** xnat-ingest 0.13.1 wrote the `deidentify`
output one directory level deeper than `assign` does. So `upload` reported
`Found 0 sessions` and data stopped there. That was
[xnat-ingest#144](https://github.com/Australian-Imaging-Service/xnat-ingest/issues/144),
closed on 2026-08-31 (GitHub state checked 2026-11-10). This is historical
behavior in 0.13.1. The pinned image,
`ghcr.io/australian-imaging-service/accessionflow:0.20.0`, writes the same layout as
`assign` (`accessionflow/model/accession.py`, `save()` in 0.20.0). The
2026-11-10 test run reached XNAT with this layout. That result does not prove
delivery for a different site or guarantee header extraction after upload.

**The `ais_deid` salt caveat does not apply to the pinned image.** Older
images de-identified through the `ais_deid` package. Its per-site salt was
commented out in the package examined for the historical 2026-08-24 issue
report (0.13.1 with ais-deid 0.1.2):

```python
#_SALT: str | None = os.environ.get("DEID_SALT")
# NOTE: Salting is currently disabled. The hash is computed without a salt,
# meaning the same input always produces the same output regardless of site.
```

Unsalted, a hospital MRN is a small search space, so a pseudonym is recoverable
by brute force, and two sites produce identical codes for the same patient.
That is
[xnat-ingest#143](https://github.com/Australian-Imaging-Service/xnat-ingest/issues/143),
open upstream when checked on 2026-11-10. The pinned image does not depend on `ais_deid` (see
the installed 0.20.0 distribution dependencies). Its recipes change only the tags that
they name, and the shipped recipe removes the identifiers. It does not hash
them.

**What stays.** The XNAT labels derive from source tags, normalized as
described above, because `assign` reads them before `deidentify` runs. If a
recipe hashes a value, the key comes from a `<format>.salt` side-car file, and
the chart does not supply one. `AIS_DEID_HMAC_SALT` does not control ingest
labels or recipes. The Orthanc Lua script still requires it at load time
when the facility backup uses that script, even with the ingest engine.

## Where the data enters

Orthanc is the only DICOM **network** receiver in this stack. accessionflow ships
no DICOM network stack — `pynetdicom` is not installed and no subcommand listens
on a port — so a scanner performing a C-STORE association has nothing else to
talk to.

Orthanc is not the only way in, though. `ingest.fileDrop` runs `accessionflow
collate` over a filesystem glob. So data that arrives as *files* gets into the
pipeline without Orthanc's REST pull: a share, a vendor export or an rsync.

Only the `ingest` engine de-identifies that path. A dropped file goes from
`group` to `assign`, and under `ingest` then to `deidentify`. The Lua hook runs
only when `OnStoredInstance` sees `RequestOrigin == DicomProtocol`
(`charts/edge/files/deidentify-and-forward.lua`). It returns for REST uploads
and does not see a file drop. Those paths bypass both its backup write and
the deprecated de-identification branch. Under the deprecated
engine the uploader reads `/data/assigned`
(`charts/edge/templates/_helpers.tpl`, `edge.uploadSourceDir`), so a dropped file goes to XNAT
without de-identification.

## See also

* [components/deidentification.md](components/deidentification.md): how to configure the `ingest` engine, and the reference for the deprecated one
* [components/orthanc.md](components/orthanc.md) — the receiver
* [components/accessionflow.md](components/accessionflow.md); the pipeline stages
