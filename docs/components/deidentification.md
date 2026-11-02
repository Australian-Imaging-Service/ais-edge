# De-identification

Use `deid.engine: ingest` for new sites. See
[choosing-a-deid-engine.md](../choosing-a-deid-engine.md) for the source-data
checks. This page explains the default pipeline and its configuration.

## Overview

Orthanc receives network DICOM on port 4242. With the default
`deid.engine: ingest`, it stores the input unchanged. If the facility backup is
enabled, its Lua callback also copies each original to that backup. The callback
then returns before the AET lookup. It neither routes by AE title nor quarantines
an unknown AET in this mode.

xnat-ingest performs de-identification after assignment and before upload:

| Stage | Input | Output and purpose |
|---|---|---|
| group-orthanc | Original instances in Orthanc | `/data/grouped`, grouped by study |
| assign | Grouped studies | `/data/assigned`, with project, subject and session labels |
| deidentify | Assigned sessions and the site's recipes | `/data/deidentified`, with modified DICOM headers |
| reid output | Original and modified metadata | `/data/reid`, sensitive JSON or encrypted JSON |
| upload | Deidentified sessions, or packaged output when enabled | XNAT over HTTPS |

The default recipe is an example to review, not a statement that all possible
input is anonymous. Private tags, free text, pixel annotations and selected
labels need separate attention. A marker such as `PatientIdentityRemoved=YES`
records the recipe's assertion; it does not validate the output.

`deid.engine: orthanc` is deprecated. Its settings and behavior are collected in
[Deprecated Orthanc Lua engine](#deprecated-orthanc-lua-engine). The rest of
this page describes ingest. Do not select the deprecated engine to compensate
for missing source labels.

## Routing identifiers, and why the choice is constrained

`assign` resolves the XNAT project, subject and session before the recipe runs.
With an empty `ingest.assign.tagMapping`, the chart derives these ingest defaults:

```
StudyID           -> project
PatientID         -> subject
AccessionNumber   -> session
```

The example site states the same values. A site can choose other populated tags.
For a single-project site, `ingest.assign.constantProjectId` supplies the project
for every session. It does not supply the subject or session. Match that project
ID to one that already exists in XNAT. Limit the upload service account to the
projects this mapping can select.

```yaml
ingest:
  assign:
    constantProjectId: MYPROJECT   # Optional: all sessions go here.
    tagMapping:
      project: StudyID
      subject: PatientID           # Only if this contains an approved label.
      session: AccessionNumber     # Review this value as well.
```

Do not copy this example without examining the source values. The software
cannot tell whether PatientID contains a research code or a hospital MRN. The
chart rejects any tagMapping tag that starts with `ClinicalTrial` under ingest.
It cannot check whether the supported tags contain suitable values in a study.

Inspect a representative export locally. Use your selected tag names if they
differ from the defaults:

```bash
dcmdump file.dcm | grep -E '(StudyID|PatientID|AccessionNumber)'
```

**Missing values stop assignment.** An empty or absent required label can send
a session to `/data/assigned/__invalid__`. It has not passed through deidentify
at that point. Its original patient information remains on disk. No later stage
processes this holding directory automatically. The `InvalidSessionAssigned`
alert reports the assignment error when the observability stack is enabled.
Use the guarded recovery procedure in
[xnat-ingest.md](xnat-ingest.md#recovering-an-invalid-session), then correct the
source mapping so the next study does not fail in the same way.

**AE titles do not choose the project.** Under ingest, Orthanc does not consult
`orthanc.deid.aetMap` for routing. An empty or unused AET map does not stop the
receiver, and an unknown calling AET does not create an unknown-AET quarantine
entry. Use the network boundary to restrict senders. Use source tags or the
constant project to select XNAT placement.

**A recipe cannot change an assigned label.** `assign` takes values from the
source metadata. `ImagingSession.new_empty()` preserves `project_id`,
`subject_id` and `session_id` while deidentify builds a new session. The saved
directory and the uploader use those IDs. Changing PatientID in the output
DICOM therefore does not change the subject label already stored in the session.

With `subject: PatientID`, a raw MRN becomes an XNAT label even when the recipe
removes PatientID from every DICOM file. The same concern applies to a clinical
accession number used as a session label. Check both labels and file contents.
Do not treat a clean-looking DICOM header as proof that the labels are safe.

Before receiving patient studies, record a small mapping table for each source:

| Source fact | What to confirm |
|---|---|
| project tag or constant | It resolves to the intended existing XNAT project. |
| subject tag | Its value is an approved research identifier. |
| session tag | It is stable for that session and distinct for separate visits. |
| absent or empty field | The source owner can correct it; the operator knows where invalid input is retained. |
| repeated source label | It joins the intended subject/session, rather than combining unrelated acquisitions. |

Keep this record with the site's policy. A change to tagMapping can change XNAT
placement without changing any recipe line. Review it as an identity change,
not as a cosmetic site setting.

## Pseudonym strength

The shipped ingest recipe does not generate pseudonyms. It removes named tags,
including PatientID and AccessionNumber. Assignment has already selected the
XNAT labels, so neither removal nor a later hash transform changes those labels.
Use source labels that the site has already approved for the destination.

A hash is not automatically a safe research identifier. Patient IDs often come
from a small structured space. A plain digest permits an attacker to enumerate
candidate inputs. A secret salt can separate sites and make that enumeration
harder for a reader without the secret, but the transform, input space, secret
handling and collision policy all matter. Do not describe a value as one-way
only because it looks random or has a fixed number of hexadecimal characters.

The pinned xnat-ingest CLI documents two recipe sidecars:

```
MYPROJECT/medimage/dicom-series
MYPROJECT/medimage/dicom-series.transforms.yaml
MYPROJECT/medimage/dicom-series.salt
```

The transforms file defines `var:` and `func:` references used by the recipe.
The salt file supplies key material for hash transforms that use it. A recipe
without such a transform does not hash anything merely because a salt exists.
The chart has no dedicated salt-Secret setting or sidecar integration for this
path. Do not put a real salt into `ingest.deidentify.specs`: that map becomes a
ConfigMap and is normally committed as non-secret configuration. A custom
integration needs reviewed secret delivery and tests before it can be used.

`AIS_DEID_HMAC_SALT` is a different value. It is still present in the site
secrets because Orthanc loads the backup Lua script, which requires the variable
at startup. With ingest selected, its value has no effect on labels or DICOM
output. Changing it does not re-pseudonymise ingest sessions. Do not use this
variable as evidence that the ingest recipe performs salted hashing.

The older [issue #143](https://github.com/Australian-Imaging-Service/xnat-ingest/issues/143)
concerns the `ais_deid` package in the 0.13.1 image and remains open. The current
image's recipe/sidecar interface must be assessed separately. Its existence
does not justify assuming that a current recipe hashes PatientID, or that a
`DEID_SALT` environment variable is connected to the chart.

For a custom transform, retain synthetic examples for repeat input, separate
patients, separate sessions and a changed key. Verify both the metadata output
and the destination labels. Store the key under an institutional recovery
procedure. Loss or rotation can change future identifiers if the transform
actually uses that key. Mapping encryption uses its own Fernet key and solves
a different problem: it protects the recorded link to original metadata.

The deprecated engine's hash and its limitations are described only in the
[deprecated reference](#deprecated-orthanc-lua-engine). Do not use that hash's
name as an assurance about the default ingest pipeline.

## What the recipe does not do

The recipe changes only the tags it names. Read the complete example in
`sites/example-single/values.yaml` and the matching file under
`charts/edge/files/deid-specs.example/`. Review the result on representative
source data, not only on a minimal synthetic header.

**The patient identifier.** The example removes PatientID. `assign` does not
rewrite this field: it reads metadata and copies or hardlinks the input files.
Upload uses the session IDs for placement, so removing PatientID does not detach
the session from its subject. Leaving a real identifier in the header is unsafe
merely because PatientName and PatientBirthDate were removed.

Upload asks XNAT to populate metadata from the delivered headers through
`pullDataFromHeaders=true`. An identifier left in a DICOM can therefore be
indexed as well as archived. Inspect the final XNAT metadata and the stored
files. Keep the assignment-label check separate from this header check.

**The recipe is not an automatic pseudonymiser.** The shipped recipe removes
PatientID and AccessionNumber; it does not replace them with SHA-256 codes.
Do not rely on older documentation for `ais_deid` or on a library's own default
transforms. This chart supplies the site's recipes through a ConfigMap. An
example from another package is not proof of what this deployment executes.

**Private tags pass through.** Vendors use private fields for useful acquisition
and reconstruction information, but they can also contain local identifiers or
free text. The example has no blanket private-tag removal. Review the private
blocks each modality supplies and add supported removal rules if needed. Test
that required research metadata remains usable after that change.

**PatientSex and PatientAge remain.** These fields can be useful for research,
but can also narrow a small cohort. Their presence is an explicit example-policy
choice. A site's approval may require a different choice. Do not infer that
all patient-related fields disappear because the deidentify stage succeeded.

**The result markers are assertions.** The example adds
`PatientIdentityRemoved YES` and `DeidentificationMethod AIS-Edge xnat-ingest recipe`.
It uses `ADD` so missing source tags are created. Those fields identify the
applied policy. They do not prove that every identifying value was removed or
that the pixel data contains no annotation.

**Birth date and other dates need a separate decision.** The example removes
PatientBirthDate. The pydicom `deid` recipe language also supports `JITTER` for
dates, for example a fixed day offset. A fixed offset is not a different random
value per patient. Shifting birth date but leaving scan dates unchanged changes
computed ages. If dates must be retained, review the related fields together
and test the approved offset policy. Do not describe a retained year or a
fixed offset as complete anonymisation.

**Pixels and free text are not covered by a short header list.** The example is
a header recipe. It provides no assurance about burned-in names, screen captures,
structured reports, encapsulated documents or unsupported resource types. A
format that cannot use the supplied recipe must be handled deliberately. The
pinned implementation requires a matching recipe for formats whose deidentify
method needs one; formats classified as not containing PHI can pass through.
That classification still needs to be appropriate for the actual source.

**Re-identification is limited to what was recorded.** The map holds original
and modified metadata. It is sensitive data in its own right. It is not an
independent copy of every input file and is not a replacement for the original
archive. Keep the facility backup and the reid map under separate retention and
access decisions. File-drop input does not pass through the Orthanc backup
callback, so preserve those originals at their own location.

Before setting `policyReviewed`, inspect these three outputs together:

| Output | What to check |
|---|---|
| XNAT labels | The project, subject and session are approved and match the intended placement. |
| DICOM files | Named removals took effect; retained fields and pixels meet the site's policy. |
| reid map | Original metadata is protected, the chosen encryption works, and recovery keys are available. |

The chart gate records that this review took place. It does not perform the
review and does not compare the output to an ethics or institutional policy.

## The label coupling

Under ingest, the chart clears the effective `--to-process-label` argument
for group-orthanc. The stored `ingest.orthancGroup.toProcessLabel` value can
still be `xnat-ingest-ready`. Grouping uses its wait period for study selection
and tracks successful processing with `ingest.orthancGroup.processedLabel`.

The Lua callbacks have different roles. `OnStoredInstance` returns before
routing or header changes under ingest. The separate `OnStableStudy` callback
has no `DeidEnabled` guard. When the backup feature loads the script, this
callback can still apply a non-empty ready label and remove an existing
processed label when a study becomes stable again. A ready label under ingest
therefore does not establish that de-identification has run.

Keep the chart-derived group arguments. Adding a ready-label filter makes
ingest depend on that callback and its label settings, including whether the
script is loaded at all. Inspect the rendered arguments and both callback logs
when diagnosing study selection. Check recipe output separately from labels.

## Deprecated Orthanc Lua engine

This section is reference material for existing installations. Do not configure
new sites with `deid.engine: orthanc`. Use ingest and resolve source-label
requirements before upload. The receiver itself is not deprecated; only this
Lua de-identification mode is deprecated.

The Lua engine combines several jobs in one callback. It selects a project,
constructs subject/session codes, modifies headers, and applies a ready label.
These jobs are absent from the callback under ingest. The backup copy still
runs when `storage.facilityBackup.enabled` loads the script.

**Existing configuration.** The old `orthanc.deid.enabled` key is not the
engine selector. The current selector is the top-level `deid.engine`. For
reference, an existing Lua configuration has this shape:

```yaml
deid:
  engine: orthanc                 # Deprecated; existing sites only.
  policyReviewed: false
orthanc:
  deid:
    existingSaltSecret: orthanc-deid-salt
    aetMap:
      AISEDGE: {project: MYPROJECT}
    profile: {}                   # Existing reviewed profile must be supplied.
```

The empty profile above is not installable. The chart requires a non-empty
profile, AET map, named salt Secret and enabled facility backup for this engine.
It also requires `deid.policyReviewed: true`. The profile is passed to Orthanc
`/modify`; its syntax is different from the ingest recipe syntax.

**Routing uses the called AET.** The script looks up
`routing.AETMap[origin.CalledAet]`, the title that the sender addressed. It does
not look up the scanner's calling title. A missed entry writes the original
under `/facility-backup/__unmapped_aet__/<AET>/...` before deleting the instance
from Orthanc. If the quarantine write fails, the instance remains. A successful
C-STORE response is not a promise that the session will reach XNAT. For an
existing site, preserve the quarantine, correct its reviewed routing and resend.

**The profile supplies the assignment fields.** The usual contract is:

```yaml
ClinicalTrialProtocolID: ${ProjectCode}
ClinicalTrialSubjectID: ${SubjectHash}
ClinicalTrialTimePointID: ${SessionHash}
```

Assignment reads these three fields under this engine. The example profile
also replaces PatientID, StudyID and AccessionNumber, so reading those as if
they still held the original modality values gives incorrect placement. The
chart checks for missing routing replacements and known crossed mappings.

**The hash is not an HMAC.** `hmacShort` uses salted djb2 with a second mixing
accumulator and emits a truncated hexadecimal code. The usual 12-character
output has 48 bits. That is not a cryptographic one-way guarantee, and it does
not eliminate collision risk. A reader with the salt can enumerate a small
identifier space. The source name `AIS_DEID_HMAC_SALT` does not change those
properties. Do not describe these codes as irreversible or as impossible to
re-identify. The original backup also retains identifiers.

The salt lives in Secret `orthanc-deid-salt`, unless the site names another one.
The Lua engine uses it to derive subject/session codes. Replacing it changes
future codes for the same input and can split longitudinal linkage. Preserve
it with the site's recovery material. Under ingest its value is unused after
the script's startup check; rotation has no such label effect there.

**Header behavior.** The example profile retains StudyInstanceUID,
SeriesInstanceUID, SOPInstanceUID and FrameOfReferenceUID so references remain
consistent. Retained UIDs can still link records. The profile marks that choice
in DeidentificationMethod. It keeps private tags when `RemovePrivateTags` is
false and replaces only the named fields. It does not prove that burned-in
pixel annotations are absent.

The `${BirthYearOnly}0101` replacement retains a four-character year prefix and
sets month/day to January 1. It is coarsening, not jitter. For example,
`19551103` becomes `19550101`. Short or absent values use `1900`; the length
check is not full calendar validation. Do not promise that every malformed
source date becomes valid. The ingest example instead removes PatientBirthDate.
This difference matters when reviewing an existing site's migration.

**Callback order and failure handling.** For a mapped instance, the script
writes the original backup before modifying it. Orthanc `/modify` returns new
bytes; the callback removes the original from the store and POSTs the modified
bytes. The retained backup is therefore important if the later operation fails.
Do not claim that every failure preserves the original inside Orthanc itself.
OnStableStudy applies the ready label in this mode. If a processed study has
new input, the callback can clear its processed label and reopen it for grouping.
The current grouping snapshot check provides another safeguard for changed input.

**Configuration dependencies.** Historical guides called an engine change
three or five edits. That is not a procedure for new sites. For an existing Lua
installation, review the selector, its profile and AET map, assignment tags,
recipe configuration and cleanup policy together. With reclaim values set to
`auto`, the chart derives the engine-specific conditions. Do not leave ingest
recipes configured under an engine that would ignore them. Keep the original
archive while validating a migration on synthetic data.

**Labels are not access control.** A ready label is a producer/consumer signal,
not proof that every instance is safe. It depends on the hook and its profile.
The ingest pipeline omits this filter and performs de-identification later.
Do not copy this mode's label requirement into an ingest deployment.

## Configuration: xnat-ingest deidentify

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

The installed `load_recipe_files` function walks
`<spec-dir>/<category>/<format>` and skips anything at the top level that is not
a directory, so a flat file named `medimage@dicom-series.json` is never read.
If no project or fallback recipes are found, the stage raises an error. The
message starts with "No deidentification recipe files found for project".
The input remains in `/data/assigned` for investigation.

**The file is a pydicom `deid` recipe, not JSON. It needs no extension:**

```
FORMAT dicom

%header

REMOVE PatientName
REMOVE PatientBirthDate
REMOVE AccessionNumber
```

**Only named tags change.** Review the complete recipe as the site policy.
For a resource marked as containing patient information, the default strict
matching check fails when a required format recipe is missing. Resources
classified as not containing patient information are copied. This classification
is not a scan of every value or pixel. Validate each accepted resource type.
Do not treat a successful run as proof that all identifying content was removed.

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
looks de-identified to a spot check. Measured: an instance de-identified under the
old advice reached XNAT with `PatientID` verbatim and `PatientIdentityRemoved`
absent. The shipped recipe now ends `REMOVE PatientID`.

### 2. Put them in the site file

The recipes go in `sites/<site>/values.yaml`. The chart builds the ConfigMap
and mounts each recipe at its project/format path. A
fresh install needs no `kubectl` and nothing has to exist beforehand:

```yaml
# Keep the default engine. The chart rejects recipes under another engine.
# These short fragments illustrate paths, not a complete site policy.
# Start from the full example and review all source fields before upload.
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
        REMOVE PatientID
      "MYPROJECT/medimage/dicom-series": |
        FORMAT dicom

        %header

        REMOVE PatientName
        REMOVE PatientID
```

The key is the path under `SPEC_DIR`; the value is the recipe. Changing a
policy later is a `helm upgrade` with the edited site file — still no
`kubectl`.

A ConfigMap key cannot contain `/` or `@`, and a ConfigMap mounts flat, so the
chart sanitises each path into a legal key and maps it back with `items[].path`
on the volume. That is internal: write the real paths and ignore the
restriction.

#### Managing the ConfigMap yourself

For recipes maintained outside the site file, supply the ConfigMap and map
its keys to mounted paths. It must fit the Kubernetes ConfigMap size limit.
Remove the inline `specs` entries from the site file when selecting this route.
An empty map overlay does not remove keys supplied by another values file.

```bash
kubectl -n xnat-ingest create configmap deid-specs \
    --from-file=default-dicom-series=__default__/medimage/dicom-series
```

```yaml
ingest:
  deidentify:
    specs: null  # Clear any inline recipe map from a lower values layer.
    specConfigMap: deid-specs
    specFiles:
      default-dicom-series: "__default__/medimage/dicom-series"
```

Create the namespace and external ConfigMap before the workload starts. This
can be done before a fresh install or before an upgrade. The chart mounts the
named object; it does not create it. Verify the mounted paths and recipe content
after the workload is running. Do not store encryption keys in this ConfigMap.

### 3. Optionally, an encryption key for the reversal map

The chart always passes `--reid-dir /data/reid`. A mapping back to removed
identities is written there for each session. With no encryption key reference,
it is plain JSON on the pipeline volume. The standalone CLI can omit the map,
but this chart has no option to omit its `--reid-dir` argument.

Set an encryption key reference for production ingest. This protects new maps;
it does not migrate old plaintext maps. Review existing files separately and
preserve the recovery material needed for any previously encrypted output.

```bash
python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
kubectl -n xnat-ingest create secret generic reid-key \
    --from-literal=XINGEST_REID_ENCRYPT_KEY='<the key>'
```

Then set `ingest.deidentify.reidEncryptKeySecret: reid-key` in the site file.
The chart reads `XINGEST_REID_ENCRYPT_KEY` from this Secret in the release
namespace. The Secret existing alone does not enable encryption.

The mappings are written as `<session>.json.enc` and are unreadable
without it. **Keep the key somewhere other than the volume the mappings are
on** — together they are just a slower way of storing the identifiers.

### 4. Confirm your studies carry the routing tags

Inspect the tags selected by `ingest.assign.tagMapping` before receiving patient
data. For the derived defaults, use:

```bash
dcmdump file.dcm | grep -E '(StudyID|PatientID|AccessionNumber)'
```

Each required value must be present, non-empty and appropriate for the XNAT
label it becomes. `constantProjectId` can replace the project source at a
single-project site. It does not replace subject/session values. The chart
rejects ClinicalTrial-prefixed tag mappings in ingest mode. Use supported tags
that the source actually populates.

Check the assigned session labels and the uploaded labels on a synthetic study.
The recipe runs too late to repair those values. If assignment fails, inspect
`assigned/__invalid__` and follow the documented guarded recovery steps. Do not
change the engine to work around a missing field.

### 5. Confirm the ingest engine

```yaml
deid:
  engine: ingest
  policyReviewed: true   # Set only after the site review described above.
```

Ingest is already the default. Check it explicitly when reviewing an older site
file. The chart derives the dependent behavior from this value:

| Derived setting | Behavior under ingest |
|---|---|
| Lua `DeidEnabled` | `false`; the backup callback returns before AET routing and modification |
| effective `toProcessLabel` | Cleared; grouping does not wait for the Lua ready label |
| deidentify Deployment | Rendered with the site's recipe ConfigMap |
| upload source | `/data/deidentified`, or `/data/packaged` when packaging is on |
| assigned reclaim `auto` | `onDeidentified` |
| deidentified reclaim `auto` | `onUploaded`, or `onPackaged` when packaging is on |

The old `ingest.deidentify.enabled` setting is rejected. Use the engine selector
and inspect the rendered workload arguments. Recipes supplied while another
engine is selected are also rejected, so a reviewed recipe cannot be silently
ignored at render time. An empty recipe source under ingest fails validation.

These checks prevent configuration mismatches. They do not prove correct source
labels, suitable private-tag handling or successful XNAT delivery. Run the site
verification and a synthetic end-to-end transfer after deployment. Compare the
recipe output and destination metadata to the approved expectations.

## Where the stage sits, tier-1 versus tier-2

On this branch (tier-1) the node uploads straight to XNAT, so `deidentify` sits between
`assign` and that upload. On tier-2 the edge stages to S3 and a management-side
uploader moves it on to XNAT, so the chain is longer:

```
tier-1   orthanc -> group -> assign -> deidentify -> upload ------------> XNAT
tier-2   orthanc -> group -> assign -> deidentify -> rclone -> S3 -> mgmt xnat-upload -> XNAT
```

The placement is the same either way — immediately before whatever carries data
off the node — and the chart handles it with one helper, so no extra
configuration is needed. `upload` and the rclone S3 uploader both read
`edge.uploadSourceDir`, which becomes `/data/deidentified` when the stage is on.

This ordering matters on tier-2: the default data path runs the recipe before
S3 upload. The recipe and source labels still determine what leaves the site.
A retained identifier in a private field, pixel annotation or assigned label
can leave with that output. Validate those contents before enabling transfer.
The stage changes the data sent to S3, not the position of S3 in the chain.

Two other differences, if you also run the tier-2 (cloud) deployment from the
`main` branch:

* the alert rules live in the **management** chart there
  (`charts/mgmt/files/loki-ruler-rules.yaml`), because tier-2 runs Loki centrally
  and edges ship to it. On this branch they are in
  `charts/edge/files/loki-ruler-rules.yaml`, since a single node runs everything.
* `xnat-ingest` is pinned in **both** charts there — `charts/edge` for the
  pipeline stages and `charts/mgmt` for the S3 -> XNAT uploader, and both must
  move together because the CLI contract is shared. On this branch there is one
  chart and one pin.

## What the chart refuses

| Combination | Why it is refused |
|---|---|
| `deid.policyReviewed: false` | A person must acknowledge the site's policy, including an explicit no-deid configuration. |
| obsolete `ingest.deidentify.enabled` | The single `deid.engine` selector now derives the stage. |
| ingest with no recipe source | The stage needs non-empty `specs`, or an external `specConfigMap` with `specFiles`. |
| both inline specs and external ConfigMap settings | The chart requires one unambiguous recipe source. |
| ClinicalTrial-prefixed tagMapping under ingest | The chart does not permit that mapping with this engine. |
| recipes with a different engine | The reviewed recipes would not run. |
| empty required Secret names | A non-optional reference would leave a pod unable to start. |
| a reclaim condition for a tree whose consumer cannot satisfy it | The data policy would appear active while retaining data indefinitely. |

The chart cannot examine future DICOM values. It does not detect missing or
sensitive contents in an otherwise supported tag. Those failures need source
data checks. `deid.engine: none` is an explicit exception for already-cleaned
input or a separately approved environment; it still requires policy review.
New sites should retain ingest and validate its policy.

## Operations

```bash
# Which engine is actually running
kubectl -n xnat-ingest get deploy | grep -E 'orthanc|deidentify'

# Receiver and backup errors
kubectl -n xnat-ingest logs deploy/RELEASE-orthanc --tail=50

# deidentify stage
kubectl -n xnat-ingest logs deploy/RELEASE-deidentify --tail=50

# What a session's reversal map recorded (unencrypted only)
kubectl -n xnat-ingest exec deploy/RELEASE-deidentify -- \
    cat /data/reid/<project>.<subject>.<session>.json
```

A non-empty assigned session with no output needs investigation. The pinned
image reports incomplete or failed de-identification above the resource level.
An empty polling cycle is normal when there is no work. Do not infer success
from a running pod or a quiet log. Compare assigned input, deidentified output,
resource manifests and upload results before changing paths or cleanup rules.

## Current limitations

The old output-layout blocker in
[#144](https://github.com/Australian-Imaging-Service/xnat-ingest/issues/144)
was reported for 0.13.1 and is closed. The pinned image publishes sessions at
`/data/deidentified/<project>.<subject>.<session>/`, with the scan and resource
directories below that session. Upload reads that root directly. There is no
need to flatten an extra session directory by hand, and doing so can damage
metadata and manifest relationships.

Current constraints are policy and integration constraints. The shipped recipe
does not hash identifiers, alter assigned labels or guarantee that pixels and
private fields are safe. The chart always requests a re-identification map.
Without `reidEncryptKeySecret`, that map is plaintext. It also has no dedicated
secret-backed wiring for the CLI's transform salt sidecar.

Verify deployment-specific outcomes after an install. A source inspection can
establish the output-path contract, but does not prove that a particular XNAT
endpoint is reachable or that its saved data matches the source. Keep original
input until the intended destination has been checked.

## Version notes

This branch pins `ghcr.io/akshitbeniwal/xnat-ingest:0.16.2.post1`.
The locally inspected image has image ID
`sha256:f5df17d3b05774fbad5c319adfe726a4e3b9333512fa495bb9fbfa6d68e5058c`
and reports package version `0.16.3.dev49+ais.20261021.r13.g3182cc6`.
The registry tag and installed package version are different identifiers.
Record the deployed digest when checking a site; do not infer a live version
from this documentation alone.

Historical releases explain some obsolete instructions. Version 0.12.x had a
stub DICOM de-identification implementation. Version 0.13.0 had a dependency
import problem; fixes followed in 0.13.1. That older version also had the output
layout problem in #144. These are not reasons to keep a new site on the Lua
engine. The current chart passes `--reid-dir` as an option, not a fourth
positional argument, and supplies the recipe path separately.

Check image changes against the chart's CLI arguments, source-label behavior,
recipe output, mapping encryption and upload discovery before rollout. An
upstream release number alone does not establish that a fork-specific fix is
present. Keep evidence for the exact image and configuration used at the site.
