# De-identification

> **Deciding which engine to use?** See
> [choosing-a-deid-engine.md](../choosing-a-deid-engine.md). This page covers
> configuration once you have chosen.

## Overview

**Orthanc is always present.** It is the only DICOM network receiver in this
stack, so it receives every study regardless of which engine de-identifies. What
this page configures is *where de-identification happens*.

Two engines exist, built for pipelines that differ in where the routing
identifiers — the XNAT project, subject and session — come from:

| | Orthanc Lua hook | xnat-ingest deidentify |
|---|---|---|
| values key | `orthanc.deid.enabled` | `ingest.deidentify.enabled` |
| chart default | on | off |
| runs | inside Orthanc, per instance on arrival | own stage, between `assign` and `upload` |
| source of routing identifiers | derives them from the calling AE title | expects them in the incoming data |
| needs an AE-title map | yes | no |
| strips PHI | yes, JSON profile via Orthanc `/modify` | yes, pydicom `deid` recipe per project |
| pseudonymises | yes, salted djb2 (not an HMAC, see below) | yes, SHA-256 ([salting disabled upstream](https://github.com/Australian-Imaging-Service/xnat-ingest/issues/143)) |
| re-identification possible | no | yes, via the reid mapping |
| identifiable data on the pipeline volume | no | yes, until the stage runs |
| applies the ready label | yes | no |

> **Deciding between them?** See
> [choosing-a-deid-engine.md](../choosing-a-deid-engine.md), which sets out the
> two architectures and what each requires. This page covers configuration once
> the choice is made.

## Routing identifiers, and why the choice is constrained

`assign` files a study using three DICOM tags:

```
ClinicalTrialProtocolID    -> project
ClinicalTrialSubjectID     -> subject
ClinicalTrialTimePointID   -> session
```

The Lua hook populates them: it maps the calling AE title to a project and
hashes the patient identifier into subject and session codes (salted djb2, not
an HMAC — see *Pseudonym strength* below). `deidentify` does
not — it works on identifiers already present, which is why it needs no AE-title
map.

So if studies arrive carrying those tags, either engine can be used. If they
arrive identified only by an AE title, the Lua hook is what supplies the
routing, and with it disabled `assign` places every study in
`/data/assigned/__invalid__`:

```
/data/assigned/__invalid__/INVALID_MISSING_CLINICALTRIALPROTOCOLID_...
                           INVALID_MISSING_CLINICALTRIALSUBJECTID_...
                           INVALID_MISSING_CLINICALTRIALTIMEPOINTID_...
```

Checking which case applies, on a study a modality actually sends:

```bash
dcmdump file.dcm | grep -E 'ClinicalTrial(ProtocolID|SubjectID|TimePointID)'
```

> **CAUTION — the quarantined studies still hold PHI.**
>
> The hook that would have supplied the routing tags is the same hook that
> strips the patient identifiers. Turning it off removes both, so studies that
> land in `/data/assigned/__invalid__` for want of routing are sitting there
> **identified**. Nothing downstream reads that directory, no stage retries it,
> and the deidentify stage reports `Found 0 sessions` on every cycle while it
> fills up. Measured on a test edge: 531 instances, still carrying the patient
> name, parked indefinitely with nothing failing loudly.
>
> The chart refuses the DEFAULT form of this at render time: `deidentify`
> enabled while `tagMapping` still names the `ClinicalTrial*` tags. It cannot
> detect the other form, where `tagMapping` names real tags that this site's
> modalities happen not to populate — that configuration looks correct and
> reaches the same end state. Confirm the tags on a real study rather than
> relying on the guard.

> **CAUTION — choosing `deidentify` gives up AE-title routing.**
>
> Mapping a calling AE title to a project is an Orthanc Lua feature
> (`orthanc.deid.aetMap`). The `deidentify` stage has no equivalent and never
> sees the AE title, so with the Lua hook off **there is no way to derive the
> project from which machine sent the study**.
>
> A site running `deidentify` must therefore have its modalities populate the
> project, subject and session in tags they actually send, and point
> `ingest.assign.tagMapping` at those tags. If every modality sends the same
> value, every study lands in the same project.
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
> These three keys default to the `ClinicalTrial*` tags because the default
> engine is the Lua hook, which writes them. They are values, not constants:
> re-point them when you change engine.

> **CAUTION — whatever tags you name become the XNAT labels, verbatim and
> un-de-identified.**
>
> `assign` reads the three tags and lifts their values into the session object.
> Everything after that uses the values, not the tags. `deidentify` builds its
> output with `ImagingSession.new_empty()`, which copies `project_id`,
> `subject_id` and `session_id` across unchanged; `save()` names the directory
> `<project>.<subject>.<session>`; and `upload` creates the XNAT subject and
> experiment from those same ids.
>
> **A recipe cannot change them.** The recipe rewrites DICOM tags, but `assign`
> has already taken the values out before `deidentify` runs. So the tag you
> name in `subject` becomes the XNAT subject label exactly as the modality sent
> it.
>
> Under the Lua hook this is safer, because the hook has already replaced those
> tags with pseudonyms before `assign` sees them. Note what that pseudonym is
> and is not: a salted djb2 truncated to 48 bits, not an HMAC despite the
> function's name (`deidentify-and-forward.lua:24` says so itself). It does not
> collide at any realistic cohort size, but it is not one-way — anyone holding
> the salt can enumerate a medical-record-number space in minutes. The salt
> stays on the edge and never reaches XNAT, so it is not reversible by an
> XNAT-side reader, and that is the property being relied on. Under `deidentify`
> there is
> no such step, so pointing `subject` at `PatientID` puts the raw medical record
> number into XNAT's metadata **while the pixel data and headers are correctly
> stripped** — the data looks clean and the identifier is in the label.
>
> Choose tags that are ALREADY pseudonymous at the modality, or arrange for the
> modality to send one. Verify on a real study before enabling the engine:
>
> ```bash
> # whatever these print is what will appear in XNAT
> dcmdump file.dcm | grep -E '<the three tags you configured>'
> ```

## Pseudonym strength

The Lua hook's subject and session codes come from a function called
`hmacShort`. **It is not an HMAC**, and the code says so on the line above it:

```lua
-- Salted djb2. NOT cryptographic; jodogne/orthanc-plugins doesn't expose
-- ComputeMd5/Sha1 in Lua. For HMAC-grade switch to jodogne/orthanc-python.
local function hmacShort(value, length)
```

The salt's environment variable is `AIS_DEID_HMAC_SALT`, which reinforces the
same wrong impression. What it actually computes is a salted djb2 with a second
mixing accumulator, formatted to 16 hex characters and truncated to 12, so 48
bits of output.

What that is and is not good for:

* **Collisions are not a concern.** 48 bits puts the birthday bound near 2^24,
  about 16.7 million subjects. No realistic cohort approaches it.
* **It is not one-way.** djb2 is a cheap rolling hash, and medical record
  numbers occupy a small space — six to ten digits. Anyone holding the salt can
  enumerate that space and invert the mapping in minutes.

So the guarantee is not "these pseudonyms cannot be reversed". It is **"the salt
never leaves the edge"**. It lives in a Kubernetes Secret (`orthanc-deid-salt`)
on the edge cluster and is never sent to XNAT, so an XNAT-side reader cannot
reverse the pseudonyms without also compromising the edge. Anyone with read
access to the edge cluster, or the SOPS key for the site secrets, can.

That may be entirely acceptable for a given site's threat model. It should be a
decision someone made, not one inherited from a function name. If it is not
acceptable, the code names its own remedy: switch the hook to
`jodogne/orthanc-python`, which exposes real digest functions.

## The label coupling

The Lua hook does two jobs, not one. It de-identifies, **and** it applies the
`xnat-ingest-ready` label that `group-orthanc` filters on. Turning it off
removes both, so `ingest.orthancGroup.toProcessLabel` has to be cleared at the
same time or `group-orthanc` filters out every study and the pipeline stalls
with no error. The chart catches this and says so.

## Configuration — Orthanc Lua hook (default)

```yaml
orthanc:
  deid:
    enabled: true
    policyReviewed: false        # no safe default; a human must confirm
    existingSaltSecret: orthanc-deid-salt
    aetMap:
      SIEMENS_3T_AET: {project: MYSITE_RESEARCH}
    profile: {}                  # from files/deidentification-profile.example.json
```

`existingSaltSecret` is what makes pseudonyms stable: the same patient always
hashes to the same subject, so their second visit lands on the same XNAT
subject as their first. Rotating it re-links every pseudonym and existing XNAT
subjects stop matching new arrivals.

## Configuration — xnat-ingest deidentify

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

That structure is load-bearing. `load_specs` walks
`<spec-dir>/<category>/<format>` and skips anything at the top level that is not
a directory, so a flat file named `medimage@dicom-series.json` is never read.
The stage then finds no recipes at all and fails every session with "No
deidentification specs found for project ... and no default specs provided",
leaving the data sitting in `/data/assigned`.

**Despite the `.json` extension the file is a pydicom `deid` recipe, not JSON:**

```
FORMAT dicom

%header

REMOVE PatientName
REMOVE PatientBirthDate
REMOVE AccessionNumber
```

**Only the tags a recipe names are removed.** Anything not listed passes
through untouched, so the recipe *is* the policy — review it as one. A session
whose format has no applicable recipe is skipped and logged rather than
uploaded with identifiers still attached.

Do not remove `PatientID`: `assign` has already rewritten it to the routed
project/subject, and `upload` needs it to place the session in XNAT.

### 2. Put them in the site file

The recipes go in `sites/<site>/values.yaml`, the same way
`orthanc.deid.profile` does. The chart builds the ConfigMap and mounts it, so a
fresh install needs no `kubectl` and nothing has to exist beforehand:

```yaml
ingest:
  deidentify:
    enabled: true
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
files too large to sit in a site file — supply the ConfigMap instead and do the
mapping by hand. `specs` must then be empty:

```bash
kubectl -n xnat-ingest create configmap deid-specs \
    --from-file=default-dicom-series=__default__/medimage/dicom-series
```

```yaml
ingest:
  deidentify:
    specConfigMap: deid-specs
    specFiles:
      default-dicom-series: "__default__/medimage/dicom-series"
```

Note this route needs the namespace to exist already, so it is a post-install
step rather than a fresh-install one.

### 3. Optionally, an encryption key for the reversal map

The mapping back to the removed identities is written to `/data/reid`, one
JSON file per session. Unencrypted, it sits on the same volume as the data it
de-identifies.

```bash
python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
kubectl -n xnat-ingest create secret generic reid-key \
    --from-literal=XINGEST_REID_ENCRYPT_KEY='<the key>'
```

Set, the mappings are written as `<session>.json.enc` and are unreadable
without it. **Keep the key somewhere other than the volume the mappings are
on** — together they are just a slower way of storing the identifiers.

### 4. Confirm your studies carry the routing tags

**Before switching, check this** — it is the difference between a working
pipeline and every study landing in `__invalid__`:

```bash
# on a study your modality actually sends
dcmdump file.dcm | grep -E 'ClinicalTrial(ProtocolID|SubjectID|TimePointID)'
```

All three must be present and populated. If they are not, the Lua hook has to
stay on, because nothing else writes them. See "The Lua hook does more than
de-identify" above.

### 5. Switch engines — two settings, not one

```yaml
orthanc:
  deid:
    enabled: false               # turn the Lua engine off
ingest:
  orthancGroup:
    toProcessLabel: ""           # nothing applies the label now — see above
  deidentify:
    enabled: true
    specs: {...}                 # from step 2
    reidEncryptKeySecret: reid-key   # optional
```

`upload` follows automatically: it reads `/data/deidentified` instead of
`/data/assigned` whenever the stage is on.

## Where the stage sits, tier-1 versus tier-2

On this branch (tier-1) the node uploads straight to XNAT, so `deidentify` sits between
`assign` and that upload. On tier-2 the edge stages to S3 and a management-side
uploader moves it on to XNAT, so the chain is longer:

```
tier-1   orthanc -> group -> assign -> [deidentify] -> upload ------------> XNAT
tier-2   orthanc -> group -> assign -> [deidentify] -> rclone -> S3 -> mgmt xnat-upload -> XNAT
```

The placement is the same either way — immediately before whatever carries data
off the node — and the chart handles it with one helper, so no extra
configuration is needed. `upload` and the rclone S3 uploader both read
`edge.uploadSourceDir`, which becomes `/data/deidentified` when the stage is on.

This ordering matters on tier-2 specifically: **de-identification happens before
anything reaches S3**, so identifiable data never leaves the facility, even into
your own object store. Turning the stage on does not change where S3 sits in the
chain; it changes what has already been stripped by the time data gets there.

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

| combination | why |
|---|---|
| both engines enabled | the Lua hook strips first, so the reid mapping records pseudonyms as if they were originals — it reverses to nothing while appearing to work |
| `deidentify` with no `specConfigMap` | the volume renders with an empty source; the pod sits in `CreateContainerConfigError` on the edge |
| neither engine, `policyReviewed: false` | identifiable data would reach XNAT unchanged |
| *(not caught by the chart)* | `deidentify` alone when studies lack the ClinicalTrial routing tags — the chart cannot see inside your DICOM, so this fails at runtime with every study in `__invalid__` |
| `toProcessLabel` set with the Lua hook off | nothing applies the label; `group-orthanc` filters out every study |

Neither engine *is* allowed when acknowledged with `policyReviewed: true` — for
a site whose modalities de-identify upstream, or one staging into a trusted
enclave.

## Operations

```bash
# Which engine is actually running
kubectl -n xnat-ingest get deploy | grep -E 'orthanc|deidentify'

# Lua hook events
kubectl -n xnat-ingest logs deploy/RELEASE-orthanc | grep instance_deidentified

# deidentify stage
kubectl -n xnat-ingest logs deploy/RELEASE-deidentify --tail=50

# What a session's reversal map recorded (unencrypted only)
kubectl -n xnat-ingest exec deploy/RELEASE-deidentify -- \
    cat /data/reid/<project>.<subject>.<session>.json
```

A session that produced no output files is worth checking by hand:
`deidentify` reports success even when it processes nothing, so an empty
`/data/deidentified` alongside a populated `/data/assigned` means the layout or
the recipes are not matching, not that there was nothing to do. See
[xnat-ingest#144](https://github.com/Australian-Imaging-Service/xnat-ingest/issues/144).

## Current limitation

`deidentify` cannot yet be chained to `upload`. The stage itself works — images
are de-identified and the reversal mapping is written — but its output is one
directory level deeper than `assign` produces:

```
/data/deidentified/<session>/<session>/<scan>/DICOM/*.dcm   <- what it writes
/data/assigned/<session>/<scan>/DICOM/*.dcm                 <- what upload expects
```

so `upload` reports `Found 0 sessions` and the data stops there. This is
upstream and no chart setting works around it — the chart already points
`upload` at the right directory. Tracked as
[xnat-ingest#144](https://github.com/Australian-Imaging-Service/xnat-ingest/issues/144).

Until that lands, `ingest.deidentify.enabled: true` is usable for evaluating
the engine and its recipes, but the Orthanc Lua hook remains the only engine
that carries data all the way to XNAT.

## Version notes

Requires xnat-ingest **0.13.1** or later. 0.12.x shipped
`dicom_deidentify` as a stub that raised `NotImplementedError`, so the engine
did nothing; 0.13.0 implemented it but could not import at all because its
`fileformats-medimage` floor was too low. Both are fixed in 0.13.1
([#138](https://github.com/Australian-Imaging-Service/xnat-ingest/pull/138),
[#139](https://github.com/Australian-Imaging-Service/xnat-ingest/pull/139)).
