# Tier-1 Single-Node Edge Medical Imaging Ingest

A single-node appliance that receives DICOM from local modalities, de-identifies
it on-node, and uploads it to XNAT. Part of
[NIF FDRI Stream 2](https://github.com/Australian-Imaging-Service).

One Ubuntu machine runs the whole pipeline on a single-node
[k0s](https://k0sproject.io/) cluster:

```
modality --C-STORE--> Orthanc (deid) --> xnat-ingest sort --> xnat-ingest upload --> XNAT (HTTPS)
```

There is **no** SeaweedFS, **no** S3 hop, **no** k0smotron / child cluster /
konnectivity, **no** separate edge worker, **no** nginx-ingress, and **no**
cert-manager. Original DICOMs never leave the node; only de-identified data is
uploaded to XNAT. Optional observability (Loki + Prometheus + Grafana +
Alertmanager + Vector) runs natively on the same node.

## Prerequisites

- **One Ubuntu node**: Ubuntu 22.04+, 8GB+ RAM, 100GB+ disk. This single machine
  runs k0s and every pipeline component.
- **One XNAT instance**: reachable over HTTPS, with a local (non-AAF/OIDC) service
  account and a pre-existing project for the sessions to land in.
- **DICOM source(s)**: one or more modalities on the local LAN that can C-STORE to
  this node on port **4242** with `AET=AISEDGE`. Each modality's Called-AET must be
  listed in `config/orthanc/routing.json`.
- **`AIS_DEID_HMAC_SALT`**: a per-deployment secret. Generate one with
  `openssl rand -hex 32` and set it in `config/management.env` before install.
- **Outbound internet**: needed to pull the k0s binary and container images, and
  ongoing HTTPS to the XNAT server.

## Quick Start

### Files a site admin must edit before install

**Three** files — every one has a `.template` next to it. Copy and fill in. All
three are gitignored once copied, so secrets never end up in version control.

| File (after copy) | What to set | Source |
|---|---|---|
| `config/management.env` | `MGMT_NODE_IP`, XNAT URL/user/pass, `PROJECT_ID`, `AIS_DEID_HMAC_SALT`, optional observability vars | `management.env.template` |
| `config/orthanc/routing.json` | `AETMap` — each modality's Called-AET → XNAT project | `routing.json.template` |
| `config/orthanc/deidentification-profile.json` | Replace / Keep blocks per Orthanc `/modify` API — the deid contract for this site. Applied to every accepted study | `deidentification-profile.json.template` |

Anything else under `config/` (`k0s-controller.yaml`, the Lua hook, `orthanc.json`)
ships with sane defaults and rarely needs editing. Inside each template, look for
`# REQUIRED` markers (env file) or `REPLACE_*` placeholders (JSON files) to
identify the fields you must fill in.

### Steps

```bash
# 1. Clone this repo on the node
git clone <repo-url> && cd k0s-k0smotron-mvp

# 2. Copy templates + edit the three files above
cp config/management.env.template                          config/management.env
cp config/orthanc/routing.json.template                    config/orthanc/routing.json
cp config/orthanc/deidentification-profile.json.template   config/orthanc/deidentification-profile.json
$EDITOR config/management.env \
        config/orthanc/routing.json \
        config/orthanc/deidentification-profile.json

# 3. Generate the deid HMAC salt and paste it into management.env
openssl rand -hex 32   # set AIS_DEID_HMAC_SALT="<paste>" in config/management.env

# 4. Install — step 07c shows the AETMap + profile and asks for explicit
#    confirmation before deploying the deid policy.
chmod +x install.sh scripts/*.sh
./install.sh          # interactive
# or: ./install.sh -y # non-interactive / CI (auto-confirm)
```

Architecture, data flow, security model, and component-by-component reference are
all below.

---

## Architecture

Everything runs on one node. Modalities C-STORE to Orthanc on the node's own IP
(port 4242 on the local LAN). Orthanc de-identifies in-process, keeps the deid'd
instance, and backs up the original to a node-local directory that never leaves
the machine. `xnat-ingest sort` and `xnat-ingest upload` move the deid'd data to
XNAT over HTTPS. The only inbound port is DICOM 4242; the only outbound path is
HTTPS to XNAT (plus the Grafana NodePort for the local admin).

```
════════════════════════════════════════════════════════════════════════════════
  SINGLE NODE   (MGMT_NODE_IP)      inbound: DICOM :4242 (LAN)   outbound: :443 XNAT
════════════════════════════════════════════════════════════════════════════════

  Host directories (all on one filesystem so hardlinks resolve)
    /data/xnat-ingest/orthanc-storage   deid'd DICOM instances (Orthanc storage)
    /data/xnat-ingest/staging           PROJECT.SUBJECT.VISIT/ dirs (sort output)
    /data/facility-backup               ORIGINAL DICOMs (real IDs) — never leaves node

  ┌─ namespace: xnat-ingest ──────────────────────────────────────────────────┐
  │   orthanc            DICOM SCP :4242 (hostPort, AET=AISEDGE)               │
  │     Lua deidentify-and-forward.lua:                                        │
  │       OnStoredInstance  deid per routing.json profile;                     │
  │                         write ORIGINAL → /facility-backup; keep deid'd     │
  │       OnStableStudy     label study `xnat-ingest-ready`                    │
  │     env  AIS_DEID_HMAC_SALT (Secret)                                       │
  │     REST :8042 (ClusterIP) — how sort pulls                               │
  │        │                                                                   │
  │        ▼  REST-pull labelled studies                                      │
  │   xnat-ingest-sort   loop 60s; hardlinks deid'd DICOMs from               │
  │                      /data/orthanc-storage → /data/staging/PROJECT.SUB.VIS │
  └────────────────────────────────────────────────────────────────────────────┘
  ┌─ namespace: xnat-upload ──────────────────────────────────────────────────┐
  │   xnat-ingest-upload reads LOCAL /data/staging directly; loop 60s;         │
  │                      uploads sessions to XNAT over HTTPS                    │
  │     Secret  xnat-credentials (server, username, password)                 │
  └────────────────────────────────────────────────────────────────────────────┘
  ┌─ namespace: observability (optional) ─────────────────────────────────────┐
  │   Loki (filesystem storage on a PVC) · Prometheus · Grafana (NodePort)    │
  │   Alertmanager (email/Slack) · Vector (DaemonSet → in-cluster Loki)       │
  └────────────────────────────────────────────────────────────────────────────┘

                     │  HTTPS REST (XNAT credentials live only here)
                     ▼
  ┌──────────────────────────┐
  │  XNAT Server             │   ◄──────── Modalities C-STORE to
  │ (separate infrastructure)│             AET=AISEDGE on :4242 (LAN)
  └──────────────────────────┘
```

## Data Flow

```
1. Modality C-STOREs to Orthanc on the node
   - Orthanc receives on port 4242 with AET=AISEDGE
   - routing.json AETMap maps the Called-AET → XNAT project
         │
         ▼
2. Orthanc Lua hook (deidentify-and-forward.lua)
   - OnStoredInstance:
     a. Writes the ORIGINAL to /facility-backup/ (site-controlled retention)
     b. /modify with the deidentification profile; UIDs are kept so the
        deid'd instance lands in the same Study
     c. Deletes the ORIGINAL from Orthanc (keeps the deid'd instance in storage)
   - OnStableStudy (after StableAge=30s silence):
     d. PUTs label "xnat-ingest-ready" on the study
         │
         ▼
3. xnat-ingest sort (REST-pull mode)
   - Polls Orthanc's REST API every INGEST_LOOP_SECONDS (default 60s)
   - Filters: has label "xnat-ingest-ready", lacks label "xnat-ingest-skip"
   - Hardlinks instances from /data/orthanc-storage into
     /data/staging/PROJECT.SUBJECT.VISIT/  (same filesystem — hardlink, not copy)
   - PUTs label "xnat-ingest-skip" on the study
         │
         ▼
4. xnat-ingest upload (local source → XNAT)
   - Reads the LOCAL /data/staging directory directly (no S3)
   - Uploads sessions to XNAT via REST over HTTPS (XNAT credentials only here)
   - Creates project/subject/session/scan hierarchy in XNAT
   - Skips sessions already in XNAT (idempotent); loops every 60s
```

The deid happens at step 2 inside Orthanc; everything downstream of
`OnStoredInstance` works with deid'd identifiers. The original DICOM exists only
in `/data/facility-backup` (real identifiers, site-retained) and nowhere else —
it never leaves the node and is never uploaded.

Orthanc, sort, and upload all mount the host directory `/data/xnat-ingest` at
`/data`. Because `orthanc-storage`, `staging`, and the upload source all live on
the same filesystem, sort can hardlink (rather than copy) and the upload pod reads
byte-for-byte the same staged files sort wrote. Cross-filesystem hardlinks fail
with `EXDEV`, so these directories **must** be on one physical mount.

## Security Model

```
Single node                                    XNAT
├─ XNAT credentials (local Secret)             ├─ User data
├─ AIS_DEID_HMAC_SALT (local Secret)           │
├─ ORIGINAL DICOMs in /data/facility-backup    │
│  (real identifiers; never leaves the node)   │
├─ Inbound: DICOM :4242 on the local LAN only  │
└─ Outbound: HTTPS :443 to XNAT                 │
```

- **De-identification happens on-node, before anything is uploaded.** Only deid'd
  data is staged and sent to XNAT.
- **Original DICOMs stay put.** They live only in `/data/facility-backup` under
  site-controlled retention and are never transmitted anywhere.
- **XNAT credentials are local** to this node (Kubernetes Secret in the
  `xnat-upload` namespace) and are used only for the outbound HTTPS upload.
- **One inbound port.** DICOM 4242 on the local LAN, from modalities. Nothing is
  exposed to the internet. Outbound is HTTPS to XNAT (and, if observability is
  enabled, the Grafana NodePort for the local admin on the LAN).
- **No S3 keys, no CA distribution, no per-site key scoping.** This is a single,
  self-contained appliance — there is no fleet, no shared object store, and no
  transport CA to manage.

| If compromised... | Impact |
|--------------------|--------|
| The node | This is the whole appliance — harden it accordingly. An attacker gets the local DICOMs (originals in `/data/facility-backup`, deid'd in Orthanc storage), the XNAT credentials, and the deid salt. Restrict LAN access to :4242 and OS-level access to the machine. |
| The DICOM port (:4242) | Anyone on the LAN who can reach :4242 can push studies (subject to the `routing.json` AETMap — unlisted AETs are rejected). Keep it on a trusted modality VLAN. |
| The XNAT credentials | Scope the XNAT service account to the target project only (Member/Collaborator), so a leak can't reach unrelated data. |

## Repository Structure

```
k0s-k0smotron-mvp/
├── README.md                              ← You are here
├── install.sh                             ← Main installer (run this)
├── config/
│   ├── management.env.template            ← Single node config (copy to management.env)
│   ├── k0s-controller.yaml                ← k0s single-node cluster config
│   └── orthanc/                           ← Orthanc config (mounted as ConfigMaps)
│       ├── orthanc.json                   ← Daemon config (AET, ports, storage paths, StableAge)
│       ├── deidentify-and-forward.lua     ← Deid + label Lua hook (identical across sites)
│       ├── routing.json.template          ← Per-site AET → XNAT project mapping
│       └── deidentification-profile.json.template ← The site's deid contract
├── manifests/
│   ├── 01-management/
│   │   ├── xnat-upload.yaml.tpl           ← Upload pod: reads LOCAL /data/staging → XNAT
│   │   └── observability/                 ← Loki/Prometheus/Grafana/Alertmanager/Vector
│   └── 02-edge/
│       ├── orthanc.yaml.tpl               ← Orthanc Deployment + Service + deid-salt Secret
│       └── xnat-ingest.yaml.tpl           ← Sort pod (Orthanc REST-pull mode)
├── scripts/
│   ├── 00-common.sh                       ← Shared functions (render, etc.)
│   ├── 01-install-k0s.sh                  ← Install single-node k0s + local-path storage
│   ├── 07c-deploy-edge-orthanc.sh         ← Deploy Orthanc + deid Lua hook
│   ├── 07-deploy-edge-ingest.sh           ← Deploy xnat-ingest sort (REST-pull)
│   ├── 04-deploy-xnat-upload.sh           ← Deploy xnat-ingest upload (local staging → XNAT)
│   ├── 02d-install-observability.sh       ← Loki + Prom + Grafana + Alertmanager + Vector (optional)
│   └── uninstall.sh                       ← Tears everything down
└── docs/                                  ← Component + operations reference
```

`.tpl` files are manifest templates — placeholders like `{{ORTHANC_IMAGE}}` are
replaced with values from `config/management.env` by the `render()` function in
`scripts/00-common.sh` at install time. No Helm/Jinja for these; the observability
stack uses Helm charts driven by rendered values files. You never edit `.tpl`
files directly.

## Installing on an Existing Kubernetes Cluster

If you already have a single-node Kubernetes cluster (k3s, kubeadm, MicroK8s, …):

1. Set `INSTALL_MODE="existing"` in `config/management.env`.
2. Ensure `kubectl` is configured and points at your cluster (`~/.kube/config`).
3. Ensure a default StorageClass exists (`kubectl get sc`) — needed for the Loki /
   Prometheus / Grafana PVCs when observability is enabled.
4. Run `./install.sh` — it skips the k0s install and deploys onto your cluster.

Note that Orthanc uses `hostPort: 4242` and all pipeline pods use `hostPath`
mounts under `/data`, so the DICOM modalities must be able to reach the node's IP
and the node must have `/data` available.

## XNAT Configuration

Before ingesting data, ensure:

1. **The XNAT project exists** — create it in the XNAT web UI first. Its ID must
   match both `PROJECT_ID` in `config/management.env` and the `project` value in
   `routing.json`'s AETMap. The Lua hook does not create the project.
2. **The XNAT user is a local account** — not AAF/OIDC. Create via
   Administer → Users.
3. **The XNAT user has project permissions** — at least Member or Collaborator on
   the target project.

`xnat-ingest` authenticates via `POST /data/JSESSION` with username/password and
uses the session token for subsequent REST calls. The upload pod runs with
`--dont-verify-ssl` so it works against XNAT servers presenting a private or
self-signed certificate.

## Tested Versions

| Component | Version | Notes |
|-----------|---------|-------|
| Ubuntu | 22.04.5 LTS | The single node |
| k0s | v1.35.2+k0s.0 | Single-node cluster (`k0s install controller --single`) |
| local-path-provisioner | v0.0.30 | Default StorageClass for observability PVCs |
| Orthanc | 1.12.6 (plugins) | `jodogne/orthanc-plugins:1.12.6` — DICOM SCP on port 4242. Needs ≥ 1.12.0 for study-level labels |
| xnat-ingest | v5 | `ghcr.io/akshitbeniwal/xnat-ingest:v5` — JSON logging, Orthanc REST-pull sort, and local-path upload source |
| Loki | 3.x (single-binary) | Local **filesystem** storage on a PVC (no object store) |
| Prometheus | kube-prometheus-stack | Metrics + alert-rule evaluation |
| Grafana | kube-prometheus-stack | Dashboards, exposed on a NodePort |
| Alertmanager | kube-prometheus-stack | Email + optional Slack routing |
| Vector | timberio/vector | DaemonSet, tails all pod logs, pushes to in-cluster Loki |

To pin versions in production, set explicit image tags in `config/management.env`
(`ORTHANC_IMAGE`, `XNAT_INGEST_IMAGE`).

## Testing

Drop a study by C-STORE. The Called-AET (`-aec`) must be listed in
`config/orthanc/routing.json`'s AETMap — that's how the deid hook knows which XNAT
project to route to. Unlisted AETs are rejected (the instance is deleted and no
backup is written).

```bash
# C-STORE a study to Orthanc on the node (from a machine with dcmtk):
storescu -aec <AET-from-routing.json> -aet TEST_MOD <MGMT_NODE_IP> 4242 study/*.dcm

# Watch the Orthanc deid + label events
kubectl logs -n xnat-ingest deploy/orthanc -f \
  | grep -E 'instance_deidentified|study_labeled_ready|REJECT|ERROR'

# Watch sort REST-pull from Orthanc and hardlink into staging
kubectl logs -n xnat-ingest -l component=sort -f

# Watch upload to XNAT
kubectl logs -n xnat-upload -l component=upload -f
```

Then confirm the session appears in the XNAT project's web UI. The original study
stays in `/data/facility-backup`; only the de-identified session is uploaded.

## Health Checks

```bash
# All pods across every namespace should be Running
kubectl get pods -A

# Node should be Ready
kubectl get nodes

# The three pipeline log tails
kubectl logs -n xnat-ingest deploy/orthanc --tail=20            # Orthanc + deid
kubectl logs -n xnat-ingest -l component=sort --tail=20         # sort (REST-pull → staging)
kubectl logs -n xnat-upload -l component=upload --tail=20       # upload → XNAT

# XNAT reachability
curl -sk <XNAT_URL>                                             # should return HTML

# Grafana (only if observability is enabled)
#   http://<MGMT_NODE_IP>:<GRAFANA_NODEPORT>   (default 30030)
```

## Failure Scenarios

| Scenario | What happens | Recovery |
|----------|-------------|---------|
| Modality sends an unmapped AET | Orthanc rejects; instance deleted, no backup, REJECT logged | Add the modality's Called-AET to `routing.json` AETMap and re-run `07c` |
| Network drops mid-upload | The in-flight session upload fails | Upload loops every 60s and retries the still-staged session on the next cycle |
| Node reboots | k0s auto-starts; pods resume; staged files are safe on the local disk | Nothing — the pipeline picks up where it left off |
| Orthanc pod restarts | In-flight receive interrupted | Modality re-sends, or the study completes on the next stable cycle |
| XNAT is down | Uploads fail; staged sessions accumulate in `/data/staging` | XNAT returns; the upload loop clears the backlog |
| DICOM missing AccessionNumber | Sort routes the session to `/data/staging/__invalid__/` | Manual rename/move; real clinical DICOMs populate this field |
| `/data` disk fills | Staging + Orthanc storage grow unbounded (no auto-cleanup) | Expand `/data`, or delete studies labelled `xnat-ingest-skip` once confirmed in XNAT |

## Observability

Optional log-aggregation, metrics, dashboarding, and alerting — native to the
single node, with simpler plumbing than a fleet needs:

- **Loki** stores logs using **local filesystem storage** on a PVC (the
  single-binary standard — no S3 / object store).
- **Prometheus** scrapes pod `/metrics` and kube-state-metrics, stores time
  series, and evaluates alert rules.
- **Grafana** queries both and hosts the dashboards, exposed on a **NodePort** at
  `http://<MGMT_NODE_IP>:<GRAFANA_NODEPORT>` (default `30030`).
- **Alertmanager** routes alerts via email (primary) and optional Slack.
- **Vector** runs as a DaemonSet, tails every pod's logs, and pushes them to the
  in-cluster Loki Service directly (no 443 / SNI / TLS hop).

The stack is optional. With `ALERT_EMAIL_TO` blank in `config/management.env` the
install script skips it cleanly. Set the email + SMTP vars (and, if wanted, the
Slack webhook) and re-run `./install.sh` (or `bash scripts/02d-install-observability.sh`
directly) to enable it.

Dashboards land in Grafana under the `AIS Edge` folder:

- **Pipeline Overview** — counters and timeseries for the whole ingest pipeline
  (DICOMs and sessions uploaded, upload failures, invalid sessions, recent events).
- **Edge Site Drilldown** — single-node / per-worker view with a live log tail.
- **Session Timeline** — a single-session trace by session name.

The same alert rules as before apply; only the SeaweedFS-health and
s3-uploader-specific panels/alerts are gone because those components no longer
exist. For per-panel detail see [`docs/dashboards.md`](docs/dashboards.md); for the
Loki-ruler-vs-Prometheus split see
[`docs/alerting-architecture.md`](docs/alerting-architecture.md); for
component-by-component reference see [`docs/`](docs/README.md).

## Uninstall

```bash
./scripts/uninstall.sh          # interactive
# or: ./scripts/uninstall.sh -y
```

This removes the `xnat-ingest`, `xnat-upload`, and `observability` namespaces and
the local `/data/xnat-ingest/staging` directory. It **leaves
`/data/facility-backup` (original DICOMs) and `/data/xnat-ingest/orthanc-storage`
intact**. On a `fresh` install it optionally offers to `k0s stop && k0s reset` the
node itself.

## Network Ports

| From | To | Port | Purpose | Encrypted? |
|------|-----|------|---------|---|
| Modalities (LAN) | Node | **4242** | DICOM C-STORE (DIMSE, `AET=AISEDGE`) | No (local LAN; keep on a trusted modality VLAN) |
| Node | XNAT | **443** | XNAT REST API uploads (HTTPS) | TLS |
| Local admin (LAN) | Node | **GRAFANA_NODEPORT** (default 30030) | Grafana UI (only if observability enabled) | No (local LAN) |

The only inbound port is DICOM 4242 on the local LAN. The only outbound path is
HTTPS to XNAT. No inbound ports are exposed to the internet.

**Site IT firewall rule:** allow the modalities to reach the node on TCP 4242, and
allow the node to reach the XNAT server on TCP 443.
