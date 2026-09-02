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

|             | Management node                                  | Edge node                                                                |
| ----------- | ------------------------------------------------ | ------------------------------------------------------------------------ |
| Who runs it | You                                              | Sits in the hospital                                                     |
| Chart       | `charts/mgmt`                                  | `charts/edge`                                                          |
| Kubernetes  | a full k0s cluster                               | **only a worker** — its control plane runs on the management node |
| Holds       | S3 staging, XNAT uploader, observability, the CA | Orthanc, the ingest pipeline                                             |
| Credentials | XNAT, SMTP, S3 admin                             | its own S3 key, its own Loki key, the de-id salt                         |

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
    join: ssh              # ssh | bundle — see §4.1
    sshUser: ubuntu        # join: ssh only
    sshKey: ~/.ssh/id_ed25519
    s3SecretRef: edge-dev-s3
    exposure: sni          # ← use this. No ports to assign.
```

**File:** `sites/<site>/values.yaml`

Each entry produces, automatically: a hosted control plane, an S3 bucket named
`ingest-<name>`, an S3 identity scoped to that bucket, an uploader, and a
reclaimer.

`sshUser`/`sshKey` belong to `join: ssh`, the default: this node pushes the join
to the edge over 22, and `scripts/uninstall.sh` later reaches back the same way
to run `k0s reset` and wipe `/data`. If nothing can dial *into* the site — a
whitelisted-IP allowlist, a VPN, GlobalProtect — set `join: bundle`, omit both
fields entirely, and read §4.1; teardown then has to be finished by hand on the
edge. Either way the bootstrap is a script rather than a chart, because the edge
machine is not a Kubernetes node yet and there is no API path onto it to apply
anything declaratively. Note it is not that the API server appears later: the
edge never has one. Its control plane is hosted *here*, and step 5 creates it
before the worker exists.

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
* **The pseudonym salt must survive reinstalls.** The same patient hashed with a
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
    grouped:        {reclaim: onAssigned}      # no minAge — rejected at render
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

**Every derived rule is `(condition AND minAge)` — both must hold**, with
`grouped` the deliberate exception noted below. A pure age rule would expire a
session that never reached XNAT because a credential was wrong. A pure condition
rule frees nothing the moment the signal breaks.

**`grouped` takes no `minAge`, and setting one fails the render.**
`assign --unlink-source all` deletes each grouped tree at assign time, so a
window measured from assign can never elapse — there is nothing left to wait
on. What
reaches the policy engine is only an *orphan*: a tree assign copied but failed to
unlink (crash, OOM, eviction). Delaying an orphan buys nothing, because its bytes
are still in Orthanc storage and in the facility backup. So the key was removed
rather than defaulted, and `charts/edge` **rejects it at render**
(`charts/edge/templates/_helpers.tpl`) instead of ignoring it — a site file
carrying `minAge` under `grouped` fails `helm upgrade` of the edge chart with an
explanation, which is the loud version of a setting that would otherwise do
nothing. (`charts/mgmt` never reads that key, so the management release renders
either way; step 7 is where you would see it.)

**A fresh install expires nothing.** Run with `dryRun` for a week, read the
decisions in the logs, then enable.

---

## 3. Secrets

Secrets live in git, encrypted. You hold an age keypair; the private half stays
at `~/.config/sops/age/keys.txt` and is never committed, the public half goes in
`.sops.yaml`. Any key listed there can decrypt, which is why adding a colleague
is one command. Only the **values** are encrypted, so `git diff` still shows
*which* secret changed without showing what it changed to.

**One file per machine:** `sites/<name>/secrets.enc.yaml`. They are not
interchangeable — `apply` pushes a whole file into whatever cluster
`KUBECONFIG` points at, so a merged file would put the XNAT account and the S3
admin key on a hospital machine.

> **The file is plaintext until you run `encrypt`.** It is called
> `secrets.enc.yaml` from the moment it is created, which is a promise it has
> not kept yet. Two things catch it: `install.sh` refuses to run against an
> unencrypted secrets file, and `site-secrets.sh check` fails on any committed
> one.

### What goes where

|                        | Management site (one)                                    | Each edge site                        |
| ---------------------- | -------------------------------------------------------- | ------------------------------------- |
| Namespaces             | `ais-mgmt`, `xnat-upload`                                | `xnat-ingest`                         |
| You fill in            | 6 credentials — 7 Secret *documents*, because `seaweedfs-upload` is created twice — plus one `<edge>-s3` per edge | **1 Secret** — the de-id salt         |
| Delivered for you      | —                                                        | CA bundle, Loki client cert, S3 key   |

That last row is the part people get wrong: an edge has **exactly one** secret
you write by hand. Everything else arrives via cert-sync (see "Three secrets you
must NOT create by hand" below).

**Management site** (`sites/example-mgmt/secrets.example.yaml`):

| Secret                        | Namespace                        | Keys                                   | What it is                                                                                                                                                                 | Rotating it needs         |
| ----------------------------- | -------------------------------- | -------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------- |
| `seaweedfs-admin`           | `ais-mgmt`                     | `access-key`, `secret-key`         | full access to the object store                                                                                                                                            | restart SeaweedFS (below) |
| `seaweedfs-upload`          | `xnat-upload` **and** `ais-mgmt` | `access-key`, `secret-key`         | the XNAT uploader + reclaimer's S3 identity —**and** the entry SeaweedFS builds for it in `s3.json`                                                                | restart SeaweedFS         |
| `xnat-credentials`          | `xnat-upload`                  | `server`, `username`, `password` | the XNAT account every site's data is pushed with                                                                                                                          | restart the uploader      |
| `grafana-admin-credentials` | `ais-mgmt`                     | `admin-user`, `admin-password`     | Grafana login                                                                                                                                                              | restart Grafana           |
| `loki-s3-credentials`       | `ais-mgmt`                     | `access-key`, `secret-key`         | Loki's log-chunk storage identity                                                                                                                                          | restart SeaweedFS + Loki  |
| `alertmanager-smtp`         | `ais-mgmt`                     | `username`, `password`             | alert mail. For Gmail this is an**App Password** — a 2FA account rejects the real one with `535 BadCredentials`, and the only symptom is alerts that never arrive | restart Alertmanager      |
| `<edge>-s3` (one per edge)  | `ais-mgmt`                     | `access-key`, `secret-key`         | that edge's bucket-scoped S3 identity                                                                                                                                      | restart SeaweedFS         |

> **`seaweedfs-upload` is one credential in two Secret objects.** The template
> carries it twice — in `xnat-upload`, where the uploader and reclaimer
> *authenticate* with it (`charts/mgmt/templates/xnat-upload.yaml`,
> `s3-staged-reclaimer.yaml`), and in `ais-mgmt`, where the SeaweedFS pod
> projects it alongside `seaweedfs-admin`, `loki-s3-credentials` and each
> `<edge>-s3` to build the `s3.json` identity list that *authorises* that key
> (`charts/mgmt/templates/seaweedfs.yaml`). A pod can only mount a Secret from
> its own namespace and SeaweedFS runs in the release namespace, so both copies
> are required. Drop the `ais-mgmt` one and the install stalls at step 4 with
> SeaweedFS in `Init:0/1` — `MountVolume.SetUp failed … secret
> "seaweedfs-upload" not found` — and every other component healthy.
>
> **Keep the two values identical, and change both when you rotate.** If they
> drift, SeaweedFS authorises one key while the uploader presents another and
> every upload fails with S3 403 — the same symptom as a wrong key, from a file
> where both copies look right in isolation. `make secret-contract`
> (`scripts/ci/secret-namespaces.sh`) checks both the presence and the match.
>
> Two caveats. The `ais-mgmt` copy is only mounted when `xnatUpload.enabled` is
> true; and if an edge sets `edges[].uploadSecretRef`, that name replaces
> `seaweedfs-upload` for *both* readers, so a per-edge upload identity needs the
> same pair of copies under its own name.

**Edge site** (`sites/example-edge/secrets.example.yaml`):

| Secret                | Keys                                  | What it is                                                                                                                              |
| --------------------- | ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `orthanc-deid-salt` | `AIS_DEID_HMAC_SALT` (64 hex chars) | the salt that turns a patient identifier into `${SubjectHash}`. Despite the variable's name this is a salted djb2, NOT an HMAC — see components/deidentification.md, *Pseudonym strength*. **Effectively permanent** — see the rotation warning below |

Everything else in the edge template is commented out and optional (Orthanc
auth, Samba). `s3-edge-credentials` is deliberately absent — see "Three secrets
you must NOT create by hand on an edge" below.

### Step A — once per operator, on a new machine

```bash
scripts/site-secrets.sh init-key
```

Every command tells you what it did and what to do next, so you can follow the
prompts rather than this page. `init-key` prints your **public** key:

```
[site-secrets] created /home/you/.config/sops/age/keys.txt (mode 600)

  PUBLIC key — share this, add it as a recipient:
    age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg8sfn9aqmcac8p
```

**Back that file up to a password manager now.** There is no escrow and no
reset: if every recipient key for a file is lost, the file is gone. Then
register your public half so you can read encrypted files:

```bash
scripts/site-secrets.sh add-recipient age1ql3z7...
```

### Step B — the management site

```bash
scripts/site-secrets.sh new my-deployment mgmt
```

```
[site-secrets] created sites/my-deployment/ from sites/example-mgmt/
  1. edit sites/my-deployment/values.yaml       (non-secret site config)
  2. edit sites/my-deployment/secrets.enc.yaml  (still PLAINTEXT at this point)
  3. scripts/site-secrets.sh encrypt my-deployment   <-- do not commit before this
```

Do exactly those three. Fill in every `REPLACE_` in the secrets file — the six
credentials in the table above, remembering that `seaweedfs-upload` appears
twice and both copies must carry the same value — then encrypt.

### Step C — each edge

Use `add-edge`, not `new`: it generates the S3 key pair instead of making you
invent one and type it into two files that must match. It is the **first of six
steps**, not a replacement for them — you still fill in the salt, and you still
encrypt.

```bash
scripts/site-secrets.sh add-edge my-deployment hospital-a
```

It does three things and then tells you the other five, including the exact
`edges:` block to paste — you do not have to remember any of this:

```
[site-secrets] created sites/hospital-a/ from sites/example-edge/
[site-secrets] appended hospital-a-s3 to sites/my-deployment/secrets.enc.yaml (re-encrypted)

  Still needed by hand:

  1. Fill in sites/hospital-a/values.yaml — the AE-title map, de-identification
     profile and disk paths are facts only you have; nothing generates them.
  2. Fill in sites/hospital-a/secrets.enc.yaml — orthanc-deid-salt still needs
     'openssl rand -hex 32'
  3. Paste this into sites/my-deployment/values.yaml, under 'edges:':

       - name: hospital-a
         nodeIP: "<this edge's IP>"
         sshUser: ubuntu
         sshKey: ~/.ssh/id_ed25519
         s3SecretRef: hospital-a-s3
         exposure: sni

  4. scripts/site-secrets.sh encrypt hospital-a
  5. ./install.sh my-deployment
```

**There is no manual `apply` for an edge.** `install.sh` applies the management
secrets at its step 3 and this edge's into the child cluster at step 7. You only
run `apply` by hand to change a secret on an already-running system.

> **Step 2 is the one that bites — do not skip the salt.** `add-edge` scaffolds
> the edge's secrets from the template, so `orthanc-deid-salt` arrives as the
> literal placeholder `REPLACE_64_HEX_CHARS`. **Nothing rejects that value**: the
> chart checks only that a salt Secret is *named*, never that its contents are
> real. An edge installed with the placeholder starts cleanly and derives every
> `${SubjectHash}` and `${SessionHash}` from a string published in this
> repository.
>
> `encrypt` now catches this — so do not train yourself to click past it. It
> matches only unfilled **values** (`<key>: REPLACE_...` on a line that is not
> commented out), never the templates' own comments, and it names the offending
> keys:
>
> ```
> WARNING: sites/<edge-name>/secrets.enc.yaml has unfilled placeholder VALUES:
>     38:  AIS_DEID_HMAC_SALT: REPLACE_64_HEX_CHARS
>   Encrypt anyway? [y/N]:
> ```
>
> It used to grep the whole file, so it warned on **every** site, correct ones
> included — the templates' comments contain that string, one of them literally
> reading "fill in every REPLACE_" — and an operator who learned to answer `y`
> to the noise would answer `y` to a real one too. That is fixed: a correctly
> filled edge produces no warning at all, so a warning here is always a real
> placeholder. **Never answer `y` to it.** `AIS_DEID_HMAC_SALT` is the only
> uncommented placeholder the edge template ships, so in practice this prompt
> means the salt. Belt and braces before encrypting:
>
> ```bash
> grep AIS_DEID_HMAC_SALT sites/<edge-name>/secrets.enc.yaml   # must NOT say REPLACE_
> ```
>
> `install.sh` runs the same value-only check on the site you name on its
> command line, decrypting to a pipe and never to disk, and refuses to install.
> That covers the **management** site only: an edge's secrets are applied at
> step 7 without a placeholder check, so `encrypt` is the one gate an edge gets.
>
> Treat the salt as permanent once set: rotating it gives the same patient a
> different pseudonym and breaks linkage to everything already in XNAT.

Both `add-edge` and `new` leave the same two things to you deliberately: the
`edges:` block (that file is the most heavily hand-annotated in the repo, and a
generated rewrite would drop every caution comment in it — so the command prints
the block for you to paste), and the salt.

### The everyday loop

| Command            | What it does                                                                                                   |
| ------------------ | -------------------------------------------------------------------------------------------------------------- |
| `view <site>`    | decrypt to stdout, change nothing.**This prints secrets to your terminal** — prefer `edit`            |
| `edit <site>`    | decrypt into`$EDITOR`, re-encrypt on save. The normal way to change a value                                  |
| `encrypt <site>` | encrypt a file that is still plaintext. Warns, naming the keys, if any placeholder**value** is still unfilled, and asks before proceeding    |
| `apply <site>`   | decrypt and`kubectl apply` into the cluster                                                                  |
| `check`          | fails if any**committed** `sites/*/secrets*.yaml` lacks the `sops:` header. Run it before every push |

> **`apply` sends the whole file to whatever `KUBECONFIG` points at.** Applying
> a management file while pointed at an edge would push the XNAT account and the
> S3 admin key onto a hospital machine. Check `kubectl config current-context`
> first. `install.sh` handles this correctly on its own (it applies the edge
> file with `KUBECONFIG` set to that edge's kubeconfig); the risk is a hand-run
> `apply`.

### Rotating a secret, and what must be restarted afterwards

Changing the value is only half of it. **Nothing reloads a Secret it read at
startup**, and none of these restart themselves:

```bash
scripts/site-secrets.sh edit <site>      # change the value
scripts/site-secrets.sh apply <site>     # push it to the cluster
# ...then restart whatever consumes it:
kubectl -n ais-mgmt   rollout restart deploy/mgmt-seaweedfs      # any S3 key
kubectl -n xnat-upload rollout restart deploy/mgmt-upload-<edge> # xnat-credentials
kubectl -n ais-mgmt   rollout restart deploy/mgmt-grafana        # grafana password
```

SeaweedFS is the sharp one: its `s3.json` is assembled by an init container and
read **once** by `weed server -s3.config`. Rotating a key inside an existing
Secret changes no pod spec, so Helm does not roll the pod and the old key keeps
working until something restarts it — see the note in
`charts/mgmt/templates/seaweedfs.yaml`.

> **`orthanc-deid-salt` is not rotatable in practice.** It is the pseudonym salt
> behind `${SubjectHash}` and `${SessionHash}`, so changing it gives every
> future study a *different* pseudonymous PatientID for the same real patient.
> Sessions already in XNAT keep the old hash, and the two can never be linked
> again without the original identifiers. Treat it as permanent per site, and
> back it up with the same care as the age key.

### Turning on Orthanc's REST API authentication

The shipped edge site sets `orthanc.auth.enabled: false`. Orthanc's REST API is
`ClusterIP`-only, so nothing outside the cluster can reach it — but that is an
accident of network placement, not a control. Anything running *inside* the
cluster can call that API, and it can **delete studies**. Turn it on for any
deployment where that matters.

Three keys, all required, because two different things read this Secret:

| Key | Read by | If it is wrong |
| --- | --- | --- |
| `users.json` | Orthanc itself, via `RegisteredUsersFile` | Orthanc fails to start — the file its config points at was never mounted |
| `orthanc-user` | `group-orthanc`, calling the REST API | Orthanc answers 401 and the pipeline stalls with data sitting in Orthanc |
| `orthanc-password` | `group-orthanc` | as above |

`orthanc-user` / `orthanc-password` **must match** the user and password inside
`users.json`. They are separate keys because Orthanc wants a file and
`group-orthanc` wants environment variables; nothing reconciles them for you.

**1. Generate a password and add the Secret.**

```bash
openssl rand -base64 24                       # use this as <password> below
scripts/site-secrets.sh edit <site>           # decrypts to $EDITOR, re-encrypts on save
```

Add this document (the template is already in your `secrets.enc.yaml`, commented
out — uncomment and fill it in):

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: orthanc-credentials
  namespace: xnat-ingest          # the EDGE site's namespace
type: Opaque
stringData:
  users.json: '{"RegisteredUsers":{"admin":"<password>"}}'
  orthanc-user: admin
  orthanc-password: <password>
```

The password is **plaintext inside that JSON** — Orthanc has no hashed-password
format here. That is precisely why this file is SOPS-encrypted before it is
committed, and why `scripts/site-secrets.sh check` refuses a plaintext one.

**2. Turn it on in the site file.**

```yaml
orthanc:
  auth:
    enabled: true
    existingSecret: orthanc-credentials
```

The chart refuses to render if `enabled: true` and `existingSecret` is empty —
the deployment mounts that Secret non-optionally, so an empty name would fail
as a confusing volume error rather than an auth one.

**3. Apply, and restart what reads it.**

```bash
scripts/site-secrets.sh apply <site>
./install.sh <site>
KUBECONFIG=kubeconfig-<edge> kubectl -n xnat-ingest rollout restart deploy/<release>-orthanc
KUBECONFIG=kubeconfig-<edge> kubectl -n xnat-ingest rollout restart deploy/<release>-group-orthanc
```

Both restarts are needed: Kubernetes does not restart a pod when a Secret
changes, and neither Orthanc nor `group-orthanc` re-reads one at runtime.

**4. Verify.**

```bash
# from inside the cluster — should now be 401 without credentials
KUBECONFIG=kubeconfig-<edge> kubectl -n xnat-ingest exec deploy/<release>-orthanc -- \
    curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8042/studies
# and 200 with them
KUBECONFIG=kubeconfig-<edge> kubectl -n xnat-ingest exec deploy/<release>-orthanc -- \
    curl -s -o /dev/null -w '%{http_code}\n' -u admin:<password> http://localhost:8042/studies
```

Then confirm the pipeline still moves: `group-orthanc`'s log should keep
reporting `Found N studies`, not 401s. If it 401s, `orthanc-user` /
`orthanc-password` disagree with `users.json`.

> **Do not expose port 8042 to the host or a NodePort just because auth is now
> on.** `orthanc.expose.http` stays `ClusterIP`. Authentication is a second
> layer here, not a replacement for keeping the API off the network.

### Adding or removing a colleague

```bash
scripts/site-secrets.sh add-recipient age1theirpublickey...
```

This edits `.sops.yaml` only. **Existing encrypted files are not re-encrypted,
so the new key cannot read anything yet** — rotate each file explicitly:

```bash
for f in sites/*/secrets.enc.yaml; do sops updatekeys "$f"; done
```

Removing someone is the mirror image with one caveat that matters: dropping them
from `.sops.yaml` and re-running `updatekeys` stops them reading *future*
versions, but they have already seen the current values. **Removal is only real
once the secrets themselves are rotated** — see the standing gap in §9.

### Three secrets you must NOT create by hand on an edge

`ca-bundle`, `loki-push-client-tls` and `s3-edge-credentials` are written into
each edge cluster by the management side's **cert-sync** CronJob.
`loki-push-client-tls` is this site's mTLS identity for the Loki push endpoint,
and hand-writing it produces a certificate the management CA never signed — the
push is then rejected at the TLS handshake, its logs stop arriving, and the
alerts that would tell you are built from those same logs.

`s3-edge-credentials` is this edge's S3 identity. It is written **once**, on the
management side, as the `<edge>-s3` Secret named by that edge's
`edges[].s3SecretRef`, and cert-sync copies it in under the edge-side name. It
used to live in both files with identical values, and that was the bug: nobody
cares what the key pair *is*, only that the two copies match, so making a human
the consistency mechanism guaranteed eventual drift — surfacing as an S3 403 at
upload with nothing saying which side was wrong. Writing a copy on the edge does
not "also work" either: cert-sync overwrites it on the next run, so the edge
authenticates correctly right up until the credential silently changes underneath
it, which is worse than failing immediately.

<details>
<summary><b>How that is possible when the edge accepts no inbound connection</b>
— background, not needed to set anything up</summary>

This doc says two things that sound contradictory, and the resolution is worth
stating once rather than leaving every reader to work out: the hospital "never
accepts an inbound connection" (§0), yet a **management-side** CronJob "writes
into each edge cluster".

Both are true, because **the edge cluster's control plane does not run on the
edge.** k0smotron hosts it on the management node. Measured on this deployment:

```
mgmt node (stream-2-ab-dev), namespace edge-dev:
  kmc-edge-dev-0        the edge cluster's API server
  kmc-edge-dev-etcd-0   the edge cluster's etcd

the edge child cluster's only node:
  k0s-edge-worker-dev   203.101.230.171   ROLES <none>   worker, no control plane
```

So cert-sync never contacts the facility. It makes a local API call to
`https://kmc-edge-dev.edge-dev.svc.cluster.local:30443` — a ClusterIP Service on
the *management* cluster (`API_ENDPOINT_MODE: inCluster`, see the reasoning in
`charts/mgmt/templates/cert-sync.yaml`) — and the Secret lands in an etcd that is
also on the management node. **The edge then pulls it:** the kubelet on the edge
worker holds an outbound connection to its API server, and fetches the Secret
over the connection it opened. Nothing dials in.

Konnectivity is a separate mechanism and follows the same rule. Its agent runs
*on the edge* and dials *out* (`--proxy-server-host=konnectivity-edge-dev.aisedge.local --proxy-server-port=443`, i.e. `<konnectivityPrefix>-<edge>.<domain.internal>`); it exists so the API server can reach back toward the
node for `kubectl exec`/`logs`/`port-forward`, and even that reverse traffic
rides a tunnel the edge established. Secrets do not use it at all.

The honest consequence, since it is the flip side of the same design: an edge's
etcd — holding that site's Secrets — physically lives on the management node.
Isolation between sites is Kubernetes-level (separate clusters, separate etcd,
separate credentials), not physical. That is inherent to hosted control planes,
and it is the same reason `charts/mgmt/templates/cert-issuers.yaml` states
plainly that a compromised management node already holds the staged imaging, the
XNAT credentials and every child kubeconfig.

</details>

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

There is **no `--set` on either chart.** The management release is
`-f <site values>`; the edge release is `-f <site values> -f <edge values>`. A
flag needed to make an install work is a value that belongs in the site file,
and an install nobody can reproduce from the file alone is not reproducible.

> The installer's single `--set` — `crds.enabled=true`, at `install.sh` step 2 —
> belongs to the pinned cert-manager prerequisite, which is installed outside the
> charts (see the dependency loop under step 2 below) and is not configured from
> the site file at all. `install.sh`'s own header still claims "no `--set`
> anywhere below"; it means the charts.

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

**6 — join the worker** (`scripts/06-join-edge-worker.sh` or `06b-make-bootstrap.sh`)
Writes `/etc/hosts` on the edge, mints a server certificate for the k0smotron
haproxy from the child cluster's CA, and installs k0s as a worker. Then
`scripts/06c-post-join.sh` waits for the node and **rewrites the child cluster's
CoreDNS** so konnectivity can resolve the management hostnames.

Which of the two runs is `edges[].join` — see §4.1 below.

**7 — the edge chart, then seed cert-sync** (`charts/edge`)
Orthanc, the pipeline, the uploader, Vector. Then it runs the cert-sync CronJob
**once, immediately**.

> Without that, the edge waits up to **six hours** for the three Secrets
> cert-sync delivers — the s3-uploader reads `s3-edge-credentials` for its keys
> and mounts `ca-bundle` to trust the S3 endpoint, and Vector mounts
> `loki-push-client-tls`, so neither pod can start at all. The install would
> report success and the site would do nothing until the small hours.

### 4.1 Joining an edge you cannot SSH to — `join: bundle`

Step 6 normally **pushes**: the management node SSHes to the edge. A hospital
behind a whitelisted-IP allowlist, a VPN, or GlobalProtect has no inbound path,
so that cannot work — and it fails *after* the management cluster is built,
which is the worst place to discover it.

Set the mode per edge, in the management site's `edges[]` entry:

```yaml
edges:
  - name: hospital-a
    nodeIP: "10.20.30.40"     # still required — the bundle refuses other machines
    join: bundle              # ssh (default) | bundle
    # sshUser / sshKey are not used and can be omitted entirely
```

**Only the one-time bootstrap changes.** Once joined, the two modes are
identical: the edge dials *out* (konnectivity, and the kubelet to its hosted
control plane) and nothing ever connects into the site. That is the same
property that lets cert-sync deliver Secrets inward without inbound access.

> **`bundle` is not `offline`.** A bundle-joined edge still needs **outbound**
> reachability to the management node on 443, permanently — its control plane
> lives there. An air-gapped machine cannot be a worker in this architecture at
> all. The bundle removes the *inbound* requirement, nothing more.

**What the operator does**

```bash
# on the management node — needs no path to the edge
./install.sh -y <site>
   --- 6/7  hospital-a: bootstrap bundle (no ssh to this edge) ---
     wrote hospital-a-join.sh  (12K)
     token valid until 2026-08-10 16:22 UTC
   waiting for hospital-a to appear in its cluster... (29m left)

# carry hospital-a-join.sh over by whatever route exists, then on the edge:
sudo bash hospital-a-join.sh
   [1/6] preconditions ....................... ok (root, 3 staged files)
   [2/6] /etc/hosts .......................... ok (k0s-hospital-a... -> 10.0.0.1)
   [3/6] reach k0s-hospital-a...:443 ......... ok (HTTP 401)
   [4/6] current join state .................. ok (not joined — will install)
   [5/6] haproxy certs ....................... ok (/etc/haproxy/certs)
   [6/6] k0s worker .......................... ok (installed, kubelet active)

   JOINED — hospital-a is a k0s worker.
```

The installer on the other side notices the node arrive and carries on to
step 7 by itself. If it times out, nothing is lost — re-run it once the edge is
joined and it will pick up where it stopped.

**It is a single plain-text file on purpose.** A tarball needs a binary-safe
channel; an ASCII file also survives a console paste, a ticket attachment or an
email body, and in a locked-down site the console is often the only channel
there is.

**The bundle is a credential.** It carries the join token, which grants cluster
membership. It defends itself:

| Guard | Why |
| --- | --- |
| SHA-256 of its own payload | a truncated console paste is the likeliest failure of this delivery method |
| refuses a machine without `nodeIP` | stops hospital-a's bundle joining hospital-b in a fleet (override: `--any-host`) |
| refuses after the token expires | says "ask for a fresh bundle" instead of failing later as a TLS error |
| shreds the token after use | it belongs in `/etc/k0s/join-token` at 0600, not in `/tmp` |

Tokens are minted with `expiry: 2h` by default
(`scripts/05-setup-edge-cluster.sh:128`). The ssh path consumes one in seconds, so
the bound costs it nothing there.

> **`joinTokenTTL` sets it per edge.** `install.sh` reads it into `EDGE_JOIN_TTL`
> and passes it to step 5, which is where the token is actually minted
> (`scripts/05-setup-edge-cluster.sh:128` reads it, `:139` writes it as the
> Secret's `expiry`). Raise it only for a `join: bundle` edge whose bundle has to
> travel further than the default — a bundle carried to a hospital by hand is the
> case this exists for. It is a BEARER credential: anything holding it can join a
> node, so a longer window is a deliberate decision rather than a convenience.
> `JOIN_TOKEN_TTL=8h ./install.sh <site>` still works as a fleet-wide override for
> a run, and the per-edge value takes precedence over it.
**Re-running is safe and is the repair path.** The join converges rather than
skipping: it rewrites `/etc/hosts` rather than leaving a stale block, and it
asks the API whether this node's identity is still accepted rather than trusting
`systemctl is-active`. A worker holding a credential the control plane has
started refusing is reset and re-joined.

> **Teardown still needs a way in.** `scripts/uninstall.sh` runs `k0s reset` and
> wipes `/data` on the edge over SSH. For a `join: bundle` site it cannot — and
> the same is true of any edge whose entry has no `sshUser`. The cluster-side
> half still happens from here, through `kubeconfig-<edge>`: the edge release,
> its namespaces and its PVs go. Only the machine-level half is skipped, loudly,
> with the commands to run on the edge by hand printed for you. A site removed
> only from the management side leaves patient data on the edge — finish the job
> there.

### What can go wrong

| Symptom                                      | Cause                                                                                |
| -------------------------------------------- | ------------------------------------------------------------------------------------ |
| `conversion webhook … connection refused` | k0smotron operator not ready; cert-manager must come first                           |
| `invalid ownership metadata`               | an object exists without Helm's labels, from a previous non-Helm install             |
| Worker join times out                        | the management node cannot resolve its own child API — check`/etc/hosts`          |
| Edge pods`CreateContainerConfigError`      | a Secret is missing — one of the three cert-sync delivers:`ca-bundle`, `loki-push-client-tls` or `s3-edge-credentials` |

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

Six steps. `add-edge` does three of them for you; the rest are facts only you
have, plus one command you must not skip.

```bash
# 1. generate + scaffold
scripts/site-secrets.sh add-edge <management-site> edge-syd

# 2. the AE-title map, de-identification profile and disk paths
$EDITOR sites/edge-syd/values.yaml

# 3. the de-identification salt — THIS IS NOT OPTIONAL, see the warning below
openssl rand -hex 32                       # paste as AIS_DEID_HMAC_SALT
$EDITOR sites/edge-syd/secrets.enc.yaml    # still PLAINTEXT despite the name

# 4. paste the printed 'edges:' block into the management values.yaml
$EDITOR sites/<management-site>/values.yaml

# 5. encrypt before committing anything
scripts/site-secrets.sh encrypt edge-syd

# 6. install, then prove it worked
./install.sh <management-site>
make verify-live SITE=<management-site>
```

> **Do not skip step 3.** `add-edge` scaffolds
> `sites/edge-syd/secrets.enc.yaml` from the template, so `orthanc-deid-salt`
> arrives as the literal placeholder `REPLACE_64_HEX_CHARS`. Nothing rejects
> it: the chart only checks that a salt Secret is *named*, not that its value
> is real, so the edge installs, Orthanc starts, and every `${SubjectHash}` and
> `${SessionHash}` on that site is derived from a string published in this
> repository. `encrypt` catches it and names the key —
> `WARNING: sites/edge-syd/secrets.enc.yaml has unfilled placeholder VALUES:`
> followed by `38:  AIS_DEID_HMAC_SALT: REPLACE_64_HEX_CHARS` — then asks
> `Encrypt anyway? [y/N]`, and answering `y` there is the whole failure. A
> correctly filled edge produces no warning at all, so a prompt here always
> means a real unfilled value. The salt is also effectively permanent: rotating it later gives the
> same patient a different pseudonym and breaks linkage to everything already
> in XNAT (§3, "Rotating a secret").

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

### 2. Generate its secrets — one command

```bash
scripts/site-secrets.sh add-edge <management-site> edge-syd
```

That generates the S3 key pair, appends the `edge-syd-s3` Secret to the
management site's `secrets.enc.yaml` (decrypting and re-encrypting it if it is
already sealed), and scaffolds `sites/edge-syd/` from `sites/example-edge`.

Then fill in the edge's own site file — the AE-title map, the de-identification
profile, the storage paths — and encrypt it:

```bash
$EDITOR sites/edge-syd/values.yaml
scripts/site-secrets.sh encrypt edge-syd
```

There is **no Loki push credential to add**, and **no S3 credential to write on
the edge**. Both come from the `edges:` entry in step 1: cert-manager issues
`edge-syd-loki-client` from the fleet CA with `CN=edge-syd`, and cert-sync
delivers it into the site alongside the CA bundle and `s3-edge-credentials`.
Writing either by hand on the edge just gets overwritten on the next sync.
Removing the entry and upgrading revokes them.

`add-edge` deliberately leaves **one** thing to you: the `edges:` block in step 1.
That file is the most heavily hand-annotated in the repo and a generated rewrite
would silently drop every caution comment in it, so the command prints the exact
block to paste instead.

<details>
<summary>Doing step 2 by hand (if you cannot run the script)</summary>

`add-edge` is the supported path; this is what it does, for reference or recovery.
Add the Secret to the management site's file:

```bash
scripts/site-secrets.sh edit <management-site>
```

```yaml
# the new edge's S3 identity, in the RELEASE namespace
apiVersion: v1
kind: Secret
metadata: {name: edge-syd-s3, namespace: ais-mgmt}
stringData:
  access-key: "<openssl rand -hex 10>"
  secret-key: "<openssl rand -hex 20>"
```

Then `cp -r sites/example-edge sites/edge-syd`, fill in its `values.yaml`, and
`scripts/site-secrets.sh encrypt edge-syd`. Do **not** add `s3-edge-credentials`
to the edge's own secrets file — cert-sync delivers it from the Secret above.

</details>

### 3. Re-run the installer

```bash
./install.sh <site>
```

It is idempotent. Steps 1–4 no-op on what already exists; the per-edge loop then
runs steps 5–7 for **every** edge, so `edge-dev` is re-verified and `edge-syd` is
built: hosted control plane → child kubeconfig + join token → worker join → edge
chart → cert-sync seeded.

**Step 6 is the one that differs per site.** The loop branches on that edge's
`edges[].join`: the default `ssh` pushes the join from here over 22, while
`bundle` writes a `<edge>-join.sh` for someone to run at the facility and then
waits for the node to appear. A hospital behind a whitelisted-IP allowlist, a VPN
or GlobalProtect — which is exactly the kind of site the second and later entries
tend to be — needs `join: bundle` on the `edges:` entry you pasted in step 1, and
`sshUser`/`sshKey` can be omitted there entirely. §4.1 has the whole procedure,
including the teardown caveat that comes with it.

### What the new site gets automatically

|                         |                                                                     |
| ----------------------- | ------------------------------------------------------------------- |
| Hosted control plane    | `kmc-edge-syd` in namespace `edge-syd`                          |
| S3 bucket               | `ingest-edge-syd` — isolated from every other site               |
| S3 identity             | scoped to that bucket alone                                         |
| Uploader + reclaimer    | `mgmt-upload-edge-syd`, `mgmt-reclaim-edge-syd`                 |
| Ingress hostnames       | `k0s-edge-syd.<domain>`, `konnectivity-edge-syd.<domain>`       |
| Loki push client cert   | `edge-syd-loki-client`, `CN=edge-syd`, issued from the fleet CA |
| CA bundle, client cert + S3 key | all three delivered into the site by cert-sync               |

### Check it landed

```bash
kubectl -n edge-syd get pods                                    # control plane up
kubectl --kubeconfig kubeconfig-edge-syd get nodes              # worker Ready
kubectl --kubeconfig kubeconfig-edge-syd -n xnat-ingest get pods
kubectl --kubeconfig kubeconfig-edge-syd -n xnat-ingest get secret ca-bundle loki-push-client-tls s3-edge-credentials
```

If the edge pods sit in `CreateContainerConfigError`, one of those three has not
arrived yet — `ca-bundle` and `s3-edge-credentials` for the s3-uploader,
`loki-push-client-tls` for Vector. `verify-live` reports them as one line ("all 3
cert-sync Secrets present"), which is the same check. Run cert-sync by hand:

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

## 5c. dataPolicy — what actually deletes, and what it deletes

`dataPolicy` is enforced by the `edge-data-policy` DaemonSet. It attaches to the
VOLUMES rather than to Orthanc, so replacing the de-identifier (AIS-deid) or the
ingest path (Prefect for non-DICOM) does not silently end retention or edge disk
monitoring — the new store declares a stage and inherits both.

### Three switches, and originals need all three

| | `enabled` | `dryRun` | `allowExpiry` | Effect |
|---|---|---|---|---|
| report-only *(default)* | false | true | false | measures only; **both volumes mounted read-only** |
| dry-run | true | true | false | logs every decision, deletes nothing |
| armed | true | **false** | false | reclaims DERIVED stages; facility backup still read-only |
| originals armed | true | **false** | **true** | originals may expire |

The mount is the enforcement, not the script: until all three line up the kernel
refuses the write, so a bug in the engine cannot remove an original.

### What a `retain` duration deletes

The unit is the **top-level entry** under the stage's location. For the facility
backup that tree is `<PatientID>/<StudyUID>/<SOPUID>.dcm`, so the entry is one
PATIENT, and the age used is the **newest file anywhere beneath it**. With
`retain: 30d`:

> **A patient directory whose most recent file is older than 30 days is deleted
> entirely.**

Both halves matter. A patient with any recent activity is fully protected even
if some of their studies are years old — the newest file wins, deliberately. But
when a patient does expire, everything under them goes, **including studies far
older than the window**. This is per-entry expiry, not per-study.

Verified with `retain: 30d` against real files: a patient last touched 31 days
ago was reported `WOULD expire` in dry-run and removed when armed; a patient
holding a 60-day-old study *and* a 2-day-old one was kept in both.

### Derived stages need a condition AND an age — with one exception

`assigned` is reclaimed only when something downstream proves the copy is
reconstructible — the uploader's own fingerprint file — **and** `minAge` has
elapsed. `grouped` is the exception: assign's `--unlink-source all` has already
removed each tree, so the only thing left to reclaim is an orphan assign failed
to unlink, and there is no age to wait out. It runs on the condition alone, and
the chart rejects a `minAge` there at render rather than ignoring it (§2.4).

An unknown condition word keeps rather than deletes, so a typo in values.yaml
cannot authorise removal.

`orthancStorage` is different: Orthanc names files by UUID, so a directory walk
cannot map them to sessions. That stage declares `backend: orthanc-rest` and is
handed to an adapter which asks Orthanc for studies carrying the processed
label. That backend seam is where a future store plugs in.

---

## 6. Observability

Two sources of alerts, deliberately:

* **Prometheus rules** — resources, certificates. `charts/mgmt/files/prometheus-rules/`
* **Loki ruler rules** — the pipeline. `charts/mgmt/files/loki-ruler-rules.yaml`

The pipeline alerts live in the Loki ruler because the management Prometheus
**cannot scrape edge pods** across the one-way konnectivity tunnel, and because
the source of truth is the JSON log event, not a derived metric.

> **The uploader's log schema is a public interface.** `upload_started`,
> `upload_completed` and `upload_failed` are matched by three alert rules in
> `charts/mgmt/files/loki-ruler-rules.yaml` — `XNATUploadFailingForAllSessions`,
> `S3UploaderRetryStorm` and `SessionUploadStalled` — across five match
> expressions, since two of those rules test a started/completed pair. Renaming
> one event disables the corresponding alert *silently*.

```bash
scripts/check-alert-inputs.sh    # asks LIVE Prometheus whether each alert can fire
```

That script exists because three alerts were once found that had never been able
to fire — including certificate expiry, on a fleet whose CA rotation takes weeks.
An alert that cannot fire is worse than no alert: it looks like coverage.

---

## 7. Testing

There are **two** kinds of check here, and they answer different questions.
Neither substitutes for the other.

|                                  | Question                                             | Needs a cluster? |
| -------------------------------- | ---------------------------------------------------- | ---------------- |
| `make ci-fast` / `make ci`   | Is the code and config I am about to deploy correct? | No               |
| `make verify-live SITE=<site>` | Is the thing I already deployed actually working?    | Yes — reads it  |

### 7.1 Verifying an install — `make verify-live`

**Run this straight after `./install.sh`, and any time you are asked "is it
working?"** It is read-only: it creates, patches and deletes nothing.

```bash
make verify-live SITE=stream-2-ab-dev
```

It checks, in order: the management API server and node; every pod in
`ais-mgmt` and `xnat-upload`; the CA certificate and every issued certificate;
the SeaweedFS S3 gateway answering **in-cluster**; then per edge — the hosted
control plane, the child API server, the worker node, the pipeline pods, and
the three Secrets cert-sync delivers; then every CronJob's freshness against
its own schedule; and finally XNAT: reachable, credentials accepted, **and
returning a file listing consistent with its own catalog**.

That last one exists because of a real fault. On 2026-08-09 XNAT began
answering `200` with `file_count: 1` and an empty file list. Every pod stayed
green, the reclaimer completed normally, and no alert fired — it simply could
not confirm any delivery, and a critical alert was silently armed to fire two
days later against sessions that were perfectly healthy. Nothing in this repo
would have told you. Now `verify-live` says so in one line.

Read the output carefully in one respect:

> **`SKIP` is not `PASS`.** Skips are counted and listed separately under
> `NOT CHECKED`. A missing kubeconfig, an unreachable edge or an absent tool
> produces a skip, and the whole point is that it must never read as green.

Exit status is `0` only when nothing failed, so it drops straight into a
smoke-test or a cron.

### 7.2 Checking the code — `make ci`

```bash
make ci-fast     # no cluster needed
make ci          # adds the three stages that need docker
```

Thirteen stages; `ci-fast` runs ten of them, skipping the three that need docker
— `loki-rules` (evaluates the real rules against the pinned Loki), `data-policy`
(runs the real engine under the image the chart ships) and `greenfield` (a
kind-based install from nothing). Each of those skips loudly rather than
silently, so a run without docker never reads as a full pass. Three of the ten
are worth explaining:

**`reclaimer`** — 31 cases that assert on **what was deleted**, not on log text.
A run that logs `reclaim_kept` and issues a DELETE anyway passes a log-only test
and fails this one. Its `aws` and `curl` are stubbed and **fail by default** for
anything a case does not explicitly configure, because a stub that invented a
plausible success would test the opposite of the property that matters.

**`secret-contract`** — renders both charts and fails if any mounted Secret is
absent, in the wrong namespace, or missing a key. A wrong namespace and a missing
key fail *identically and silently* at runtime.

**`values-consumers`** — fails if a `dataPolicy` key declares operator policy
that **nothing implements**. Helm never warns about a value nobody reads, so
such a key renders green and silently does nothing. An audit found 14 of that
block's 26 leaf keys had no reader — four of them printed to the operator by
`NOTES.txt` after every install as though they were in force. Those 14 are
listed as tracked debt in `scripts/ci/values-consumers.sh`; the stage fails on
any *new* one, and also if a listed key gains a reader, so the list cannot
quietly become a permanent exemption.

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
`k0s reset` on both machines — **unless the edge is `join: bundle`**, or its
`edges:` entry has no `sshUser`, because then there is no inbound SSH path from
the management node. In that case `scripts/uninstall.sh` still removes the edge's
Helm release, its namespaces and its PVs through `kubeconfig-<edge>` — that half
runs from here, over the hosted control plane — but the machine-level half,
`k0s reset` and `/data` and the `/etc/hosts` marker, is skipped with a loud
warning and a printed block of commands to run at the site. See §4.1.

It requires you to type the site name, because it deletes `/data` — the facility
backup. It never deletes your age key or your site files. On a `join: bundle`
edge that `/data` deletion is precisely the part that does *not* happen from
here: until someone runs the printed commands on the edge, the facility backup —
patient data — is still sitting on that machine.

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

**2. The uploader caches XNAT state across a `--loop` lifetime.** `xnat-ingest upload --loop` opens one XNAT connection and xnatpy caches the
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
  have opened new surface while closing old. The chart passes
  `-s3.port.iceberg=0` (`charts/mgmt/templates/seaweedfs.yaml`), and it is now
  the only place SeaweedFS is deployed: the legacy `manifests/` copy and
  `scripts/03-deploy-seaweedfs.sh` were deleted when the install moved into the
  chart, leaving `manifests/01-management/edge-cluster.yaml.tpl` as the sole
  surviving manifest. Nothing here speaks Iceberg.
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

**9. Four alert rules were removed, not fixed, because a fix would have
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

The other two, `EdgePodCrashLoop` and `KonnectivityTunnelFlapping`, were
Prometheus rules that named child-cluster objects — `namespace="xnat-ingest"`
and `pod=~"konnectivity-agent-.*"` in `kube-system` — that mgmt Prometheus
cannot see: `EdgePodCrashLoop`'s namespace has zero series on mgmt because it
does not exist there at all, and konnectivity-agent runs on the edge's own
kube-system, not mgmt's. Confirmed live: `count(kube_pod_info) by (namespace)`
on mgmt Prometheus lists `k0smotron`, `ais-mgmt`, `cert-manager`, `edge-dev`
(the k0smotron CONTROL-PLANE namespace on mgmt, not the child cluster's own
namespaces), `kube-system`, `local-path-storage`, `xnat-upload` — no
`xnat-ingest`, ever. Same root cause as the two Loki-side removals had before
mTLS: this class of signal cannot cross the one-way konnectivity tunnel, only
now it is metrics rather than logs, and there is no remote-write path to fix
it with.

While investigating `KonnectivityTunnelFlapping`, edge Vector's own log
stream showed the live tunnel actively cycling — `"no servers connected"`,
`"authentication handshake failed: EOF"`, roughly every 10s — while the
container's own restart count stayed at 0 (the process reconnects
internally rather than crashing, which is also why the deleted metric-based
rule could never have caught this even if mgmt could see it). Every
`kubectl` command in this session against that same edge worked throughout,
so this reads as background reconnection churn rather than an outage, but
it was not investigated further given the volume of other work in progress.
If it recurs: `kubectl -n kube-system logs -l k8s-app=konnectivity-agent`
on the edge child cluster, and consider a Loki-side rule — those logs
already reach Loki with a correct `cluster` label via Vector, unlike the
dead Prometheus approach.

All four are recorded in `docs/alerting-architecture.md` and
`docs/components/xnat-ingest.md` rather than silently dropped. None of the
gaps are currently covered by another rule: `SessionStagedNotConfirmedInXNAT`
is
the closest existing backstop for the XNATBacklogGrowing case, but fires only
after `minAge` + the confirmation offset, not on rate.

**10. cert-sync has failed one scheduled run out of three observed, on a TLS
error, and self-healed on the next one without intervention.** Its job
history for `edge-dev`: succeeded 14h ago, failed 8h ago, succeeded again
146m ago — no hand-created job in between. The failure was
`x509: certificate is valid for kubernetes, ..., kmc-edge-dev-nodeport...`
while dialing `https://kmc-edge-dev.edge-dev.svc.cluster.local:30443` — the
control-plane API's serving certificate did not carry that in-cluster
Service DNS name as a SAN at that moment. The following run, same URL, same
pod, connected and reported `sync_unchanged` for all three secrets, meaning
the SAN was present again. Read as a transient window around k0smotron
reconciling the API server's serving certificate rather than a standing
misconfiguration — nothing here forces the SAN list, so a reconcile pass
that briefly regenerates it without the Service name would look exactly like
this. Not chased further: it self-corrects on the existing 6-hour cadence,
and `CreateContainerConfigError` on the edge (§5b, "Check it landed") is the
symptom if it ever does not. If it recurs on every run rather than one in
three, check whether the k0smotron `Cluster` spec's API server
`extraArgs`/SAN configuration actually includes the in-cluster Service DNS
name, rather than assuming it always will.

**11. The full pipeline was run end-to-end with a synthetic DICOM drop, and
it works.** `storescu` against `edge-orthanc:4242` with AE title `AISEDGE` →
synchronous de-identification (`PatientIdentityRemoved: YES`, name/ID/
accession replaced per the profile) → `group-orthanc` labels it within one
60s pass → `assign` stages it under the mapped project within the next →
`edge-s3-uploader` uploads it to `s3://ingest-edge-dev/staged/` once past
the 5-minute settle guard → `mgmt-upload-edge-dev` picks it up on its own
60s poll and lands it in XNAT (`test_project`), confirmed both by the
`Successfully uploaded all files` line and by checking XNAT directly.
Two things surfaced along the way, neither in the plumbing:

- A first attempt used `Modality: OT` (Other), which XNAT's session-type
  mapping does not support. The uploader does not quarantine a permanently
  invalid session — it retried the same `unsupported modalities` error
  every 60s, forever. Not a bug in this repo's charts; recorded because it
  is a real gap in `xnat-ingest` itself. Re-run with `Modality: MR` to get
  a clean pass. The poison-pill session was cleaned up afterward: deleted
  from S3 staging through the SeaweedFS filer (`docs/components/ seaweedfs.md`, "Deletion must go through the filer"), not `aws s3 rm`.
- The re-run's success also triggered a real, correctly-firing
  `XNATAuthFailure` — a genuine one-time 401 from an expired XNAT session
  token mid-loop, self-healed by `xnat-ingest`'s own reconnect logic one
  cycle later, confirmed resolved in Alertmanager within minutes. Worth
  recording only because it is easy to mistake for the tqdm-progress-bar
  false positive fixed earlier this session (`charts/mgmt/files/ loki-ruler-rules.yaml`, `XNATAuthFailure` comment) — it is not that; the
  fix for that bug held throughout this test (no progress-bar line ever
  matched), and this was a different, real event. A third, previously
  unknown finding came out of the same run: a benign ERROR-level checksum
  mismatch that `xnat-ingest` re-logs every loop for several minutes after
  a session first lands, before XNAT's own catalog catches up — see
  `docs/components/xnat-ingest.md`, "Known upstream defects" §3.

**12. LIVE AND UNALERTED as of 2026-08-10: XNAT lists zero files for a
resource it says holds one, so nothing has been confirmed since
2026-08-09 11:17:50Z.** Measured directly against the server:

```
GET /data/experiments/XNAT_E00065/scans/ALL/resources -> file_count "1", file_size "1400", label DICOM
GET /data/experiments/XNAT_E00065/scans/ALL/files?format=json -> HTTP 200, "Result":[]   <-- EMPTY
```

XNAT reports the resource holds one 1400-byte file and then lists none.
`reclaim-staged.sh` reads exactly that endpoint, correctly treats an empty
`Result` as "cannot tell", and logs `reclaim_kept` / `xnat_count_unavailable`
rather than deleting — the fail-safe direction, working as designed. This is
an XNAT-side regression, not a fault in this repo: it worked until
2026-08-09 11:17:50Z, whose `reclaim_confirmed` carried `"have":1`.

**The consequence is a scheduled false alarm.** The second half of
`SessionStagedNotConfirmedInXNAT` is `reclaim_confirmed [72h]`. With the last
one at 2026-08-09 11:17:50Z that window empties at **2026-08-12 11:17:50Z**,
and the rule then fires **critical** on both sessions — including
`test_project.BAD8D5A4B895.0CCF48EA26CC`, which is genuinely in XNAT and
healthy. It will read as data loss for data that is present.

Note which alert does *not* cover this: `ReclaimerRunUnavailable` stays quiet,
because the runs complete normally — they just cannot confirm anything. The
absence alert is doing its job; the input it depends on has gone bad.

Check whether it is still happening before assuming the 08-12 pages are real:

```bash
kubectl -n xnat-upload logs -l component=s3-reclaimer --tail=50 | grep -c xnat_count_unavailable
```
