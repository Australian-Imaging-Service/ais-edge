# De-identification

The pipeline tool is accessionflow (called xnat-ingest before 0.18.0).

> **Which engine?** Use `deid.engine: ingest`. It is the default, and it is the
> only engine for a new site. [choosing-a-deid-engine.md](../choosing-a-deid-engine.md)
> gives the reasons. This page tells you how to configure it.

## Overview

**Review date: 2026-11-10.** This page describes the pinned accessionflow
0.19.0 implementation. The facility-backup write in `OnStoredInstance` is
limited to `RequestOrigin == "DicomProtocol"`. REST uploads and file-drop
input do not get that backup copy. Verify the retained originals separately
from recipe output. Orthanc/Lua de-identification was deprecated on 2026-11-02;
that decision does not deprecate Orthanc as the DICOM receiver.

**Orthanc is always present.** It is the only DICOM network receiver in this
stack. The optional file-drop input bypasses it. Its callback attempts the
facility backup for DICOM-protocol arrivals; REST arrivals bypass that write. Under the
default engine it does not de-identify. What this page configures is *where
de-identification happens*.

**The default engine is `deid.engine: ingest`** (key `deid.engine` in
`charts/edge/values.yaml`).
It is the `deidentify` stage of accessionflow. It runs on the edge, between
`assign` and the upload. The recipe, retained fields, pixel content, and
assigned labels determine whether identifying data can leave. The stage
location alone does not establish that the output is anonymous.

**The Orthanc Lua engine, `deid.engine: orthanc`, is deprecated.** Do not use
it for a new site. Its reference material is in one section of this page:
"Deprecated: Orthanc Lua engine (`deid.engine: orthanc`)".

| | Orthanc Lua hook (deprecated) | accessionflow deidentify |
|---|---|---|
| values key | `deid.engine: orthanc` | `deid.engine: ingest` |
| chart default | no, deprecated | **DEFAULT** |
| runs | inside Orthanc, per DICOM-protocol instance on arrival | own stage, between `assign` and `upload` |
| source of the XNAT project, subject and session | the called AE title and hashes of the patient ID | the DICOM tags that `ingest.assign.tagMapping` names, or `ingest.assign.constantProjectId` |
| needs an AE-title map | yes | no |
| changes selected metadata | JSON profile via Orthanc `/modify`; only DICOM-protocol arrivals reach this callback | format-specific recipe per project or fallback; no general guarantee for pixels or unnamed fields |
| pseudonymises the XNAT labels | yes (salted djb2, not an HMAC) | **no**, the labels are the tag values, verbatim. See *Routing identifiers* |
| re-identification evidence | originals remain in the backup if written and retained; weak hashes are not irreversible | sensitive mapping records transformed metadata; it is not a complete original archive |
| identifiable data on the pipeline volume | can remain in Orthanc storage after a failure or REST bypass; profile output also needs review | original/intermediate data, assigned labels, and reid maps can remain after the stage runs |
| `group-orthanc` waits for the ready label | yes | no, it takes each study that has been quiet for `waitPeriod` |

> **Why ingest?** See
> [choosing-a-deid-engine.md](../choosing-a-deid-engine.md). It sets out what
> each engine needs and why new sites use `ingest`. This page covers
> configuration.

## Routing identifiers, and why the choice is constrained

`assign` files each session under three XNAT ids: project, subject and session.
It reads each id from one DICOM tag. `ingest.assign.tagMapping` names the tags.
Leave it empty and the chart fills it in for the engine
(`charts/edge/templates/_helpers.tpl`). Under `ingest` the default is:

```
StudyID            -> project
PatientID          -> subject
AccessionNumber    -> session
```

Set a key to another tag when your modalities put the id there. A value can also
be a format string over several tags, for example
`{PatientID}_{StudyDate:%Y%m%d}` (see `accessionflow label xnat --help`).

`ingest.assign.constantProjectId` files every session under one XNAT project.
`assign` then ignores the project tag (`charts/edge/templates/ingest-pipeline.yaml`).
Use it for an edge that sends to one project only.

Under `ingest`, nothing writes these tags for you. Only the deprecated Lua
engine writes the `ClinicalTrial*` tags. So under `ingest` the chart refuses a
`tagMapping` value that starts with `ClinicalTrial`
(`charts/edge/templates/_helpers.tpl`).

If a tag is empty or absent, `assign` cannot resolve that id. It then puts the
session in `/data/assigned/__invalid__`. The placeholder name contains the tag
that was missing, for example:

```
/data/assigned/__invalid__/INVALID_MISSING_STUDYID_<8 random characters>.<subject>.<session>/
```

(accessionflow 0.19.0, `helpers/arg_types.py:426-447` and
`api/label_api.py:224-230`.)

Check the tags on a study that a modality actually sends:

```bash
dcmdump file.dcm | grep -E 'StudyID|PatientID|AccessionNumber'
```

> **CAUTION: the studies in `__invalid__` still hold PHI.**
>
> `assign` runs before `deidentify`. So a session that `assign` puts in
> `/data/assigned/__invalid__` was never de-identified. No stage reads that
> directory: accessionflow skips every name that starts with `__`
> (`accessionflow/helpers/remotes.py:554-562`). The `deidentify` stage reports
> `Found 0 sessions` on each cycle while the directory fills up. Measured on a
> test edge in a historical run (date not verified, reviewed 2026-11-10):
> 531 instances, with the patient name still in them, stayed there
> and nothing failed loudly. `InvalidSessionAssigned` now fires when `assign`
> reports one.
>
> The chart refuses the `ClinicalTrial*` form of this mistake at render time. It
> cannot detect the other form: `tagMapping` names real tags that the modalities
> of this site do not populate. That configuration looks correct and gets the
> same result. Do not rely on the guard. Examine the tags on a real study.

> **CAUTION: `ingest` has no AE-title routing.**
>
> Orthanc accepts any calling AE title (`orthanc.json` has
> `DicomModalities: {}`, `charts/edge/templates/orthanc-config.yaml`). Under
> `ingest` the Lua script stops before its AE-title lookup
> (`charts/edge/files/deidentify-and-forward.lua`, lookup at `charts/edge/files/deidentify-and-forward.lua`). So no
> study is routed by AE title, and no study is quarantined for its AE title. The
> `deidentify` stage never sees the AE title. **You cannot get the project from
> the machine that sent the study.**
>
> So your modalities must put the project, subject and session in tags that
> they actually send. Point `ingest.assign.tagMapping` at those tags. If every
> modality sends the same project value, every study goes to that project.
>
> ```yaml
> ingest:
>   assign:
>     tagMapping:
>       project: StudyID          # whatever your modalities actually populate,
>       subject: <pseudonym tag>  # see the caution below before choosing these
>       session: <pseudonym tag>
> ```
>
> The chart derives the default for these three keys from the engine. Under
> `ingest` the default is `StudyID`, `PatientID` and `AccessionNumber`. They
> are values, not constants. Set them to the tags that your modalities fill in.

> **CAUTION: the tags that you name become the XNAT labels, verbatim and not
> de-identified.**
>
> `assign` reads the three tags and puts their values into the session object.
> All later steps use the values, not the tags. `deidentify` builds its
> output with `ImagingSession.new_empty()`, which copies `project_id`,
> `subject_id` and `session_id` unchanged. `save()` names the directory
> `<project>.<subject>.<session>`. `upload` creates the XNAT subject and
> experiment from the same ids.
>
> **A recipe cannot change them.** The recipe changes DICOM tags. But `assign`
> has already read the values before `deidentify` runs. So the tag that you
> name in `subject` becomes the XNAT subject label as the modality sent it.
> The only change: `assign` turns each run of characters other than letters,
> digits, `_` and `-` into one `_` (`IDSpec.xnat_id_escape_re` in accessionflow),
> so `SMITH^ALEX` becomes `SMITH_ALEX`. The identity stays.
>
> Under `ingest` no step makes a pseudonym from these values. PatientID often
> holds a hospital medical record number. If it does and `subject` reads
> `PatientID`, that raw number goes into the XNAT metadata. The DICOM
> headers may look clean after named removals, but the identifier remains
> in the label. The shipped header recipe does not strip burned-in pixels. An approved research identifier in PatientID is fine.
>
> Choose tags that are ALREADY pseudonymous at the modality, or make the
> modality send one. Examine a real study before you enable the engine:
>
> ```bash
> # whatever these print is what will appear in XNAT
> dcmdump file.dcm | grep -E '<the three tags you configured>'
> ```

## Pseudonym strength

Under `ingest`, nothing in this chart makes a pseudonym. The XNAT labels are
the tag values that `assign` reads (see the caution above). The recipe changes
only the tags that it names. The shipped recipe removes `PatientID`,
`PatientName` and `AccessionNumber`. It does not replace them with a code.

A recipe can hash a value. accessionflow reads the `var:` and `func:` values of
a recipe from a `<format>.transforms.yaml` side-car file. A `<format>.salt`
side-car file can hold a key for those hashes (`accessionflow deidentify --help`,
`accessionflow/cli/deidentify_cli.py`, recipe-sidecar help in 0.19.0). The chart does not
supply a salt side-car. `ingest.deidentify.specs` writes its files into a
ConfigMap, and a ConfigMap is not a place for a secret. Also, a hash in the
headers does not get to the XNAT labels: `assign` reads them before
`deidentify` runs.

`AIS_DEID_HMAC_SALT` in the Secret `orthanc-deid-salt` is a different salt.
Only the Orthanc Lua script reads it. Under `ingest` the script never uses the
value: it stops at `charts/edge/files/deidentify-and-forward.lua`, before it hashes anything.
But the Orthanc pod gets the variable whenever the facility backup is on
(`charts/edge/templates/orthanc-deployment.yaml`). The script stops at
load if the variable is not set (`charts/edge/files/deidentify-and-forward.lua`). So the Secret
must exist, but under `ingest` its value changes nothing. You can rotate it
without an effect on XNAT. Restart Orthanc after a rotation, because the pod
reads the value only at start.

The strength of the pseudonyms of the deprecated engine is in "Deprecated:
Orthanc Lua engine (`deid.engine: orthanc`)", below.

## What the recipe does not do

**Content limits:** the example does not remove every private tag, free-text
field, or pixel annotation. It retains PatientSex and PatientAge. Added
`PatientIdentityRemoved` and `DeidentificationMethod` fields are assertions
about processing, not validation of anonymity. Check headers, pixels, assigned
XNAT labels, and the sensitive mapping together. A copied resource classified
as not containing PHI has not had every byte inspected for identifiers.

The engine applies a recipe, and **only the tags the recipe names are touched**.
The shipped example needs a site review before it is used as policy. Three
things about it are not clear
from the recipe text, so they are stated here.

**Historical example defect (date not verified, reviewed 2026-11-10):**
the example previously kept `PatientID`, justified
by a note claiming `assign` had already rewritten it and that `upload` needed
it. Both halves were false. `assign` reads tag values to resolve ids and then
copies or hardlinks files unchanged — it never writes a dataset. And upload
places the session from the session object's ids, not from this header. The
example now removes it. If you write your own recipe, decide about `PatientID`
explicitly. If it holds a real medical record number, leaving it means that
number travels with every instance while `PatientName`, birth date and
institution are stripped, so the result passes a spot check.

That matters more than it looks, because upload finishes with:

```
/data/experiments/<id>?pullDataFromHeaders=true
```

which asks XNAT to populate its own metadata **from these headers**. An
identifier left in the header is not merely archived, it is indexed.

**The upstream default transforms are not pseudonymisers.** The accessionflow
package contains its own `__default__` recipe. The chart does not use it: the
stage reads only the recipes in `ingest.deidentify.specs`. If you copy the
upstream recipe, also read its side-car,
`accessionflow/specs/__default__/medimage/dicom-series.transforms.yaml` (in
0.19.0). It sets these values:

```yaml
anon_patient_name:   {tag: PatientID}
anon_patient_id:     "{patient_id}-{acquisition_time}"   # PatientID, AcquisitionTime
patient_comments:    "Project={project};Subject={subject};Session={subject}-{acquisition_time}"
                     # project = ReferringPhysicianName, subject = PatientID
```

Each derives its replacement from the raw identifier: the patient's *name*
becomes their medical record number, and `PatientComments` is rebuilt to
contain that number twice along with the referring physician. These are the
identifier with decoration, not pseudonyms. Supply your own recipes and
transforms rather than relying on those.

**The birth date.** The shipped recipe has `REMOVE PatientBirthDate`, so the
date does not get to XNAT. If your policy must keep part of the date, write
that in your recipe. The upstream default keeps the year: its
`anon_birth_date` value keeps the first four characters and adds `0101`. That
is truncation to the year. It is not jitter. The deprecated Lua profile did the
same, and "Deprecated: Orthanc Lua engine" below records how it did it.

A site that moves from the deprecated engine to `ingest` with the shipped
recipe changes what gets to XNAT in this field. Nothing in the move tells you.

## The label coupling

Under `ingest`, `group-orthanc` does not filter on a label. The chart gives it
`--to-process-label` only under the deprecated `orthanc` engine
(`charts/edge/templates/ingest-pipeline.yaml`). So `group-orthanc` takes each
study that needs processing, including a changed source snapshot despite a
prior processed label, and has been quiet for
`ingest.orthancGroup.waitPeriod` seconds. After it stages a study, it applies
`processedLabel` and a snapshot label.

When the facility backup is on, the chart loads the Lua script, and its
`OnStableStudy` callback runs under `ingest` too. Under `ingest` the chart
requires the facility backup (`charts/edge/templates/_helpers.tpl`), so the script is always
loaded there. `OnStableStudy` has no `DeidEnabled` guard. Only
`OnStoredInstance` returns early (`charts/edge/files/deidentify-and-forward.lua`).
`OnStableStudy` (`charts/edge/files/deidentify-and-forward.lua`) applies the ready label to a stable study. It
removes `processedLabel` when a stable study gets new instances, and logs
`study_reopened`. The ready label is `Defaults.ReadyLabel` in `routing.json`.
The chart takes it from the raw `ingest.orthancGroup.toProcessLabel` value,
`xnat-ingest-ready` by default (`charts/edge/templates/orthanc-config.yaml`). An empty value
stops the label write.

Under `ingest` no stage filters on the ready label. **So a ready label does
not prove that de-identification ran.** It marks a stable study. To check the
de-identification, read the `deidentify` log and the output in
`/data/deidentified`.

The chart derives the filter from `deid.engine`. You do not clear
`toProcessLabel` by hand. Do not add a ready-label filter to an `ingest` site:
study selection would then depend on this callback and its label setting. The
coupling under the deprecated engine is described in the deprecated section
below.

## Deprecated: Orthanc Lua engine (`deid.engine: orthanc`)

> **Deprecated.** Do not use this engine for a new site. Use
> `deid.engine: ingest`. This section is reference material for a site that
> still runs this engine, and for a site that moves off it. "5. Switch engines"
> below tells you how to move a site.

```yaml
deid:
  engine: orthanc                # deprecated
  policyReviewed: false          # no safe default; a human must confirm.
                                 # Top level, NOT under orthanc: it gates
                                 # every engine.

orthanc:
  deid:
    existingSaltSecret: orthanc-deid-salt
    aetMap:
      SIEMENS_3T_AET: {project: MYSITE_RESEARCH}
    profile: {}                  # from files/deidentification-profile.example.json
```

Do not set `orthanc.deid.enabled`. The chart refuses that key and tells you to
use `deid.engine` (`charts/edge/templates/_helpers.tpl`).

Under this engine the chart also refuses an empty `aetMap` and an empty
`profile` (`charts/edge/templates/_helpers.tpl`). It refuses recipes in
`ingest.deidentify` (`charts/edge/templates/_helpers.tpl`). It refuses a `tagMapping` that
reads a tag the profile rewrites for another role (`charts/edge/templates/_helpers.tpl`).

`existingSaltSecret` is what makes the pseudonyms stable. The same patient
always hashes to the same subject, so the second visit of a patient goes to the
same XNAT subject as the first. If you rotate the salt, every pseudonym changes,
and existing XNAT subjects stop matching new studies. Under this engine, keep
the salt for the life of the site.

### Routing by called AE title

The hook routes on the **called** AE title. That is the AE title that the
modality sends to (`origin.CalledAet`, `charts/edge/files/deidentify-and-forward.lua`). It is
not the AE title of the modality itself. Orthanc accepts any called AE title,
so each modality can send to its own AE title, and `orthanc.deid.aetMap` maps
that AE title to an XNAT project.

For each DICOM-protocol instance, the historical engine does these steps.
REST input returns before this path and can retain original identifiers:

| step | what happens |
|---|---|
| backup | writes the original to the facility backup (`charts/edge/files/deidentify-and-forward.lua`) |
| project | looks up the called AE title in `routing.json` `AETMap` (`charts/edge/files/deidentify-and-forward.lua`) |
| subject / session | hashes `PatientID`, and `PatientID` with `StudyInstanceUID`, with the salt (`charts/edge/files/deidentify-and-forward.lua`) |
| routing tags | the profile writes those values into the three `ClinicalTrial*` tags |
| PHI | stripped per the JSON profile through Orthanc `/modify` (`charts/edge/files/deidentify-and-forward.lua`) |

`assign` then reads the routing tags. Under this engine the chart sets
`tagMapping` to them:

```
ClinicalTrialProtocolID    -> project
ClinicalTrialSubjectID     -> subject
ClinicalTrialTimePointID   -> session
```

If a study does not carry them, `assign` puts it in `__invalid__`, with names
such as `INVALID_MISSING_CLINICALTRIALPROTOCOLID_...`.

**An unmapped called AE title is quarantined, not dropped** (`charts/edge/files/deidentify-and-forward.lua`). The
hook writes the original to
`<FacilityBackupDir>/__unmapped_aet__/<AET>/<PatientID>/<StudyUID>/<SOPUID>.dcm`.
Then it removes the instance from Orthanc. If the write fails, it keeps the
instance in Orthanc. It logs `REJECT: no project mapped for CalledAET <AET>`,
which the `DICOMRejectedUnmappedAET` alert matches. `QuarantinedDataUnresolved`
fires when quarantined data is older than
`dataPolicy.originals.quarantine.alertAfter`. To ingest the studies, add the AE
title to `aetMap` and send them again.

Under `ingest` none of this happens. The hook stops at
`charts/edge/files/deidentify-and-forward.lua`, before the lookup.

### Pseudonyms: salted djb2, not an HMAC

The subject and session codes come from a function called `hmacShort`. **It is
not an HMAC.** The code says so on the line above it
(`charts/edge/files/deidentify-and-forward.lua`):

```lua
-- Salted djb2. NOT cryptographic; jodogne/orthanc-plugins doesn't expose
-- ComputeMd5/Sha1 in Lua. For HMAC-grade switch to jodogne/orthanc-python.
local function hmacShort(value, length)
```

The name of the environment variable, `AIS_DEID_HMAC_SALT`, gives the same
wrong impression. The function computes a salted djb2 with a second mixing
accumulator. It formats the result as 16 hex characters and keeps 12. So the
output has 48 bits.

What that is good for, and what it is not good for:

* **Collisions remain possible.** Twelve hexadecimal characters encode at
  most 48 bits. Even an ideal uniform 48-bit output has a birthday collision
  probability of about 0.18% after one million distinct inputs. This weak
  non-cryptographic construction does not establish uniformity or eliminate
  collisions; a cohort being below 16.7 million is not a no-collision proof.
* **It is not a cryptographic one-way transform.** Small structured patient-ID
  spaces can be enumerated, particularly by a reader with the salt. The older
  claim that inversion took minutes was not benchmarked in this review
  (2026-11-10), so it is retained only as an unverified historical estimate.

The salt is delivered as a Kubernetes Secret on the edge. That does not prove
it exists nowhere else: site secrets, backups, recovery material, and authorized
administrative access are other copies or access paths. The hook does not send
the salt to XNAT, but a secret location is not a cryptographic guarantee about
its pseudonyms. Preserve linkage and recovery material for existing sites.

The source's suggestion to move this hook to a Python-enabled Orthanc image
is historical, predating the 2026-11-02 deprecation. It is not the recommended
new-site path. Use the ingest stage and an approved label/recipe policy. Do not
replace an existing site's salt or algorithm without a reviewed identity
migration, because that can split subjects and sessions already in XNAT.



Because the hook writes these codes before `assign` runs, the XNAT labels are
pseudonyms under this engine. Under `ingest` they are the raw tag values. See
*Routing identifiers* above.

### What the Lua profile changes

The hook replaces the identifiers with salted hashes at the front door, before
`group`, `assign` or another stage sees them. That explains its historical label layout; it is not an overall security
ranking or a reason to deploy this deprecated mode. Backup failures, REST
bypass, collisions, and retained fields still need separate consideration.

**The birth date is truncated to the year.** The shipped Orthanc profile sets:

```yaml
PatientBirthDate: ${BirthYearOnly}0101
```

The hook resolves `${BirthYearOnly}` from the first four characters of the
incoming date (`charts/edge/files/deidentify-and-forward.lua`):

```lua
local birthYear = (rawBirth and #rawBirth >= 4) and string.sub(rawBirth, 1, 4) or "1900"
```

So `19551103` becomes `19550101`. The day and month are removed and **the true
birth year of the patient stays**. That is truncation to the year, a research
trade-off: the age at scan stays correct to within a year. It is not jitter.
Nothing here shifts the date by a random amount. If your ethics approval does
not permit the real year, remove the tag. Do not reshape it.

A zero-length birth date was a defect here. Lua treats only `nil` and `false`
as false, so an empty `PatientBirthDate` did not use the `or` fallback. It
resolved to the four-character string `0101`, which is not a valid DICOM date,
in every instance of that study. The code now examines the length. An absent or shorter-than-four-character value gives `19000101`. Four or
more characters are not calendar-validated, so a malformed prefix can still
produce an invalid date. This is a remaining limit of the deprecated hook.

The shipped `ingest` recipe makes the opposite choice: `REMOVE PatientBirthDate`.

### The ready label

Under this engine the hook does two jobs. It de-identifies, **and** it applies
the `xnat-ingest-ready` label in `OnStableStudy`. The chart then gives
`group-orthanc` `--to-process-label xnat-ingest-ready`
(`charts/edge/templates/ingest-pipeline.yaml-107`). So `group-orthanc` takes
only labelled studies. The label is meant to hold a study back until the hook
has stripped it. It is not a receipt. `OnStableStudy` does not check each
instance. If `/modify` fails for an instance, the hook keeps the original in
Orthanc unchanged (`charts/edge/files/deidentify-and-forward.lua`), and the stable study
still gets the ready label.

If the hook does not apply the label, `group-orthanc` filters out every study,
and the pipeline stops with no error. That is why the chart derives the flag
from `deid.engine` and does not let you set it per engine.

## Configuration: accessionflow deidentify

### 1. Write the recipes

Copy `charts/edge/files/deid-specs.example/`, which ships a working default:

```
deid-specs/
    __default__/
        medimage/
            dicom-series              # fallback for any project
    MYPROJECT/
        medimage/
            dicom-series              # this project only
```

One directory per project, named for the project ID `assign` gave the session,
plus an optional `__default__` fallback. Inside each, the format's MIME-like
identifier becomes a PATH rather than a filename: `medimage/dicom-series` is a
directory `medimage` holding a file `dicom-series`.

That structure is load-bearing. The stage walks
`<spec-dir>/<project>/<category>/<format>` and skips a file at the top level
that is not in a directory. So a flat file named `medimage@dicom-series.json`
is never read. The stage then finds no recipes and fails each session with
`No deidentification recipe files found for '<project>' and no default
recipe files provided.` (`accessionflow/api/deidentify_api.py:136-137` in
0.19.0). The data stays in `/data/assigned`.

**The file is a pydicom `deid` recipe, not JSON, whatever its extension.** The
upstream default is named `dicom-series.json`. The example in this repository
has no extension. accessionflow accepts both:

```
FORMAT dicom

%header

REMOVE PatientName
REMOVE PatientBirthDate
REMOVE AccessionNumber
```

This sample shows the syntax only. It is not a policy.

**Only the tags a recipe names are removed.** Anything not listed passes
through untouched, so the recipe *is* the policy ; review it as one. For a resource that declares it contains PHI and whose deidentify method
accepts a recipe, the default strict check fails when the matching recipe is
missing. Resources classified as not containing PHI are copied. That format
classification is not an inspection of all values or pixels; verify each
accepted resource type and the session-level resources as well.

**Remove `PatientID`.** An earlier version of this page said not to, on the
grounds that `assign` had already rewritten it to the routed subject and that
`upload` needed it for placement. Both claims were wrong. `assign` only READS tag
values to resolve ids and then copies or hardlinks the files unchanged; it never
opens a dataset for writing. Placement is explicit, built from the session's ids
which came from `ingest.assign.tagMapping`, not from this header.

What actually happens if it is left: `upload` finishes by calling
`/data/experiments/<id>?pullDataFromHeaders=true`, which asks XNAT to populate its
own metadata FROM THESE HEADERS. A real medical record number left here is not
merely present in the pixel archive, it is pulled into XNAT's fields, while
PatientName, birth date and institution are correctly stripped, so the result
looks de-identified to a spot check. Historical test (date not verified,
reviewed 2026-11-10): an instance de-identified under the
old advice reached XNAT with `PatientID` verbatim and `PatientIdentityRemoved`
absent. The shipped recipe now ends `REMOVE PatientID`.

### 2. Put them in the site file

The recipes go in `sites/<site>/values.yaml`. The chart builds the ConfigMap
and mounts it. So a new install needs no `kubectl`, and nothing has to exist
before the install. The recipes below show the format only. They are not a
policy. Start from the complete recipe in `sites/example-edge/values.yaml`. A
short recipe at a key replaces the complete one there:

```yaml
# ingest IS THE DEFAULT ENGINE, so you need not set deid.engine. The chart
# refuses these recipes under any other engine
# (charts/edge/templates/_helpers.tpl). Without that guard they were
# discarded silently: helm succeeded, no pod was created and nothing warned.
deid:
  engine: ingest
ingest:
  deidentify:
    specs:
      "__default__/medimage/dicom-series": |
        FORMAT dicom

        %header

        REMOVE PatientName
        REMOVE PatientBirthDate
        REMOVE AccessionNumber
      "MYPROJECT/medimage/dicom-series": |
        FORMAT dicom

        %header

        REMOVE PatientName
```

The key is the path under `SPEC_DIR`; the value is the recipe. Changing a
policy later is a `helm upgrade` with the edited site file — still no
`kubectl`.

A ConfigMap key cannot contain `/` or `@`, and a ConfigMap mounts flat, so the
chart sanitises each path into a legal key and maps it back with `items[].path`
on the volume. That is internal: write the real paths and ignore the
restriction.

#### Managing the ConfigMap yourself

For recipes that come from elsewhere — sealed-secrets, an external pipeline, or
externally managed files, supply the ConfigMap and map its keys to paths.
The same Kubernetes ConfigMap size limit still applies; this is not a route
around it. Clear inline `specs` from every values layer:

```bash
kubectl -n xnat-ingest create configmap deid-specs \
    --from-file=default-dicom-series=__default__/medimage/dicom-series
```

```yaml
ingest:
  deidentify:
    specs: null  # Clear any inline recipe map from lower values layers.
    specConfigMap: deid-specs
    specFiles:
      default-dicom-series: "__default__/medimage/dicom-series"
```

Create the namespace and external ConfigMap before the workload starts.
This can precede a fresh install or an upgrade; it is not limited to a
post-install step. The chart only mounts the named object. Check its recipe
content and paths, and keep secrets out of that ConfigMap.

### 3. Optionally, an encryption key for the reversal map

The chart gives the stage `--reid-dir /data/reid`
(`charts/edge/templates/ingest-pipeline.yaml`). So the stage writes the
map back to the removed identities into `/data/reid`, one file per session. On
the host that is `/data/xnat-ingest/reid`, on the same volume as the data that
it de-identifies. Without a key, each map is plain JSON,
`<project>.<subject>.<session>.json`.

The key is optional for the chart. **A production site must set it** (the
comment on `ingest.deidentify.reidEncryptKeySecret` in
`charts/edge/values.yaml`). Generate a Fernet key:

```bash
python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

Put it in a Secret in the edge site file, `sites/<edge>/secrets.enc.yaml`. The
key name must be `XINGEST_REID_ENCRYPT_KEY`.
`sites/example-edge/secrets.example.yaml` has a template for it. Then name the
Secret in the site values:

```yaml
ingest:
  deidentify:
    reidEncryptKeySecret: reid-key
```

On a test edge you can also make the Secret by hand:

```bash
kubectl -n xnat-ingest create secret generic reid-key \
    --from-literal=XINGEST_REID_ENCRYPT_KEY='<the key>'
```

With the key, the stage writes each map as `<project>.<subject>.<session>.json.enc`
(`accessionflow/api/deidentify_api.py`, re-identification map encryption in 0.19.0). You cannot read
it without the key. **Keep the key somewhere other than the volume the maps are
on.** Together, they are just a slower way to store the identifiers.

The key affects new maps only. It does not encrypt or remove the plain `.json`
maps that already exist. A map that the stage wrote with an old key needs that
old key. Keep the old key while you keep those maps.

### 4. Confirm your studies carry the routing tags

**Do this check before you send real studies.** It is the difference between a
working pipeline and every study in `__invalid__`:

```bash
# on a study your modality actually sends: the tags tagMapping names
dcmdump file.dcm | grep -E 'StudyID|PatientID|AccessionNumber'
```

All three tags that `tagMapping` names must be present and filled in. If one is
not, set `tagMapping` to a tag that the studies do carry. For the project, you
can set `ingest.assign.constantProjectId` instead. Do not go back to the Lua
engine for this: it is deprecated. See *Routing identifiers* above.

### 5. Switch engines — ONE setting

```yaml
deid:
  engine: ingest        # ingest (the default) | orthanc (deprecated) | none
```

`ingest` is the default. A new site does not change this key. A site that still
runs the deprecated `orthanc` engine moves to `ingest` with this one key, plus
the site file changes below. Everything else follows from the key, because a
pipeline with one of these out of step rendered cleanly and then did not work:

| derived | what it becomes under `ingest` |
|---|---|
| the Lua hook's `DeidEnabled` | `false`. The hook still attempts the original backup for DICOM-protocol arrivals. It does not read the AE-title map, it quarantines nothing and it does not change the instance (`charts/edge/files/deidentify-and-forward.lua`). `OnStableStudy` does not read this flag: it still labels stable studies |
| `ingest.orthancGroup.toProcessLabel` | not given to `group-orthanc`, because no stage filters on the label under `ingest` |
| `ingest.assign.tagMapping` | `StudyID`, `PatientID`, `AccessionNumber` when you leave it empty |
| the `deidentify` stage | rendered |
| the tree `upload` reads | `/data/deidentified` instead of `/data/assigned` (`/data/packaged` with the optional package stage) |
| `dataPolicy.derived.assigned.reclaim: auto` | `onDeidentified`: the stage removes each session from `/data/assigned` when it has written a complete copy |

To move an existing site:

1. Add `ingest.deidentify.specs`. The chart refuses `ingest` without a recipe
   (`charts/edge/templates/_helpers.tpl`).
2. Set `tagMapping` to tags that your studies carry (step 4), or set
   `constantProjectId`.
3. Read the recipe, then set `deid.policyReviewed: true`.
4. Set `deid.engine: ingest`.

`orthanc.deid.aetMap` and `orthanc.deid.profile` have no effect under `ingest`.
You can leave them or remove them.

**The labels change shape.** Under the Lua engine the XNAT subject and session
labels were pseudonyms. Under `ingest` they are the values of the tags that you
name. So a patient who is already in XNAT gets a new subject at the next study.
Decide how to link the two before you move a site.

An earlier version of this page told you to set `orthanc.deid.enabled: false`
and `ingest.deidentify.enabled: true` by hand. Both keys are gone. The chart
refuses to render if you set either one and tells you to use `deid.engine`
(`charts/edge/templates/_helpers.tpl`). So that older advice fails loudly.

**What did NOT fail loudly, and is the trap to know:** recipes in
`ingest.deidentify.specs` while another engine is selected. When `orthanc` was
the default, a site that pasted recipes and left the engine alone got a clean
install. Helm exited 0, no ConfigMap was built, no `deidentify` pod existed,
and the Orthanc profile continued to de-identify. The install looked correct
and the recipe never ran. The chart now refuses that combination.

The engines also disagree about one field, and a move does not tell you: see
"The birth date" under *What the recipe does not do*.

## Where the stage sits on a tier-2 (cloud) deployment

On tier-1 the edge uploads straight to XNAT, so `deidentify` sits between
`assign` and that upload. On tier-2 the edge stages to S3 and a management-side
uploader moves it on to XNAT, so the chain is longer:

```
tier-1   orthanc -> group -> assign -> [deidentify] -> [package] -> upload ------------> XNAT
tier-2   orthanc -> group -> assign -> [deidentify] -> [package] -> rclone -> S3 -> mgmt xnat-upload -> XNAT
```

The placement is the same either way — immediately before whatever carries data
off the node — and the chart handles it with one helper, so no extra
configuration is needed. `upload` and the rclone S3 uploader both read
`edge.uploadSourceDir`. Under the default `ingest` engine that is
`/data/deidentified`, and `/data/packaged` when the optional package stage runs
after it (see [package-stage.md](../package-stage.md)).

This ordering matters on tier-2 specifically: **the default path runs the recipe before S3 upload**. Retained identifiers
in labels, private fields, pixels, or unsupported formats can still leave
with the output. Review that content before enabling transfer. The stage is
on by default; it changes what is sent, not S3's position in the chain.

Two other tier-2 differences:

* the alert rules live in the **management** chart
  (`charts/mgmt/files/loki-ruler-rules.yaml`), because tier-2 runs Loki centrally
  and edges ship to it. `DeidentifyStageError` is there, next to
  `OrthancDeidLuaError`.
* `accessionflow` is pinned in **both** charts: `charts/edge` for the pipeline
  stages and `charts/mgmt` for the S3 -> XNAT uploader. Both pin the upstream image
  `ghcr.io/australian-imaging-service/accessionflow:0.19.0` (`ingest.image` in
  `charts/edge/values.yaml`; `xnatUpload.image` and
  `dataPolicy.derived.s3Staged.image` in `charts/mgmt/values.yaml`). Both must
  move together, because the CLI contract is shared.

## What the chart refuses

| combination | why |
|---|---|
| both engines at once | you cannot express it: `deid.engine` selects one engine. Under the Lua engine the hook strips first, so a reid mapping would record pseudonyms as if they were originals. It would reverse to nothing while it seemed to work |
| an unknown `deid.engine` word | it would select no engine (`charts/edge/templates/_helpers.tpl`) |
| `ingest` with no `specs` and no `specConfigMap` | the volume renders with an empty source; the pod sits in `CreateContainerConfigError` on the edge (`charts/edge/templates/_helpers.tpl`) |
| `specConfigMap` without `specFiles` | the ConfigMap mounts flat, so no recipe matches (`charts/edge/templates/_helpers.tpl`) |
| `ingest.deidentify` recipes under another engine | nothing would mount them, so they would never run (`charts/edge/templates/_helpers.tpl`) |
| `ingest` with a `tagMapping` value that starts with `ClinicalTrial` | nothing writes those tags under `ingest`, so every session would go to `__invalid__` with its PHI (`charts/edge/templates/_helpers.tpl`) |
| `ingest` with `dataPolicy.derived.assigned.reclaim: onUploaded` | the uploader reads `/data/deidentified`, so the condition can never be true (`charts/edge/templates/_helpers.tpl`) |
| `ingest` or `orthanc` with `deid.policyReviewed: false` | a human must confirm the recipe first (`charts/edge/templates/_helpers.tpl`) |
| `none` with `policyReviewed: false` | identifiable data would reach XNAT unchanged (`charts/edge/templates/_helpers.tpl`) |
| the removed keys `orthanc.deid.enabled`, `ingest.deidentify.enabled` and `orthanc.deid.policyReviewed` | they do nothing now, so they fail and name the new key (`charts/edge/templates/_helpers.tpl`, `charts/edge/templates/_helpers.tpl`) |
| *(not caught by the chart)* | `tagMapping` names tags that the modalities of this site do not populate. The chart cannot see inside your DICOM, so this fails at runtime with every study in `__invalid__` |
| `toProcessLabel` under `ingest` | not refused, and not needed: the chart does not give it to `group-orthanc` under `ingest` (`charts/edge/templates/ingest-pipeline.yaml`) |

`deid.engine: none` is allowed only with `policyReviewed: true`. Use it for a
site whose modalities de-identify upstream, or for one that stages into a
trusted enclave.

## Operations

```bash
# Which engine is actually running
kubectl -n xnat-ingest get deploy | grep -E 'orthanc|deidentify'

# Lua hook events. Under ingest: instance_archived, study_labeled_ready and
# study_reopened. The label events do not prove that de-identification ran.
# Under the deprecated orthanc engine: instance_deidentified as well.
kubectl -n xnat-ingest logs deploy/edge-orthanc | grep -E 'instance_archived|instance_deidentified'

# deidentify stage
kubectl -n xnat-ingest logs deploy/edge-deidentify --tail=50

# What a session's reversal map recorded (unencrypted only)
kubectl -n xnat-ingest exec deploy/edge-deidentify -- \
    cat /data/reid/<project>.<subject>.<session>.json
```

`edge` is the release name that `install.sh` gives the edge chart. A site
installed under another release name has other object names.

An empty `/data/deidentified` beside a populated `/data/assigned` needs
investigation. Work may still be within its wait period, in progress, or
already packaged/reclaimed downstream; the two directory counts alone do
not prove failure. Read stage logs and inspect manifests and downstream output. A missing recipe logs
`No deidentification recipe files found for ... and no default recipe files provided.`. An input with no data files
and no session metadata raises an error. A metadata-only skeleton is skipped
with event `deid_skeleton_skipped`. Each loop logs
`Deidentification completed with N errors` when sessions failed
(`accessionflow/api/deidentify_api.py` and
`accessionflow/cli/deidentify_cli.py` in 0.19.0).

## Current limitation

The layout limit that this section described is gone. In the pinned image,
`deidentify` writes the same layout as `assign`
(`accessionflow/model/accession.py`, `staging_dirname()` and `save()`):

```
/data/deidentified/<project>.<subject>.<session>/<scan>/...   <- what it writes
/data/assigned/<project>.<subject>.<session>/<scan>/...       <- what assign writes
```

So `upload` and the S3 uploader find the sessions, and `deid.engine: ingest`
carries data all the way to XNAT. That is why it is the default.

The history: xnat-ingest 0.13.1 wrote one directory level deeper
(`/data/deidentified/<session>/<session>/<scan>/DICOM/*.dcm`). So `upload`
reported `Found 0 sessions` and the data stopped there. That was
[xnat-ingest#144](https://github.com/Australian-Imaging-Service/xnat-ingest/issues/144),
closed on 2026-08-31 (upstream status checked 2026-11-10).

The limits that stay:

* The XNAT labels are the tag values, verbatim. Hashing at the `assign` step is
  a known second-pass item (the comment on `ingest.assign.tagMapping` in
  `charts/edge/values.yaml`). Choose pseudonymous tags.
* The chart supplies no salt side-car for hash transforms (see *Pseudonym
  strength*).
* No retention rule removes the maps in `/data/reid`. See
  [accessionflow.md](accessionflow.md), "Reidentification maps at production sites".

## Version notes

The package namespace is `accessionflow`. Current CLI examples use
`accessionflow label xnat` and `accessionflow deidentify`. The source-retirement
and sidecar behavior described in the [component guide](accessionflow.md#source-retirement-and-metadata-in-0190)
also applies here. Under `--unlink-source all`, unprocessed files in the input
snapshot can be removed after success; keep session folders pipeline-managed.
The facility backup remains separate from this cleanup. It is written only
for DICOM-protocol input when the callback succeeds, and its own retention
policy may remove copies later. `--unlink-source all` does not prove that
an original or encrypted mapping remains recoverable. It is written only
for DICOM-protocol input when the callback succeeds, and its own retention
policy may remove copies later. `--unlink-source all` does not prove that
an original or encrypted mapping remains recoverable. It is written only
for DICOM-protocol input when the callback succeeds, and its own retention
policy may remove copies later. `--unlink-source all` does not prove that
an original or encrypted mapping remains recoverable.

**Historical minimum for the old interface:** xnat-ingest 0.13.1 first
contained those fixes. It is not a supported downgrade target for this
0.19.0 chart and its current CLI contract. 0.12.x shipped
`dicom_deidentify` as a stub that raised `NotImplementedError`, so the engine
did nothing; 0.13.0 implemented it but could not import at all because its
`fileformats-medimage` floor was too low. Both are fixed in 0.13.1
([#138](https://github.com/Australian-Imaging-Service/xnat-ingest/pull/138),
[#139](https://github.com/Australian-Imaging-Service/xnat-ingest/pull/139)).

The charts pin the upstream image `ghcr.io/australian-imaging-service/accessionflow:0.19.0`
(`ingest.image` in `charts/edge/values.yaml`). Current source references on this
page refer to 0.19.0. The former 0.16.2.post1 fork is migration history;
its old module names and source line numbers are not the current interface.
