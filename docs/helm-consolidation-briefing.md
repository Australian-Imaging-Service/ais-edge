# AIS Edge — Consolidation Briefing

*Repo: `/home/ubuntu/k0s-k0smotron-mvp` (Australian-Imaging-Service/ais-edge). All line refs verified against `main` @ `3958594` working tree and `origin/ais-edge-update` @ `54200fc`.*

---

## 1. What the two codebases actually are

**Ours (`install.sh` + `scripts/*.sh` + `manifests/**` + `config/*.env`)** is a **two-plane, multi-cluster fleet installer**. It builds a k0s single-node *management* cluster (`scripts/01-install-k0s.sh:26-33`), installs cert-manager + k0smotron on it (`scripts/02-install-k0smotron.sh:45,55`), stands up shared central services there (self-signed root CA, ingress-nginx with ssl-passthrough, SeaweedFS S3, a mgmt-side S3→XNAT uploader, a full Prometheus/Loki/Grafana/Alertmanager stack), then for *each* edge site creates a k0smotron-hosted control plane (`manifests/01-management/edge-cluster.yaml.tpl`), SSHes to the edge VM to join a k0s worker (`scripts/06-join-edge-worker.sh`), and deploys the DICOM pipeline into that **child** cluster using a second kubeconfig. Templating is a hand-rolled bash substituter — `content="${content//\{\{$1\}\}/$2}"` at `scripts/00-common.sh:19-28` — with an awk-based `{{#ONPREM_ONLY}}` conditional at `:40-69`. Data flow: Orthanc → de-id Lua → group/assign → **edge S3 upload to central SeaweedFS** → mgmt pod pushes S3 → XNAT. It carries everything the pipeline needs that James's chart does not have: de-identification, AET routing, quarantine, facility backup, CA/TLS, and the entire observability + alerting stack.

**James's `helm/edge` (PR #8, `origin/ais-edge-update`)** is a **single-cluster, single-site Helm chart**. 23 files, one namespace (`values.yaml:1` `ais-edge`), one kubectl context (`helm/setup.sh:48-52`), one PVC. It knows nothing about k0s, k0smotron, ingress, cert-manager, TLS, or observability — verified: zero `kind: Ingress`, zero `Certificate`/`ClusterIssuer`, zero `ServiceAccount`/`Role`, and `git grep -iE "loki|grafana|prometheus|vector|alertmanager|servicemonitor"` over the whole PR tree returns nothing. Data flow is **edge → XNAT directly** (`helm/edge/files/upload.sh:12`), with S3 as an optional *side*-sync to an external bucket (`helm/edge/files/s3sync.sh:38`, `s3Sync.enabled: false`). It has no de-identification at all (`values.yaml:62` `deidentify: "0"`). What it *does* have, and does better than us, is Helm hygiene: a Retain PV/PVC with `helm.sh/resource-policy: keep` (`templates/storage.yaml:6-8,31-33`), non-root Orthanc with probes and resources (`templates/orthanc-deployment.yaml:22-73`), `.Files.Get` script ConfigMaps with `checksum/script` rollout annotations, and credentials that never touch `values.yaml`.

**The two sit on opposite sides of one boundary**: James's chart lives entirely *below* our `scripts/05`/`06` cluster-bootstrap line. They are complementary, not competing — except on the ~6 edge pods, where they overlap almost 1:1.

---

## 2. PR #8 merge verdict

**Scope — clean.** `git diff --stat main origin/ais-edge-update -- . ':(exclude)helm'` is **empty**. All 20 changed files (+903/−457) are under `helm/`. Nothing in `install.sh`, `scripts/`, `manifests/`, `config/`, or `docs/` is touched.

**Fast-forward — yes.** `git merge-base main origin/ais-edge-update` = `3958594` = `git rev-parse main` = `git rev-parse origin/main`. Four commits ahead (`ebaccf4`, `0fd3610`, `0648169`, `54200fc`). A merge is a pure fast-forward with zero conflicts.

**Chart validity — verified.** `helm lint helm/edge` → 0 failures (1 INFO: no icon). `helm template` renders clean with default values and with `s3Sync.enabled=true`; the `required` guard on `s3Sync.dest` fires correctly (`templates/s3sync-pod.yaml:29`).

### Defects

| # | Sev | Location | Defect |
|---|-----|----------|--------|
| D1 | **HIGH** (data) | `helm/edge/values.yaml:86` (+`:80` enables it) | `fsIngest.unlinkSource: all` → `XINGEST_UNLINK_SOURCE=all` on the file-drop pod (`templates/xnat-ingest-fs-group-pod.yaml:28-31`). On the Samba/fs path there is **no Orthanc copy and no facility backup**, so `/data/incoming` is the only copy of operator-supplied data and it is deleted after grouping. `helm/edge/README.md:27-29` documents this as intended. **Must default to `""`.** |
| D2 | **HIGH** (install-blocking) | `helm/setup.sh:134` | `helm upgrade --install ... --rollback-on-failure`. **This flag does not exist in Helm 3.** Verified on helm `v3.20.1`: `Error: unknown flag: --rollback-on-failure`. `scripts/01-install-k0s.sh:55` installs Helm 3 via `get-helm-3`. The installer script aborts at the install step for every Helm-3 user. Fix: `--atomic`. |
| D3 | **HIGH** (exposure) | `templates/samba-deployment.yaml` (no `if` guard, `:42-44`, `:46-47`, `:51-53`) | Samba is deployed **unconditionally** — confirmed present in default `helm template` output. It binds `hostPort: 445` and mounts the **entire pipeline PVC** at `/storage`, i.e. `orthanc-storage/`, `grouped/`, `assigned/`, `LOGS/` are all readable over SMB. Needs `samba.enabled: false` + a `subPath: incoming` mount. |
| D4 | MED | `helm/setup.sh:9` vs chart `.Values.namespace` | `NAMESPACE=ais-edge` is hardcoded in the script while every template uses `{{ .Values.namespace }}`. A site values file that sets `namespace:` gets its Secrets created and its namespace annotated in `ais-edge` while the chart renders elsewhere → install fails or pods reference non-existent Secrets. |
| D5 | MED | `templates/xnat-ingest-associate-pod.yaml:1` | No `enabled` guard — an idle `sleep infinity` Deployment (`:41-42`) is always deployed and always holds the PVC mount. Confirmed in default render. |
| D6 | MED | `values.yaml:116` | `amazon/aws-cli:latest` — unpinned. Everything else in the chart is pinned (`orthanc 1.12.11`, `samba 4.23.5`, `busybox:1.36`, `xnat-ingest 0.12.3`). |
| D7 | MED | `values.yaml:92` | `assign.unlinkSource: all` deletes `/data/grouped`. Safe on the Orthanc path (originals retained in Orthanc storage); **compounds D1** on the fs path — after D1 deletes `/data/incoming`, this deletes the only remaining copy. |
| D8 | LOW | `templates/upload-configmap.yaml:1` | No `{{- if .Values.xnatIngest.upload.enabled }}` guard, unlike `s3sync-configmap.yaml:1`. Cosmetic orphan ConfigMap. |
| D9 | LOW | `templates/storageclass.yaml` | Cluster-scoped StorageClass with no `helm.sh/resource-policy: keep` (unlike the PV/PVC). Two releases with `storageClass.create=true` in one cluster collide on install. |
| D10 | LOW | `templates/storage.yaml:5` | PV name `pv-{{ .Values.pvcName }}` is cluster-scoped but keyed only on `pvcName` — two releases in different namespaces with the default `pvcName: ais-edge` collide. Mitigated only by remembering to override `pvcName`. |
| D11 | LOW | `xnat-ingest-*-pod.yaml`, `samba-deployment.yaml`, `s3sync-pod.yaml` | No `securityContext` and no `resources` on any pod except Orthanc. |
| D12 | LOW | `templates/orthanc-deployment.yaml:31` | `chown ... /data` is non-recursive. Pre-existing root-owned files under `orthanc-storage/` stay unreadable to uid 10001 on migration from our layout. |
| D13 | INFO | `templates/xnat-ingest-orthanc-group-pod.yaml:47-55` | No `--to-process-label`. Correct for a no-deid chart; blocks direct reuse with our Lua `xnat-ingest-ready` label gate. |

### Verdict: **MERGE-WITH-FOLLOWUP**

Merge it. It is a fast-forward, touches nothing outside `helm/`, lints and templates cleanly, and is strictly ahead of the stale `helm/edge` already on `main`. Nothing in it can affect the running installer or any live cluster, because nothing invokes it.

**Fix before anyone runs it at a site (same-day follow-up PR):** D1, D2, D3.
**Fix before consolidation work starts:** D4–D7.
**Backlog:** D8–D13.

---

## 3. Feature reconciliation

Sorted: certain first, user-decision last.

| Feature | Ours | James | Verdict | Conf |
|---|---|---|---|---|
| PV/PVC with `Retain` + `helm.sh/resource-policy: keep` | none — raw hostPath (`manifests/02-edge/orthanc.yaml.tpl:105-112`) | `templates/storage.yaml:1-43` | **Goes in chart — take his** | High |
| Namespace object with `resource-policy: keep` | `kubectl create ns` imperative | `templates/namespace.yaml:5-7` | Goes in chart — take his | High |
| Host dir pre-creation | SSH `mkdir 777/750` (`scripts/07:20-22`, `07c:68-73`) | PV `DirectoryOrCreate` + init `chown` (`orthanc-deployment.yaml:24-38`) | Goes in chart — take his; **delete SSH step** | High |
| Orthanc Deployment hardening (non-root, caps, probes, resources) | none at all | `values.yaml:30-46`, `orthanc-deployment.yaml:22-73` | Goes in chart — take his wholesale | High |
| Orthanc `orthanc.json` templated | static file + `--from-file` (`scripts/07c:81-116`) | `orthanc-configmap.yaml:9-26` + `checksum/config` | Goes in chart — his shape, **plus our keys** (`StableAge:30`, `MaximumStorageSize:0`, `MaximumPatientCount:0`, `LuaScripts`) | High |
| Orthanc REST auth | `AuthenticationEnabled: false` (`config/orthanc/orthanc.json:16`), hardcoded `orthanc`/`orthanc` creds | `authenticationEnabled: true` + `orthanc-credentials` Secret | Goes in chart — take his | High |
| Credentials referenced, never templated | inline bash substitution into YAML (unquoted, `00-common.sh:19-28`) | `envFrom`/`secretKeyRef` only (`setup.sh:67-127`) | Goes in chart — take his; **governing rule: charts hold references, never secrets** | High |
| `.Files.Get` script ConfigMaps + `checksum/script` | shell heredocs inline in manifests | `s3sync-configmap.yaml`, `upload-configmap.yaml` | Goes in chart — take his | High |
| `group-orthanc` pod | `xnat-ingest.yaml.tpl:28-78` (`--to-process-label`, `--wait-period`, loop 60) | `xnat-ingest-orthanc-group-pod.yaml` (no to-process-label, loop 300) | Goes in chart — merged, labels/loop as values | High |
| `assign` pod | `xnat-ingest.yaml.tpl:86-146` (ClinicalTrial* tags) | `xnat-ingest-assign-pod.yaml` (StudyDescription/PatientName/PatientID + `--scan`) | Goes in chart — one template, **tag mapping as a preset coupled to `deid.enabled`** | High |
| Grafana dashboards (4 JSON, 26 panels) | imperative `kubectl create cm \| label \| annotate` (`02d:164-173`) | absent | Goes in chart — `.Files.Glob` loop (**never inline**) | High |
| Loki ruler rules (11 alerts) | `observability/loki-ruler-rules.yaml` ConfigMap | absent | Goes in chart via `.Files.Get` (**never inline** — `{{ $labels.cluster }}`) | High |
| PrometheusRules (10 alerts) | `observability/alerts/{critical,warning,info}.yaml` | absent | Goes in chart (mgmt) | High |
| Alertmanager config | `alertmanager-config.yaml.tpl` → opaque Secret (`02d:68-85`) | absent | Goes in chart (mgmt); SMTP password via `existingSecret`; Go-template `text:` fields need backtick escaping | High |
| kube-prometheus-stack / Loki / vector-mgmt | 3 unpinned `helm upgrade` (`02d:94,115,129`) | absent | Goes in chart — **pinned `dependencies:`** under `observability.enabled` | High |
| Loki ruler-CM ordering hack (`02d:100-102`) | required today | n/a | Deleted by the chart (same-release ordering) | High |
| SeaweedFS ServiceMonitor CRD-ordering hack | `seaweedfs-servicemonitor.yaml:1-17` | n/a | Deleted by the chart | High |
| SeaweedFS deployment | `seaweedfs.yaml.tpl:17-164` | absent | Separate **mgmt chart** (our templates, not upstream SeaweedFS chart) | High |
| SeaweedFS S3 identities (`s3.json`) | bash heredoc → **plaintext ConfigMap** (`scripts/03:22-104`) | n/a | Mgmt chart: `range .Values.edges` → **Secret, not ConfigMap**. Fixes the 6-vs-7-field parse bug (`03:41` vs `00-common.sh:74`) by construction | High |
| SeaweedFS TLS cert + Ingress | `seaweedfs-tls-cert.yaml.tpl`, `seaweedfs-ingress.yaml.tpl` | absent | Mgmt chart; `{{#ONPREM_ONLY}}` awk → `{{- if eq .Values.topology "onprem" }}` | High |
| Observability TLS certs + Ingresses | `observability/tls-certs.yaml.tpl`, `observability-ingress.yaml.tpl` | absent | Mgmt chart | High |
| ingress-nginx (ssl-passthrough, 50g body) | 2 topology values files + `helm install` (`02c:87-90`) | absent | Mgmt chart, optional subchart; collapse the 2 files into one `if`. **Fixes the `02c:69` loadBalancerIP line-deletion bug** | High |
| cert-manager + CA issuers | `latest` URL (`02:45`) + `cert-issuers.yaml:14-47` | absent | Mgmt chart: pinned subchart + issuer CRs in a **separate release** (CRD ordering) | High |
| mgmt-side `xnat-upload` (S3→XNAT) | `xnat-upload.yaml.tpl:1-101` (24-line script) | architecturally different, not a duplicate | Mgmt chart — cleanest lift-and-shift. **Add `strategy: Recreate`** (missing today → two concurrent `--loop` uploaders on rollout), scope the S3 identity down from admin | High |
| Edge Vector DaemonSet | `manifests/02-edge/vector.yaml.tpl:21-237` | absent | Edge chart, `observability.enabled` flag. **Every bare `{{ cluster }}` at `:112-124` needs backtick escaping** | High |
| RBAC / ServiceAccounts | only Vector (`vector.yaml.tpl:27-52`) | none at all | Goes in chart — named SA + `automountServiceAccountToken: false` per workload (new, both sides) | High |
| De-id Lua hook | `config/orthanc/deidentify-and-forward.lua` (211 lines) | absent | Edge chart via `.Files.Get`, `orthanc.deid.enabled`. **Do not** reimplement as `xnat-ingest --deidentify` (broken for DICOM in 0.12.x) | High |
| De-id profile + HMAC salt | `deidentification-profile.json`, Secret `orthanc-deid-salt` | absent | Edge chart; salt = `existingSecret` **only**, never a values key | High |
| AET routing table (`routing.json`) | site-edited file, sole source of XNAT project | absent (project = a raw DICOM tag) | Edge chart as structured values → rendered; **mount outside `/etc/orthanc`** (Orthanc merges every `*.json` in that dir as server config — verified) | High |
| Quarantine of unmapped AET | Lua `:99-137`, write-then-delete, abort if no backup dir | absent | Edge chart — carry across **verbatim incl. the log string** the `DICOMRejectedUnmappedAET` alert matches | High |
| Facility backup of originals | Lua `:143-153` + hostPath `/data/facility-backup` | absent | Edge chart — **own PV**, `Retain` + `resource-policy: keep`, separate from the pipeline PV | High |
| JSON event logging (`AIS_LOG_FORMAT` + `jlog`) | `xnat-ingest.yaml.tpl:69-70,137-138,219-223` | `XINGEST_LOGGERS` file logging only | Edge chart — **both**; the event schema is a hard dependency of 11 alerts + 4 dashboards | High |
| Loop intervals / wait periods | `INGEST_LOOP_SECONDS`/`WAIT_PERIOD` = 60 | per-stage values, all 300 | Chart — his per-stage shape, our 60s default on the Orthanc path | High |
| Orthanc plugins / `DicomScuTimeout` | absent | `values.yaml:23-29` | Optional flag, default on (Explorer2 is useful) | High |
| Samba | absent | always-on (D3) | **Optional flag, default OFF**, `subPath: incoming` | High |
| fs / file-drop ingest | absent | `fsIngest.enabled: true` (D1) | **Optional flag, default OFF**, `unlinkSource: ""` | High |
| `associate` pod | absent | always-on idle (D5) | Optional flag, default OFF | High |
| StorageClass creation | local-path on mgmt only (`01:59-63`) | `storageclass.yaml` behind `create` | Edge chart, `create` flag (false on k0smotron children which have local-path) | High |
| k0s install / kubectl+helm bootstrap | `scripts/01` | n/a | **Stays script** (no API server exists) | High |
| cert-manager + k0smotron CRD install | `scripts/02` | n/a | Stays script / separate pre-pass | High |
| k0smotron `Cluster` CR | `edge-cluster.yaml.tpl:15-53` | absent | **Separate tiny mgmt chart**, one release per site. **Fix `persistence.type: emptyDir` (`:43-44`) → PVC before porting** | High |
| kubeconfig extract + join-token gzip/base64 rewrite | `scripts/05:51-116` | n/a | Stays script | High |
| SSH worker join, haproxy CA gen, CoreDNS overwrite | `scripts/06` | n/a | Stays script | High |
| CA export → `ais-edge-ca.crt` → per-edge `ca-bundle` Secret | `02b:56-59` → `07:30-40`, `07b:57-65` | n/a | Stays script (no Helm cross-cluster primitive); chart consumes by name | High |
| Loki push-token minting + cross-cluster copy | `02d:190-200` → `07b:41-53` | n/a | Stays script; chart references, **never creates** these Secrets | High |
| CA rotation (2-phase, weeks apart) | `scripts/rotate-ca.sh` | n/a | Stays script (runbook) | High |
| `clear-staged-s3.sh` (day-2 data op) | exec-into-pod, `weed shell` | n/a | Stays standalone tool | High |
| OpenStack Octavia LB pre-create | `scripts/00a` | n/a | **Stays external** — Terraform/OpenTofu, not Helm | High |
| OpenStack CCM | already a helm release (`01b:190`) | absent | Optional subchart, `cloud.enabled` | High |
| `uninstall.sh` | `rm -rf /data/xnat-ingest` on every edge (`:45`), `/data/seaweedfs` (`:63`) | n/a — structurally safe | Stays script, **but strip the `rm -rf`** into a separate type-the-word tool | High |
| S3 client (mc vs aws-cli) | `minio/mc:latest` + `rm -rf $session_dir` (`xnat-ingest.yaml.tpl:195,340`) | `amazon/aws-cli` + non-destructive fingerprint state (`s3sync.sh:27-28,38-43`) | **Goes in chart — standardise on aws-cli, adopt his non-destructive design, port our `jlog` schema onto it** | Med-High |
| Post-upload staging deletion | `rm -rf` after zero-exit mirror | fingerprint state file, never deletes | Chart — adopt his; make deletion an explicit opt-in value defaulting false | Med-High |
| SOPS | absent (secrets in `config/management.env`, live in working tree) | absent (interactive prompts) | Goes in chart infra — layered on top; **no template changes needed** | Med-High |
| Version pinning | nothing pinned (see §5c) | mostly pinned; aws-cli isn't | `Chart.yaml dependencies:` + pinned image values | High |
| S3 bucket creation | `mc` binary + port-forward + `mc mb` (`03:152-199`) | assumes bucket exists | Mgmt chart post-install **hook Job**, create-only | Med-High |
| Let's Encrypt DNS-01 issuers | `cert-issuers-letsencrypt.yaml.tpl` — **dead code**, `dns01-solvers/` has only README.md, `02b:89-95` hard-exits | absent | **User decision**: implement as a values map, or delete | Med |
| Edge Prometheus / kube-state-metrics | absent — 3 alerts can never fire (`critical.yaml:38-44`, `warning.yaml:40-48,50-57`) | n/a | **User decision** (see Q5) | Med |
| Loki bearer-token gate | minted + shipped + sent, **never validated** (`loki-values.yaml.tpl:25` `auth_enabled:false`, no ingress auth annotation anywhere) | n/a | **User decision** (see Q4) | Med |
| Orthanc DICOM exposure | hostPort 4242 | NodePort 30042/30842 | **User decision** (see Q2) — chart supports both | Med |
| Upload architecture | edge→S3→mgmt→XNAT | edge→XNAT direct | **User decision** (see Q1) — chart supports both as `upload.mode` | Med |
| Namespace name | `xnat-ingest` (in 11 LogQL selectors) | `ais-edge` | **User decision** (see Q3) | Med |
| `IngestTranscoding` | absent | `"1.2.840.10008.1.2.1"` (decompress on ingest) | **User decision** (see Q8) — transcode happens *before* the Lua hook, so `/facility-backup` would not be the wire original. UNVERIFIED ordering | Low |
| Orthanc version | 1.12.6 | 1.12.11 | **User decision** (see Q8) — needs a Lua regression test | Med |
| Cloud/OpenStack topology | full path, partly broken | absent | **User decision** (see Q9) | Med |

---

## 4. Proposed chart architecture

**Shape: three charts in one repo, not one chart.** A Helm release is scoped to exactly one cluster and one kubeconfig. In the k0smotron topology the mgmt plane and every edge plane are *different clusters*, so no single release can span them. Equally, forcing everything into one chart would break James's standalone single-VM sites, which have no mgmt plane at all.

* **`charts/edge`** — **one chart with feature flags**, not subcharts. Every template is ours or James's; there are no upstream dependencies worth pulling in (we deliberately hand-write the Vector DaemonSet for the bearer/CA/hostAliases specifics). Feature flags, not subcharts, because the components are not independently releasable — Orthanc, group, assign and upload are one pipeline sharing one PVC.
* **`charts/mgmt`** — **parent chart with subcharts**. Five of its components already *are* upstream Helm releases (`cert-manager`, `ingress-nginx`, `kube-prometheus-stack`, `loki`, `vector`, `openstack-cloud-controller-manager`). A `dependencies:` block is the only mechanism that pins their versions, which is the single strongest reason to move at all (§5c).
* **`charts/mgmt-edge-cluster`** — a 1-template chart holding the k0smotron `Cluster` CR, installed once per site. Separate because its lifecycle is per-site, not per-fleet.

```
charts/
  edge/
    Chart.yaml                     # no dependencies
    values.yaml
    files/
      deidentify-and-forward.lua   # .Files.Get — never inlined
      deidentification-profile.json
      s3sync.sh                    # aws-cli, from James, + our jlog()
      upload.sh
    templates/
      namespace.yaml               # resource-policy: keep
      storageclass.yaml            # if .Values.storage.storageClass.create
      storage-pipeline.yaml        # PV+PVC, Retain + keep
      storage-facility-backup.yaml # SEPARATE PV+PVC, Retain + keep
      serviceaccounts.yaml
      orthanc-{configmap,routing-cm,deid-cm,deployment,service}.yaml
      ingest-{orthanc-group,fs-group,assign,associate,upload}.yaml
      s3sync-{configmap,deployment}.yaml
      samba-deployment.yaml        # if .Values.samba.enabled
      vector-{rbac,configmap,daemonset}.yaml   # if .Values.observability.enabled
      NOTES.txt
  mgmt/
    Chart.yaml                     # dependencies: cert-manager, ingress-nginx,
                                   #   kube-prometheus-stack, loki, vector,
                                   #   openstack-cloud-controller-manager — ALL PINNED
    values.yaml
    files/
      loki-ruler-rules.yaml        # .Files.Get
      dashboards/*.json            # .Files.Glob
      alertmanager-config.yaml
    templates/
      cert-issuers.yaml            # + letsencrypt, if enabled
      seaweedfs-{configsecret,deployment,service,cert,ingress}.yaml
      seaweedfs-bucket-job.yaml    # post-install hook, create-only
      xnat-upload.yaml             # + strategy: Recreate
      observability-{certs,ingress,rules,dashboards,servicemonitor}.yaml
  mgmt-edge-cluster/
    templates/cluster.yaml         # k0smotron Cluster CR, PVC-backed persistence
bootstrap/                         # ex-scripts/ — cluster creation only
  00-common.sh 01-k0s.sh 02-crds.sh 02b-ca-export.sh
  05-edge-cluster.sh 06-join-worker.sh 08-distribute-secrets.sh
  rotate-ca.sh uninstall.sh (non-destructive) purge-data.sh (type-the-word)
```

### `charts/edge` values.yaml top-level keys

```yaml
namespace:            # default xnat-ingest  (see Q3)
nameOverride / fullnameOverride:
topology:             # onprem | cloud     — replaces {{#ONPREM_ONLY}}
storage:
  storageClass: {create:, name:}
  pipeline:        {hostPath:, capacity:}
  facilityBackup:  {enabled:, hostPath:, capacity:}
orthanc:
  image: {repository:, tag:, pullPolicy:}
  aet: dicomPort: httpPort: stableAge: plugins: ingestTranscoding: dicomScuTimeout:
  auth:   {enabled:, existingSecret:}
  expose: {dicom: hostPort|nodePort|both, hostPort:, nodePorts:{dicom:,http:}, http: ClusterIP|nodePort}
  deid:   {enabled:, policyReviewed:, existingSaltSecret:, aetMap:{}, profile:{}}
  podSecurityContext: securityContext: resources: probes:
pipeline:
  image: {repository:, tag:, pullPolicy:}
  logFormat: json
  orthancGroup: {enabled:, interval:, toProcessLabel:, processedLabel:, copyMode:}
  fsGroup:      {enabled: false, interval:, inputGlob:, datatypes:, unlinkSource: ""}
  assign:       {interval:, tagMapping:{project,subject,sessionLabel,sessionUid,scanDesc}, unlinkSource:}
  associate:    {enabled: false, ...}
upload:
  mode: direct | s3            # see Q1
  direct: {enabled:, replicas:, existingSecret: xnat-credentials, loop:, waitPeriod:, verifySsl:, ...}
  s3:     {enabled:, endpoint:, bucket:, prefix:, region:, addressingStyle: path,
           existingSecret: s3-edge-credentials, caBundleSecret: ca-bundle,
           interval:, settleMinutes:, deleteAfterUpload: false}
samba:
  enabled: false
  image: shareName: existingSecret: subPath: incoming
observability:
  enabled: false
  clusterLabel:
  loki: {endpoint:, tokenSecret:, caBundleSecret:}
  vector: {image:, resources:}
serviceAccounts: {create: true, automountToken: false}
```

### `charts/mgmt` values.yaml top-level keys

```yaml
topology: onprem|cloud
domain: {internal:, mgmtNodeIP:}
hostnames: {seaweedfs:, k0sApi:, konnectivity:, grafana:, loki:, ingressPort:}
certManager: {enabled:, issuer: ais-edge-ca-issuer|letsencrypt-prod|..., acmeEmail:, dns01Solver:{}}
ingressNginx: {enabled:, loadBalancerIP:, ...}
seaweedfs:  {enabled:, image:, storage:{...}, buckets:[], existingIdentitiesSecret:}
edges: [{name:, s3AccessKey:, s3SecretKey:, lokiToken:}]   # typed — kills the pipe-parse bug
xnatUpload: {enabled:, image:, existingSecret:, bucket:, prefix: staged, loop:}
observability:
  enabled:
  prometheusReleaseLabel:            # NOT hardcoded "kube-prometheus-stack"
  retentionDays: lokiRetentionHours:
  loki: {storage: filesystem|s3, ...}   # filesystem needed for tier-1
  alerting: {existingSmtpSecret:, emailTo:, slackWebhookSecret:}
cloud: {enabled:, provider: openstack, existingCloudConfigSecret:}
# subchart keys, versions pinned in Chart.yaml:
cert-manager: {} ; ingress-nginx: {} ; kube-prometheus-stack: {} ; loki: {} ; vector: {}
```

**One hard chart-level landmine to design around:** `release: kube-prometheus-stack` is hardcoded as a discovery label in 5 places (`kube-prometheus-stack-values.yaml.tpl:47,50,53`; `alerts/{critical,warning,info}.yaml:15`; `seaweedfs-servicemonitor.yaml:24`; `loki-values.yaml.tpl:143`) and the derived Service name `kube-prometheus-stack-grafana` in `observability-ingress.yaml.tpl:35`. If the subchart release name changes, Prometheus silently stops loading our rules and the Grafana Ingress 503s. Make it `.Values.observability.prometheusReleaseLabel` in the same commit that introduces the subchart.

---

## 5. The three cross-cutting workstreams

### (a) S3 client standardisation → `aws-cli`

**Call sites that change:**

| File:line | Today | Change |
|---|---|---|
| `manifests/02-edge/xnat-ingest.yaml.tpl:195` | `image: minio/mc:latest` | `amazon/aws-cli:<pinned>` |
| `:219-223` | `jlog()` emitter | **keep verbatim** — port onto the new script |
| `:225,262,266,269,319,328,338,343` | events `startup`, `alias_failed`, `alias_retrying`, `alias_configured`, `upload_started`, `upload_skipped`, `upload_completed`, `upload_failed` | **reproduce byte-for-byte** |
| `:248-269` | `mc alias set` + 12-attempt probe → `exit 1` | replace with `aws s3api head-bucket` probe, same fail-fast semantics |
| `:327-336` | `mc --json mirror --overwrite` | `aws s3 sync` |
| `:340` | `rm -rf "$session_dir"` | **delete** — replace with James's fingerprint state file (`helm/edge/files/s3sync.sh:27-28,39`) |
| `:353-365` | CA Secret mounted at `/root/.mc/certs/CAs` (a *directory*) | `AWS_CA_BUNDLE=/etc/ssl/ais-edge-ca/ca.crt` (a *single file*) |
| `scripts/03-deploy-seaweedfs.sh:152-156,161-165,168-183,185-193,198-199` | curl-install `mc`, background port-forward, `mc alias set`, `mc mb`, host alias | one post-install hook Job running `aws s3api create-bucket` in-cluster |
| `scripts/clear-staged-s3.sh:63-64,67-74,78-115` | `mc ls --recursive` in-pod for counts, `weed shell → fs.rm -r` for deletion | counts → `aws s3 ls --recursive`; **keep `weed shell`** for deletion (it exists because `mc rm --recursive` leaves 0-byte SeaweedFS directory entries — that is a SeaweedFS filer quirk, not an S3-client one) |
| `manifests/01-management/xnat-upload.yaml.tpl:94,96` | already `AWS_ENDPOINT_URL` + `AWS_DEFAULT_REGION` | **no change** — mgmt side is already AWS-native |
| `manifests/01-management/observability/loki-values.yaml.tpl:37-49` | `s3ForcePathStyle: true`, `insecure: true` | no change — Loki's own client, already path-style |
| `helm/edge/values.yaml:116` | `amazon/aws-cli:latest` | pin |

**What breaks against SeaweedFS:**

1. **Addressing style.** aws-cli v2 defaults to virtual-hosted style. SeaweedFS is served at one hostname (`seaweedfs.aisedge.local`) with a single-SAN cert (`seaweedfs-tls-cert.yaml.tpl:28`), so `<bucket>.seaweedfs.aisedge.local` fails DNS *and* cert validation. Must set `AWS_S3_ADDRESSING_STYLE=path` (or `s3.addressing_style = path` in the config file). `mc` did this implicitly.
2. **Custom CA.** `mc` reads every PEM in `/root/.mc/certs/CAs/`. aws-cli needs `AWS_CA_BUNDLE` pointing at **one file**. The Secret mount changes from a directory to a `subPath`-style single-key file. This is the easiest thing to get silently wrong at cutover.
3. **Region.** SeaweedFS ignores it, but aws-cli **refuses to run without one**. Set `AWS_DEFAULT_REGION=us-east-1` to match `xnat-upload.yaml.tpl:96` and `loki-values.yaml.tpl:41`.
4. **Endpoint.** `AWS_ENDPOINT_URL` (aws-cli ≥ 2.13) or `--endpoint-url` on every call.
5. **Checksums — UNVERIFIED, must test.** Recent aws-cli v2 sends `x-amz-checksum-*` / CRC32 integrity headers by default on upload. SeaweedFS 3.99's S3 gateway may reject or mishandle them. Mitigation if so: `AWS_REQUEST_CHECKSUM_CALCULATION=when_required`. **Test this first — it is the most likely hard blocker.**
6. Multipart body limits are already handled: `seaweedfs-ingress.yaml.tpl:25-30` sets `proxy-body-size 50g`, `proxy-request-buffering off`.

**Migration order (do not reorder — steps 1-3 are reversible, 4 is not):**
1. Pin both image tags (`xnat-ingest.yaml.tpl:195`, `values.yaml:116`). Zero behaviour change.
2. Port `jlog()` + all 8 event names onto James's `s3sync.sh`; add the endpoint/CA/region/path-style env. Do **not** deploy yet.
3. Run the new script **alongside** the existing mc uploader in dev, targeting a scratch prefix. Diff the Loki event stream against the old one — every one of the 11 ruler rules must still match. Confirm the checksum behaviour from (5).
4. Swap the edge uploader. **Ship it with `deleteAfterUpload: false`** — the fingerprint state file replaces the `rm -rf`.
5. Convert `scripts/03`'s bucket bootstrap to the hook Job.
6. Rewrite `clear-staged-s3.sh`'s counting half; leave the `weed shell` deletion half alone.

### (b) SOPS

**Files that get encrypted:**

| File | Contains |
|---|---|
| `config/management.env` | **live** Gmail app password + Grafana admin password (`:52-68`), `AIS_DEID_HMAC_SALT` (`:50`), `XNAT_PASS`, `S3_ADMIN_*`. Gitignored today (`.gitignore:2`) but present in the working tree. |
| `config/edge-nodes.env` | per-edge S3 access/secret keys |
| new `sites/<site>/secrets.enc.yaml` | per-site chart values: XNAT creds, Orthanc creds, Samba creds, S3 creds, deid salt |
| new `sites/<site>/values.yaml` | **not** encrypted — non-secret site config (AET map, hostnames, flags) |

**Key management — recommend `age`, not KMS.** Reasons: no cloud dependency at install time (edge VMs are on-prem and sometimes air-gapped), no IAM to provision per site, keys are a single 60-char string that fits in a password manager. Shape: one **team recipient key** (all operators can decrypt everything) + one **per-site recipient key** held on that site's admin box, both listed as recipients in `.sops.yaml` creation rules keyed by path. Move to KMS only if you later need per-operator revocation with an audit trail.

**How the chart/installer consumes them:** the charts **never** see plaintext. Two supported paths:
* `helm secrets upgrade --install ... -f sites/<site>/secrets.enc.yaml` (helm-secrets plugin decrypts to a temp file, deletes it after), or
* a bootstrap step: `sops -d sites/<site>/secrets.enc.yaml | kubectl apply -f -` creating the Secrets, then plain `helm upgrade` referencing them by name.

The second is strictly better and is what both codebases already imply: James's pods reference `orthanc-credentials` / `samba-credentials` / `xnat-credentials` / `s3-credentials` purely via `secretKeyRef`/`envFrom`, and ours will once §3's "credentials by reference" row lands. **This means SOPS can be bolted on without editing a single template.** Make it the governing design rule: *charts contain references, never credentials.*

**What stays as ordinary k8s Secrets, not SOPS-managed** (they are generated in-cluster and have no plaintext source of truth): `ais-edge-ca-secret` and every cert-manager-issued cert; `<cluster>-kubeconfig` and `<cluster>-ca` from k0smotron; `loki-push-token-<cluster>` (minted by `openssl rand`, `02d:190-200`); `ca-bundle` on each edge (derived from the mgmt CA). These continue to be created and distributed by the bootstrap scripts.

**Do not rotate the HMAC salt while doing this.** Move the existing value into SOPS as-is — see Q11.

### (c) Version pinning — every unpinned dependency

| File:line | Dependency | State |
|---|---|---|
| `scripts/02-install-k0smotron.sh:45` | cert-manager | `.../releases/**latest**/download/cert-manager.yaml` |
| `scripts/02-install-k0smotron.sh:55` | k0smotron | `https://docs.k0smotron.io/**stable**/install.yaml` |
| `scripts/02d-install-observability.sh:94` | `prometheus-community/kube-prometheus-stack` | no `--version` (local cache already shows 7 versions, 84.3.0 → 87.19.2) |
| `scripts/02d-install-observability.sh:115` | `grafana/loki` | no `--version` (cache: 7.0.0, 7.1.0) |
| `scripts/02d-install-observability.sh:129` | `vector/vector` | no `--version` |
| `scripts/02c-install-nginx-ingress.sh:87` | `ingress-nginx/ingress-nginx` | no `--version` |
| `scripts/01b-install-cloud-controller.sh:190` | `cpo/openstack-cloud-controller-manager` | no `--version` |
| `scripts/01-install-k0s.sh:21` | k0s (mgmt) | `curl -sSLf https://get.k0s.sh \| sudo sh` — latest |
| `scripts/06-join-edge-worker.sh:120` | k0s (edge worker) | same — **can drift from the mgmt/control-plane version** |
| `scripts/01-install-k0s.sh:55` | helm binary | `get-helm-3` from `helm/helm@**main**` |
| `manifests/02-edge/xnat-ingest.yaml.tpl:195` | `minio/mc` | `:latest` |
| `helm/edge/values.yaml:116` | `amazon/aws-cli` | `:latest` |
| `scripts/04-deploy-xnat-upload.sh:18` | xnat-ingest | falls back to `:latest` if `XNAT_INGEST_IMAGE` unset |

*Pinned but hardcoded rather than templated (fix while porting):* `manifests/01-management/edge-cluster.yaml.tpl:22` k0s `v1.35.2+k0s.0`; `manifests/01-management/seaweedfs.yaml.tpl:48` `chrislusf/seaweedfs:3.99`; `manifests/02-edge/vector.yaml.tpl:178` `timberio/vector:0.49.0-distroless-libc`.

*Correctly pinned today:* `scripts/01-install-k0s.sh:60` local-path-provisioner `v0.0.30`; James's `orthanc 1.12.11`, `samba 4.23.5`, `busybox:1.36`, `xnat-ingest 0.12.3`.

Also drifting: `config/management.env.template:233` pins xnat-ingest `0.12.3` but the live mgmt deployment runs `0.12.1` (step 04 not re-run).

---

## 6. Open questions for the user

1. **Upload architecture — which is the default?** Edge→XNAT direct (James: no SeaweedFS, no CA plumbing, no mgmt cluster) vs edge→central S3→mgmt uploader→XNAT (ours: buffering, central retry, one XNAT credential). This determines whether the whole k0smotron/SeaweedFS management half is still needed for new sites.
   → **Recommendation: build both as `upload.mode`, default `direct` in `charts/edge`, keep `s3` for the existing k0smotron fleet.** They must never both be enabled for one data path (double uploads into XNAT).

2. **Orthanc DICOM exposure default:** our `hostPort 4242` vs James's `NodePort 30042`. Whichever loses, that cohort's scanners stop talking until every modality is reconfigured.
   → **Recommendation: default `hostPort: 4242`** (standard DICOM port; you cannot easily repoint clinical modalities), NodePort available as a per-site value. Note hostPort pins the pod to one node — fine for single-node edges.

3. **Namespace name:** ours `xnat-ingest`/`xnat-upload` vs his `ais-edge`. `xnat-ingest` and `xnat-upload` are hardcoded literals in 11 Loki ruler rules and both drilldown dashboards; renaming fails *open* (no alerts, no error).
   → **Recommendation: keep `xnat-ingest` as the chart default**, templated as `.Values.namespace` so James's sites can override.

4. **Loki push bearer token:** verified security theatre. Tokens are minted (`02d:190-200`), shipped (`07b:41-53`) and sent (`vector.yaml.tpl:96-98`) but `auth_enabled: false` (`loki-values.yaml.tpl:25`) and there is no auth annotation anywhere (`grep -rn "auth-" manifests/` → nothing). `loki.<domain>:443` currently accepts unauthenticated writes from anything that can route to it.
   → **Recommendation: fix it — add `nginx.ingress.kubernetes.io/auth-*` on the Loki Ingress.** The end-to-end plumbing already exists; only the annotation is missing. Avoid Loki multi-tenancy — turning on `auth_enabled` changes tenant IDs and orphans existing chunks in `logs-bucket`.

5. **Edge cluster metrics.** Three Prometheus alerts (`EdgeWorkerDisconnected`, `KonnectivityTunnelFlapping`, `EdgePodCrashLoop`) query objects that exist only on edge clusters, which the mgmt Prometheus cannot scrape (konnectivity is one-way — stated at `loki-ruler-rules.yaml:10-13`). They can never fire.
   → **Recommendation: re-express them as Loki absence rules over Vector's own log stream and drop the Prometheus versions for the k0smotron topology; keep them enabled for single-cluster/tier-1 where they do work.** Adding edge-side Prometheus + remote-write is a whole new component and auth surface — don't.

6. **File-drop retention policy.** If Samba/fs ingest is used at all, `/data/incoming` has no Orthanc copy and no facility backup, so *something* must stop re-processing without deleting.
   → **Recommendation: `fsIngest.unlinkSource: ""` always, plus a processed-marker or move-to-`processed/` scheme.** Refuse `all` at values-validation time unless a facility-backup equivalent is configured for the fs path.

7. **SOPS key management: age vs KMS.**
   → **Recommendation: age.** One team recipient + one per-site recipient, `.sops.yaml` creation rules keyed by path.

8. **Orthanc version + `IngestTranscoding`.** Ours 1.12.6, his 1.12.11. His enables `IngestTranscoding: "1.2.840.10008.1.2.1"`, which rewrites pixel data *at receive time, before* the Lua `OnStoredInstance` hook — so `/facility-backup` would hold the transcoded copy, not the wire original. (Ordering is UNVERIFIED against Orthanc 1.12.x — worth confirming empirically.)
   → **Recommendation: standardise on 1.12.11 after a Lua regression test; default `ingestTranscoding: ""` (off) whenever deid + facility backup are enabled.**

9. **Is cloud/OpenStack topology still in scope?** It adds a whole conditional dimension and the `LB_PUBLIC_IP` path is currently broken anyway (`scripts/02c:69` line-deletes `loadBalancerIP`; both branches render byte-identically).
   → **Recommendation: park it.** Keep `topology: onprem|cloud` as a values key so templates stay ready, but do not port `00a-precreate-lb.sh` (that's Terraform work) until a cloud site is actually queued.

10. **Let's Encrypt DNS-01: implement or delete?** `manifests/01-management/dns01-solvers/` contains only `README.md`, so `02b:89-95` hard-exits for every `DNS_PROVIDER` value and `cert-issuers-letsencrypt.yaml.tpl` is unreachable dead code.
    → **Recommendation: delete it from the port.** Re-add as a `certManager.dns01Solver` values map (`toYaml | nindent`) when a site actually needs public certs — that's ~10 lines and strictly better than the sed-indent splice.

11. **De-id HMAC salt: rotate or preserve?** `config/management.env:50` holds a real 64-hex salt in the working tree. Changing it re-links every subject/session pseudonym — existing XNAT subjects would stop matching new arrivals.
    → **Recommendation: preserve the existing salt, move it into SOPS unrotated.** Separately: the pseudonym hash is a salted djb2 (`deidentify-and-forward.lua:26-37`, ~64-bit) because the Orthanc Lua API exposes no hash primitives. If pseudonym strength matters, that's a move to `jodogne/orthanc-python` and a real HMAC — a separate decision.

12. **Landing branch.** `origin/tier-1-solution` already carries a *stale* `helm/edge` marked "REFERENCE ONLY", pinned to the old design (xnat-ingest 0.9.1, a `sort` pod, `proxy-configmap`), plus a filesystem-storage Loki variant. Landing the consolidated chart there means **replacing** that chart, not merging into it.
    → **Recommendation: land on `main`, then rebase `tier-1-solution` onto it and delete the stale copy.** Make sure `observability.loki.storage: filesystem|s3` and `seaweedfs.enabled` exist as values or tier-1 forks again immediately.

---

## 7. Risk register

**Data-safety risks first.**

| # | Risk | Where | Mitigation |
|---|---|---|---|
| R1 | **`uninstall.sh` destroys received DICOM.** `scripts/uninstall.sh:45` does `sudo rm -rf /data/xnat-ingest` on every edge VM — `orthanc-storage/` lives under that path. `:63` wipes `/data/seaweedfs`, i.e. staged sessions not yet in XNAT. Only `/data/facility-backup` survives. Gated by nothing but a `-y` prompt. | `uninstall.sh:45,63,108-112` | Adopt James's pattern **everywhere**: `Retain` + `helm.sh/resource-policy: keep` on namespace/PV/PVC (`storage.yaml:6-8,31-33`) makes this structurally impossible. Strip the `rm -rf` lines out of `uninstall.sh` into a separate `purge-data.sh` requiring a typed confirmation word (the pattern `clear-staged-s3.sh:78-89` already uses). |
| R2 | **Adopting James's `values.yaml` as the baseline ships source deletion as the default.** `fsIngest.unlinkSource: all` with `fsIngest.enabled: true` deletes the operator's Samba-dropped files, which have no second copy. | `helm/edge/values.yaml:80,86,92` | Default **every** `unlinkSource` to `""`. Require explicit per-site opt-in. State the never-delete policy in the values comment. Keep our two intermediate deletions (grouped, staging-after-verified-upload) only because Orthanc storage + facility backup demonstrably retain originals — and make each a value. |
| R3 | **Dropping the `rm -rf` without a replacement stalls the pipeline instead.** `xnat-ingest.yaml.tpl:120-133` documents that without unlink, `--loop` re-assigns the same sessions forever, re-uploading and re-firing alerts. "Retain everything" has a real operational cost. | `xnat-ingest.yaml.tpl:120-133,340` | Adopt James's content-fingerprint state file (`s3sync.sh:27-28,39`) — it achieves "don't re-process" without deleting anything, and incidentally removes the failure mode that `clear-staged-s3.sh` exists to clean up (empty staged prefixes re-firing `XNATUploadSuccess`, observed ~2 alerts/min for 2 days on 2026-07-29). |
| R4 | **Losing the unmapped-AET quarantine.** `deidentify-and-forward.lua:99-137` writes originals to `__unmapped_aet__/` and deletes from Orthanc **only if that write succeeded**, aborting entirely if no backup dir is set. This is the concrete never-delete guarantee for the most likely real failure (a new or mistyped scanner AE title). | Lua `:99-137` | Carry across verbatim, including write-then-delete ordering, the abort-on-no-backup-dir branch, and the exact log string `REJECT: no project mapped for CalledAET` that `DICOMRejectedUnmappedAET` matches. `docs/components/orthanc.md:111` is stale (still says unmapped instances are deleted with no backup) — fix the doc. |
| R5 | **Facility-backup volume fills the disk unnoticed.** It is unbounded by design and there is no alert on its free space. Additionally, switching Orthanc to uid 10001 breaks writes into the root-owned `0750` dir created by `scripts/07c:71`, and the Lua `writeAtomic()` shells out to `mkdir -p`/`mv` (`:47,58`) which fails with a printed ERROR (instance kept, but nothing forwarded). | `07c:69-71`, `orthanc.yaml.tpl:109-112` | Model it as its **own** PV with `Retain` + `keep`, chown it in the same init-container, and add a disk-free alert before the non-root switch ships. Test on one site before fleet rollout. |
| R6 | **k0smotron hosted control plane uses `emptyDir`.** A control-plane pod restart discards the child cluster's datastore. (UNVERIFIED that state is actually lost — emptyDir semantics make it near-certain; the pod was not restarted to confirm.) | `edge-cluster.yaml.tpl:43-44` | Make persistence a PVC-backed value in `charts/mgmt-edge-cluster` before porting the CR as-is. |
| R7 | **Re-running step 03 breaks edge S3 auth silently.** `scripts/03-deploy-seaweedfs.sh:41` parses **7** pipe fields; `scripts/00-common.sh:74` parses **6**. Against the committed 6-field `config/edge-nodes.env:3`, step 03 emits `accessKey="edge-writer-secret-change-me"`, `secretKey=""` while step 07 hands the uploader `edge-writer`/`edge-writer-secret-change-me`. The live ConfigMap (2026-07-08) still holds the correct pair, so today's cluster works — until step 03 re-runs. | `03:41` vs `00-common.sh:74` | Fix before any port, or a typed `edges: [{name, s3AccessKey, s3SecretKey}]` values list carries the fix by construction. Neither field layout currently satisfies both parsers. |
| R8 | **S3 client swap silently kills monitoring.** All 11 Loki ruler rules and 2 dashboards key off `component="s3-uploader"` and exact `event=` values from our `jlog()`. `aws s3 sync --only-show-errors` emits none of them. Failure mode is silence, not error. | `xnat-ingest.yaml.tpl:219-223,225-343`; `loki-ruler-rules.yaml` | Port the event schema byte-for-byte onto the aws-cli script **before** cutover; run both in parallel in dev and diff the Loki stream (§5a step 3). |
| R9 | **CA trust path changes shape during the S3 swap.** `mc` reads a *directory* of PEMs (`/root/.mc/certs/CAs`); aws-cli needs `AWS_CA_BUNDLE` pointing at a *single file*. Easy to miss; fails as a TLS error at runtime, not install time. | `xnat-ingest.yaml.tpl:353-365` | Change the volume mount to a single-key `subPath` in the same commit as the client swap; smoke-test against the self-signed SeaweedFS cert. |
| R10 | **Helm double/triple templating eats runtime templates.** Bare `{{ cluster }}`, `{{ kubernetes.pod_namespace }}` (`vector.yaml.tpl:112-124`), `{{ $labels.cluster }}` (every ruler annotation), `{{ range .Alerts }}` / `{{ .CommonLabels.session }}` (`alertmanager-config.yaml.tpl:92,102-108`), and Grafana `line_format "{{.component}}"` in all 4 dashboard JSONs. The mgmt Vector values file already carries backtick escaping for the Vector chart's own `tpl` call (`vector-mgmt-values.yaml.tpl:122-133`); the edge manifest does not. Two escaping regimes for the same config. | as listed | **Rule: load all of these via `.Files.Get`/`.Files.Glob`, never inline into a template.** Verify with `helm template` and inspect the rendered ConfigMaps before merging. This is the top source of subtle breakage in the port. |
| R11 | **Renaming the observability Helm release breaks rule loading and the Grafana Ingress, silently.** `release: kube-prometheus-stack` is a hardcoded discovery label in 5 files; `kube-prometheus-stack-grafana` is a hardcoded Service name in the Ingress. | see §4 landmine | Introduce `.Values.observability.prometheusReleaseLabel` and `{{ .Release.Name }}`-derived Service names in the same commit as the subchart. |
| R12 | **Non-root Orthanc migration breaks existing sites.** Existing `/data/xnat-ingest/orthanc-storage` is root-owned `777` from earlier installs; the init-container `chown` is non-recursive (`orthanc-deployment.yaml:31`) and Orthanc's SQLite index must be writable afterwards. | `orthanc-deployment.yaml:24-38` | Make the chown recursive for the migration, or run a one-off migration job. Test on one site before fleet rollout. |
| R13 | **Path migration between the two storage layouts.** Ours: `/data/xnat-ingest/{orthanc-storage,grouped,staging}` + `/data/facility-backup`. His: `/data/ais-edge/{orthanc-storage,grouped,assigned,incoming,LOGS,tmp}`. All pipeline stages must stay on **one** filesystem or `hardlink_or_copy` degrades to copy (`orthanc.yaml.tpl:84-86` notes EXDEV). UNVERIFIED: whether hardlinks work across `subPath`s of the same hostPath PV (they should — same inode namespace). | `storage.yaml`, `orthanc.yaml.tpl:84-86` | Pick one layout, verify hardlinking empirically on a test VM, write a migration note. Default the chart's `hostPath` to our existing path so live sites migrate without moving bytes. |
| R14 | **Unpinned everything.** Six Helm releases with no `--version`, cert-manager from `latest`, k0smotron from `stable`, k0s from `get.k0s.sh` on both the mgmt node and each edge worker independently (they can drift apart). A rebuild months from now is not reproducible. | §5c table | `Chart.yaml dependencies:` with explicit versions fixes six of them by construction; pin the rest explicitly, including a single `k0sVersion` value shared by `scripts/01`, `scripts/06` and `edge-cluster.yaml.tpl:22`. |
| R15 | **The working tree is ahead of `main` by 988 uncommitted insertions** across 5 observability files plus modified `deidentify-and-forward.lua` and `xnat-ingest.yaml.tpl`, and `scripts/clear-staged-s3.sh` is untracked. Anyone porting from `main` gets a materially older, smaller stack than what is described here. | `git status` | Commit or stash this **before** the consolidation branch is cut, or the port silently drops the newer dashboards, alert rules and Lua changes. |
| R16 | **`helm/setup.sh` is broken on Helm 3** (D2) and hardcodes the namespace (D4). Any site that runs it today fails at the install step. | `helm/setup.sh:134,9` | Same-day follow-up PR: `--atomic`, and read the namespace from the values file. |
| R17 | **Orthanc merges every `*.json` in `/etc/orthanc` as server config** — verified by running the image against our config dir; it reads `orthanc.json`, `deidentification-profile.json` **and** `routing.json` in non-deterministic filesystem order, later files overriding earlier keys. A future `"Name"` or `"DicomAet"` key in `routing.json` silently reconfigures the server. | `orthanc.yaml.tpl:53,76-83` | Mount `routing.json` and the deid profile under a non-config path (`/etc/ais-edge/`) and point `AIS_ROUTING_FILE` there. |
| R18 | **`StableAge: 30` is load-bearing and absent from James's ConfigMap.** `OnStableStudy` (`deidentify-and-forward.lua:197-211`) applies the `xnat-ingest-ready` label that `group-orthanc` filters on. Drop it in the merge and nothing is ever labelled — the pipeline stalls with data sitting in Orthanc and no error. | `config/orthanc/orthanc.json:13` vs `orthanc-configmap.yaml:9-26` | Add `stableAge` (default 30) to the templated ConfigMap; couple `--to-process-label` to `deid.enabled` so the label gate and the labeller are always both on or both off. |
| R19 | **Samba over-exposure** (D3): the whole PVC at `/storage` includes `orthanc-storage/` (raw or de-identified DICOM depending on layout) and `LOGS/`, plus `hostPort 445` conflicting with any host `smbd`. | `samba-deployment.yaml:42-47,51-53` | `samba.enabled: false` default; mount `subPath: incoming` only; move `/data/LOGS` off any Samba-exposed subPath. |
| R20 | **Unauthenticated Loki write endpoint** (Q4) and **unauthenticated Orthanc REST with delete rights** (`config/orthanc/orthanc.json:15-16` — mitigated today only by ClusterIP, but James's default is NodePort 30842). | as listed | Adopt James's `AuthenticationEnabled: true` + `orthanc-credentials`; add the Loki ingress auth annotation. Both are cheap; both become dangerous the moment the current mitigating accident (ClusterIP-only / route reachability) changes. |
---

# Appendix A — AWS CLI vs SeaweedFS 3.99: measured results

Run 2026-08-04 against the live SeaweedFS on stream-2-ab-dev
(`version 30GB 3.99 a80b5eea5`) using `amazon/aws-cli:2.31.19`, from a pod in
the mgmt cluster. Scratch prefix `s3://ingest-bucket/__awscli-probe__`,
outside `staged/` so the uploader could not see it. All artefacts removed
afterwards; `staged/` untouched throughout and active alerts stayed at 0.

## Result summary

| # | Test | Result |
|---|---|---|
| 1 | `s3api head-bucket` (liveness probe) | PASS |
| 2 | `s3 ls` | PASS |
| 3 | `s3 sync` of a session, **default checksum behaviour** | PASS, exit 0 |
| 4 | Round-trip md5 of a 1 MiB object | Identical |
| 5 | **Multipart** 50 MiB over plain HTTP | PASS, md5 identical, 3.5 s |
| 6 | Incremental re-`sync` | Transferred nothing |
| 7 | Explicit `--checksum-algorithm CRC32` | Accepted, ETag returned |
| 8 | HTTPS through nginx ingress + `AWS_CA_BUNDLE` | PASS |
| 9 | **Multipart** 50 MiB over HTTPS through the ingress | PASS, md5 identical |

**The feared blocker did not materialise.** AWS CLI v2's default integrity
headers are accepted by SeaweedFS 3.99 for both single-part and multipart
uploads. `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` is NOT needed.

## Three findings that change the design

### A1. Path-style addressing is automatic — and `AWS_S3_ADDRESSING_STYLE` is not a thing

`--debug` shows botocore resolving with `'ForcePathStyle': True` purely
because a custom `AWS_ENDPOINT_URL` is set:

```
botocore.regions - Calling endpoint provider with parameters:
  {'Bucket': 'ingest-bucket', 'Endpoint': 'https://seaweedfs.aisedge.local',
   'ForcePathStyle': True, ...}
botocore.regions - Endpoint provider result:
  https://seaweedfs.aisedge.local/ingest-bucket
```

`AWS_S3_ADDRESSING_STYLE` is a config-FILE key, not an environment variable —
`aws configure list` never shows it and setting it changed nothing. A values
key for it would have been silently ignored, so the chart has none.

### A2. An empty `AWS_CA_BUNDLE` silently disables TLS verification

This is the trap. Unset and empty behave differently:

```
env -u AWS_CA_BUNDLE   -> SSL: CERTIFICATE_VERIFY_FAILED
                          unable to get local issuer certificate     (correct)
AWS_CA_BUNDLE=''       -> urllib3 InsecureRequestWarning:
                          Unverified HTTPS request is being made      (!!)
```

With the empty string, a request to `https://10.108.222.5` — a hostname the
certificate does not cover — **succeeded**. With the real CA the same request
correctly failed on SAN validation.

A Helm template that renders `AWS_CA_BUNDLE: "{{ .Values...caBundle }}"` with
an unset value therefore produces a pod that talks to the staging bucket with
no certificate validation at all, and logs only a warning. Requirements:

* emit `AWS_CA_BUNDLE` **only** when it has a real value;
* `fail` at render time on an `https://` endpoint with no CA configured.

### A3. The ghost-prefix bug is SeaweedFS, not `mc` — switching client does not fix it

`aws s3 rm --recursive` leaves exactly the same 0-byte directory entries that
`mc rm --recursive` did:

```
aws s3 rm s3://ingest-bucket/__awscli-probe__/SESSION1 --recursive   -> exit 0
aws s3 ls --recursive .../SESSION1/     -> 0 objects
aws s3 ls .../__awscli-probe__/         -> PRE SESSION1/      <-- still listed
weed shell fs.ls .../__awscli-probe__/  -> SESSION1
```

Only `weed shell fs.rm -r` clears the entry. That prefix shape is what made
the uploader log a bogus `Successfully uploaded all files in ...` every 60 s
and re-fire `XNATUploadSuccess` for two days.

Consequences:
* `scripts/clear-staged-s3.sh` must keep `weed shell fs.rm -r` for deletion
  after the client swap. Only its counting half moves to `aws s3 ls`.
* It is an additional argument for `dataPolicy.derived.assigned.reclaim:
  onUploaded` being implemented as a fingerprint/marker state file rather
  than a delete — never creating the ghost prefix beats cleaning it up.

## Migration consequence

Step 3 of the S3 workstream ("run both clients in parallel and confirm
checksum behaviour") loses its blocking question. The remaining risk in that
workstream is entirely about **log-event compatibility** — the 11 Loki ruler
rules and 2 dashboards key off the `jlog` event names our `mc` wrapper emits,
and `aws s3 sync --only-show-errors` emits none of them. That port still has
to be byte-for-byte.
