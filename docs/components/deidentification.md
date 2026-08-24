# De-identification

## Overview

Two engines can strip patient identifiers before data leaves the facility. A
site picks **one**; the chart refuses to render with both enabled.

| | Orthanc Lua hook | xnat-ingest deidentify |
|---|---|---|
| values key | `orthanc.deid.enabled` | `ingest.deidentify.enabled` |
| default | **on** | off |
| runs | on each instance, as it arrives | as a stage between `assign` and `upload` |
| reversible | no, by design | yes — writes a re-identification mapping |
| policy format | JSON profile passed to Orthanc `/modify` | pydicom `deid` recipe, one per project |
| stable pseudonyms | yes — HMAC of the patient ID with a site salt | no — removes fields rather than hashing them |
| needs | `orthanc.deid.aetMap`, `profile` | a ConfigMap of recipes |

The Lua hook is the default because it cleans at the front door: identifiable
data exists inside Orthanc briefly, the original goes to the facility backup,
and every later stage only ever sees stripped data. `deidentify` runs later, so
identifiable data passes through `group` and `assign` first and sits on the
pipeline volume until the stage catches up.

Prefer `deidentify` when the *reversal* matters — a clinical follow-up needing
to find the original scan. The Lua hook cannot do that at all.

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
        medimage@dicom-series.json    # fallback for any project
    MYPROJECT/
        medimage@dicom-series.json    # this project only
```

One directory per project, named for the project ID `assign` gave the session,
plus an optional `__default__` fallback. Inside each, one file per format,
named for the format's MIME-like identifier with `/` replaced by `@`.

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

### 2. Load them as a ConfigMap

```bash
kubectl -n xnat-ingest create configmap deid-specs \
    --from-file=__default__/medimage@dicom-series.json
```

For more than one project, build the ConfigMap from the whole tree so the
per-project directories are preserved.

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

### 4. Switch engines — two settings, not one

```yaml
orthanc:
  deid:
    enabled: false               # turn the Lua engine off
ingest:
  orthancGroup:
    toProcessLabel: ""           # nothing applies the label now — see above
  deidentify:
    enabled: true
    specConfigMap: deid-specs
    reidEncryptKeySecret: reid-key   # optional
```

`upload` follows automatically: it reads `/data/deidentified` instead of
`/data/assigned` whenever the stage is on.

## What the chart refuses

| combination | why |
|---|---|
| both engines enabled | the Lua hook strips first, so the reid mapping records pseudonyms as if they were originals — it reverses to nothing while appearing to work |
| `deidentify` with no `specConfigMap` | the volume renders with an empty source; the pod sits in `CreateContainerConfigError` on the edge |
| neither engine, `policyReviewed: false` | identifiable data would reach XNAT unchanged |
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
[xnat-ingest#140](https://github.com/Australian-Imaging-Service/xnat-ingest/issues/140).

## Version notes

Requires xnat-ingest **0.13.1** or later. 0.12.x shipped
`dicom_deidentify` as a stub that raised `NotImplementedError`, so the engine
did nothing; 0.13.0 implemented it but could not import at all because its
`fileformats-medimage` floor was too low. Both are fixed in 0.13.1
([#138](https://github.com/Australian-Imaging-Service/xnat-ingest/pull/138),
[#139](https://github.com/Australian-Imaging-Service/xnat-ingest/pull/139)).
