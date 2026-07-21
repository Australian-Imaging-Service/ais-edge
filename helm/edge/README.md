# AIS Edge Helm chart

AIS Edge receives imaging data on a MicroK8s VM, groups it into XNAT sessions, and uploads them to XNAT.

## Default architecture

```text
Scanner -> Orthanc -> ingest-orthanc --\
                                         -> /data/assigned -> upload -> XNAT
Samba -> incoming/ -> ingest-fs --------/
```

- Host storage: `/data/ais-edge`
- Orthanc storage: `/data/ais-edge/orthanc-storage`
- Samba drop directory: `/data/ais-edge/incoming`
- Assigned sessions: `/data/ais-edge/assigned`
- Copy mode: `hardlink_or_copy`
- XNAT upload: enabled with one replica
- Source deletion and de-identification: disabled

Allow inbound TCP ports `445`, `30042`, and `30842` in the VM or site
firewall. Restrict them to the local facility network.

Both ingest Deployments run `group` followed by `assign`. Orthanc studies are
marked with the `xnat-sorted` label. Filesystem studies are tracked
with content fingerprints under `/data/LOGS/fs-pipeline-state`.

## Fresh Ubuntu VM installation

Before running setup, install MicroK8s, enable its DNS add-on, install Helm and
`kubectl`, and configure `kubectl` to use the MicroK8s cluster. Confirm the
cluster is ready:

```bash
kubectl get nodes
helm version
```

Copy and edit the non-secret example values to suit your facilities needs (see **Site values**):

```bash
cp helm/values-example.yaml ~/.config/ais-edge/my-site.yaml
$EDITOR ~/.config/ais-edge/my-site.yaml
```

Then run setup from the repository root:

```bash
bash helm/setup.sh ~/.config/ais-edge/my-site.yaml
```

The setup script:

1. Confirms the current Kubernetes context.
2. Creates Kubernetes Secrets for Orthanc and Samba.
3. Creates the XNAT credentials Secret.
4. Installs or upgrades the Helm release using the supplied values.
5. Prints Orthanc and Samba connection details.

Credentials are never written to the values file. Existing Secrets are reused
on later runs with the same command:

```bash
bash helm/setup.sh ~/.config/ais-edge/my-site.yaml
```

## Site values

See `helm/values-example.yaml`. The most important settings are:

```yaml
orthanc:
  aet: ORTHANC

samba:
  shareName: edge

xnatIngest:
  dicomTagMapping:
    project: StudyDescription
    subject: PatientName
    sessionLabel: PatientID
    sessionUid: StudyInstanceUID
    scanDesc: SeriesDescription

  upload:
    enabled: true
    replicas: 1
```

The project, subject, and session fields must exist in the incoming DICOM
metadata. Verify the mapping before running setup because upload starts
automatically (disable in your values file if you don't want this).

## Enable or disable pipeline components

All components are enabled by default. Change the following settings in the
site values file, then rerun `setup.sh` to apply them.

```yaml
xnatIngest:
  # Stop processing studies received by Orthanc.
  orthancIngest:
    enabled: false

  # Stop processing studies copied to the Samba/local drop directory.
  fsIngest:
    enabled: false

  # Keep the Upload Deployment installed but stop automatic XNAT uploads.
  upload:
    replicas: 0
```

To remove the Upload Deployment entirely, use:

```yaml
xnatIngest:
  upload:
    enabled: false
```

Set an ingest component's `enabled` value back to `true`, or set upload
`replicas` back to `1`, to resume it. Orthanc and Samba remain available when
their respective ingest pipelines are disabled.

S3 sync is optional and disabled by default:

```yaml
s3Sync:
  enabled: true
  dest: "s3://example-bucket/site-prefix"
```

When enabled, `setup.sh` prompts for the AWS access key, secret key, and region
and stores them in the `s3-credentials` Kubernetes Secret. Set `enabled: false`
and rerun setup to remove the S3 sync Deployment.

## Inputs

### Orthanc

Configure scanners with the VM address, the configured AET, and NodePort
`30042`. Open Orthanc Explorer at:

```text
http://<vm-ip>:30842/ui/app/
```

### Samba

Connect to:

```text
\\<vm-ip>\<share-name>
```

Copy each complete study into its own directory under `incoming/`. The
filesystem pipeline waits for recent writes to settle before processing.

## Monitor and review

```bash
kubectl get deployments,pods,pvc -n ais-edge
kubectl logs deployment/ingest-orthanc -n ais-edge -f
kubectl logs deployment/ingest-fs -n ais-edge -f
```

Review assigned sessions:

```bash
kubectl exec deployment/ingest-fs -n ais-edge -- \
  find /data/assigned -mindepth 1 -maxdepth 2 -type d
```

Sessions with missing identifiers are retained under:

```text
/data/assigned/__invalid__/
```

Set upload replicas to zero before testing or manual review if sessions should
not be sent to XNAT.

If files are added to an already processed filesystem study, the pipeline logs
`changed after processing` and does not merge them automatically. Review and
remove the existing assigned output, then remove the study state file to
reprocess:

```bash
kubectl exec deployment/ingest-fs -n ais-edge -- \
  rm "/data/LOGS/fs-pipeline-state/<study-directory>"
```

## Control XNAT upload

Setup creates the required `xnat-credentials` Secret. Upload starts
automatically with:

```yaml
xnatIngest:
  upload:
    enabled: true
    replicas: 1
```

Apply the reusable values file:

```bash
helm upgrade edge helm/edge \
  -f ~/.config/ais-edge/my-site.yaml \
  -n ais-edge \
  --rollback-on-failure \
  --timeout 10m

kubectl logs deployment/upload -n ais-edge -f
```

To pause upload for testing or review, set `replicas: 0` and repeat the Helm
upgrade.

## Optional S3 sync

S3 sync independently copies completed directories from `/data/assigned` to
the configured S3 prefix. It skips `__invalid__` and other directories whose
names begin with `__`, waits for files to settle, and records fingerprints in
`/data/LOGS/s3sync-state` to avoid uploading unchanged sessions repeatedly.

Monitor it with:

```bash
kubectl logs deployment/s3sync -n ais-edge -f
```

Failures are retried during the next sweep and recorded in
`/data/LOGS/s3sync.log`. To force one session to sync again, remove its state
file:

```bash
kubectl exec deployment/s3sync -n ais-edge -- \
  rm "/data/LOGS/s3sync-state/<session-directory>"
```

## Upgrade and uninstall

```bash
helm upgrade edge helm/edge \
  -f ~/.config/ais-edge/my-site.yaml \
  -n ais-edge \
  --rollback-on-failure \
  --timeout 10m

helm uninstall edge -n ais-edge
```

The PV and PVC use the `keep` resource policy and the host data directory is
not removed by uninstall.

## Important paths

| Path | Purpose |
|---|---|
| `/data/incoming` | Samba/local filesystem drop directory |
| `/data/orthanc-storage` | Orthanc database and DICOM files |
| `/data/grouped-orthanc` | Temporary Orthanc grouping |
| `/data/grouped-fs` | Temporary filesystem grouping |
| `/data/assigned` | Sessions ready for review or upload |
| `/data/assigned/__invalid__` | Sessions with unresolved identifiers |
| `/data/LOGS/fs-pipeline-state` | Completed filesystem study fingerprints |
| `/data/LOGS/xnat-ingest-*.log` | Component logs |
