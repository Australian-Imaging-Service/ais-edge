# TBPET Tier-1 migration / deployment notes

This site ports TBPET onto `origin/tier-1-solution` at
`be7728236238d63d845ecc6660f008179b01c2a4`, without merging `main`.
Development is on `usyd-tbpet-dev`; only merge into `usyd-tbpet-tier1` after
validation. Nothing here deploys it or changes live data. Completing this
open merge will require an operator-authorized commit.

* **No de-identification:** `deid.engine: none` and `policyReviewed: true`
  deliberately retain original identifiers. Neither ingest deidentify nor the
  Orthanc de-id/backup hook runs. The optional stable-label Lua hook still
  applies `xnat-ingest-ready`; group-orthanc must retain that filter.
* Orthanc storage, both grouped trees and assigned remain on the **same local
  pipeline PVC**, hostPath `/data/ais-edge`, 1500Gi. The existing storage class
  is not recreated. The separate `usyd-data-export` NFS PVC is mounted read-only
  at `/data/usyd-export` in every reader of its symlinks. Originals on NFS are
  never deleted by the pipeline.
* xnat-ingest **0.15.6** is inherited from Tier-1. Version 0.15.0
  narrowed default group session/scan scopes to DICOM only. Explicit
  `StudyInstanceUID` / `SeriesNumber` mappings over `generic/file-set` preserve
  grouping for all nine configured DICOM / Siemens raw datatypes. Resource
  clashes explicitly use `avoid all`. Assign still maps PatientComments,
  PatientID, AccessionNumber and SeriesDescription.
* The Tier-1 **AWS CLI** uploader is retained, with the TBPET bucket, prefix,
  region, proxies and external credentials/egress CA. `aws s3 sync` follows
  symlinks and never uses `--delete`. There is no direct XNAT uploader.
  Durable events are published before the atomic completion marker and survive reclamation;
  Discord reports a **snapshot synced**, not completion of all future arrivals.
  Fingerprints, settling and policy age checks dereference symlinks;
  changed-during-sync sessions are retried. This fixes Tier-1 treating link
  metadata as file metadata and reporting symlink-only sessions as age-unknown.
* Both remote observability and the local monitoring stack are disabled.

## Before any production upgrade

The restored pending policy is **enabled, not dry-run**: assigned sessions are
reclaimed after successful upload (`onUploaded`, minAge 0); processed Orthanc
studies are eligible at **3 days since Orthanc `LastUpdate`**, not three days
since being labelled. StableAge and both ingest waits are 86400 seconds.
Facility backup remains off. Review these settings before applying them.

The configured processed label remains **`xnat-sorted`**, matching the deployed
CLI override. No label migration or bulk relabelling is included.

Immediate assign/grouped cleanup remains upstream behavior. The filesystem
walker and standalone assign/uploader can run concurrently; the manifest guard
and direct NFS links do not make that handoff transactional. A successful S3
snapshot does not prove that every later raw/DICOM arrival has finished.

Verify the external NFS PVC and egress CA/credentials/Discord secrets exist and
that the site can pull the ingest and AWS CLI images. Confirm representative
raw/DICOM data and the AWS/proxy/TLS path in a controlled test. Orthanc HTTP
remains unauthenticated on NodePort 30842 as before; restrict it to trusted
networks.

For this existing MicroK8s installation, use the Helm chart directly with
release `edge`, namespace `ais-edge`, and `-f sites/tbpet/values.yaml`.
Do **not** run `install.sh` or bootstrap k0s. Preserve the existing
`edge-pipeline` PVC, local hostPath and external export PVC; do not reinstall
storage or change live services as part of this development merge.

Regression: `make tbpet` renders the full existing matrix, checks this actual
site's mounts/configuration, exercises the walker on synthetic data, and parses
its actual arguments against the released 0.15.6 Docker image. It does not call
Orthanc, AWS, Discord or Kubernetes.

The runtime fixtures require Bash, GNU findutils/coreutils, Python with PyYAML,
and Docker (as on the Linux CI runner). On macOS, put Homebrew's Bash and the
findutils/coreutils `libexec/gnubin` directories first in `PATH`. Set
`CI_WORK_DIR` to a project-local build directory when required by local policy.
