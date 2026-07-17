# AIS Edge Pipeline Helm Chart

Receives imaging data at a scanner site, resolves XNAT identifiers from DICOM
metadata, and stages sessions for upload.

## Architecture

```
scanner ──DICOM──▶ Orthanc ──▶ ingest-orthanc: group-orthanc ─▶ assign ─┐
                                                                        ├─▶ /data/assigned/<Project.Subject.Session>/
file export ────▶ drop dir ──▶ ingest-fs:      group ────────▶ assign ─┘   
                                                                        │
                                                          ┌─────────────┴─────────────┐
                                                          ▼                           ▼
                                                   upload (XNAT)              s3sync (S3 bucket)
```

Every component is a single-replica Deployment (Recreate strategy) and
individually switchable in values: `xnatIngest.orthancIngest.enabled`,
`xnatIngest.fsIngest.enabled`, `xnatIngest.upload.enabled`,
`s3Sync.enabled`. 
`helm upgrade` rolls pods automatically.

## Prerequisites

- MicroK8s (or any Kubernetes cluster) with Helm v3 and kubectl installed
- The configured NodePorts and host port 445 (Samba) free on the node

Conventions: run all commands on the edge VM. Text in `<angle brackets>` is
a placeholder. Everything the chart installs lives in one Kubernetes namespace, `ais-edge` by default (the `namespace`
key in values).

## Install

1. Copy a values file and edit it for your site (see `values-tbpet.yaml`
   for a working example, or the Configuration reference below):

```bash
cp helm/values-example.yaml helm/values-<my-site>.yaml
```

2. Run the setup script:

```bash
bash helm/setup.sh helm/values-<my-site>.yaml
```

3. Check everything came up (all pods should show `Running` after a minute
   or two):

```bash
kubectl get pods -n ais-edge
```

That's a complete install. The rest of this section is only needed if you
skip the setup script or have to recreate a credential later.

Credentials live in Kubernetes secrets (the pipeline reads them from there;
they are never stored in the values file). To create one manually, delete it first with
`kubectl delete secret <name> -n ais-edge`, then:

```bash
kubectl create secret generic orthanc-credentials -n ais-edge \
  --from-literal=users.json='{"RegisteredUsers": {"admin": "<password>"}}' \
  --from-literal=orthanc-user=admin --from-literal=orthanc-password=<password>

kubectl create secret generic samba-credentials -n ais-edge \
  --from-literal=username=<user> --from-literal=password=<password>

kubectl create secret generic xnat-credentials -n ais-edge \
  --from-literal=server=<https://xnat.example.org> \
  --from-literal=username=<user> --from-literal=password=<password>

# only if s3Sync.enabled:
kubectl create secret generic s3-credentials -n ais-edge \
  --from-literal=AWS_ACCESS_KEY_ID=<key-id> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<secret> \
  --from-literal=AWS_DEFAULT_REGION=<region>
```

Installing without the setup script: create the namespace
(`kubectl create namespace ais-edge`), create the secrets as above, then:

```bash
helm upgrade --install edge helm/edge -f helm/values-<my-site>.yaml -n ais-edge
```

Behind a corporate proxy, set the `proxy:` map in values — without it pods
have **no** proxy env and outbound requests (S3, XNAT) hang, typically with
no error at all. Keep in-cluster names (`orthanc`, `.svc`, `.cluster.local`)
in `NO_PROXY` or pipeline pods will send Orthanc API calls to the proxy.

## Things that are not obvious (read before operating)

**Orthanc `StorageCompression` must stay off** (off by default).
`group-orthanc` hardlinks files straight out of Orthanc's storage; a
compressed store cannot be staged.

**`group-orthanc` only sees Orthanc-indexed tags** (MainDicomTags +
PatientMainDicomTags). If the project field is an unindexed tag (e.g.
PatientComments), the Orthanc pipeline cannot resolve it even though the fs
pipeline (which reads full file headers) can.

## Runbook

The two watch-points needing routine attention:

* **`/data/assigned/__invalid__/`** — sessions assign could not identify
  (missing/typo'd project field in the DICOM headers). Fix the metadata
  problem, delete the `__invalid__` entry, and remove the study's line from
  `/data/LOGS/fs-pipeline-done.list` to re-process it.
* **`FAIL` lines in `/data/LOGS/s3sync.log`** — failed or refused syncs.
  Transfer errors retry automatically each cycle; "dangling symlinks" means
  the source study was removed from the share before it was synced.

Common operations:

```bash
# live logs (-f = keep following; Ctrl-C to stop). 
kubectl logs deploy/ingest-fs -n ais-edge -f        # pipeline activity
kubectl logs deploy/s3sync -n ais-edge -f           # sync activity
kubectl exec deploy/s3sync -n ais-edge -- tail -50 /data/LOGS/s3sync.log

# re-process a study from scratch:
#   1. remove its line from /data/LOGS/fs-pipeline-done.list
#   2. delete its session dir(s) under /data/assigned
#   3. delete /data/LOGS/s3sync-state/<session>

# force a re-sync of one session
kubectl exec deploy/s3sync -n ais-edge -- rm "/data/LOGS/s3sync-state/<session>"

# make an Orthanc study eligible for re-staging:
#   remove its processed label (default "xnat-sorted") in the Orthanc UI
```

State on `/data` (survives pod restarts and upgrades):

| Path | What it is |
|---|---|
| `/data/LOGS/fs-pipeline-done.list` | fs studies already processed; delete a line to re-process |
| `/data/LOGS/s3sync-state/<session>` | fingerprint of last successful sync; delete to force re-sync |
| `/data/LOGS/s3sync.log` | sync audit trail (SYNC / DONE / FAIL) |
| `/data/LOGS/xnat-ingest-*.log` | xnat-ingest debug logs per component |
| `/data/assigned/__invalid__/` | sessions with unresolvable IDs; never auto-retried |

## Sizing

`xnatIngest.resources` sets a memory limit because `group` holds every
matched file's metadata in memory: an oversized drop of files OOMKills the
pod (self-recovering) instead of freezing the node. Raise the limit if
studies routinely exceed it.

## Upgrade / uninstall

After any change to your values file or the chart:

```bash
helm upgrade edge helm/edge -f helm/values-<my-site>.yaml -n ais-edge
```

Pods restart themselves as needed — no manual deletes.

```bash
helm uninstall edge -n ais-edge
```

The PV, PVC, and namespace carry `helm.sh/resource-policy: keep` — uninstall
does not touch data on disk.

## Configuration reference

| Key | Default | Description |
|-----|---------|-------------|
| `namespace` | `ais-edge` | Target namespace |
| `storage.hostPath` | `/data/ais-edge` | Host directory for pipeline data |
| `storage.capacity` | `1500Gi` | Nominal PV/PVC size (hostPath: not enforced) |
| `orthanc.aet` / `nodePorts` | see values.yaml | DICOM receiver identity/ports |
| `orthanc.authenticationEnabled` | `true` | Require credentials for web UI / REST |
| `samba.shareName` | `edge` | SMB share name |
| `xnatIngest.dicomTagMapping` | see values.yaml | DICOM tag → XNAT field mapping |
| `xnatIngest.orthancIngest.*` | enabled | Orthanc → assigned pipeline |
| `xnatIngest.fsIngest.*` | disabled | drop dir → assigned pipeline (glob, datatypes, copyMode, exportClaim) |
| `xnatIngest.upload.*` | enabled | assigned → XNAT upload |
| `xnatIngest.resources` | 8Gi limit | resources for all xnat-ingest pods |
| `s3Sync.*` | disabled | assigned → S3 staging sync (dest, interval, settleMinutes) |
| `proxy` | `{}` | outbound proxy env for all pipeline pods |
