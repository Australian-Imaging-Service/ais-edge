# A guided tour of this repository

Written to be read start to finish by someone who has never seen it. It follows
the order you would actually do things in: understand the shape, fill in the
config, install, then operate.

At each step: **what you configure**, **which file controls it**, **what happens
when it runs**, **what can go wrong**, and **what happens to the data**.

---

## 0. The shape of the thing, in one paragraph

A hospital sends DICOM to a machine in its own building (the **edge**). That
machine de-identifies the images immediately, keeps the untouched original in a
local archive, and pushes the de-identified copy out to a **management node**
over HTTPS. The management node stages it in S3, then writes it into XNAT, then
— only after re-checking that XNAT really holds every file — deletes the staged
copy. The hospital never accepts an inbound connection, and no XNAT credential
ever exists inside the hospital.

Everything else in this repo is in service of that sentence.

---

## 1. Two kinds of machine, two charts, one directory per machine

| | Management node | Edge node |
|---|---|---|
| Who runs it | You | Sits in the hospital |
| Chart | `charts/mgmt` | `charts/edge` |
| Kubernetes | a full k0s cluster | **only a worker** — its control plane runs on the management node |
| Holds | S3 staging, XNAT uploader, observability, the CA | Orthanc, the ingest pipeline |
| Credentials | XNAT, SMTP, S3 admin | its own S3 key, its own Loki key, the de-id salt |

The unusual part is that **the edge's Kubernetes control plane physically runs on
the management node**, via k0smotron. The hospital gets a Kubernetes node without
having to operate a Kubernetes cluster, and the edge dials outward through a
konnectivity tunnel rather than accepting connections.

### The files you edit

**You never edit anything under `charts/`.** Those hold the defaults and the
reasoning behind them. Everything you configure lives in `sites/`, and there is
**one directory per machine** — one for the management node, one for each edge:

```
sites/
  my-deployment/values.yaml       ← THE management node   (one per deployment)
  my-deployment/secrets.enc.yaml
  hospital-a/values.yaml          ← one edge              (one per facility)
  hospital-a/secrets.enc.yaml
  hospital-b/values.yaml          ← another edge
  hospital-b/secrets.enc.yaml
```

Start each from the matching template — `sites/example-mgmt/` or
`sites/example-edge/`. `scripts/site-secrets.sh new <name> <mgmt|edge>` copies
the right one. The role argument is required and deliberately not guessed: the
two templates are completely different, and scaffolding from the wrong one
produces a file that renders happily and fails much later.

### How Helm combines them

```
management chart:  -f sites/my-deployment/values.yaml
edge chart:        -f sites/my-deployment/values.yaml  -f sites/hospital-a/values.yaml
                      └─ shared facts, read FIRST         └─ this edge's own, read LAST
```

The management file reaches **both** charts. That is the whole point: a fact that
means the same thing on both sides — the internal domain, the published
hostnames, the management node's IP, the data policy — is written **once**, and
each edge derives its S3 endpoint, staging bucket, Loki endpoint and hostAliases
from it. Because the edge file is read last, anything it sets wins, so a site
that genuinely needs to differ still can.

There used to be a second config system (`config/*.env`) that the charts could
not see, so the edge's name, the node IPs, the hostnames and the bucket were each
typed twice — and every one of those mismatches failed *silently*: the edge
retried an endpoint that would never answer, correctly kept its local copy, and
the management side, which watches for arrivals rather than absences, reported
nothing wrong. That file is gone, and the derivation above is what replaced it.

> **Do not copy a shared key into an edge file.** It will silently override the
> shared value for that edge only, and because the management chart never reads
> the edge file, the same name then means two independent settings. `dataPolicy`
> was duplicated this way: both copies said `false`, so nothing was broken, but
> enabling the policy centrally would have started the management reclaimer
> freeing staged objects while the edge kept everything.

---

## 2. Before you install: what you must decide

These are the values with no safe default. Everything else has one.

### 2.1 Where things live

```yaml
domain:
  internal: aisedge.local        # internal DNS suffix — needs no real zone
  mgmtNodeIP: "203.0.113.10"     # what the edges dial

hostnames:
  seaweedfs: seaweedfs.aisedge.local
  grafana:   grafana.aisedge.local
  loki:      loki.aisedge.local
```

**File:** `sites/<site>/values.yaml`

These hostnames get real TLS certificates from the internal CA, and the edge
resolves them through `/etc/hosts` entries rather than DNS. You do not need to
register the domain anywhere.

> **Risk:** if a hostname here does not match what the edge is told to dial, the
> edge gets NXDOMAIN, the uploader treats it as an unreachable endpoint, and
> **correctly keeps its local copy and retries**. Nothing errors. The management
> side is watching for arrivals, not absences, so it reports nothing wrong while
> the edge slowly fills its disk. This is why the edge chart now *derives* its
> endpoints from this block instead of having them retyped.

### 2.2 Your edges

```yaml
edges:
  - name: edge-dev
    nodeIP: "203.0.113.20"
    sshUser: ubuntu
    sshKey: ~/.ssh/id_ed25519
    s3SecretRef: edge-dev-s3
    exposure: sni          # ← use this. No ports to assign.
```

**File:** `sites/<site>/values.yaml`

Each entry produces, automatically: a hosted control plane, an S3 bucket named
`ingest-<name>`, an S3 identity scoped to that bucket, an uploader, and a
reclaimer.

`sshUser`/`sshKey` are here because joining a worker **must** be done over SSH —
there is no API server on the edge until it has happened.

#### `exposure: sni` vs `nodePort`

**Use `sni`.** The control plane becomes a ClusterIP Service reached through the
ssl-passthrough Ingress on :443 — which is already how the worker connects. The
ports stay at the CRD defaults but are *Service* ports, which are per-Service,
so **two sites can never collide and you assign nothing**.

`nodePort` additionally reserves those numbers cluster-wide, which is what
forces a unique pair per site. Verified on this deployment: the worker dials
`<mgmtNodeIP>:443` and the ingress routes to the Service's ClusterIP — nothing
ever dialled the node port from outside. It buys nothing here.

> **Migrating an existing site from `nodePort` to `sni`** works, with one manual
> step: k0smotron creates a *new* ClusterIP Service and leaves the old NodePort
> one behind, still holding the ports. Delete it once the new Service has
> endpoints:
>
> ```bash
> kubectl -n <edge> get endpoints kmc-<edge>          # wait for an address
> kubectl -n <edge> delete svc kmc-<edge>-nodeport
> ```
>
> Both were verified end to end on this cluster: worker stayed `Ready`, all edge
> pods stayed running, node ports freed.

> **Capacity:** roughly **231Mi per uploader**, measured. On a 16Gi management
> node that is a practical ceiling around **15 sites**.

### 2.3 De-identification — the one you must actually read

```yaml
orthanc:
  aet: AISEDGE
  deid:
    enabled: true
    policyReviewed: false        # ← NO DEFAULT. You must set this to true.
    aetMap:
      AISEDGE: {project: my_project}
    profile:
      Keep: [StudyInstanceUID, SeriesInstanceUID, SOPInstanceUID, FrameOfReferenceUID]
      Replace:
        PatientName: ANONYMOUS
        PatientID: ${ProjectCode}-${SubjectHash}
```

**File:** `sites/<edge>/values.yaml`

`policyReviewed` has **no default and the chart refuses to render without it.**
It is not a feature flag — it is an assertion that a human has read this profile
and this AE-title map and accepts what they do and do not remove.

Three things worth understanding:

* **`aetMap` is the routing table.** The calling AE title decides which XNAT
  project the study lands in. An unmapped AE title is **quarantined, not
  dropped** — it goes to `__unmapped_aet__` and raises an alert after 24h.
* **UIDs are retained** so a study stays internally consistent across series.
  That is a deliberate research-data choice, not an oversight.
* **The HMAC salt must survive reinstalls.** The same patient hashed with a
  different salt becomes a different pseudonym, so rotating it splits one person
  into two subjects in XNAT. It lives in `secrets.enc.yaml` and
  `uninstall.sh` deliberately never deletes it.

### 2.4 Data policy — what is kept, for how long

```yaml
dataPolicy:
  enabled: false      # nothing expires until you turn this on
  dryRun: true        # decisions are logged, never acted on

  originals:
    facilityBackup: {retain: forever, minFreeDiskPercent: 10}
    quarantine:     {retain: forever, alertAfter: 24h}

  derived:
    orthancStorage: {reclaim: onGrouped,       minAge: 7d}
    grouped:        {reclaim: onAssigned,      minAge: 0}
    assigned:       {reclaim: onUploaded,      minAge: 0}
    s3Staged:       {reclaim: onXnatConfirmed, minAge: 1d, maxRemovals: 50}
```

**File:** `sites/<site>/values.yaml` — passed to **both** charts, so a site has
exactly one answer to "what is kept".

The model has two categories:

* **originals** — the archive of record. The facility backup holds the DICOM
  exactly as it arrived, written *before* de-identification. Default `forever`.
* **derived** — anything reproducible from the originals. These have reclaim
  rules.

**Every derived rule is `(condition AND minAge)` — both must hold.** A pure age
rule would expire a session that never reached XNAT because a credential was
wrong. A pure condition rule frees nothing the moment the signal breaks.

**A fresh install expires nothing.** Run with `dryRun` for a week, read the
decisions in the logs, then enable.

---

## 3. Secrets

```bash
scripts/site-secrets.sh init-key                  # once per operator
scripts/site-secrets.sh add-recipient <pub>       # register the key
scripts/site-secrets.sh new <name> <mgmt|edge>    # scaffold, one per machine
scripts/site-secrets.sh encrypt <name>            # before committing anything
scripts/site-secrets.sh apply <name>              # decrypt straight into the cluster
```

**Files:** `scripts/site-secrets.sh`, `.sops.yaml`, `sites/<name>/secrets.enc.yaml`

### How SOPS works here, in one paragraph

You have a keypair. The private half lives at `~/.config/sops/age/keys.txt` and
is never committed; the public half goes in `.sops.yaml`. Encrypting a file locks
it so that **any** public key listed there can be opened by its owner's private
key — which is why adding a colleague is just `add-recipient` plus
`sops updatekeys` on each existing file. Adding a recipient does **not**
retroactively unlock files encrypted before you added them.

> **The file is plaintext until you run `encrypt`.** It is named
> `secrets.enc.yaml` from the moment it is created, which reads as a promise it
> has not kept yet. `install.sh` refuses to run against an unencrypted secrets
> file, and `site-secrets.sh check` fails if a committed one is not encrypted.

### Which secrets go where

They are **not** interchangeable, and `apply` sends a whole file to whatever
cluster `KUBECONFIG` points at — so a merged file would push management
credentials onto a hospital machine.

| | Management site | Each edge site |
|---|---|---|
| Namespaces | `ais-mgmt`, `xnat-upload` | `xnat-ingest` |
| Holds | S3 admin + upload identities, the XNAT account, Grafana, Loki's storage identity, SMTP, one `<edge>-s3` per edge | the de-identification salt, and its S3 identity |
| Roughly | eight Secrets | two |

`scripts/ci/secret-namespaces.sh` renders both charts and fails if a mounted
Secret is missing, in the wrong namespace, or declared in the wrong template.

### Two secrets you must NOT create by hand on an edge

`ca-bundle` and `loki-push-client-tls` are written into each edge cluster by the
management side's **cert-sync** CronJob. `loki-push-client-tls` is this site's
mTLS identity for the Loki push endpoint, and hand-writing it produces a
certificate the management CA never signed — the push is then rejected at the
TLS handshake, its logs stop arriving, and the alerts that would tell you are
built from those same logs.

### The names that must line up

Adding an edge means several strings agreeing. Getting one wrong fails at
install, or worse, at runtime. For an edge called `hospital-a`, all of these must
be the identical string:

1. `edges[].name` in the management `values.yaml`
2. the directory name `sites/hospital-a/`
3. `clusterLabel` in `sites/hospital-a/values.yaml`
and separately, `edges[].s3SecretRef` must name a Secret that exists in the
management secrets file — conventionally `hospital-a-s3`. There is no fourth
string to keep in step any more: the Loki push identity is derived from
`edges[].name`, not written down a second time.

> This is friction the tool should absorb rather than the operator, and that is
> being addressed. Until it is, `docs/TOUR.md` §5b walks the whole sequence.

The charts contain **no credentials at all**. They reference Secrets by name.
`apply` pipes plaintext directly into `kubectl` — it never writes to disk.

Only `data`/`stringData` are encrypted; names, namespaces and keys stay readable,
so `git diff` shows *which* credential changed without showing it.

> **The single most dangerous thing in this repo:** `~/.config/sops/age/keys.txt`
> is the only key that can decrypt every site file, nothing can regenerate it,
> and losing it makes every encrypted secret permanently unreadable. Put it in
> the team password manager **today**. `uninstall.sh` deliberately never touches
> it.

> **Namespaces are part of the contract.** A Secret is only readable from its own
> namespace, and almost everything runs in the *release* namespace (`ais-mgmt`),
> not in namespaces named after the component. Getting this wrong installs
> cleanly and leaves pods in `CreateContainerConfigError` with nothing in the
> chart to explain why. `make secret-contract` checks it.

---

## 4. Installing

```bash
./install.sh <site>        # interactive, one prompt per step
./install.sh -y <site>     # non-interactive
```

**File:** `install.sh`

There is **no `--set` anywhere in it.** A flag needed to make an install work is
a value that belongs in the site file.

### The seven steps

**1 — k0s, kubectl, helm, local-path-provisioner** (`scripts/01-install-k0s.sh`)
Builds the management cluster. Skipped if `installMode: existing`.

**2 — cert-manager, then the k0smotron operator.** Both pinned.

> This step exists because of a dependency loop that is not obvious:
> the chart renders `Cluster` objects → their CRD declares a conversion webhook →
> served by the k0smotron operator → which will not start until cert-manager
> issues its certificate → and cert-manager would be installed by that same
> chart. So cert-manager **must** be installed first, outside the chart. Keep
> `certManager.enabled: false`. Setting it true fails with
> `conversion webhook … connection refused`, which reads as a network fault.

**3 — site Secrets** (`scripts/site-secrets.sh apply`)
Always before the workloads. A pod that starts without its Secret sits in
`CreateContainerConfigError`, so the charts deliberately do **not** create the
namespaces that hold operator-supplied credentials — `site-secrets.sh` does, and
that is what makes secrets-before-workloads possible on a bare cluster.

**4 — the management chart** (`charts/mgmt`)
SeaweedFS, the per-edge uploaders and reclaimers, Prometheus/Loki/Grafana/
Alertmanager, the CA and its issuers, ingress-nginx, and one `Cluster` object per
edge.

**5 — child kubeconfig + join token, per edge** (`scripts/05-setup-edge-cluster.sh`)
Waits for the hosted control plane, extracts the child kubeconfig and rewrites
its `server:` to the ingress hostname, adds `/etc/hosts` entries on the
management node, then mints a join token and re-points it at the ingress.

> The token stays in a script rather than the chart because a Helm-rendered token
> would be **re-minted on every upgrade**.

**6 — join the worker over SSH** (`scripts/06-join-edge-worker.sh`)
Writes `/etc/hosts` on the edge, mints a server certificate for the k0smotron
haproxy from the child cluster's CA, installs k0s as a worker, and **rewrites the
child cluster's CoreDNS** so konnectivity can resolve the management hostnames.

**7 — the edge chart, then seed cert-sync** (`charts/edge`)
Orthanc, the pipeline, the uploader, Vector. Then it runs the cert-sync CronJob
**once, immediately**.

> Without that, the edge waits up to **six hours** for its `ca-bundle` and its
> `loki-push-client-tls` — the s3-uploader mounts the first and Vector mounts the
> second, so neither pod can start at all. The install would report success and
> the site would do nothing until the small hours.

### What can go wrong

| Symptom | Cause |
|---|---|
| `conversion webhook … connection refused` | k0smotron operator not ready; cert-manager must come first |
| `invalid ownership metadata` | an object exists without Helm's labels, from a previous non-Helm install |
| Worker join times out | the management node cannot resolve its own child API — check `/etc/hosts` |
| Edge pods `CreateContainerConfigError` | a Secret is missing, usually `ca-bundle` or `loki-push-client-tls` from cert-sync |

---

## 5. What happens to a study, hop by hop

This is the part worth understanding properly, because every safety property
lives in it.

```
 1. modality ──C-STORE──▶ Orthanc :4242
 2.   Lua hook writes the ORIGINAL to /data/facility-backup/     ← archive of record
 3.   then de-identifies in place
 4.   then labels the study `xnat-ingest-ready`
 5. group-orthanc pulls it to /data/grouped, relabels `xnat-ingest-processed`
 6. assign builds an XNAT session in /data/assigned
       + __MANIFEST__.json  (filenames + MD5 per resource)
 7. s3-uploader waits settleMinutes, then uploads to s3://ingest-<edge>/staged/
 8. mgmt-upload-<edge> writes it into XNAT
 9. mgmt-reclaim-<edge> re-queries XNAT, compares names AND checksums,
       and only then deletes the staged copy
```

**Order matters at step 2.** The original is written to the facility backup
*before* de-identification, so the archive of record is the wire original, not a
processed derivative.

**Step 7's settle window** (`settleMinutes`, default 5) exists because a session
being written to is not a session ready to ship. The uploader waits for the tree
to stop changing.

**Step 9 is the only place patient data is deleted**, and it is deliberately
paranoid:

* XNAT creates the experiment on the *first* resource POST, so "the experiment
  exists" is **true for a partial upload**. Existence is not evidence.
* So the reclaimer sums every `__MANIFEST__.json` into a set of
  `filename → MD5`, lists what XNAT actually holds, and deletes only when
  `missing == 0 AND mismatched == 0`.
* Every uncertainty — unreadable manifest, HTTP 500, unparseable listing —
  resolves to **keep**.
* `maxRemovals: 50` bounds a bug: a run that decided "delete everything" is
  capped, leaving the rest for someone to notice.

**Files:** `charts/edge/files/deidentify-and-forward.lua`,
`charts/edge/files/s3-uploader.sh`, `charts/mgmt/files/reclaim-staged.sh`

---

## 5b. Adding another edge site, after the first deploy

This is the normal growth path, and it is deliberately boring: **edit one file,
re-run one command.**

### 1. Add the entry

`sites/<site>/values.yaml`:

```yaml
edges:
  - name: edge-dev            # existing site — leave it alone
    nodeIP: "203.0.113.20"
    sshUser: ubuntu
    sshKey: ~/.ssh/id_ed25519
    s3SecretRef: edge-dev-s3
    exposure: sni

  - name: edge-syd            # the NEW site
    nodeIP: "203.0.113.30"
    sshUser: ubuntu
    sshKey: ~/.ssh/id_ed25519
    s3SecretRef: edge-syd-s3
    exposure: sni
```

**Nothing else is needed.** No ports to allocate — that is what `sni` buys you —
and no hostnames to invent: `apiHost`/`konnectivityHost` default to
`<prefix>-<name>.<domain>`, so `edge-syd` gets `k0s-edge-syd.aisedge.local`
automatically. Pin them only when adopting a site that already runs other names.

### 2. Add its secrets

The new site needs its own S3 identity. That is the only credential you write
by hand:

```bash
scripts/site-secrets.sh edit <site>     # decrypts into $EDITOR, re-encrypts on save
```

```yaml
# the new edge's S3 identity, in the RELEASE namespace
apiVersion: v1
kind: Secret
metadata: {name: edge-syd-s3, namespace: ais-mgmt}
stringData:
  access-key: "<openssl rand -hex 6>"
  secret-key: "<openssl rand -base64 24>"
```

There is **no Loki push credential to add.** The `edges:` entry is what
provisions it: cert-manager issues `edge-syd-loki-client` from the fleet CA with
`CN=edge-syd`, cert-sync copies it into the site, and the push Ingress adds
`edge-syd` to the CNs it accepts. Removing the entry and upgrading revokes it.

Then create the edge's own two files — `sites/edge-syd/values.yaml` (AE map,
de-identification profile, storage paths) and `sites/edge-syd/secrets.enc.yaml`
(`orthanc-deid-salt`, and `s3-edge-credentials` holding the same key pair you
just generated) — and encrypt both:

```bash
scripts/site-secrets.sh encrypt <site>
scripts/site-secrets.sh encrypt edge-syd
```

### 3. Re-run the installer

```bash
./install.sh <site>
```

It is idempotent. Steps 1–4 no-op on what already exists; the per-edge loop then
runs steps 5–7 for **every** edge, so `edge-dev` is re-verified and `edge-syd` is
built: hosted control plane → child kubeconfig + join token → SSH worker join →
edge chart → cert-sync seeded.

### What the new site gets automatically

| | |
|---|---|
| Hosted control plane | `kmc-edge-syd` in namespace `edge-syd` |
| S3 bucket | `ingest-edge-syd` — isolated from every other site |
| S3 identity | scoped to that bucket alone |
| Uploader + reclaimer | `mgmt-upload-edge-syd`, `mgmt-reclaim-edge-syd` |
| Ingress hostnames | `k0s-edge-syd.<domain>`, `konnect-edge-syd.<domain>` |
| Loki push client cert | `edge-syd-loki-client`, `CN=edge-syd`, issued from the fleet CA |
| CA bundle + client cert | delivered into the site by cert-sync |

### Check it landed

```bash
kubectl -n edge-syd get pods                                    # control plane up
kubectl --kubeconfig kubeconfig-edge-syd get nodes              # worker Ready
kubectl --kubeconfig kubeconfig-edge-syd -n xnat-ingest get pods
kubectl --kubeconfig kubeconfig-edge-syd -n xnat-ingest get secret ca-bundle loki-push-client-tls
```

If the edge pods sit in `CreateContainerConfigError`, `ca-bundle` or
`loki-push-client-tls` has not arrived yet — run cert-sync by hand:

```bash
kubectl -n ais-mgmt create job seed --from=cronjob/mgmt-cert-sync-edge-syd
```

### Two things to know

**Watch the ceiling.** Each uploader costs ~231Mi on the management node, so a
16Gi node runs out of headroom around **15 sites**. The 16th is a capacity
decision, not a config change.

**Removing a site** is the reverse: delete its entry, `helm upgrade`, then
`k0s reset` on that edge machine. Its bucket, identity, uploader and reclaimer
go with the entry. Its staged data does not — remove that deliberately.

---

## 6. Observability

Two sources of alerts, deliberately:

* **Prometheus rules** — resources, certificates. `charts/mgmt/files/prometheus-rules/`
* **Loki ruler rules** — the pipeline. `charts/mgmt/files/loki-ruler-rules.yaml`

The pipeline alerts live in the Loki ruler because the management Prometheus
**cannot scrape edge pods** across the one-way konnectivity tunnel, and because
the source of truth is the JSON log event, not a derived metric.

> **The uploader's log schema is a public interface.** `upload_started`,
> `upload_completed` and `upload_failed` are matched by five alert rules.
> Renaming one disables the corresponding alert *silently*.

```bash
scripts/check-alert-inputs.sh    # asks LIVE Prometheus whether each alert can fire
```

That script exists because three alerts were once found that had never been able
to fire — including certificate expiry, on a fleet whose CA rotation takes weeks.
An alert that cannot fire is worse than no alert: it looks like coverage.

---

## 7. Testing

```bash
make ci-fast     # no cluster needed
make ci          # adds a kind-based greenfield install
```

Nine stages. Two are worth explaining:

**`reclaimer`** — 28 cases that assert on **what was deleted**, not on log text.
A run that logs `reclaim_kept` and issues a DELETE anyway passes a log-only test
and fails this one. Its `aws` and `curl` are stubbed and **fail by default** for
anything a case does not explicitly configure, because a stub that invented a
plausible success would test the opposite of the property that matters.

**`secret-contract`** — renders both charts and fails if any mounted Secret is
absent, in the wrong namespace, or missing a key. A wrong namespace and a missing
key fail *identically and silently* at runtime.

---

## 8. Uninstall

```bash
scripts/uninstall.sh <site>                  # full reset, both nodes
scripts/uninstall.sh --keep-cluster <site>   # workloads only
```

A **partial teardown is worse than none.** A CRD without its operator, a
namespace Helm cannot adopt, cert-manager RBAC from a release that no longer
exists, or a stale `/etc/hosts` marker each make the *next* install fail in a way
that looks like a chart bug. So the default removes all of it, including
`k0s reset` on both machines.

It requires you to type the site name, because it deletes `/data` — the facility
backup. It never deletes your age key or your site files.

---

## 9. Known shortcomings — read this part

Stated plainly so you can weigh them.

**1. `Successfully uploaded all files in '<session>'` is a LEVEL, not an
event.** The uploader re-scans staging roughly every 62 seconds and logs that
line on every pass — including the passes where it correctly decides the
session is already in XNAT and skips it. One 30-minute sample: 30 success
lines beside 14 `already exists` and 14 `Skipping`. So the line does not mean
"this just uploaded"; it means "this session is in XNAT", re-asserted for as
long as the session sits in staging, which with `dataPolicy.enabled: false` is
forever.

This matters to anything that keys on it. `XNATUploadSuccess` uses a `[10m]`
range for exactly this reason — see the comment on that rule, and the range
floor `scripts/ci/promtool.sh` enforces.

**2. The uploader caches XNAT state across a `--loop` lifetime.** `xnat-ingest
upload --loop` opens one XNAT connection and xnatpy caches the
project/experiment listing on it. A connection opened while a session does not
yet exist keeps returning that stale view.

It is a STATE bug, not a logic bug. Restarting `mgmt-upload-<edge>` clears it.
It also means: **if you ever clear XNAT by hand, restart the uploader**, or it
will skip everything staged against a snapshot that no longer matches reality.

(Two earlier diagnoses in this repo were wrong and are recorded because they
were confidently written down first: one blamed `all_uploaded()` for ignoring
scan-level resources — measurement disproved it; the other blamed this cache
for the duplicate alert mail — it was not that either. The duplicate mail was
a flapping alert, item 1 above.)

**3. Loki logs `NoSuchBucket` at startup.** The bucket-creation hook is
`post-install`, so Loki retries its chunk store until the bucket appears. Non-
fatal and self-correcting, but noisy and it looks alarming.

**4. cert-sync runs every 6 hours.** `install.sh` now seeds it once at install,
but a CA rotation still propagates on that cadence.

**5. `helm/edge` has been deleted.** It was a dead duplicate of `charts/edge`
with a divergent values schema that no CI stage validated — a second,
untested source of truth. Removed; CI stayed green, confirming nothing
depended on it.


**6. Pinned versions HAVE now been checked for CVEs — and one of them is
still a standing risk that no version bump can fix.**

Audited 2026-08-06 against OSV, the GitHub Advisory DB, NVD and each vendor's
advisories. Three pins were changed and the reasoning lives next to each one:

* **SeaweedFS 3.99 → 4.34.** The important one. 3.99 is vulnerable to three
  S3 path traversals: CVE-2026-54917 (10.0) through `..` in the request path,
  CVE-2026-58372 (8.1) through the same trick in the *multi-object delete*
  handler, and CVE-2026-55874 (7.7) through the `X-Amz-Copy-Source` header.
  Together they let a key scoped to one bucket read, copy and delete across
  **any** bucket. Per-site buckets are the *entire* cross-site isolation
  mechanism here (`charts/mgmt/values.yaml`: "the bucket IS the boundary"),
  and the S3 endpoint is published on the internet-reachable management node,
  so this turned any one leaked edge key into fleet-wide access to every
  site's staged imaging — and let the deliberately-quarantined `loki-writer`
  key reach the ingest buckets. 4.30 fixes only the first; 4.34 is the lowest
  version clean of all six published SeaweedFS advisories.

  The bump is **not** just a tag change. 4.x defaults an Iceberg REST Catalog
  on to port 8181 that 3.99 did not have at all, and that server is the
  subsystem two of these advisories are about — so upgrading naively would
  have opened new surface while closing old. Both the chart and the legacy
  manifest now pass `-s3.port.iceberg=0`. Nothing here speaks Iceberg.
* **Grafana 13.1.1 → 13.1.2**, pinned ahead of its subchart. CVE-2026-13438,
  no public details yet. Grafana is the only thing ingress-nginx publishes
  with no auth in front of it.
* **Samba 4.23.5 → 4.23.10.** Latent — nothing enables samba — but 4.23.5
  misses two unauthenticated smbd RCEs.

**The standing risk: ingress-nginx is dead upstream.** The pin here,
chart 4.15.1 / controller 1.15.1, is not stale — it is the FINAL release. The
Kubernetes project retired ingress-nginx in March 2026; v1.15.1 shipped on
retirement day carrying the fix for CVE-2026-4342, and **there will be no
further security releases, ever.** It terminates :443 on the
internet-reachable management node with `hostNetwork: true`, and in a default
install the controller can read Secrets cluster-wide. Nothing to bump: the
next CVE in it is permanent until this cluster moves to a maintained
controller or a Gateway API implementation. That migration is the single
largest piece of unscheduled security work in this repo.

A fourth pin changed for the same reason: `scripts/01-install-k0s.sh` was
installing local-path-provisioner v0.0.30, which is affected by
CVE-2025-62878 (CVSS 9.9, StorageClass `pathPattern` traversal) and
CVE-2026-44543 (8.7). Both need cluster-scoped write to reach, so this is
hardening rather than an open door — but it is a version number, and that
provisioner backs the Prometheus, Grafana and Alertmanager volumes. Note the
`if` guard around it: this installs the provisioner only when the StorageClass
is absent, so **it does not upgrade the cluster that already runs v0.0.30.**

Everything else that is behind upstream is behind for currency reasons, not
CVE reasons. The gaps worth a diary entry: `amazon/aws-cli` 2.31.19 is from
October 2025, so it carries ~9 months of unpatched Amazon Linux base layer in
a pod that holds S3 credentials on both clusters; `timberio/vector` is 0.49.0
on the edges against 0.57.0 on management, eight releases and about a year of
skew inside one fleet; and Loki 3.6.8 carries CVE-2026-21729, a genuine
unauthenticated DoS upstream that is not unauthenticated *here* because the
Loki ingress requires HTTP basic auth — which is fortunate, because no Loki
chart ships the 3.7.0 that fixes it.

Deliberately NOT bumped, so nobody re-litigates them: **k0smotron v2.0.3**
(v2.0.4 exists and pulls in grpc 1.79.3 for CVE-2026-33186, critical — but
that CVE is an authorization bypass in grpc's authz interceptors and
k0smotron runs no gRPC server that uses them, so it buys nothing and costs a
control-plane operator upgrade under a live pipeline); **helm v3.20.1** in
`scripts/ci/lib.sh` (CVE-2026-35206 is specifically `helm pull --untar`, which
this repo never runs — if you bump it anyway the sha256 for v3.20.2 linux-amd64
is `258e830a9e613c8a7a302d6059b4bb3b9758f2f3e1bb8ea0d707ce10a9a72fea`); and
**busybox:1.36** in the Orthanc init container (its known CVEs are in awk,
tar and wget parsing untrusted input; that container runs `mkdir` and `chown`
on template-controlled paths and touches no input at all).

**7. The cloud/OpenStack path is not ported** to the charts, and the
`loadBalancerIP` handling is unfinished.

**8. Duplicate alert mail is fixed, and it took two changes, not one.**
Alertmanager now groups by `session`, so concurrent per-session alerts do not
share a group and re-notify on every membership change. That alone was not
enough: grouping cannot suppress an alert that resolves and re-fires, because
each re-fire is a new alert instance. The second change was giving
`XNATUploadSuccess` a range longer than the uploader's loop period so it stops
flapping. Verified live — with the uploader still re-emitting the success line
every ~62s, the notification count stayed flat.

**9. Two alert rules were removed, not fixed, because a fix would have
shipped false coverage.**

`OrthancStorageGrowing` matched `"new stored instance"` in the Orthanc log
stream. Measured against a live edge: neither that string nor the corrected
`"new instance stored"` word order appears at Orthanc's default log
verbosity — the message is a Verbose-level log this deployment does not
enable. Fixing the regex would not have fixed the rule; nothing in the
current log stream indicates a stored-instance count. Enabling `--verbose`
was rejected as the fix — it makes every REST call and DICOM operation
chatty for the sake of one counter — and no alternative low-cost signal for
"Orthanc storage is backing up" exists today. Deleted rather than left
silently dead.

`XNATBacklogGrowing` tried to measure "arriving in S3 faster than reaching
XNAT" by subtracting a count of one log string from another. It could not
fire for two independent reasons, only the second of which is fixable in
this repo: the RHS parsed a JSON `event` key the management uploader's log
format has never emitted (its lines carry `logger`/`message`/`ts`, no
`event`), and even fixed to match on the real success string, that string is
a **level** (docs/components/xnat-ingest.md, "Known upstream defects" §1) —
its count grows with the size of the static backlog sitting in staging, not
with new arrivals in the window, so a genuine backlog would make the
subtraction more negative, exactly the wrong direction for a `> 3` alert.
Deleted rather than shipped as an alert that reads as backlog coverage and
provides the opposite.

Both are recorded in `docs/alerting-architecture.md` and
`docs/components/xnat-ingest.md` rather than silently dropped. Neither gap
is currently covered by another rule: `SessionStagedNotConfirmedInXNAT` is
the closest existing backstop for the XNATBacklogGrowing case, but fires only
after `minAge` + the confirmation offset, not on rate.
