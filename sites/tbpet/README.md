# TBPET merge / deployment notes

This site file is a TBPET branch addition, retained when merging `main`.
Nothing in this merge deploys it or changes live data.

* **No de-identification:** `deid.engine: none` and `policyReviewed: true`
  deliberately retain original identifiers. Neither ingest deidentify nor the
  Orthanc de-id/backup hook runs. The optional stable-label Lua hook still
  applies `xnat-ingest-ready`; group-orthanc must retain that filter.
* Orthanc storage, both grouped trees and assigned remain on the **same local
  pipeline PVC**, hostPath `/data/ais-edge`, 1500Gi. The existing storage class
  is not recreated. The separate `usyd-data-export` NFS PVC is mounted read-only
  at `/data/usyd-export` in every reader of its symlinks. Originals on NFS are
  never deleted by the pipeline.
* xnat-ingest **0.15.2** contains the Orthanc label safety fix. Version 0.15.0
  narrowed default group session/scan scopes to DICOM only. Explicit
  `StudyInstanceUID` / `SeriesNumber` mappings over `generic/file-set` preserve
  grouping for all nine configured DICOM / Siemens raw datatypes. Resource
  clashes explicitly use `avoid all`. Assign still maps PatientComments,
  PatientID, AccessionNumber and SeriesDescription.
* The upstream uploader now stages **rclone 1.75.0** in the existing GNU/Bash
  runtime. TBPET selects provider **AWS**, retaining its bucket, prefix, region,
  proxies and external credentials/egress CA. Transfers use `copy --copy-links`,
  never destination-deleting `sync`. Durable events survive local reclamation;
  Discord reports a **snapshot synced**, not completion of all future arrivals.

## Before any production upgrade

The restored pending policy is **enabled, not dry-run**: assigned sessions are
reclaimed after successful upload (`onUploaded`, minAge 0); processed Orthanc
studies are eligible at **3 days since Orthanc `LastUpdate`**, not three days
since being labelled. StableAge and both ingest waits are 86400 seconds.
Facility backup remains off. Review these settings before applying them.

The configured processed label changes from `xnat-sorted` to
`xnat-ingest-grouped`. **Changing the value does not migrate existing labels.**
Inventory existing studies and verify corresponding grouped/assigned/uploaded
data before choosing a controlled migration or reprocessing procedure. Do not
bulk relabel: the new label authorizes Orthanc deletion for sufficiently old
studies. Old-labelled studies may otherwise be reprocessed or retained. Verify
this transition before production, with reclamation paused during migration.

Verify the external NFS PVC and egress CA/credentials/Discord secrets exist and
that the site can pull the new ingest and rclone images. Confirm representative
raw/DICOM data and the AWS/proxy/TLS path in a controlled test. Orthanc HTTP
remains unauthenticated on NodePort 30842 as before; restrict it to trusted
networks.

Regression: `make tbpet` renders the full existing matrix, checks this actual
site's mounts/configuration, exercises the walker on synthetic data, and parses
its actual arguments against the released 0.15.2 Docker image. It does not call
Orthanc, AWS, Discord or Kubernetes.

The runtime fixtures require Bash, GNU findutils/coreutils, Python with PyYAML,
and Docker (as on the Linux CI runner). On macOS, put Homebrew's Bash and the
findutils/coreutils `libexec/gnubin` directories first in `PATH`. Set
`CI_WORK_DIR` to a project-local build directory when required by local policy.
