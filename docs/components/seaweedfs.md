# SeaweedFS

## Overview

[SeaweedFS](https://seaweedfs.com/) is a distributed file/object store with
an S3-compatible API. We use it as the central staging layer between edge
sites and XNAT. Apache 2.0 licensed.

## Role in this stack

The DICOM staging buffer. Edge sites copy session directories with
`rclone copy` (`charts/edge/files/s3-uploader.sh` — the `minio/mc` and AWS
CLI implementations are gone) into the `staged/` prefix of **their own**
bucket, and keep their own copy until the edge's staged-reclaimer has proved
the bucket's copy against it ([xnat-ingest.md](xnat-ingest.md), "S3 mode:
prove, then delete"). With `seaweedfs.perSiteBuckets: true`, the default, that bucket
is `ingest-<edge>`; the single shared `ingest-bucket` survives only for
sites not yet migrated off it. The management-side `mgmt-upload-<edge>`
pod polls that one bucket and forwards new sessions to XNAT. SeaweedFS
also stores the observability stack's logs (Loki writes chunked log data
to a separate `logs-bucket`).

**Why a bucket per site.** SeaweedFS matches an identity's actions as
`<action>:<bucket>`, so `Write:<bucket>/*` is bucket-wide — there is no
prefix-level scoping. Measured on the live cluster: the `edge-dev` key
lists its own bucket fine and gets `AccessDenied` on `logs-bucket`, so
the bucket is the enforcement boundary, and only the bucket. While every
site shared one bucket, any edge key could read, list and delete every
other site's staged imaging. One bucket per site makes the enforcement
boundary and the trust boundary the same thing, and it is what lets the
uploader and reclaimer be per-site instead of a fleet-wide single point
of failure.

## What SeaweedFS has access to

- **hostPath `/data/seaweedfs`** on the management node (Haystack
  volumes + filer leveldb), surfaced as a PV/PVC pair by the chart
- **In-cluster network** (its own Service)
- **No outbound network** — fully passive; only accepts requests
- **S3 IAM identities**, four kinds, each scoped to what it actually
  needs:
  - `admin` — `Admin`/`Read`/`Write`/`List`/`Tagging` over the store.
    Used by the bucket-creation hook, **not** by the upload pod
  - `<edge-name>` — one per `edges[]` entry:
    `Read`/`List`/`Write`/`Tagging` on **that site's own bucket** only
  - `upload-<edge-name>` — one per edge, for the S3→XNAT uploader, same
    scope. `Write` is what lets it remove a staged session once XNAT has
    confirmed it: SeaweedFS folds object DELETE into that action
  - `loki-writer` — `Read`/`List`/`Write`/`Tagging` on `logs-bucket`
    only. Deliberately cannot see any ingest bucket; the log store has
    no business holding a key that reads imaging data

### Optional second factor: mTLS on the upload path

The SigV4 key pair above is a **bearer** secret — anything holding a copy
can use it from anywhere the endpoint is reachable. Set
`seaweedfs.ingress.clientCerts.*` and each edge additionally presents a
cert-manager client certificate (`CN=<edge name>`, signed by the fleet CA,
rotated every 90 days by cert-sync) which the Ingress verifies before the
request ever reaches SeaweedFS. The two are independent and neither
replaces the other: the key pair is still what scopes a site to **its own
bucket** — the certificate CN pin admits every site on the one upload
hostname, exactly as it does on the Loki push endpoint, so it bounds
*which* certificates are accepted at the door rather than which bucket a
site can touch.

**It ships off, and it is turned on in four steps, not one.**

| Step | Where | What |
|---|---|---|
| 1 | mgmt | `seaweedfs.ingress.clientCerts.issue: true` **and** the `<edge>-s3-client` entry in `certSync.secrets` — the chart refuses either half alone |
| 2 | edge | `kubectl -n <edge ns> get secret s3-client-tls` answers, on **every** site |
| 3 | edge | `upload.s3.requireClientCert: true` in each edge site file |
| 4 | mgmt | `seaweedfs.ingress.clientCerts.require: true` |

Doing step 4 before step 2 has answered breaks every upload with an error
that names nothing. Measured against nginx `ssl_verify_client on` and rclone
1.75.0:

| Client presents | nginx answers | What rclone logs |
|---|---|---|
| nothing | `400 No required SSL certificate was sent` (HTML body) | `error while deserializing xml error response : XML syntax error … element <hr>` |
| a cert from the wrong CA | the same `400` | the same XML parse failure |
| a valid cert, CN outside `auth-tls-match-cn` | `403` (HTML body) | the same XML parse failure |
| a cert whose **file** is missing | — | `CRITICAL: Failed to load --client-cert/--client-key pair` (the one loud case) |

Note that the handshake **succeeds** in the first three: under TLS 1.3 the
client certificate is sent after the server's `Finished`, so nginx cannot
refuse the connection and refuses the first request instead. The check is
real; the error is an HTTP one, and it mentions neither certificates nor
authentication. All of it lands on the uploader's pre-flight probe as
`endpoint_failed`, which reads as a dead endpoint — which is why that event's
message now names the client-certificate state explicitly, why the ordering is
enforced by render guards as far as a template can see it, and why
`scripts/verify-live.sh` checks the one step no template can (that
`s3-client-tls` actually reached the edge).

**There is no `s3-config` ConfigMap.** A Helm template cannot read a
Secret's contents, so this chart cannot render `s3.json` at all — which
is the point. The identity document is assembled **inside the pod** by
the `build-s3-identities` init container, from the per-identity Secrets
projected in by name, written with `umask 077` to a tmpfs
`emptyDir{medium: Memory}`. Nothing secret is ever templated and nothing
secret is written to a second object at rest. The predecessor,
`scripts/03-deploy-seaweedfs.sh`, did `kubectl create configmap s3-config
--from-file=s3.json` — every edge's S3 secret key in plaintext, readable
by anything with configmap-read in the namespace and dumped in full by
`kubectl get cm -o yaml`. It also mis-parsed `edge-nodes.env` with a
7-field `IFS='|' read` where the rest of the scripts used 6, so every
edge identity got an **empty** secretKey; SeaweedFS starts happily with
one, and the edge just gets 403 on every PUT forever with nothing wrong
on the management side. A missing or empty credential is now a hard
init-container failure, naming the identity in the log.

## Where it runs

- Cluster: management cluster only
- Namespace: `ais-mgmt` — the management **release namespace**
  (`MGMT_NS` in `install.sh`). Everything below renders into
  `.Release.Namespace`; there is no `seaweedfs` namespace, and there has
  not been one since the Helm migration
- Workload: Deployment `mgmt-seaweedfs` (single replica, all-in-one).
  The `mgmt-` prefix is the Helm release name (`MGMT_RELEASE`), applied
  by `mgmt.fullname` — a site installed under a different release name
  shifts every object below
- Image: `chrislusf/seaweedfs:4.34` (was 3.99 — moved off it because 3.99 is
  vulnerable to CVE-2026-54917, CVE-2026-58372 and CVE-2026-55874: three S3
  path traversals that let one site's key read, copy and *delete* across
  another site's bucket. 4.34 is the lowest version clean of all six published
  SeaweedFS advisories. Issue #9035, the 4.18/4.19 filer memory regression the
  old pin avoided, is closed — but see the risk table for #10253, which is not.
  The Iceberg REST Catalog 4.x turns on by default is disabled explicitly with
  `-s3.port.iceberg=0`.)
- Service: `mgmt-seaweedfs.ais-mgmt.svc.cluster.local` (ClusterIP only).
  In-cluster consumers get this address from the `mgmt.s3InternalEndpoint`
  helper rather than a literal, so it follows the release name
- External: nginx-ingress route `https://seaweedfs.aisedge.local:443`
  (TLS-terminated, signed by ais-edge-ca). This is the address **edges**
  use; in-cluster traffic stays on plain http so the custom CA never has
  to reach pods that have no other reason to trust one. That the Ingress
  **terminates** TLS rather than passing it through is what makes mTLS
  possible on this host — nginx performs the handshake, so it is the party
  that can ask the edge for a client certificate. It coexists with
  `ingressNginx.sslPassthrough=true` (which k0smotron needs) because the
  controller SNI-routes non-passthrough hosts to its own HTTPS listener,
  where the `auth-tls-*` annotations still apply. On cloud the load
  balancer in front is layer 4 and does not terminate TLS either, so this
  behaves identically there
- Metrics Service: `mgmt-seaweedfs-metrics.ais-mgmt.svc:9324` — a
  separate metrics-only Service so the ServiceMonitor can select it
  without also matching the S3 Service above

## Configuration

| File | Purpose |
|---|---|
| `charts/mgmt/templates/seaweedfs.yaml` | Deployment, Service, Certificate, Ingress, bucket-creation hook, and the S3 client-CA anchor + per-edge client Certificates when `ingress.clientCerts.issue` is set |
| `charts/mgmt/values.yaml` (`seaweedfs:`) | storage path, `perSiteBuckets` + `bucketPrefix`, image tag, resource limits |
| `sites/<site>/values.yaml` | `hostnames.seaweedfs`, `seaweedfs.buckets.logs`, and `edges[].bucket` to pin one site's bucket name. `seaweedfs.buckets.ingest` only takes effect with `perSiteBuckets: false` — otherwise the name is `<bucketPrefix>-<edge name>`, computed by the `mgmt.edgeBucket` helper |
| `sites/<site>/secrets.enc.yaml` | the `seaweedfs-admin` and `loki-s3-credentials` Secrets — named by `seaweedfs.adminSecretRef` and `observability.loki.s3SecretRef` |

## Operations

```bash
# Pod state
kubectl get pods -n ais-mgmt -l app=seaweedfs

# In-cluster S3 (admin). The client is the AWS CLI now, not mc.
kubectl port-forward -n ais-mgmt svc/mgmt-seaweedfs 8333:8333 &
export AWS_ENDPOINT_URL=http://localhost:8333 AWS_DEFAULT_REGION=us-east-1
aws s3 ls s3://ingest-edge-dev/staged/   # one bucket per site

# Master + filer admin UIs
kubectl port-forward -n ais-mgmt svc/mgmt-seaweedfs 9333:9333 &  # master
kubectl port-forward -n ais-mgmt svc/mgmt-seaweedfs 8888:8888 &  # filer

# NOT the metrics port: `weed server -metricsPort=9324` binds the pod IP,
# not 127.0.0.1, so port-forward to :9324 fails BY DESIGN while Prometheus
# (which dials the Service IP) scrapes it fine. A failed port-forward here
# is not evidence of broken metrics.

# Adding or removing an entry in `edges` changes the projected volume and
# the init script, so Helm rolls the pod by itself:
helm upgrade mgmt charts/mgmt -n ais-mgmt -f sites/<site>/values.yaml
```

**After rotating a key inside an existing Secret, restart by hand.**
That kind of edit does not change the pod spec, so Helm does not roll
anything, and `weed server -s3.config` reads the assembled `s3.json`
exactly once at startup — the pod keeps serving the old key indefinitely
with no error anywhere:

```bash
kubectl rollout restart deploy/mgmt-seaweedfs -n ais-mgmt
```

The `S3_CONFIG_HASH` annotation the shell installer used to recompute for
this is gone, along with the installer.

### Deleting staged objects

Measured on SeaweedFS 3.99: `aws s3 rm --recursive` (and `mc rm` before it)
removes the objects but leaves a 0-byte directory entry, which `aws s3 ls`
still reports as `PRE <session>/`. That entry made the uploader of the time
log a bogus success every cycle, so the reclaimer then deleted through the
filer's HTTP API (`DELETE ...?recursive=true`), which removes the entry.

That is no longer how it works, for two reasons measured on 4.34:

- A filer folder delete is not atomic. Even without `recursive=true` the
  filer checks the folder, then removes it, and a child written between the
  two is dropped with it (`filer_delete_entry.go`). The reclaimer therefore
  never deletes a folder. It deletes each object on its own with S3
  `DeleteObject` and `If-Match` set to the ETag it listed before its proof, so
  an object rewritten after the listing answers 412 and stays. Empty folders
  are left behind: the current uploader lists objects and skips a key that
  ends in `/`, so an empty folder is not a session to it.
- SeaweedFS removes an empty folder on its own about 90 seconds after its
  last object goes (the empty-folder cleaner; `-s3.allowEmptyFolder` is
  deprecated and ignored), with the same window. A bucket opts out through
  the filer attribute `Seaweed-X-Amz-Allow-Empty-Folders: true`, set with
  `PUT /buckets/<bucket>?tagging` and that header, and the policy is cached
  for about 5 minutes. The reclaimer deletes nothing from a bucket until it
  reads two attributes back from the filer: that one, and
  `Seaweed-X-Ais-Cleaner-Drained: <time>`, the attestation that the opt-out
  was activated in order. `charts/mgmt` writes both for a bucket it creates
  (no history) and only the first for an existing bucket; for an existing
  deployment run `scripts/cleaner-activation.sh <release> -- <edge>...`: it
  suspends and drains the mgmt reclaimers, scales the edge uploaders to zero
  and waits until no multipart upload is in flight, sets the attribute and
  reads it back, restarts SeaweedFS (no cached policy and no pending cleanup
  survives that), reads it back again, writes the attestation and resumes.
  What it suspends or scales it marks on the object (an annotation with the
  state before), so the resume puts back the replicas the uploader had and
  resumes only the CronJobs the script suspended; one an operator suspended,
  unmarked, stays suspended. A failure leaves nothing attested beyond that
  point; what was changed stays changed and marked, and a rerun after the
  repair puts it back. A query that fails is never read as "nothing runs".
  Measured on 4.34: a folder emptied just before that procedure survived it; without the
  attribute the folder was gone within 3 minutes.

Deletion of a local upload tree (the edge's staged-reclaimer) is in
[xnat-ingest.md](xnat-ingest.md); both deleters run the same
`reclaim-files.py`.

## Benefits

- **All-in-one** — master + volume + filer + S3 in a single pod for
  the MVP. No separate components to operate
- **Apache 2.0** — clean licensing
- **S3-compatible** — every S3 client (mc, boto3, AWS SDK) works
- **Cheap on disk** — Haystack format keeps small files efficient
- **Built-in Prometheus metrics** on `:9324`

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| Pod crash | Edge uploads + Loki writes pause | Pod auto-restarts; fast (~10s) |
| `/data/seaweedfs` disk full | Writes fail | `SeaweedFSDiskFull` at 80% of `SeaweedFS_volumeServer_resource`, plus the staged-data reclaimer described below — one CronJob per edge, no longer a TODO |
| Single replica | Window of unavailability during pod restart | Acceptable for staging (edge + xnat-upload retry naturally) |
| An S3 key is rotated inside its Secret | Nothing rolls; the pod keeps serving the old key until it restarts, and the edge gets 403 on every PUT with nothing wrong on the management side | `kubectl rollout restart deploy/mgmt-seaweedfs -n ais-mgmt` after the rotation. Adding or removing an `edges[]` entry *does* roll the pod by itself — only in-place key edits are invisible to Helm. A missing or empty credential is caught earlier: the init container fails hard, naming the identity |
| An edge's S3 key pair leaks | The holder can read, write and delete that site's staged imaging from anywhere the endpoint is reachable | The key is per-site and scoped to one bucket, so the blast radius is one site's staging area. `seaweedfs.ingress.clientCerts` closes the "from anywhere" half: with it on, a request also needs a private key that never leaves the site and that cert-manager replaces every 90 days. Off by default — see the four-step rollout above, and note that enabling `require` before the certificates land rejects **every** upload with an error that names neither certificates nor auth |
| Filer memory growth on 4.x | Pod OOMKilled and restarts | Upstream #10253 is still open (steady growth under concurrent load). Bounded here by `resources.limits.memory: 4Gi` — it costs a restart, not the node — and `SeaweedFSDown` fires. Accepted in exchange for closing the cross-bucket traversals; watch `container_memory_working_set_bytes` for the pod |
| ~~aws-cli checksum headers unverified on 4.34~~ RESOLVED | — | Was only ever measured against 3.99. Re-measured live against 4.34's real S3 gateway: `s3api put-object --checksum-algorithm SHA256` is accepted, and `s3api head-object --checksum-mode ENABLED` echoes back the identical `ChecksumSHA256` value. Round-tripped correctly. |

## Staged-data reclaim (shipped, not future work)

`xnat-ingest upload` has **no S3 retention of its own**: it rebuilds its
work list from a live listing every `--loop` pass, so a delivered session
stays in the bucket, is listed again, "uploaded" again and re-fires
`XNATUploadSuccess` forever while staging grows without bound. The
reclaimer is the only thing that deletes from staging.

| Fact | Value |
|---|---|
| Object | CronJob `mgmt-reclaim-<edge>`, **one per `edges[]` entry**, namespace `xnat-upload` |
| Driven by | `dataPolicy.derived.s3Staged` in `charts/mgmt/values.yaml` |
| Schedule | `17 * * * *` |
| Age gate | `minAge: 36h`, the longer of the two clocks (and at most 36h: the XNAT proof runs only after it, and `SessionStagedNotConfirmedInXNAT` counts a session unconfirmed after 48h; the chart refuses more): the edge's staged-reclaimer must prove its local copy against the bucket (`stagedReclaimer.minAge`, a day) before this removes the bucket copy, or the two ping-pong (`RecopyLoop`); see [xnat-ingest.md](xnat-ingest.md), "S3 mode: prove, then delete" |
| Per-run cap | `maxRemovals: 50` — bounds a "delete everything" bug to 50 sessions per hour, while still draining ~1200/day if genuinely needed |
| Confirmation | `verifyAgainstXnat: true` — re-queries XNAT before deleting, rather than trusting the uploader's exit code, which only means the call returned |
| Deletion path | one S3 `DeleteObject` per object, with `If-Match` set to the ETag listed before the proof, never a folder and never `aws s3 rm` or a filer folder delete — see "Deleting staged objects" above for why; the bucket must carry the cleaner opt-out and its attestation first |
| Opt out | `reclaim: never` renders **nothing** — not a suspended CronJob, not an empty ConfigMap, so there is no object left that could be resumed by accident |

Metrics discovery is likewise done: `charts/mgmt/templates/observability.yaml`
ships a ServiceMonitor for `mgmt-seaweedfs-metrics`, and the
`SeaweedFS_volumeServer_resource` series it collects are what
`SeaweedFSDiskFull` reads (measured on the live cluster). The rule
replaced one built on `kubelet_volume_stats_used_bytes`, which publishes
nothing for a hostPath volume — `count()` returned no series at all, and
the alert had been green its entire life for want of an input.

## Replacements / future

- **MinIO** — was the original choice; archived in Feb 2026 → switched
  to SeaweedFS
- **AWS S3** — drop SeaweedFS entirely; point edges + upload pod at
  `s3.<region>.amazonaws.com` with IAM users. Documented in main README.
- **Garage** — Rust-based S3 implementation; lighter than SeaweedFS but
  newer. Considered, not adopted (SeaweedFS' ecosystem is more mature)
- **Multi-replica scale-out** — split master/volume/filer/S3 into
  separate Deployments with 3-master Raft + N volume servers + 2+
  filers behind a Service. Documented in README "Scaling SeaweedFS"

## Future enhancements

- S3 lifecycle rules as a *second* line of defence under the reclaimer,
  for objects it never learns about (an aborted multipart, a session
  written by something outside the pipeline)
- Replication: 3-master HA with Raft, separate volume/filer/s3
  deployments
