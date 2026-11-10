# De-identification engines: two architectures

The pipeline tool is accessionflow (called xnat-ingest before 0.18.0).

Use **`deid.engine: ingest` for every new site**. This is the chart default.
Orthanc receives DICOM. accessionflow groups the instances, assigns the XNAT
labels, applies the site's recipe, and uploads the result. The two arrival
patterns below both use this pipeline. They differ in the labels the modality
provides, not in the engine a site must select.

`deid.engine: orthanc` is deprecated. Its reference material is in
[Deprecated Orthanc Lua engine](components/deidentification.md#deprecated-orthanc-lua-engine).
Use that section to understand an existing installation. Do not use it to
configure a new site. The current ingest configuration is in
[components/deidentification.md](components/deidentification.md).

## What routing identifiers are

XNAT placement needs three values: project, subject and session. Under ingest,
the chart derives the following mapping when `ingest.assign.tagMapping` is empty:

```
StudyID           -> project
PatientID         -> subject
AccessionNumber   -> session
```

The example site states this same mapping explicitly. These are source tags,
not replacement values. Inspect what each modality sends before you adopt them.
A site can select other populated tags. `ingest.assign.constantProjectId` can
supply one destination project for all sessions when that is the site's policy.
Create the project in XNAT first and restrict the service account to it.

`assign` reads these values before `deidentify` runs. The recipe can remove or
replace a DICOM tag, but it cannot change an XNAT label that assignment has
already copied. IDSpec preserves letters, digits, underscores and hyphens;
other character runs become underscores. This normalization does not make a
clinical identifier private. With `subject: PatientID`, a hospital MRN in PatientID becomes
the subject label in clear text. Removing PatientID in the recipe does not fix
that label. Use identifiers approved for the destination before enabling upload.

The chart rejects tagMapping entries that start with `ClinicalTrial` in ingest
mode. Those entries are not the current defaults. If a site's research IDs use
those tags, agree on a supported tag mapping before installation. Do not bypass
the guard or choose a different engine to avoid reviewing the labels.

---

## Architecture A: studies arrive unidentified

A scanner may send only clinical patient and order identifiers. Its AE title
identifies a DICOM endpoint, but is not an XNAT project selector under ingest.
Orthanc accepts calling AE titles with the shipped configuration. There is no
AE-title routing or unknown-AET quarantine in this mode. Control which senders
can reach port 4242 at the network boundary.

Before receiving production studies, arrange the three placement values:

| Value | Site decision |
|---|---|
| project | Populate a tag with an existing XNAT project ID, or set `constantProjectId` for a single-project site. |
| subject | Use a research identifier approved for XNAT. Do not assume a clinical PatientID is a pseudonym. |
| session | Use a stable visit or acquisition identifier. Check that different sessions do not resolve to the same value. |
| recipe | Review `ingest.deidentify.specs` for every source format and project. |
| original | Keep the facility backup and pre-deidentification directories under local access controls. |

**Requires:** a supported tag mapping, populated source values, the site's
recipe, and an explicit `deid.policyReviewed: true` acknowledgement. The gate
checks that a person acknowledged the policy. It cannot inspect a scanner's
future output or determine whether an MRN is acceptable in the destination.

**Properties**

* The clinical input remains identifiable in Orthanc, grouped and assigned
  storage until the deidentify stage processes it. These directories need the
  same access controls as the facility backup.
* Missing placement values send a session to `assigned/__invalid__`. That
  directory can contain identifiable data. A successful receive does not mean
  the session has reached deidentify or XNAT.
* A constant project supplies only the project. It does not generate subject
  or session pseudonyms, and it does not make empty subject/session tags valid.
* The re-identification map is a separate sensitive output. The chart writes
  it under `/data/reid`; encrypt it and control access as described below.

Resolve incomplete source metadata with the modality or export owner. Keep the
original files while doing so. Do not send the same clinical identifier under
a new label without checking how it relates to existing subjects in XNAT.

---

## Architecture B: studies arrive already identified

A research export may already contain approved project, subject and session
values in tags that the chart supports. Select those tags in
`ingest.assign.tagMapping`. The data still needs a recipe: research labels do
not prove that the remaining headers, private fields or pixels are safe.

The same accessionflow pipeline applies:

| Step | What happens |
|---|---|
| group | Collects instances into studies without de-identifying them. |
| assign | Reads the selected tags and stores the placement values in session metadata. |
| deidentify | Applies the matching project recipe, or the `__default__` fallback. |
| reid mapping | Writes per-session JSON under `/data/reid`, encrypted when the configured key Secret is supplied. |
| upload | Reads `/data/deidentified`, or `/data/packaged` if packaging is enabled, and sends the output to XNAT. |

**Requires:** valid source labels, recipes in `ingest.deidentify.specs`, and
review of both the labels and the resulting data. Recipe keys have the form
`<PROJECT_ID or __default__>/medimage/dicom-series`. The value is a pydicom
`deid` recipe, not JSON. The chart mounts it at the path accessionflow expects.

**Properties**

* The example removes PatientID and AccessionNumber. It does not hash them.
  Neither stable pseudonyms nor salted hashing are automatic properties of
  the ingest engine.
* The recipe changes only the tags it names. The example retains private tags,
  PatientSex and PatientAge. A site must review these choices against its data.
* The mapping records original and modified metadata. It does not restore
  removed pixel content or replace the facility backup as an archive of record.
* The mapped XNAT labels survive recipe processing unchanged. Inspect them
  separately from the de-identified DICOM headers.

---

## Which applies to a given site

Both cases use ingest. Check a representative synthetic export before enabling
production traffic, then validate the mapping on approved site data in a
controlled environment:

```bash
# These are the derived defaults. Inspect your selected tags if they differ.
dcmdump file.dcm | grep -E '(StudyID|PatientID|AccessionNumber)'
```

Use this sequence for each modality and project:

1. Identify the populated tags and the destination project.
2. Confirm that the subject/session values are approved research labels.
3. Configure `constantProjectId` only if all input belongs to that project.
4. Check the recipe's removals, retained fields and de-identification markers.
5. Confirm that the pipeline produces a deidentified session with the intended
   XNAT labels. Check the destination headers as well as the labels.
6. Check `/data/reid` access and encryption before receiving patient data.

A field can be present but empty. Such a field does not provide a usable label.
If assignment fails, use the guarded recovery procedure in
[components/accessionflow.md](components/accessionflow.md#recovering-an-invalid-session).
Do not flatten directories or move a session into an existing target by hand.
The invalid input may still be needed to correct the site's source mapping.

## Side by side

| Check | Clinical source values | Research source values |
|---|---|---|
| engine for a new site | `ingest` | `ingest` |
| receiver | Orthanc on DICOM port 4242 | Orthanc on DICOM port 4242 |
| project selection | Populated tag or `constantProjectId` | Supported tag with the approved project ID |
| subject/session selection | Arrange approved research labels before upload | Select the tags that carry those labels |
| AE-title routing | Not used | Not used |
| recipe | Site-reviewed pydicom `deid` recipe | Site-reviewed pydicom `deid` recipe |
| automatic pseudonym hashing | None in the shipped recipe | None in the shipped recipe |
| original data on pipeline volume | Yes, before deidentify | Yes; research labels do not clean the other fields |
| re-identification map | Written by the chart configuration | Written by the chart configuration |
| ready-label filter | Cleared by the chart under ingest | Cleared by the chart under ingest |

## Upstream caveats affecting Architecture B

The pinned chart image is
`ghcr.io/australian-imaging-service/accessionflow:0.19.0`. Treat the image reference and
its installed Python version as separate identifiers. The locally inspected
image reports `0.19.0` as its package version. The previous fork reported
`0.16.3.dev49+ais.20261021.r13.g3182cc6`; that is a historical identifier from
the 2026-10-21 integration build, retained for comparing old run records.
Record the deployed image digest when comparing behavior across installations.

[#144](https://github.com/Australian-Imaging-Service/xnat-ingest/issues/144)
described an extra output directory in version 0.13.1. This historical issue
closed on 2026-08-31; GitHub state was checked on 2026-11-10. The pinned
image builds and publishes one session directory under the output root. That
layout is consumed by upload. The old claim that ingest cannot reach XNAT does
not describe this image. A running stage is still not delivery proof: inspect
its output, upload results and the destination files after each site install.

[#143](https://github.com/Australian-Imaging-Service/xnat-ingest/issues/143)
is open as of the 2026-11-10 GitHub check and describes the historical
0.13.1 `ais_deid` salting path reported on 2026-08-24. Do not infer that
`AIS_DEID_HMAC_SALT` or `DEID_SALT` enables hashing in the current chart recipe.
The pinned CLI documents a `<format>.salt` sidecar for hash transforms in a
`<format>.transforms.yaml` sidecar. The chart does not wire this as a salt
Secret, and the shipped recipe has no hash transform. A custom integration
needs its own reviewed secret mount, transforms and reproducibility checks.

The chart still supplies `AIS_DEID_HMAC_SALT` to Orthanc when the facility backup
is enabled. The Lua script requires the variable at load time. Its value does
not affect ingest labels or recipe output. Set the placeholder once as the
installation instructions require; do not treat that as ingest pseudonymisation.

## Where the data enters

Orthanc is the DICOM network receiver in this stack. A modality sends C-STORE
to the configured called AE title at `<nodeIP>:4242`. accessionflow processes
files and the Orthanc REST API; the chart does not expose a second DICOM receiver.
Network restrictions must enforce the intended sender boundary because the
shipped Orthanc configuration accepts any calling AE title.

`ingest.fileDrop` is the other entry path. It runs `accessionflow collate` over a
filesystem glob, for example an approved share or vendor export. It bypasses
Orthanc and its facility-backup callback. Keep the input files as originals;
`dataPolicy.originals.fileDrop.reclaim: never` is the default. A file-drop age
setting alone does not expire them. Both input paths feed assignment and the
same ingest recipe, so test label resolution for each source format.

## See also

* [components/deidentification.md](components/deidentification.md): recipes, labels, mapping encryption and the single deprecated-engine reference.
* [components/orthanc.md](components/orthanc.md): receiver configuration and the original-data backup.
* [components/accessionflow.md](components/accessionflow.md): stage paths, invalid-session recovery and cleanup controls.
