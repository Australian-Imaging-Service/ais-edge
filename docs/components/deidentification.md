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
| pseudonymises | yes, HMAC + per-site salt | yes, SHA-256 ([salting disabled upstream](https://github.com/Australian-Imaging-Service/xnat-ingest/issues/143)) |
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
HMACs the patient identifier into subject and session codes. `deidentify` does
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

## Where the stage sits on a tier-2 (cloud) deployment

On tier-1 the edge uploads straight to XNAT, so `deidentify` sits between
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

Two other tier-2 differences:

* the alert rules live in the **management** chart
  (`charts/mgmt/files/loki-ruler-rules.yaml`), because tier-2 runs Loki centrally
  and edges ship to it. `DeidentifyStageError` is there, next to
  `OrthancDeidLuaError`.
* `xnat-ingest` is pinned in **both** charts — `charts/edge` for the pipeline
  stages and `charts/mgmt` for the S3 -> XNAT uploader. Both must move together;
  the CLI contract is shared.

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
