# s3-uploader (AWS CLI)

## Overview

The edge S3 uploader is a bash loop running inside the
[AWS CLI](https://docs.aws.amazon.com/cli/) image. It pushes assigned
session directories from the edge's working volume into that site's
staging bucket in SeaweedFS.

**This file is still named `mc.md` for link stability.** It used to
document [`mc`](https://min.io/docs/minio/linux/reference/minio-mc.html),
the MinIO client, which was the uploader until the client migration.
`mc` is gone from the deployment entirely — no chart, script or installer
references it (`charts/edge/files/s3-uploader.sh:5-7` says so outright).
The S3 client is now the AWS CLI, so that edge, management and any future
cloud target speak one client with one set of credential and endpoint
conventions. Where behaviour differs from the `mc` era, this doc says so,
because live alert rules and dashboards still carry `mc`-era names.

The client remains vendor-neutral: it speaks plain S3 against SeaweedFS,
AWS S3, MinIO, Garage or Ceph RGW.

## Role in this stack

The S3 uploader on every edge worker. We run the AWS CLI inside a
single-replica Deployment (`s3-uploader`) whose loop runs every
`upload.s3.interval` seconds (default **60**, not 30):

1. Scan `/data/assigned/*/` for settled session directories — **not**
   `/data/staging/`, which does not exist anywhere in the edge chart.
   `staged` is the *S3 prefix*, not a local directory.
2. Skip xnat-ingest's internal directories (`__build__`, `__invalid__`,
   `__metadata__`) and any session touched within the last
   `settleMinutes` (default 5) — assign may still be writing into it.
3. Skip any session containing dangling symlinks. The assigned tree is
   links into `orthanc-storage/`; uploading a tree whose targets have
   gone produces a session in XNAT that is missing files, which is worse
   than not uploading at all.
4. Fingerprint the session (`find -L … | md5sum`) and compare against a
   state file. Unchanged, already-uploaded sessions emit **nothing** — a
   per-cycle "still fine" event is what produced two days of duplicate
   alert mail.
5. `aws s3 sync` the session into
   `s3://<this site's bucket>/staged/<session>/`
6. On success, write the fingerprint and — only if the data policy says
   so — `rm -rf` the local copy
7. Emit a JSON log line per event

Why not write the upload logic in Python (as part of xnat-ingest)?
Three reasons, unchanged by the client swap:
- xnat-ingest's upload command pushes to **XNAT**, not to S3
- the AWS CLI handles multipart, parallel, resumable uploads natively —
  no point reimplementing
- the client is a thin wrapper; the s3-uploader pod is the CLI plus one
  shell loop, easy to reason about

This whole Deployment renders only when `upload.mode: s3`. The
alternative, `upload.mode: direct`, replaces it with a pod running
`xnat-ingest upload` straight to XNAT and no object store in the path.
The mode is a single enum rather than two booleans because both at once
would deliver every session to XNAT twice.

## What the uploader has access to

- **PVC `<release>-pipeline` mounted at `/data`** — the shared pipeline
  volume (hostPath `/data/xnat-ingest` on the worker, 1500Gi by
  default). It reads `/data/assigned/`, writes state under
  `/data/LOGS/s3-uploader-state/`, and deletes session directories after
  a verified upload. Every pipeline stage shares this one filesystem or
  xnat-ingest's `hardlink_or_copy` degrades to a full copy (EXDEV).
- **Outbound HTTPS** to `https://seaweedfs.aisedge.local:443` (derived
  from `domain.internal`, or set explicitly via `upload.s3.endpoint`)
- **Secret `s3-edge-credentials`**, keys `access-key` / `secret-key` —
  a key scoped to **this edge's own bucket**. SeaweedFS matches actions
  as `<action>:<bucket>` with no prefix-level scoping, so the bucket is
  the isolation boundary between sites.
- **Secret `ca-bundle`, key `ca.crt`**, mounted at
  `/etc/ssl/ais-edge/ca.crt` — the public ais-edge-ca cert. The AWS CLI
  reads `AWS_CA_BUNDLE` as a **single file**, not as a directory of PEMs
  the way `mc` read `/root/.mc/certs/CAs/`.
- **ConfigMap `<release>-s3-uploader`** mounted read-only at `/scripts`,
  holding `s3-uploader.sh` at mode 0755

Both Secrets are delivered by cert-sync, not by the edge chart.

## Where it runs

- Cluster: each edge child cluster
- Namespace: `xnat-ingest`
- Workload: Deployment `<release>-s3-uploader` — `edge-s3-uploader` with
  the release name install.sh uses. One replica, `strategy: Recreate`:
  two uploaders would race on the same session directories and on the
  reclaim that follows a successful sync.
- Image: `amazon/aws-cli:2.31.19` (pinned in `upload.s3.image`, not
  `latest`). Its entrypoint is `aws`, so the pod overrides `command` to
  `/bin/bash /scripts/s3-uploader.sh`.
- Labels `app=xnat-ingest`, `component=s3-uploader`. **The component
  label is load-bearing** — every uploader alert rule and dashboard
  panel selects on it, and renaming it disables them silently.
- A `checksum/script` pod annotation hashes `files/s3-uploader.sh`, so
  the pod rolls exactly when the uploader logic changes
- Hostnames resolved via `hostAliases` on `onprem` topology (no
  in-cluster DNS for `aisedge.local` names inside this pod)

## Configuration

The script is a real file, `charts/edge/files/s3-uploader.sh`, loaded
into a ConfigMap with `.Files.Get` rather than inlined in the template —
it contains `${…}` and backticks that Helm would otherwise need escaping
around, and keeping it a real file lets `bash -n` lint it in CI. Key env
vars, as rendered by `charts/edge/templates/upload.yaml`:

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

The shell loop, in essence:
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

**`DRY_RUN` does not gate the upload, only the reclaim.** It used to,
which meant setting `dataPolicy: {enabled: true, dryRun: true}` to
preview reclaim decisions silently stopped the edge shipping to S3 at
all. Uploading is the pipeline's job, not a data-policy action. Note
also that `DRY_RUN` is `(not enabled) OR dryRun`: a *disabled* data
policy must never be read as permission to delete.

(The script also emits structured JSON log lines — `startup`,
`endpoint_ready` / `endpoint_retrying` / `endpoint_failed`,
`upload_started` / `upload_completed` / `upload_failed`,
`upload_skipped`, `reclaim_skipped` — that Vector ships to Loki and the
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
aws s3 ls "s3://${S3_BUCKET}/staged/"     # list what's been uploaded

# Test the TLS + credential path to SeaweedFS (this is the pre-flight probe).
# Wrapped in sh -c so $S3_BUCKET expands IN THE POD — unwrapped, the local
# shell expands it to empty and the probe silently tests the wrong thing.
KUBECONFIG=kubeconfig-edge-dev kubectl exec -n xnat-ingest \
  deploy/edge-s3-uploader -- sh -c 'aws s3api head-bucket --bucket "$S3_BUCKET"'

# What has already been uploaded, from the uploader's own point of view
KUBECONFIG=kubeconfig-edge-dev kubectl exec -n xnat-ingest \
  deploy/edge-s3-uploader -- ls /data/LOGS/s3-uploader-state/
```

`edge-` is the Helm release name install.sh uses; a site setting
`fullnameOverride` changes that prefix.

## Benefits

- **One client everywhere** — edge, management and any future cloud
  target use the same binary, the same `AWS_*` variables and the same
  credential shape. This was the reason for the migration off `mc`.
- **Vendor-neutral** — the same client works against AWS S3 if we ever
  swap SeaweedFS out
- **Trust model is just a PEM file** — `AWS_CA_BUNDLE` points at the
  `ca-bundle` Secret's `ca.crt`; no custom trust-store layout
- **Multipart, parallel, resumable** — handles 100GB+ DICOMs without
  custom logic, and `aws s3 sync` is natively incremental
- **A full userland** — `amazon/aws-cli` ships bash and findutils, so
  the loop can use `find -L`, `du` and `md5sum` directly. The old
  busybox-based `minio/mc` image had none of them, which forced
  workarounds the script no longer needs.

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| `ca-bundle` Secret missing | TLS verify fails: "x509: cert signed by unknown authority" | Pushed by cert-sync (CronJob); verifiable with the `head-bucket` probe under Operations above |
| `AWS_CA_BUNDLE` renders empty | **TLS verification silently OFF**, not a fallback to the system store | The variable is emitted only when `caBundleSecret` is set, and the chart refuses to render an `https` endpoint without one |
| Wrong S3 access key | 403 Forbidden; pod crashloops on the pre-flight probe | Each edge has its own scoped identity; rotated by editing the `<edge>-s3` Secret in `sites/<site>/secrets.enc.yaml` and re-running the install |
| Wrong bucket name for the site | `head-bucket` 404s; `S3UploaderRestartedRecently` fires | `edge.s3Bucket` derives `ingest-<clusterLabel>` from the shared management values; never hand-write it on both sides |
| Endpoint hostname unresolvable | "no such host" | `hostAliases` injected at pod-spec time on `onprem` topology |
| Disk full on edge | `aws s3 sync` fails to stage; nothing reclaims | `/data/xnat-ingest` is the worker's hostPath behind the pipeline PVC; size accordingly. `EdgeDiskLow` alerts before it bites. |
| Deletes the wrong session | Data loss | Reclaim is reached only after a zero-exit `sync`, only when `RECLAIM=onUploaded`, and never when `DRY_RUN=true`; re-runs are idempotent |
| Session still being written | Partial upload | `SETTLE_MINUTES` quiet-period guard, plus a dangling-symlink check that skips rather than uploads an incomplete tree |
| Image pulled from registry | Edge needs internet to pull `amazon/aws-cli:2.31.19` first time | Same as xnat-ingest: in air-gap, pre-import via `ctr`. Budget for a noticeably larger image than the old `minio/mc` one. |

## Replacements / future

- **`minio/mc`** — what we came from. Smaller image, but a second
  client with its own alias/credential conventions, and the
  alias-as-local-path failure mode described above. Not going back.
- **`rclone`** — broader provider support, similar feature set. Worth
  considering if we ever need to sync to multiple targets at once
- **Native xnat-ingest S3 push** — xnat-ingest could write to S3
  directly, removing the uploader pod entirely. Currently it only reads
  from S3 (in the upload command); a `--s3-target` flag for the assign
  command is a candidate upstream PR

## Future enhancements

- DICOM SHA256 stored as an S3 object tag — enables after-the-fact
  integrity comparison against XNAT. The loop already computes a
  content fingerprint per session for its state file; per-object
  checksums would be new work.
- Bandwidth limit at sites with metered links. Unlike the old
  `mc mirror --limit-upload`, the AWS CLI exposes this as the
  `s3.max_bandwidth` **config-file** key, so it would need a real
  `~/.aws/config` mounted into the pod — the chart currently configures
  the CLI purely through environment variables. Verify before adopting;
  the `AWS_S3_ADDRESSING_STYLE` trap above is the same class of mistake.
- Compression of DICOMs before upload (lossless) — DICOMs are usually
  already compressed but small headers add up
