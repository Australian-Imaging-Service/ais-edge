# s3-uploader (AWS CLI)

**Current implementation (2026-11-10): rclone.** The historical title and
`mc.md` path remain for existing links. The running copy client is rclone
1.75.0 in the Ubuntu shell container. AWS CLI commands below are explicitly
labelled history; use the rclone commands in Operations for this chart.

The pipeline tool is accessionflow (called xnat-ingest before 0.18.0).

## Overview

The edge S3 uploader is a bash loop. It ran inside the
[AWS CLI](https://docs.aws.amazon.com/cli/) image until October 2026 and now
runs in a pinned Ubuntu (`upload.s3.shell.image`) with the rclone binary
staged in by an initContainer; see the status note below. It copies session
directories from the selected source tree into that site's staging bucket
in SeaweedFS. Under the ingest engine this is `/data/deidentified`, or the
packaged output when packaging is enabled.

**This file is still named `mc.md` for link stability.** It used to
document [`mc`](https://min.io/docs/minio/linux/reference/minio-mc.html),
the MinIO client, which was the uploader until the client migration.
`mc` is no longer a deployed client. The history in
`charts/edge/files/s3-uploader.sh` (`The S3 client is rclone`) names both older clients and identifies
rclone as the current one.

**Migration history (2026-10), current status checked 2026-11-10.** The loop now runs `rclone copy` and copies only: it
never deletes the local copy, and `RECLAIM` and `DRY_RUN` are gone from the
script. The staged-reclaimer CronJob retires each session after it has proved
each eligible file in the bucket (size plus a supported single-part MD5 or
multipart ETag computed with the configured part-size contract) and
leaves a repair request the uploader answers when a file fails. The historical shell example below retains `aws s3 sync` and `rm -rf`
for diagnosis of old releases. The current numbered steps use rclone; further
proof details are in
[accessionflow.md, "S3 mode: prove, then delete"](accessionflow.md).
The loop no longer runs in the AWS CLI image either: that image has every
GNU tool the loop uses and no `flock`, and the first live run with the
writer lock skipped every copy as lock contention for five hours (2026-10-14).
The shell image is a dated `ubuntu:noble` build now; the loop checks each
tool it needs by use at startup and stops the pod with the tool named
(`dependency_missing`), and CI runs one real copy inside the pinned image
(`tests/s3-uploader/image-tests.sh`). The image and userland notes below distinguish that historical container from
the current two-image layout.
The S3 client in the AWS CLI generation was selected to use the same
credential and endpoint conventions across edge and management. The current
edge copy loop uses rclone, while accessionflow handles management-side
retrieval. The historical steps below retain the older commands for context.
Use the current loop and its image settings when diagnosing a deployed site;
do not install either older client based on those steps.

rclone supports S3-compatible targets, but the shipped remote sets provider
`SeaweedFS`. Compatibility with AWS S3, MinIO, Garage, or Ceph RGW is not
verified (2026-11-10) for this complete copy-and-reclaim contract. Validate
ETags, conditional deletion, multipart settings, TLS, and authentication
before changing the endpoint; client API compatibility alone is insufficient.

## Role in this stack

One single-replica Deployment per edge release, only in `upload.mode: s3`.
The loop sleeps for `upload.s3.interval` seconds (default **60**) after each
pass. Transfer time adds to that interval; it is not a fixed 60-second cadence.

1. Scan the tree selected by `edge.uploadSourceDir`. The default ingest engine
   uses `/data/deidentified`; packaging selects its output tree. The deprecated
   Orthanc engine uses assigned output. `/data/staging` is not a chart path;
   `staged` is the default **S3 prefix**.
2. Skip internal directories (`__build__`, `__invalid__`, `__metadata__`) and
   sessions with entries modified within `settleMinutes` (default 5).
3. Skip dangling symlinks. A surviving link can be followed with `--copy-links`;
   do not assume all engines produce the same link layout.
4. Compute a fingerprint of sorted relative filenames, sizes, and integer
   modification times. It is **not a content checksum**. An unchanged marker
   skips the session unless a reclaimer repair request asks for another copy.
5. Probe the site's bucket with `rclone lsd`, take the shared upload-tree writer
   lock, then use `rclone copy --copy-links` into
   `sw:<bucket>/staged/<session>/`. `copy` does not delete extra remote objects;
   substituting `rclone sync` would change that safety property.
6. On a zero exit, release the lock, emit `upload_completed`, and write the
   fingerprint marker. A repair copy uses `--ignore-times`, clears its claimed
   request, and emits `recopy_done`. Failures requeue the repair request.
7. Keep session data. The **separate staged-reclaimer** proves and retires
   eligible local files. The copy loop only removes obsolete state markers,
   repair-request files, and startup probe files. Uploads are not gated by
   `dataPolicy.enabled` or `dataPolicy.dryRun`.

**Historical behaviour before the October 2026 separation:** the old AWS CLI
loop combined upload with policy-gated local deletion. Its old code example
is retained below to explain prior incidents, not as a command to deploy.



Why not write the upload logic in Python (as part of accessionflow)?
Three reasons, unchanged by the client swap:
- accessionflow's upload command pushes to **XNAT**, not to S3
- rclone supplies multipart transfers and retries, while the shell provides
  the pipeline guards. This does not promise that a killed multipart transfer
  resumes from its previous byte offset
- the client is a thin wrapper; the s3-uploader pod is the CLI plus one
  shell loop, easy to reason about

This whole Deployment renders only when `upload.mode: s3`. The
alternative, `upload.mode: direct`, replaces it with a pod running
`accessionflow store xnat` straight to XNAT and no object store in the path.
The mode is a single enum rather than two booleans because both at once
would deliver every session to XNAT twice.

## What the uploader has access to

- **PVC `<release>-pipeline` mounted at `/data`** — the shared pipeline
  volume (hostPath `/data/xnat-ingest` on the worker, 1500Gi by
  default). It reads the selected upload source, writes markers and repair
  state under `/data/LOGS/s3-uploader-state/`, and does not delete session data.
  Every pipeline stage shares this one filesystem or
  accessionflow's `hardlink_or_copy` degrades to a full copy (EXDEV).
- **Outbound HTTPS** to `https://seaweedfs.aisedge.local:443` (derived
  from `domain.internal`, or set explicitly via `upload.s3.endpoint`)
- **Secret `s3-edge-credentials`**, keys `access-key` / `secret-key` —
  a key scoped to **this edge's own bucket**. SeaweedFS matches actions
  as `<action>:<bucket>` with no prefix-level scoping, so the bucket is
  the isolation boundary between sites.
- **Secret `ca-bundle`, key `ca.crt`**, mounted at
  `/etc/ssl/ais-edge/ca.crt` with the configured CA trust bundle. Current rclone reads `RCLONE_CA_CERT`
  as a PEM file. Historical AWS CLI used `AWS_CA_BUNDLE`; historical mc used
  `/root/.mc/certs/CAs/`. These are different client interfaces.
- **ConfigMap `<release>-s3-uploader`** mounted read-only at `/scripts`,
  holding `s3-uploader.sh` at mode 0755

Both Secrets are delivered by cert-sync, not by the edge chart.

## Where it runs

- Cluster: each edge child cluster
- Namespace: `xnat-ingest`
- Workload: Deployment `<release>-s3-uploader` — `edge-s3-uploader` with
  the release name install.sh uses. One replica, `strategy: Recreate`:
  multiple copies would contend for the shared writer lock and state. The
  separate reclaimer uses that lock too; scaling the uploader is not a
  supported way to increase throughput.
- Image: a dated `ubuntu:noble` build (pinned in `upload.s3.shell.image`,
  not `latest`), with the rclone binary of `upload.s3.image`
  (`rclone/rclone:1.75.0`) staged into `/opt/rclone` by an initContainer. It
  was `amazon/aws-cli:2.31.19` until October 2026 (see the status note at the
  top). The pod runs `command` `/bin/bash /scripts/s3-uploader.sh` whatever
  the image's own entrypoint is.
- Labels `app=xnat-ingest`, `component=s3-uploader`. **The component
  label is load-bearing** — every uploader alert rule and dashboard
  panel selects on it, and renaming it disables them silently.
- A `checksum/script` pod annotation hashes `files/s3-uploader.sh`, so
  script changes alter the pod template; other pod-spec changes can also roll it
- Hostnames resolved via `hostAliases` on `onprem` topology (no
  in-cluster DNS for `aisedge.local` names inside this pod)

## Configuration

The script is a real file, `charts/edge/files/s3-uploader.sh`, loaded
into a ConfigMap with `.Files.Get` rather than inlined in the template —
it contains `${…}` and backticks that Helm would otherwise need escaping
around, and keeping it a real file lets `bash -n` lint it in CI. Key env
vars in the **historical AWS CLI generation**, not the current rendered pod:

```yaml
env:
  # --- pipeline -----------------------------------------------------
  - name: EDGE_NAME       value: <clusterLabel>            (log enrichment)
  - name: S3_BUCKET       value: ingest-<clusterLabel>     (edge.s3Bucket)
  - name: S3_PREFIX       value: staged
  - name: ASSIGNED_DIR    value: /data/assigned
  - name: STATE_DIR       value: /data/LOGS/s3-uploader-state
  - name: INTERVAL        value: "60"
  - name: SETTLE_MINUTES  value: "5"
  - name: RECLAIM         value: <dataPolicy.derived.assigned.reclaim>
  - name: DRY_RUN         value: <not dataPolicy.enabled OR dataPolicy.dryRun>
  # --- AWS CLI ------------------------------------------------------
  - name: AWS_ENDPOINT_URL      value: https://seaweedfs.aisedge.local
  - name: AWS_DEFAULT_REGION    value: us-east-1     (SeaweedFS ignores it;
                                                      the CLI demands one)
  - name: AWS_ACCESS_KEY_ID     fromSecret: s3-edge-credentials/access-key
  - name: AWS_SECRET_ACCESS_KEY fromSecret: s3-edge-credentials/secret-key
  - name: AWS_CA_BUNDLE         value: /etc/ssl/ais-edge/ca.crt
```

The bucket is **per-site**, not the single `ingest-bucket` this doc used
to name. `edge.s3Bucket` takes `upload.s3.bucket` if set, otherwise
derives `<seaweedfs.bucketPrefix>-<clusterLabel>` (e.g.
`ingest-edge-dev`) because `seaweedfs.perSiteBuckets` defaults true. The
literal `ingest-bucket` exists only when `perSiteBuckets` is false, kept
for sites still being migrated off the shared layout. There is
deliberately **no default** for the shared case: the chart fails to
render rather than guess, because a shared bucket lets every edge read
and delete every other site's staged imaging.

Two AWS-CLI-specific traps the chart encodes:

**Historical client notes (pre-rclone, October 2026).** These paragraphs
explain old incidents and variable names. Current `upload.yaml` emits
`RCLONE_CONFIG_SW_*`, `RCLONE_CA_CERT`, and optional client-certificate paths.
Do not export AWS variables inside the current uploader and expect rclone
to use that old configuration.

- **`AWS_CA_BUNDLE` set to empty does not fall back to the system trust
  store — it disables certificate verification entirely**, logging only
  "Unverified HTTPS request is being made". So the variable is emitted
  only when `caBundleSecret` has a real value, and `helm template` hard-
  fails on an `https://` endpoint with no CA configured.
- **Addressing style is deliberately unset.** A custom
  `AWS_ENDPOINT_URL` makes botocore resolve with `ForcePathStyle=True`
  by itself, which is what SeaweedFS's single-SAN certificate needs.
  `AWS_S3_ADDRESSING_STYLE` is a config-file key, not a botocore env
  var, so setting it here would be silently ignored.

**Historical AWS CLI loop (before the October 2026 migration). Do not run
this deletion example against current staging data:**
```bash
aws s3api head-bucket --bucket "$S3_BUCKET"   # pre-flight, 12 tries, 5s apart
while true; do
  for session in /data/assigned/*/; do
    # settle / dangling-link / fingerprint guards elided
    aws s3 sync "$session" "s3://${S3_BUCKET}/${S3_PREFIX}/$(basename "$session")/" \
      --only-show-errors \
      && echo "$fp" > "$STATE_DIR/$(basename "$session")" \
      && [ "$RECLAIM" = onUploaded ] && [ "$DRY_RUN" != true ] && rm -rf "$session"
  done
  sleep "$INTERVAL"
done
```

The pre-flight probe exists so a broken endpoint crashloops the pod
visibly instead of quietly doing nothing; after 12 failed attempts it
logs `endpoint_failed` and exits 1. Under `mc` this guard was load-
bearing for a sharper reason: `mc` treated an unresolved alias as a
*local path*, so a failed `alias set` made `mc mirror` copy into
`./edge/<bucket>/…`, exit 0, and the script then deleted staged data
having uploaded nothing. The AWS CLI has no such failure mode — a bad
endpoint is a hard error — but failing fast is still right.

**Historical `DRY_RUN` behaviour (pre-separation, October 2026):** it gated
reclaim, not upload. In an earlier revision it gated upload too,
which meant setting `dataPolicy: {enabled: true, dryRun: true}` to
preview reclaim decisions silently stopped the edge shipping to S3 at
all. Uploading is the pipeline's job, not a data-policy action. Note
also that `DRY_RUN` is `(not enabled) OR dryRun`: a *disabled* data
policy must never be read as permission to delete.

(The script also emits structured JSON log lines — `startup`,
`endpoint_ready` / `endpoint_retrying` / `endpoint_failed`,
`upload_started` / `upload_completed` / `upload_failed`,
`upload_skipped`, `recopy_claimed`, `recopy_done`, `marker_retired` ; that Vector ships to Loki and the
ruler turns into alerts. The three `upload_*` names are a public
interface: `XNATUploadFailingForAllSessions`, `S3UploaderRetryStorm` and
`SessionUploadStalled` all match on them. The `endpoint_*` names are
operator diagnostics, renamed from the `mc`-era `alias_*` because
"alias" was an `mc` concept; `S3UploaderRestartedRecently` deliberately
matches **both** spellings so it keeps working across the migration.)

## Operations

```bash
# Pod state
KUBECONFIG=kubeconfig-edge-dev kubectl get pods -n xnat-ingest -l component=s3-uploader

# Live JSON logs
KUBECONFIG=kubeconfig-edge-dev kubectl logs -n xnat-ingest \
  -l component=s3-uploader -f | jq

# Inside the pod (interactive debugging)
KUBECONFIG=kubeconfig-edge-dev kubectl exec -it -n xnat-ingest \
  deploy/edge-s3-uploader -- /bin/bash
/opt/rclone/rclone lsf "sw:${S3_BUCKET}/${S3_PREFIX}/" --log-level ERROR

# Test the TLS + credential path to SeaweedFS (this is the pre-flight probe).
# Wrapped in sh -c so $S3_BUCKET expands IN THE POD — unwrapped, the local
# shell expands it to empty and the probe silently tests the wrong thing.
KUBECONFIG=kubeconfig-edge-dev kubectl exec -n xnat-ingest \
  deploy/edge-s3-uploader -- sh -c '/opt/rclone/rclone lsd "sw:${S3_BUCKET}" --log-level ERROR'

# What has already been uploaded, from the uploader's own point of view
KUBECONFIG=kubeconfig-edge-dev kubectl exec -n xnat-ingest \
  deploy/edge-s3-uploader -- ls /data/LOGS/s3-uploader-state/
```

`edge-` is the Helm release name install.sh uses; a site setting
`fullnameOverride` changes that prefix.

## Benefits

- **Current copy client:** rclone in the edge uploader. Management-side
  accessionflow retrieval and the AWS CLI bucket hook have their own clients;
  the earlier claim that every component used one binary was historical.
- **Explicit remote:** endpoint, region, and credentials are passed through
  `RCLONE_CONFIG_SW_*`. The optional client certificate is separate from the
  SigV4 key and the `RCLONE_CA_CERT` server-trust file.
- **Incremental copy with proof later:** the shell skips an unchanged metadata
  fingerprint. That improves efficiency but does not prove remote durability
  or byte identity. A separate reclaimer checks the files and requests recopy
  if the proof fails. Keep both mechanisms when diagnosing stalled cleanup.
- **Multipart and parallel transfers:** four transfers, eight checkers, three
  retries, and an explicit chunk size are passed by the loop. Maximum file
  sizes and recovery after an interrupted multipart transfer depend on the
  target; a general 100GB-plus guarantee is not verified (2026-11-10).
- **A full userland:** Ubuntu provides bash, GNU tools, and util-linux `flock`.
  The rclone binary is copied from a separate pinned image. Historical
  `amazon/aws-cli:2.31.19` lacked `flock`; historical busybox tools lacked
  needed `find` options. Startup probes now exercise the required behavior,
  and `tests/s3-uploader/image-tests.sh` checks the deployed image combination.

**Current environment reference (2026-11-10):** inspect the rendered pod,
not the historical AWS block above. `ASSIGNED_DIR` is a compatibility variable
name for whichever upload source the helper selects. `WRITER_LOCK` is required;
`LOCK_WAIT` is the wait bound. `RECOPY_DIR` defaults under the state directory.
`S3_CHUNK_SIZE` is shared with the reclaimer's multipart ETag proof. The remote
uses `RCLONE_CONFIG_SW_TYPE=s3`, `RCLONE_CONFIG_SW_PROVIDER=SeaweedFS`, endpoint,
region, access-key ID, and secret-access key. Credentials come from the named
Secret rather than literal values. `RCLONE_CLIENT_CERT` and `RCLONE_CLIENT_KEY`
are emitted only when client authentication is requested. A successful `lsd`
proves a bucket listing with those credentials; it does not prove that a session
is complete or that XNAT received it.



## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| `ca-bundle` Secret missing | TLS verify fails: "x509: cert signed by unknown authority" | Pushed by cert-sync (CronJob); checked with the `rclone lsd` probe under Operations above |
| Historical empty `AWS_CA_BUNDLE` | The old AWS CLI path disabled verification in the recorded test | Current rclone uses `RCLONE_CA_CERT`; preserve explicit trust and the HTTPS guard. The historical AWS behavior is not a description of current rclone |
| Wrong S3 access key | 403 Forbidden; pod crashloops on the pre-flight probe | Each edge has its own scoped identity; rotated by editing the `<edge>-s3` Secret in `sites/<site>/secrets.enc.yaml` and re-running the install |
| Wrong bucket name for the site | The rclone bucket probe fails; `S3UploaderRestartedRecently` fires | `edge.s3Bucket` derives `ingest-<clusterLabel>` from the shared management values; never hand-write it on both sides |
| Endpoint hostname unresolvable | "no such host" | `hostAliases` injected at pod-spec time on `onprem` topology |
| Disk full on edge | Writes, logs, or markers can fail; copying cannot create free local space | `/data/xnat-ingest` is the worker's hostPath behind the pipeline PVC; size accordingly. `EdgeDiskLow` alerts before it bites. |
| Incorrect reclaim decision | Data loss | The current copy loop never deletes session data. Review the separate staged-reclaimer proof, policy, and writer-lock behavior; an upload marker or zero exit alone is not permission to delete |
| Session still being written | Partial upload | `SETTLE_MINUTES` quiet-period guard, plus a dangling-symlink check that skips rather than uploads an incomplete tree |
| Image pulled from registry | Edge needs internet to pull the shell image (`ubuntu:noble-<date>`, about 30 MB compressed; `amazon/aws-cli:2.31.19` before 2026-10) and `rclone/rclone:1.75.0` the first time | Same as accessionflow: in air-gap, pre-import via `ctr`. The Ubuntu image is smaller than the AWS CLI one was. |

## Replacements / future

- **`minio/mc`** — what we came from. Smaller image, but a second
  client with its own alias/credential conventions, and the
  alias-as-local-path failure mode described above. Not going back.
- **`rclone` migration completed in October 2026:** it is the current client,
  not a future candidate. Multiple destination copies remain a separate design
  problem because each target would need an explicit proof and retention policy
- **Native accessionflow S3 push**; accessionflow could write to S3
  directly, removing the uploader pod entirely. Currently it only reads
  from S3 (in the upload command); a `--s3-target` flag for the assign
  command is a candidate upstream PR

## Future enhancements

- DICOM SHA256 stored as an S3 object tag — enables after-the-fact
  integrity comparison against XNAT. The loop already computes a
  metadata fingerprint per session for its state file; it hashes filenames,
  sizes, and modification times, not file contents. Per-object
  checksums would be new work.
- Bandwidth control for metered links is not exposed as a dedicated chart
  setting. Historical AWS CLI used its `s3.max_bandwidth` config key. Current
  rclone tuning must be checked against the pinned binary and propagated to
  every copy invocation without changing the multipart proof contract. Do not
  add an AWS variable and assume it controls this rclone process.



- Compression of DICOMs before upload (lossless) ; transfer syntaxes and size savings vary. Rewriting DICOM bytes changes
  checksum proofs and can affect clinical fidelity; no compression stage is
  enabled by this chart, and benefits for a site are not verified (2026-11-10)
