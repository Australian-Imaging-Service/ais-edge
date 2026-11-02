# A guided tour of this repository (tier-1, single node)

This is for the person who has been handed one Ubuntu machine and told to make
medical images arrive in XNAT. It assumes you know Linux and can read YAML. It
does **not** assume you know Kubernetes, Helm, Orthanc or DICOM, and it explains
every decision it asks you to make rather than listing the keys and wishing you
luck.

Read sections 0–3 before you touch anything. Section 3 (secrets) and section 2.3
(de-identification) are the two that are expensive to get wrong: one of them
loses you the ability to decrypt your own configuration, and the other one sends
identifiable patient data to a research archive.

> **Which tier am I?** If you have one machine that both receives DICOM and
> pushes to XNAT, you are tier-1 and this is your document. If you have a
> management server plus one or more hospital edge boxes, you are tier-2 — use
> the `main` branch and its own `docs/TOUR.md`. The two are different enough
> that following the wrong one wastes a day.

---

## 0. The shape of the thing, in one paragraph

A modality (a scanner, or a PACS forwarding on its behalf) sends DICOM over the
network to this machine, using the DICOM protocol's own transfer verb, C-STORE.
Orthanc receives and stores the input. xnat-ingest then groups the instances,
assigns the XNAT project, subject and session labels, and applies the site
de-identification recipe. Only the resulting output is sent to XNAT over HTTPS.
Assignment happens before de-identification, so source labels need their own
review. A recipe cannot remove an identifier already copied into an XNAT label. The
original, still-identifiable copy is written once to a *facility backup*
directory on this machine and never leaves it. Everything runs as containers on
a single-node Kubernetes cluster (k0s) that the installer sets up for you, and
the whole configuration lives in one YAML file that you write.

That is the entire system. There is no second machine.

---

## 1. One machine, one chart, one directory

Tier-2 has two kinds of machine and therefore two Helm charts and a directory
per machine. Tier-1 has one of each, and that shapes everything below.

```
sites/
  example-single/          <- the template; copy it, don't edit it
    values.yaml            <- everything non-secret
    secrets.example.yaml   <- the four secrets you must fill in
  my-hospital/             <- yours, created by `site-secrets.sh new`
    values.yaml
    secrets.enc.yaml       <- SOPS-encrypted; safe to commit
charts/
  edge/                    <- the chart. You do not edit this.
```

### The files you edit

**`sites/<site>/values.yaml`** — the whole non-secret configuration: where data
lives on disk, which source tags supply XNAT labels, the de-identification
recipe, retention policy, and whether observability is on. This is the file you
will spend your time in.

**`sites/<site>/secrets.enc.yaml`** — four Kubernetes Secrets: XNAT credentials,
the backup-script startup salt, the Grafana login, and SMTP for alert email.
Add the reid encryption Secret when setting `reidEncryptKeySecret`. The example
file is plaintext while you write it and encrypted before commit. See section 3.

That is all. There is no `config/management.env`, no separate JSON config files,
and nothing to edit under `charts/`.

### How Helm combines them

`charts/edge/values.yaml` holds the defaults and, more usefully, the reasoning
behind them — it is worth reading as documentation even though you never edit
it. Your site file is layered on top:

```
helm upgrade --install <site> charts/edge -f sites/<site>/values.yaml
```

Helm merges maps key by key, so you only state what differs from the default.
One consequence catches people out: **lists are replaced wholesale, not merged.**
Override `orthanc.plugins` to add one plugin and you have not added it — you
have replaced all four chart defaults, and the DicomWeb and GDCM plugins stop
loading. Restate the entries you still want alongside the new one.

Recipes are a map under `ingest.deidentify.specs`. Each key is a project/format
path and each value is the complete recipe text for that path. For example,
`__default__/medimage/dicom-series` supplies the fallback DICOM-series recipe.
Overriding that key replaces its full text. It does not append removal rules to
the previous recipe. Read the merged result before installing.

A project-specific recipe is a separate key. Do not assume it inherits the
fallback recipe's removals. Verify every project recipe, including private tags
and date handling. The chart checks that a source exists; it cannot determine
whether the source is a suitable policy for the actual modality data.

The example site keeps legacy profile values for compatibility, but they are
inactive with the ingest selector. Do not edit those values expecting an ingest
policy change. Edit `ingest.deidentify.specs`, review it, and confirm the
rendered deidentify workload mounts the intended recipe ConfigMap.

A second consequence matters for observability and is called out again in
section 6: **Helm cannot template subchart values.** Loki, Prometheus, Grafana
and Alertmanager are subcharts. A parent key cannot push a value into them, so
there is no friendly `observability.stack.retention` key that forwards to Loki —
such a key would be read, trusted, and silently ignored. To change subchart
settings you override the subchart's own block from your site file:

```yaml
kube-prometheus-stack:
  grafana:
    service:
      nodePort: 31000
```

---

## 2. Before you install: what you must decide

Five decisions. Take them in order; later ones depend on earlier ones.

### 2.1 Where things live

```yaml
storage:
  storageClass:
    create: true
    name: hostpath-pipeline
  pipeline:
    hostPath: /data/xnat-ingest
    capacity: 500Gi
  facilityBackup:
    enabled: true
    hostPath: /data/facility-backup
    capacity: 500Gi
```

**Only the pipeline directories must share a filesystem for hardlinks.**
`orthanc-storage`, `grouped`, `assigned` and the later stage directories live
under `storage.pipeline.hostPath`. A hardlink is a second name for the same
bytes. It cannot cross a filesystem boundary. Keeping these directories together
avoids a full copy when a stage uses `hardlink_or_copy`. Splitting them can cause
copy-mode failures or a costly copy fallback, depending on the selected mode.

The facility backup is different. The receiver writes a byte copy to
`storage.facilityBackup.hostPath`; it does not hardlink from that volume into
the pipeline. The backup can be on a separate disk. Separate filesystems can
also keep a full pipeline volume from consuming the backup's free space.
Monitor both filesystems. The verifier reports a separate backup filesystem as
a skip of its same-device comparison, not as a failed hardlink requirement.

`capacity` is the size of the PersistentVolume the chart creates. It is a
bookkeeping number for Kubernetes, not a quota — the host path can and will fill
past it. Size the actual filesystem for the workload, and see `EdgeDiskLow` in
section 6, which is the only disk-exhaustion warning you get.

**The facility backup is the archive of record.** It holds the originals, with
real patient identifiers, written before de-identification. On tier-2 there is a
management plane holding staged copies; on tier-1 there is nothing else. It is
a retained original copy. Identifiable data also exists in Orthanc, grouped and
assigned storage before deidentify runs, and in the reid maps. The uninstall
script deletes the facility backup along with the pipeline data. Back
it up by whatever means your institution requires — this repository does not do
it for you.

### 2.2 The node, and how modalities reach it

```yaml
clusterLabel: tier1-example       # appears on every log line, metric and alert
namespace: xnat-ingest            # all workloads live here
topology: onprem
installMode: fresh                # or `existing` if k0s already runs here
nodeIP: "10.0.0.1"                # this machine's address
```

`nodeIP` is used for the DICOM endpoint and the Grafana URL the installer
prints. It is **not** used for cluster networking — that is all local to the
box — so getting it wrong produces a misleading printout rather than a broken
cluster, which is worse in its own way. Use the address the modality will
actually reach.

Modalities C-STORE to **`<nodeIP>:4242`** with the AE title you set in
`orthanc.aet` (default `AISEDGE`). Whatever sits in front of this machine —
firewall, VLAN, hospital network team — needs to allow that port from the
scanners and nothing else. `topology: onprem` means the machine resolves XNAT by
its real DNS name through the node's normal resolver; there are no management
hostnames to pin, so no `/etc/hosts` entries and no `hostAliases`.

Choose a site directory name with lowercase letters, digits and hyphens,
starting with a letter and ending with a letter or digit. The installer uses it
as the Helm release name and object-name prefix. Do not use an underscore.
A `clusterLabel` is a separate label and does not change the release name.

`installMode: fresh` lets the installer install k0s, kubectl, helm and the
local-path provisioner from nothing. Use `existing` only if a cluster is already
running here, in which case the installer verifies instead of building.

### 2.3 De-identification — the one you must actually read

This is the section where a mistake sends identifiable data to a research
archive. Nothing downstream re-checks what was removed: the uploader trusts that
whatever reaches it is already de-identified.

Use **`deid.engine: ingest` for every new site**. It is already the default.
Orthanc remains the DICOM receiver on port 4242. With the facility backup
enabled, its Lua callback writes the original and returns before the AET lookup.
It does not route by AE title, quarantine unknown AETs or modify the instance.
The xnat-ingest `deidentify` stage cleans the data after `assign`.

`deid.engine: orthanc` is deprecated. Existing-engine reference material is in
[Deprecated Orthanc Lua engine](components/deidentification.md#deprecated-orthanc-lua-engine).
There is no engine-switch checklist for a new site. Keep ingest and make the
following site decisions explicitly.

**First, choose the XNAT labels.** `ingest.assign.tagMapping` names the DICOM
tags whose values become project, subject and session IDs. Empty mapping fields
are derived by the chart. Under ingest they are StudyID, PatientID and
AccessionNumber. The example site sets this same triple explicitly.

```yaml
deid:
  engine: ingest
  policyReviewed: false

ingest:
  assign:
    tagMapping:
      project: StudyID
      subject: PatientID
      session: AccessionNumber
```

This is an example of the mapping, not a guarantee about your data. PatientID
often contains a hospital MRN. If you select it as `subject`, that MRN becomes
the XNAT subject label in clear text. The recipe runs later and cannot change
that label. The same problem can apply to a clinical accession used for the
session label. Arrange approved research identifiers at the source and select
the supported tags that carry them.

For a single-project site, `ingest.assign.constantProjectId` sends all sessions
to one project. It replaces only project resolution. Subject and session still
need valid source values. Create the project in XNAT first. Scope the upload
account to the projects the site can select, rather than to entries in an unused
AET map. The receiver's called AE title is its DICOM address, not the project ID.

Inspect a representative input with the source owner. Do this locally; do not
paste patient tag values into a public issue or an unprotected log:

```bash
# Inspect these defaults, or the three tags selected by your site.
dcmdump file.dcm | grep -E '(StudyID|PatientID|AccessionNumber)'
```

An absent or empty required label causes assignment to put the session under
`assigned/__invalid__`. This input is still identifiable. Later stages do not
process the invalid holding directory automatically. Correct the source mapping
and use the guarded recovery instructions in the xnat-ingest component guide.
The chart rejects tagMapping values that start with `ClinicalTrial` in ingest
mode. It cannot inspect the values that a supported source tag will contain.

**Second, review the recipe itself.** `ingest.deidentify.specs` is a map whose
key is a project/format path. For DICOM series the key is
`<PROJECT_ID or __default__>/medimage/dicom-series`. The value is a pydicom
`deid` recipe. Use the complete example from the site template as a starting
point; a short fragment copied from a command example is not a full policy.

Only named fields change. The example removes direct identifiers, care-team
fields and selected device/order fields. It adds `PatientIdentityRemoved` and
`DeidentificationMethod` to mark the result. Those markers describe the policy;
they do not prove that every identifying field or pixel annotation is gone.

The example leaves private tags in place because they can contain reconstruction
parameters. They can also contain scheduling references and free text. Review
the actual private blocks from each modality. PatientSex and PatientAge also
remain by deliberate example-policy choice. Decide whether the destination may
receive them; do not inherit that decision without checking it.

The example removes PatientBirthDate. The recipe language also supports `JITTER`
with a day offset. A fixed offset is not independent randomisation per patient.
If a site uses it, review related dates together so computed ages and visit
intervals do not change unintentionally. The shipped recipe has no hash transform
and does not create subject or session pseudonyms.

**Third, protect the re-identification map.** The chart always passes
`--reid-dir /data/reid`. Without a key reference, the stage writes plain JSON
that links original and changed metadata. Configure
`ingest.deidentify.reidEncryptKeySecret` with a Secret that contains
`XINGEST_REID_ENCRYPT_KEY`. The key is a URL-safe base64-encoded 32-byte Fernet
key. Keep recovery material separately from the volume that holds the maps.
The component guide gives the exact setup. This setting encrypts new maps;
it does not migrate old plaintext files automatically.

Do not confuse that key with `AIS_DEID_HMAC_SALT`. The latter is still required
by the backup Lua script at startup and by the installation checks. Its value
does not affect the ingest recipe or assigned labels. Section 3 explains why it
still appears in the site secrets and how to set the placeholder.

**`policyReviewed` is a gate, not a formality.** Set it to true only after
reviewing the mapping, recipe, retained fields and reid-map handling. It is a
top-level key under `deid`, not an Orthanc setting. A successful render proves
that the configuration passed its guards. It does not prove that incoming
studies have suitable labels or that the policy matches your institutional
requirements.

Before admitting patient traffic, send a synthetic study with known labels and
known header values. Check the original backup, assigned labels, deidentified
files, mapping encryption and XNAT destination. Confirm that the output is the
one the uploader reads. For the default pipeline this is `/data/deidentified`;
with packaging enabled it is `/data/packaged`. Retain the input while resolving
any discrepancy. [choosing-a-deid-engine.md](choosing-a-deid-engine.md) explains
the two source-label situations without changing this default engine.

### 2.4 Data policy — what is kept, for how long

```yaml
dataPolicy:
  enabled: false
  dryRun: true
```

**Nothing expires on a fresh install, and that is the right default.** Run with
`enabled: false` for a week. Then set `enabled: true` with `dryRun: true`, which
makes the policy engine log every decision it *would* take without taking any,
and read those logs. Only then turn `dryRun` off.

The policy separates *originals* from *derived* data, and the distinction is the
whole point:

- **Originals**: the facility backup and any enabled file-drop input. The
  backup defaults to `retain: forever`; file drops default to `reclaim: never`.
  A legacy quarantine can remain on disk, but ingest does not create unknown-AET
  quarantine entries. Preserve it until an operator resolves its contents.
- **Derived data**: Orthanc storage, grouped, assigned and deidentified output.
  The first three can still contain patient information. Reclaim conditions
  follow progress: `onGrouped`, `onAssigned`, `onDeidentified`, then
  `onUploaded`. Optional packaging adds `onPackaged` before the final upload
  condition. These stage handoffs do not all depend on `dataPolicy.enabled`;
  inspect the selected reclaim settings and rendered `--unlink-source` flags.

On tier-1 this matters **more** than on tier-2, not less. This node holds the
only copy of the facility backup, there is no management-side reclaimer to fall
back on, and `EdgeDiskLow` is the only disk-exhaustion alert in the system.

**Who actually deletes the last tree, and why it needs its own component.**
`upload` never removes what it delivered. That is deliberate: an HTTP 200 is not
proof a study is safely in XNAT, and the uploaded copy is the last one on the
node. Retiring it is the data policy's job, and the condition it waits for is
`onUploaded`.

On tier-2 that condition is satisfied by the s3-uploader's marker. **This tier
has no s3-uploader**, so nothing would ever write it, and for a long time nothing
did: the condition could not come true, the tree was kept for ever, and the
uploader re-sent the same session every loop while XNAT answered *"already exists
with different checksums"*. A `staged-reclaimer` CronJob now closes that. It runs
hourly. For each resource of a session it finds every local file in XNAT's file
listing and checks it with a HEAD request: present, with the same size (no
download, so content is not compared). It removes only the files it proved, inside
the upload-tree writer lock, and keeps everything it cannot prove.

Two consequences worth knowing before you change anything here:

- **Which tree it watches depends on the de-identification engine.**
  `/data/deidentified` under ingest, and `/data/packaged` when the optional
  package stage is on (its
  zips are proved under their folder label, `DICOM-zip`). The chart derives
  that, and refuses a combination where the reclaim
  condition could never be satisfied rather than letting the policy read as
  though it were cleaning something.
- **`dataPolicy.enabled: false` leaves it inert.** The CronJob still renders, but
  with `DRY_RUN` set: it reports what it would remove and removes nothing. A site
  that never turns the data policy on will fill up, and the alert for it fires
  long after the uploader has started looping.
- **It deletes only inside the writer lock.** The stage that writes the tree
  holds `/data/.locks/<tree>.lock` for each pass, and the CronJob takes the same
  lock to delete. The first upgrade to this check, and any rollback to a release
  without the lock, need the drain in
  [xnat-ingest.md, "Upgrade or roll back while the cleanup can delete"](components/xnat-ingest.md).

`dataPolicy.derived.stagedReclaimer` in the site file controls its schedule, its
minimum age (counted from when the newest file reached the tree), whether it
verifies against XNAT (with `false` it removes nothing), and how many sessions one
run may remove.

`minFreeDiskPercent: 10` and `quarantine.alertAfter: 24h` are read by the
alerting rules as well as the policy engine, so changing them changes when you
get paged. That wiring is checked by the test suite.

---

## 3. Secrets

Four Secrets, one encrypted file, and one key you must not lose.

The charts never contain credentials — they reference Secrets *by name*. So the
entire integration is: create the Secrets in the cluster, then run Helm. There
is no helm-secrets plugin, no decrypt-to-tempfile, and plaintext never touches
disk during an install.

Encryption is [SOPS](https://github.com/getsops/sops) with
[age](https://github.com/FiloSottile/age) keys. SOPS encrypts *values* and
leaves *keys* readable, so an encrypted file still diffs sensibly in git and you
can see that `xnat-credentials` has a `password` without seeing the password.

### What goes where

| Secret | Holds | Consumed by |
| --- | --- | --- |
| `xnat-credentials` | `server`, `username`, `password` | the upload stage |
| `orthanc-deid-salt` | `AIS_DEID_HMAC_SALT`, 64 hex chars | Orthanc backup-script startup check; its value is unused for ingest de-identification |
| `grafana-admin-credentials` | `admin-user`, `admin-password` | Grafana |
| `alertmanager-smtp` | `username`, `password` | Alertmanager, for alert email |

The last two are needed whenever **`observability.stack.enabled`** is true — not
`observability.enabled`, which only decides whether Vector runs. The two
switches are orthogonal on purpose (§6), so a site that ships logs off-box needs
neither Secret, and a site that hosts the stack without Vector needs both.

`alertmanager-smtp` must exist even before you configure any SMTP server. The
chart names it in `kube-prometheus-stack.alertmanager.alertmanagerSpec.secrets`,
and the operator mounts it as an ordinary, non-optional volume — a missing
Secret leaves Alertmanager stuck in `ContainerCreating` with `FailedMount`, not
running-but-silent. `grafana-admin-credentials` is read as an env `secretKeyRef`
instead, so its absence surfaces differently: `CreateContainerConfigError` on
the Grafana pod. Neither failure mentions observability, which is why they are
worth recognising by shape.

### Step A — once per operator, on a new machine

```bash
scripts/site-secrets.sh init-key
```

This creates your age key at `~/.config/sops/age/keys.txt` and prints your
**public** key. Its private key can decrypt files encrypted to that recipient. Other configured
recipients can also decrypt their copies. It is not automatically a recipient
of every existing site file.

> **If all usable recipient keys are lost, the encrypted file cannot be
> recovered through SOPS.** Another retained recipient key can still decrypt it. Back
> it up somewhere that is not this machine, before you encrypt anything.
> `scripts/uninstall.sh` deliberately does not delete it.

### Step B — the site

```bash
scripts/site-secrets.sh new my-hospital single   # single selects example-single/
$EDITOR sites/my-hospital/values.yaml            # section 2
$EDITOR sites/my-hospital/secrets.enc.yaml       # STILL PLAINTEXT at this point
scripts/site-secrets.sh encrypt my-hospital      # do not commit before this
```

`single` is the template role, not part of the site name. It is the only role
on tier-1 and copies `sites/example-single`. Use a valid Helm release name for
`my-hospital`: lowercase letters, digits and hyphens, beginning with a letter.

Set the salt placeholder once, as the installer and verifier require:

```bash
openssl rand -hex 32
```

`scripts/site-secrets.sh check` verifies that no plaintext secret is staged, and
runs in CI as well, so a forgotten `encrypt` fails the build rather than landing
in history.

### The everyday loop

```bash
scripts/site-secrets.sh edit my-hospital   # decrypt to $EDITOR, re-encrypt on save
scripts/site-secrets.sh view my-hospital   # print decrypted — careful, it is your terminal
scripts/site-secrets.sh apply my-hospital  # decrypt straight into the cluster
```

Use `edit` for an existing encrypted file. SOPS opens decrypted content in the
editor, which can use temporary or swap files. Use a trusted machine and editor
settings suitable for secrets. The `apply` path decrypts through a pipe rather
than writing a plaintext manifest into the repository.

### Rotating a secret, and what must be restarted afterwards

Kubernetes does not restart a pod when a Secret changes, and neither Orthanc nor
the uploader re-reads one at runtime. Rotation is two steps, and skipping the
second leaves you running on the old value while the file says otherwise:

```bash
scripts/site-secrets.sh edit my-hospital
scripts/site-secrets.sh apply my-hospital
# ...then restart whatever consumes it:
kubectl -n xnat-ingest rollout restart deploy/<the consumer>
```

### Pointing the uploader at another XNAT

The XNAT URL, account and password live in one Secret, `xnat-credentials` in
`xnat-ingest`, with the keys `server`, `username` and `password`
(`upload.direct.existingSecret`). Two things read it: the uploader
`<release>-upload` and the staged-reclaimer CronJob. The Secret is defined in
the site's `sites/<site>/secrets.enc.yaml`.

Work in the deploy checkout on the node, as the operator whose age key is a
recipient of that file:

```bash
cd ~/ais-edge
scripts/site-secrets.sh edit <site>           # sops: decrypts into $EDITOR only
```

Change the three values of the `xnat-credentials` document and save:

```yaml
kind: Secret
metadata:
  name: xnat-credentials
  namespace: xnat-ingest
type: Opaque
stringData:
  server: https://xnat.example.org     # the new XNAT, with the scheme
  username: <account>
  password: <password>
```

The `username` and `password` can also be an XNAT alias token: put the alias in
`username` and its secret in `password`. XNAT accepts the pair as a login, and
the uploader and the reclaimer send it unchanged. An alias token expires, by
default two days after creation; the uploader then gets 401 on every pass and
`XNATAuthFailure` fires. Use a token with a long life, or plan the rotation.

SOPS re-encrypts the site file on save. The editor can still use temporary files.
If nothing changed,
sops says `File has not changed`. Then:

```bash
scripts/site-secrets.sh check                 # the file is still encrypted
scripts/site-secrets.sh apply <site>          # decrypt straight into the cluster
kubectl -n xnat-ingest rollout restart deploy/<release>-upload
kubectl -n xnat-ingest rollout status  deploy/<release>-upload
```

`apply` shows the kubectl context and the namespaces, and asks before it writes.
The reclaimer CronJob reads the Secret at each run, so it needs no restart.
Verify with the uploader log and the live check:

```bash
kubectl -n xnat-ingest logs deploy/<release>-upload --tail=50
scripts/verify-live.sh <site>
```

A wrong URL or password shows as 401 or a connection error in the first pass,
and `XNATAuthFailure` fires. For an XNAT with a certificate the node does not
trust, set `upload.direct.verifySsl: false` in the site values and upgrade the
release.

Two cautions:

- Commit and push the re-encrypted `secrets.enc.yaml` from that checkout. The
  encrypted file is meant to be in git; `.gitignore` blocks only the plaintext
  variants.
- Sessions already in the upload tree carry no XNAT identity. After the switch
  the uploader delivers them to the new XNAT. To hold them back, scale the
  uploader to zero before the switch and back to one when the new XNAT is ready.

### Turning on Orthanc's REST API authentication

The shipped site sets `orthanc.auth.enabled: false`. Orthanc's REST API is
`ClusterIP`-only, so nothing outside the cluster can reach it — but that is an
accident of network placement, not a control. Anything running *inside* the
cluster can call that API, and it can **delete studies**. Turn it on for any
deployment where that matters.

Three keys, all required, because two different things read this Secret:

| Key | Read by | If it is wrong |
| --- | --- | --- |
| `users.json` | Orthanc itself. It is mounted INTO the config directory at `/etc/orthanc/users.json` and must be a config fragment, `{"RegisteredUsers":{"admin":"<password>"}}` | Orthanc starts, registers NO users, and with authentication on refuses EVERY request including correct credentials. There is no `RegisteredUsersFile` option in Orthanc; the config used to name one and Orthanc ignored it in silence |
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
  namespace: xnat-ingest          # must match the site's `namespace:`
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
kubectl -n xnat-ingest rollout restart deploy/<release>-orthanc
kubectl -n xnat-ingest rollout restart deploy/<release>-group-orthanc
```

Both restarts are needed: Kubernetes does not restart a pod when a Secret
changes, and neither Orthanc nor `group-orthanc` re-reads one at runtime.

**4. Verify.**

```bash
# The Orthanc image has no curl, so reach the API through a port-forward.
# Run it in a second terminal, wait for "Forwarding from 127.0.0.1:8042",
# and stop it with Ctrl-C afterwards:
#   kubectl -n xnat-ingest port-forward deploy/<release>-orthanc 8042:8042
# should now be 401 without credentials
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8042/studies
# and 200 with them
curl -s -o /dev/null -w '%{http_code}\n' -u admin:<password> http://localhost:8042/studies
```

Then confirm the pipeline still moves: `group-orthanc`'s log should keep
reporting `Found N studies`, not 401s. If it 401s, `orthanc-user` /
`orthanc-password` disagree with `users.json`.

> **Do not expose port 8042 to the host or a NodePort just because auth is now
> on.** `orthanc.expose.http` stays `ClusterIP`. Authentication is a second
> layer here, not a replacement for keeping the API off the network.

### Adding or removing a colleague

Encryption is per-recipient, so a new colleague cannot read existing files until
they are re-encrypted to include their key:

```bash
scripts/site-secrets.sh add-recipient age1theirpublickey...
sops updatekeys sites/my-hospital/secrets.enc.yaml  # update this file
# Repeat updatekeys for each existing site file the colleague needs.
```

`encrypt` does nothing when a file is already encrypted. `add-recipient` changes
the creation rules, but does not update the encrypted data key in existing files.
Run `sops updatekeys` as an operator who can decrypt each file, then let the new
recipient verify access.

To remove a recipient, edit `.sops.yaml` and run `sops updatekeys` for the affected
files. Removal cannot revoke old copies or information already decrypted. Review
credential rotation separately from recipient access.

### The salt is a backup-script prerequisite under ingest

Generate `AIS_DEID_HMAC_SALT` once with `openssl rand -hex 32` and replace the
placeholder in Secret `orthanc-deid-salt`. The installer refuses `REPLACE_`
values. The live verifier also fails the placeholder and checks the 64-character
hexadecimal form. The Lua script raises an error at load if the environment
variable is missing.

The chart loads that script and passes the Secret when the facility backup is
enabled. Under ingest, the callback writes the backup and returns before the
hashing and AET-routing path. The salt's value is unused for ingest output.
Changing it does not change the XNAT labels or re-pseudonymise patients in this
pipeline. Keep the Secret valid because the receiver still needs its startup
prerequisite, not because it supplies ingest pseudonyms.

The ingest CLI's optional `<format>.salt` sidecar is separate. Only hash
transforms that use it are affected. The chart has no dedicated secret-backed
wiring for those sidecars, and the shipped recipe hashes nothing. Mapping
encryption is separate again: it uses `reidEncryptKeySecret` and a Fernet key.
Keep these three purposes distinct in the site's recovery instructions.

### The names that must line up

Three names appear in more than one place and must match exactly:

- `orthanc.deid.existingSaltSecret` ↔ `metadata.name` of the salt Secret
- `upload.direct.existingSecret` ↔ `metadata.name` of the XNAT Secret
- every Secret's `metadata.namespace` ↔ your `namespace:` key

SOPS's `encrypted_regex` covers `data` and `stringData` only, so
`metadata.name` stays readable in the encrypted file — you can check these
without decrypting anything. A mismatch shows up as a pod stuck in
`CreateContainerConfigError`, which reads like a chart bug and is not one. CI
checks this pairing too.

---

## 4. Installing

```bash
./install.sh my-hospital        # interactive, step by step
./install.sh -y my-hospital     # non-interactive
```

### The three steps

Tier-2 needs seven steps because it builds a management plane, a hosted control
plane per edge, an object store and a CA, then joins a worker over the network.
Tier-1 is one machine:

1. **k0s** — installs k0s single-node, kubectl, helm, and the local-path
   provisioner. local-path goes on **unconditionally**, even though the pipeline
   does not need it: `charts/edge` creates its own static hostPath PVs on the
   `hostpath-pipeline` StorageClass (`provisioner: kubernetes.io/no-provisioner`),
   and only the optional observability PVCs — Loki, Grafana, Prometheus,
   Alertmanager — bind against local-path. Gating it on `observability.enabled`
   would mean that turning observability on later silently produces Pending
   PVCs, so the installer pays for one small Deployment instead. It is skipped
   when a `local-path` StorageClass already exists (the step is idempotent), and
   the whole step is skipped under `installMode: existing`, which verifies a
   cluster rather than building one. The k0s version is pinned deliberately:
   this is an appliance handed to a hospital, and two installs a fortnight apart
   landing on different k0s minors is a support problem nobody can reproduce.
2. **Secrets** — decrypts `secrets.enc.yaml` with SOPS and applies it straight
   into the cluster. Plaintext never reaches disk.
3. **The chart** — `helm upgrade --install` with `upload.mode: direct`.

There is no join step, no cert-sync, no S3 identity to distribute and no second
machine to reach. Everything happens on the box you are typing on — which is
also why there is no `join: bundle` equivalent here.

The installer validates before it builds anything, and names the specific key
that is wrong rather than failing later inside a library:

- `upload.mode` must be `direct`. Tier-1 has no SeaweedFS and no management-side
  reclaimer, and the failure would be silent — the uploader retrying an endpoint
  that never answers while the pipeline quietly fills the disk.
- `nodeIP` must be set.
- `secrets.enc.yaml` must exist, must be encrypted, and must not still contain
  the shipped `REPLACE_` placeholders.
- `sops` must be installed.

### Proving it worked

```bash
scripts/verify-live.sh my-hospital
```

This checks readiness rather than pod phase (a `Running` pod with a failing
probe is not working), checks each pipeline stage by its component label,
verifies the de-identification salt is not still the placeholder, and reaches
XNAT *from inside the upload pod* — which is the only place the answer means
anything, since that is the pod whose DNS, routing and TLS trust actually
matter. The exit code is the number of failures.

### What can go wrong

| Symptom | Cause |
| --- | --- |
| Chart refuses to render, mentions `policyReviewed` | The gate in 2.3. Review the ingest recipe, labels and reid-map protection, then set it true. |
| Pod in `CreateContainerConfigError` | A Secret name or namespace does not match. Section 3. |
| Grouping fails per study, EXDEV in the logs | Pipeline stage directories are on different filesystems or the copy mode cannot link them. A separate backup disk is allowed. Section 2.1. |
| Studies stall at assign, "missing metadata fields" | A source tag selected by `ingest.assign.tagMapping` is absent or empty. Check the actual input tags and the project constant. Section 2.3. |
| Sessions land in `assigned/__invalid__` | Assignment could not resolve a required label. The input still contains patient information. Inspect the selected tags in Orthanc through a controlled port-forward, then use the guarded invalid-session recovery procedure in `docs/components/xnat-ingest.md`. Correct the source mapping for future studies. A failed grouping is separate: it is built privately and published only when complete. |

| `IngestStageError` for `group`, with `Skipping Orthanc study '<id>'` | One study cannot be staged, and the other studies go on. See "A study that group-orthanc refuses" in `docs/components/xnat-ingest.md`. |
| Upload pod `CrashLoopBackOff`, `SSLCertVerificationError ... self-signed certificate` | Your XNAT presents a certificate this node does not trust. Check with `openssl s_client -connect <xnat-host>:443` — `Verify return code: 18` means self-signed, and a subject of `Kubernetes Ingress Controller Fake Certificate` means that XNAT's ingress has no real certificate at all. Set `upload.direct.verifySsl: false` for the site, and set it back the moment XNAT gets a real one. |
| `'DICOM' resource ... already exists on XNAT with different checksums` at ERROR level | The empty-digest false ERROR was fixed in 0.15.3. This now indicates a real resource conflict. Compare staged and remote files; a later success line does not prove content equality. Preserve the source while resolving the conflict. |
| `compared by file name only` WARNING (xnat-ingest PR #227) | XNAT lists one or more files without computed checksums. Their names match, but their content was not compared. Ask the administrator to configure and compute catalog checksums. This warning can recur on each upload attempt. |
| Nothing arrives at all | Check the firewall, node address, configured called AE title, and receiver readiness on port 4242. Under ingest an AET map does not route or quarantine the study. If Orthanc holds it, inspect group and assign next. |
| Vector in `CreateContainerConfigError` | `observability.loki.clientCertSecret` is not empty. Section 6. |
| Loki `CrashLoopBackOff`, `mkdir ...: read-only file system` / `error initialising module: ruler-storage` | The ruler's `storage.local.directory` must be the path the chart's rules sidecar mounts (`/rules`), and the sidecar must write into the tenant subdirectory (`/rules/fake`, since `auth_enabled` is false). Both are set in `charts/edge/values.yaml`; if you override either, override both. Loki refusing to start means no log storage **and** no pipeline alerts, since every *pipeline* alert on this tier is Loki-sourced; the Prometheus rules in `files/prometheus-rules/` keep evaluating independently, so a green Alertmanager is not evidence that Loki is up. |

---

## 5. What happens to a study, hop by hop

1. **C-STORE arrives** at Orthanc on `<nodeIP>:4242`. The receiver stores the
   original instances. When facility backup is enabled, the Lua callback writes
   a byte copy there. Under ingest it then returns before AET routing or header
   modification. Unknown calling AETs are not quarantined by this mode.
2. **group-orthanc** polls the REST API, waits for stable input, and hardlinks
   instances into `grouped/`. The chart clears the Lua ready-label filter under
   ingest. The processed label and snapshot state track what has been exported.
3. **assign** selects the project, subject and session from the configured tags
   or project constant. It writes `assigned/`. The derived tag defaults are
   StudyID, PatientID and AccessionNumber. These values become XNAT labels before
   any recipe runs. Missing values go to the invalid holding directory.
4. **deidentify** reads `assigned/`, applies the project or fallback recipe,
   and writes `deidentified/`. It also writes a reid map under `/data/reid`.
   Use the encryption-key Secret reference to protect that map. The old
   `ingest.deidentify.enabled` key is rejected; the engine selector derives
   the stage. Optional packaging then writes `/data/packaged`.
5. **upload** reads `deidentified/`, or `packaged/` when packaging is on. It
   waits for the configured quiet period and uploads over HTTPS with the XNAT
   credentials. A quiet period reduces overlap; it cannot prove that no later
   series will arrive. Check the actual files and labels at the destination.
6. **Reclaim** follows the configured stage handoffs. Assigned input can be
   removed after de-identification when its reclaim condition selects that
   behavior. The final upload tree is removed only by the guarded reclaimer
   after its XNAT checks. Facility-backup expiry is a separate opt-in; file
   drops with `reclaim: never` stay regardless of their age.

Keep the original-data locations in the site's access-control inventory.
Orthanc, grouped and assigned storage can contain identifying data before
processing. The reid map remains sensitive after processing. A successful
upload does not erase any of these locations unless its relevant cleanup
mechanism is configured and succeeds.

Every stage is a separate workload with its own `component` label, which is what
lets you follow one study through the logs:

```bash
kubectl -n xnat-ingest logs -l component=upload --tail=100
```

---

## 6. Observability

Optional, and entirely local. Turn it off and the pipeline is unaffected — it is
observability, not plumbing.

```yaml
observability:
  enabled: true
  loki:
    clientCertSecret: ""     # MUST BE EMPTY ON TIER-1
    caBundleSecret: ""
  stack:
    enabled: true
```

**Those two empty strings are not optional and not cosmetic.** The chart is
shared with tier-2, where Vector ships logs *off* the edge to a management Loki
over mutual TLS, and the defaults are the tier-2 secret names that a management
cluster's cert-sync delivers. There is no management cluster here, so nothing
ever creates them. The gate is `clientCertSecret`: `charts/edge/templates/vector.yaml`
renders the client-cert and CA volumes and their mounts only while that name is
non-empty, so leaving the tier-2 default in place mounts Secrets nothing on this
node creates and Vector sits in `CreateContainerConfigError` indefinitely.
(`caBundleSecret: ""` is not a second gate — it is inert once `clientCertSecret`
is empty — but it is set to match, so the pair reads as one decision.)

What selects the *config file* is a different switch: `stack.enabled: true`
picks `files/vector-local.yaml`, the Vector config with the sink's `tls:` block
removed, because tier-1's Loki is in the same cluster over plain HTTP.
`stack.enabled: false` picks `files/vector.yaml`, which keeps the block for a
remote management Loki. Two separate mechanisms, easy to conflate: emptying the
Secret names does not change which file is mounted, and turning the stack off
does not stop the certs being mounted.

`stack.enabled` hosts the whole store on this node: Loki (filesystem storage on
a PVC, *not* S3 — there is no object store), Prometheus, Alertmanager, and
Grafana on a NodePort at **30030**, since there is no ingress. Log in with the
credentials from `grafana-admin-credentials`.

**Alerts are not mailed anywhere until you say where.** `observability.stack.alerting`
ships empty, and that is a deliberate default rather than an oversight: the
stack installs, the dashboards work, and nothing is sent. Every alert below is
then visible only in Grafana, which nobody is watching at 3am. On a real
deployment fill in three keys:

```yaml
observability:
  stack:
    alerting:
      emailTo: imaging-ops@example.org
      emailFrom: ""                     # defaults to emailTo
      smtpHost: smtp.example.org
      smtpPort: 587
      smtpUsername: alerts@example.org  # must match `username` in the Secret
```

The password comes from the `alertmanager-smtp` Secret in `secrets.enc.yaml`.
Only the password is read from a file — Alertmanager has no
`smtp_auth_username_file` — which is why the username sits in values.yaml and
its password does not. Until `smtpHost` is set, the password in that Secret is
simply unused — but **the Secret itself must still exist**, because it is
mounted into Alertmanager whether or not SMTP is configured (§3). Unused is not
the same as absent.

Dashboards and alert rules ship with the chart. At this revision it defines
**30 alerts**: 22 log rules in `files/loki-ruler-rules.yaml`, and eight metric
rules in `files/prometheus-rules/{critical,warning,info,uploader}.yaml`. The
metric rules cover the API server, node readiness, ingest crash loops, failed
Jobs, reclaimer success, node count and two uploader conditions. They come on top of
kube-prometheus-stack's own default rule set, which contributes roughly another 130 and is left enabled
apart from `KubeJobFailed`, which the chart replaces with a copy that leaves out
the staged-reclaimer's own Jobs. Upstream's `CPUThrottlingHigh` runs unmodified:
the data-policy reporter has no CPU limit, so the kernel never throttles it and
the rule has no series to read for it. The ones specific to this tier are:

- **`EdgeDiskLow`** — free space below `minFreeDiskPercent`. On tier-1 this is
  the only disk-exhaustion warning, and the disk holds the only copy of the
  originals. Do not ignore it.
- **`QuarantinedDataUnresolved`** — something has sat in quarantine longer than
  `alertAfter`. It can report a retained legacy quarantine. Ingest does not
  create unknown-AET entries; inspect the actual directory and its source.
- **`DataPolicyReporterSilent`**: the data-policy reporter has stopped sending
  `stage_report`. The two alerts above read only those lines, so while this
  fires a filling disk would go unreported.
- **`XNATRepairAttempted`**: XNAT already held a session with files missing,
  and the uploader tried to re-send them. It normally stands in for the
  "upload completed" mail for that session, and does not say whether the
  re-send worked; the mail says how to check. If the session had uploaded completely before, check XNAT.
- **`XNATAuthFailure`**, **`XNATUploadFailingForAllSessions`**,
  **`XNATUploadRetryStorm`**, **`SessionUploadStalled`** — the upload path.
- **`DeidentifyStageError`** reports failures from the default xnat-ingest
  deidentify stage. Inspect its recipe, input and output.
- **`OrthancDeidLuaError`** matches receiver Lua error logs. Under ingest, check
  backup writes and script startup requirements; header de-identification runs
  in the separate stage. This alert alone does not locate an ingest recipe error.
- **`InvalidSessionAssigned`** reports labels that assignment could not resolve.
  The held input has not been de-identified and needs guarded recovery.

The alert expressions are unit-tested against recorded log fixtures
(`tests/loki-rules/`), including the case that asserts a tqdm progress bar
reading `401.71it/s` does **not** raise a credential alert.

`ReclaimerRunUnavailable` and `SessionStagedNotConfirmedInXNAT` are shared with
tier-2. Under `upload.mode=direct` the staged-reclaimer CronJob runs the same
`reclaim-staged.sh` against the local upload tree instead of a bucket, so a
reclaimer that keeps failing, or a session XNAT never confirms, raises the same
two alerts. One failed run does not: the next hourly run finishing clears it.

`ReclaimerRunUnavailable` only sees runs that log why they stopped. A run killed
at its deadline, OOM-killed, crashing, stuck on an image pull or never scheduled
logs nothing, so **`ReclaimerNotSucceeding`** watches the CronJob itself: no
successful run for `dataPolicy.derived.stagedReclaimer.alertAfter` (3h) raises
it, counted from creation if it has never succeeded. One failed run never fires
it, even when the next run takes its full deadline to succeed; two failed runs,
then a third not succeeding within 15 minutes, do, about 3h15m after the last
success. It clears on the next good run, however many failed Jobs history
keeps. While `ReclaimerRunUnavailable` is firing it is held back, so one XNAT
outage raises one alert rather than two: its firing mail and its resolve, one
pair per logged reason. If you slow the schedule, raise `alertAfter` with it: it
must exceed two periods plus `deadlineSeconds`, and the chart refuses less for
the usual schedule forms (hourly, every N hours, daily).

---

## 7. Uninstalling

```bash
scripts/uninstall.sh my-hospital                  # full reset
scripts/uninstall.sh --keep-cluster my-hospital   # workloads only, keep k0s
```

It reads your site file, so it removes what this site actually installed rather
than a hardcoded list that drifts. It deletes the Helm release and namespace,
the PVs and PVCs (including the ones marked `resource-policy: keep`, which
protect data during an *upgrade* and must not survive a teardown), the
prometheus-operator CRDs (left behind, they make the next install's Prometheus
objects apply successfully and then do nothing at all), and both host data
directories.

**This deletes the facility backup**, which holds retained
originals. The pipeline and reid maps can also contain identifying information. Copy it elsewhere first unless this is a scratch
machine.

It deliberately keeps your age key, your `sites/<site>/` directory, and the k0s
binary.

**If you cannot reboot.** `k0s reset` leaves CNI interfaces and iptables rules
in the kernel, and the script says a reboot is recommended. On a machine you
cannot restart — which is most hospital appliances — the part that matters is
the leftover NAT rules from the old cluster:

```bash
sudo iptables -t nat -L -n | grep -c 'KUBE-'    # ~34 on a torn-down box
                                                # (a running cluster has far more —
                                                #  count this BEFORE reinstalling)
```

They reference service VIPs and pod IPs that no longer exist. A fresh install's
kube-proxy reconciles the chains it owns, so this is usually harmless — a
tier-1 install on this exact box succeeded with them still present. Reboot when
you can; if networking misbehaves after a reinstall, this is the first thing to
rule out.

---

## 8. What tier-1 does not have

Worth knowing, because most of the surrounding documentation and any tier-2
instructions you find will mention them:

| Not present | Why |
| --- | --- |
| SeaweedFS / S3 staging | Upload goes straight to XNAT from local disk. |
| k0smotron hosted control planes, konnectivity | One cluster, no children. |
| cert-sync, mTLS to a management Loki | Nothing to sync to; Loki is local. |
| nginx-ingress, cert-manager | Grafana is on a NodePort. |
| Joining a worker, `join: ssh` / `join: bundle` | One node. |
| Per-edge secrets, S3 identities | One site. |
| `scripts/clear-staged-s3.sh` | No staging bucket to clear. |

---

## 9. Where to go next

- `charts/edge/values.yaml` — every key, with the reasoning. The best reference
  once you know the shape.
- `docs/alerting-architecture.md` — how alerts are routed and what to do when
  one fires.
- `docs/dashboards.md` — what each Grafana dashboard shows.
- `docs/components/` — one document per pipeline stage.
- `README.md` — the short version of this document, for people who have already
  done it once.
