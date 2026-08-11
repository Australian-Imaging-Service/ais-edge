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
An Orthanc server receives it and — before anything else touches it — applies a
de-identification profile that strips or replaces the identifying fields. A
sequence of small jobs then groups the instances into studies, works out which
XNAT project and subject each one belongs to, and uploads it over HTTPS. The
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
lives on disk, which AE titles map to which XNAT projects, the de-identification
profile, retention policy, whether observability is on. This is the file you
will spend your time in.

**`sites/<site>/secrets.enc.yaml`** — four Kubernetes Secrets: XNAT credentials,
the de-identification salt, the Grafana login, and SMTP for alert email. It is
plaintext while you write it and encrypted before you commit it. Section 3.

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
If you override `orthanc.deid.profile.Keep`, you replace the entire list — the
chart's four UID entries are gone unless you restate them.

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

**Both paths must be on the same filesystem.** This is not a style preference.
The grouping stage *hardlinks* instances out of Orthanc's storage into the
grouped directory rather than copying them — a hardlink is a second name for the
same bytes, so grouping a 4 GB study costs no extra disk and no copy time. A
hardlink cannot cross a mount point. Put `/data/xnat-ingest` and
`/data/facility-backup` on different mounts and grouping fails at runtime, per
study, with an EXDEV error that looks nothing like a configuration problem.

`capacity` is the size of the PersistentVolume the chart creates. It is a
bookkeeping number for Kubernetes, not a quota — the host path can and will fill
past it. Size the actual filesystem for the workload, and see `EdgeDiskLow` in
section 6, which is the only disk-exhaustion warning you get.

**The facility backup is the archive of record.** It holds the originals, with
real patient identifiers, written before de-identification. On tier-2 there is a
management plane holding staged copies; on tier-1 there is nothing else. It is
the only identifiable copy anywhere, and `scripts/uninstall.sh` deletes it. Back
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

`installMode: fresh` lets the installer install k0s, kubectl, helm and the
local-path provisioner from nothing. Use `existing` only if a cluster is already
running here, in which case the installer verifies instead of building.

### 2.3 De-identification — the one you must actually read

This is the section where a mistake sends identifiable data to a research
archive. Nothing downstream re-checks what was removed: the uploader trusts that
whatever reaches it is already de-identified.

```yaml
orthanc:
  aet: AISEDGE
  deid:
    enabled: true
    policyReviewed: false          # <- the gate
    existingSaltSecret: orthanc-deid-salt
    aetMap:
      AISEDGE:
        project: example_project
    profile: { ... }
```

**`policyReviewed` is a gate, not a formality.** The chart refuses to render
while it is `false` and de-identification is enabled. Set it to `true` only once
you have read the profile below and the AE-title map above and agree that they
are *your site's policy* — not the example's.

**The AE-title map** is the most site-specific thing in the file. It answers:
when a study arrives from calling AE title X, which XNAT project does it belong
to? An AET that is **not** listed is *quarantined, not dropped* — it lands under
the quarantine subdirectory so you can add the mapping and re-send it. (An
earlier version of this pipeline deleted unmapped instances outright. It does
not any more, and that is deliberate.)

**The profile** is passed to Orthanc's de-identification and applied to every
incoming study. Three things about it are worth understanding rather than
copying:

*UIDs are deliberately retained.* `StudyInstanceUID`, `SeriesInstanceUID`,
`SOPInstanceUID` and `FrameOfReferenceUID` are kept, because a study whose UIDs
were randomised per-instance would no longer hang together as a study — series
would not group and spatial references would break. Identity is removed through
the replaced fields instead. This is DICOM's "Retain UIDs" option and it is
recorded in `DeidentificationMethod` so the archive knows what was done.

*Three fields are a contract with the next stage.* These:

```yaml
ClinicalTrialProtocolID:  ${ProjectCode}
ClinicalTrialSubjectID:   ${SubjectHash}
ClinicalTrialTimePointID: ${SessionHash}
```

are read by the assign stage to work out project, subject and session. Remove
any one of them and every study stalls at assign with "missing metadata fields"
— *after* de-identification has already reported success, so the logs look fine
right up until nothing uploads.

*The `${...}` values are computed, and one of them is salted.* `${SubjectHash}`
and `${SessionHash}` are HMACs of the original identifiers, keyed with a salt
you generate. Same patient, same hash, every time — which is what lets a
subject's second visit land on the same XNAT subject. See the warning in section
3 about what happens if that salt changes.

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

- **originals** — the facility backup, the quarantine, the file-drop directory.
  These are the only copies. Default `retain: forever`.
- **derived** — Orthanc's own storage, the grouped directory, the assigned
  directory. These can be recreated from originals, and are reclaimed by
  *progress* rather than by age: `reclaim: onGrouped`, `onAssigned`,
  `onUploaded`. A study's assigned copy is removed once it is confirmed in XNAT.

On tier-1 this matters **more** than on tier-2, not less. This node holds the
only copy of the facility backup, there is no management-side reclaimer to fall
back on, and `EdgeDiskLow` is the only disk-exhaustion alert in the system.

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
| `orthanc-deid-salt` | `AIS_DEID_HMAC_SALT` — 64 hex chars | Orthanc's de-identification |
| `grafana-admin-credentials` | `admin-user`, `admin-password` | Grafana |
| `alertmanager-smtp` | `username`, `password` | Alertmanager, for alert email |

The last two are only needed if `observability.enabled` is true.

### Step A — once per operator, on a new machine

```bash
scripts/site-secrets.sh init-key
```

This creates your age key at `~/.config/sops/age/keys.txt` and prints your
**public** key. The private half of that file is the only thing that can decrypt
every `sites/*/secrets.enc.yaml` in this repository.

> **If you lose `~/.config/sops/age/keys.txt`, every encrypted file becomes
> permanently unreadable.** There is no recovery, no escrow and no reset. Back
> it up somewhere that is not this machine, before you encrypt anything.
> `scripts/uninstall.sh` deliberately does not delete it.

### Step B — the site

```bash
scripts/site-secrets.sh new my-hospital single   # copies example-single/
$EDITOR sites/my-hospital/values.yaml            # section 2
$EDITOR sites/my-hospital/secrets.enc.yaml       # STILL PLAINTEXT at this point
scripts/site-secrets.sh encrypt my-hospital      # do not commit before this
```

Generate the salt properly — it is a key, not a password:

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

`edit` is the one to use. It never writes plaintext to disk.

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

### Adding or removing a colleague

Encryption is per-recipient, so a new colleague cannot read existing files until
they are re-encrypted to include their key:

```bash
scripts/site-secrets.sh add-recipient age1theirpublickey...
scripts/site-secrets.sh encrypt my-hospital     # re-encrypt to the new recipient set
```

Removing someone is the same command after editing `.sops.yaml` — but treat
anything they could already decrypt as compromised and rotate it.

### The salt is not a password — do not "just regenerate" it

`AIS_DEID_HMAC_SALT` keys the hashes that produce subject and session
identifiers. Change it and the *same patient* hashes to a *different* subject
from that moment on. XNAT will happily accept the new identity and you get one
research subject silently split into two, with no error anywhere and no way to
rejoin them without the old salt. Generate it once, back it up with your age
key, and leave it alone.

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
   provisioner if observability is on. The k0s version is pinned deliberately:
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
| Chart refuses to render, mentions `policyReviewed` | The gate in 2.3. Read the profile, then set it true. |
| Pod in `CreateContainerConfigError` | A Secret name or namespace does not match. Section 3. |
| Grouping fails per study, EXDEV in the logs | Pipeline and facility-backup paths on different filesystems. Section 2.1. |
| Studies stall at assign, "missing metadata fields" | A `ClinicalTrial*` field was removed from the profile. Section 2.3. |
| Sessions land in `assigned/__invalid__/INVALID_MISSING_CLINICALTRIALPROTOCOLID_...` | **Read the group stage's log before touching the profile.** This name is also what you get when *grouping* failed and handed assign an empty session, and the two causes look identical from here. Grouping raises `ImagingSessionParseError: Did not find 'SeriesDescription' field` on a study missing a tag it needs — the DICOM never reaches assign, so assign correctly reports no metadata. Confirm which it is by checking Orthanc directly: `curl localhost:8042/instances/<id>/simplified-tags` on the receiver pod shows whether de-identification really did set the three tags. |
| Upload pod `CrashLoopBackOff`, `SSLCertVerificationError ... self-signed certificate` | Your XNAT presents a certificate this node does not trust. Check with `openssl s_client -connect <xnat-host>:443` — `Verify return code: 18` means self-signed, and a subject of `Kubernetes Ingress Controller Fake Certificate` means that XNAT's ingress has no real certificate at all. Set `upload.direct.verifySsl: false` for the site, and set it back the moment XNAT gets a real one. |
| `'DICOM' resource ... already exists on XNAT with different checksums` at ERROR level | Usually benign: the uploader runs on a loop, and a session already delivered is found again on the next pass. It is logged at ERROR, so it inflates the "Upload errors (last 1h)" panel without anything being wrong. Look for a matching "Successfully uploaded all files in" line for the same session — if it is there, the session is delivered. |
| Nothing arrives at all | Firewall on port 4242, or the modality's calling AE title is not in `aetMap` — check the quarantine directory. |
| Vector in `CreateContainerConfigError` | `observability.loki.clientCertSecret` is not empty. Section 6. |
| Loki `CrashLoopBackOff`, `mkdir ...: read-only file system` / `error initialising module: ruler-storage` | The ruler's `storage.local.directory` must be the path the chart's rules sidecar mounts (`/rules`), and the sidecar must write into the tenant subdirectory (`/rules/fake`, since `auth_enabled` is false). Both are set in `charts/edge/values.yaml`; if you override either, override both. Loki refusing to start means no log storage **and** no pipeline alerts, since every alert on this tier is Loki-sourced. |

---

## 5. What happens to a study, hop by hop

1. **C-STORE arrives** at Orthanc on `<nodeIP>:4242`. Orthanc stores the
   instances in its own storage directory.
2. **De-identification** runs inside Orthanc, driven by your profile. The
   original is written to the facility backup first; what continues down the
   pipeline is de-identified. If the calling AE title is not in `aetMap`, the
   study goes to quarantine instead and stops here.
3. **group-orthanc** runs on a 60-second loop, finds instances labelled
   `xnat-ingest-ready`, and hardlinks them into `grouped/` organised by study.
   It relabels them `xnat-ingest-processed` so the next pass skips them.
4. **assign** reads `ClinicalTrialProtocolID`, `ClinicalTrialSubjectID` and
   `ClinicalTrialTimePointID` from the de-identified headers and works out the
   XNAT project, subject and session. Output goes to `assigned/`.
5. **upload** waits for a quiet period (`waitPeriod: 60` — no new files for a
   minute, so it does not upload a study still being sent), then PUTs the
   session to XNAT over HTTPS using `xnat-credentials`. On success it logs
   "Successfully uploaded all files in", which the alerting rules watch for.
6. **Data policy**, if enabled, reclaims the derived copies as each stage
   confirms the next one succeeded. The facility backup and quarantine are
   untouched.

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
ever creates them — and the chart mounts them non-optionally, so Vector would
sit in `CreateContainerConfigError` indefinitely. Empty also selects
`files/vector-local.yaml`, the Vector config without the sink's `tls:` block,
because tier-1's Loki is in the same cluster over plain HTTP.

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
its password does not. Until `smtpHost` is set, that Secret is simply unused.

Dashboards and alert rules ship with the chart. Eleven alerts are defined, and
the ones specific to this tier are:

- **`EdgeDiskLow`** — free space below `minFreeDiskPercent`. On tier-1 this is
  the only disk-exhaustion warning, and the disk holds the only copy of the
  originals. Do not ignore it.
- **`QuarantinedDataUnresolved`** — something has sat in quarantine longer than
  `alertAfter`. Almost always an AE title missing from `aetMap`.
- **`XNATAuthFailure`**, **`XNATUploadFailingForAllSessions`**,
  **`XNATUploadRetryStorm`**, **`SessionUploadStalled`** — the upload path.
- **`OrthancDeidLuaError`** — de-identification itself is failing.

The alert expressions are unit-tested against recorded log fixtures
(`tests/loki-rules/`), including the case that asserts a tqdm progress bar
reading `401.71it/s` does **not** raise a credential alert.

Two tier-2 alerts — `ReclaimerRunUnavailable` and
`SessionStagedNotConfirmedInXNAT` — are deliberately absent, because there is no
S3 reclaimer and no staging bucket on a single node.

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

**This deletes the facility backup**, which on this tier is the only
identifiable copy anywhere. Copy it elsewhere first unless this is a scratch
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
