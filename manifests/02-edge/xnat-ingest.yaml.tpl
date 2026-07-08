apiVersion: v1
kind: Namespace
metadata:
  name: xnat-ingest
---
# TIER-1 (single node) staging pipeline — upstream xnat-ingest (>=0.12.0).
#
# Upstream refactored the old single `sort` command into discrete stages.
# The Orthanc REST-pull is now `group-orthanc`; ID assignment is `assign`:
#
#   Orthanc (deid + label "xnat-ingest-ready")
#     -> group-orthanc : REST-pull labelled studies, HARDLINK deid'd DICOMs
#                        from /data/orthanc-storage into grouped sessions at
#                        /data/grouped, then label the study processed
#     -> assign        : extract project/subject/session IDs and collate into
#                        /data/staging/PROJECT.SUBJECT.SESSION/
#     -> upload        : (xnat-upload ns) reads /data/staging -> XNAT
#
# De-identification is NOT done here: it already happened in Orthanc. Upstream
# ships a separate optional `deidentify` command (specs + reversible re-id
# metadata) that would slot between assign and upload — we do not run it,
# because Orthanc de-identifies at source.
#
# All three stages share the host dir /data/xnat-ingest (mounted at /data) so
# the hardlinks resolve across stages (cross-fs hardlink would EXDEV).
---
# group-orthanc: pull studies labelled `xnat-ingest-ready` (set by the Orthanc
# deid hook) that are not yet labelled processed, and group them under /data/grouped.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: xnat-ingest-group
  namespace: xnat-ingest
  labels:
    app: xnat-ingest
    component: group
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: xnat-ingest
      component: group
  template:
    metadata:
      labels:
        app: xnat-ingest
        component: group
    spec:
      containers:
        - name: group
          image: {{XNAT_INGEST_IMAGE}}
          command: ["xnat-ingest", "group-orthanc"]
          args:
            - "http://orthanc.xnat-ingest.svc.cluster.local:8042"   # URL
            - "/data/orthanc-storage"                               # STORE_DIR (as mounted)
            - "/data/grouped"                                       # OUTPUT_DIR
            - "orthanc"                                             # USER (Orthanc auth disabled)
            - "orthanc"                                             # PASSWORD
            - "--to-process-label"
            - "xnat-ingest-ready"
            - "--processed-label"
            - "xnat-ingest-processed"
            - "--loop"
            - "{{INGEST_LOOP_SECONDS}}"
            - "--wait-period"
            - "{{INGEST_WAIT_PERIOD}}"
          env:
            - name: AIS_LOG_FORMAT
              value: "json"
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          hostPath:
            path: /data/xnat-ingest
            type: DirectoryOrCreate
---
# assign: extract project/subject/session IDs from the (deid'd) DICOM metadata
# and collate into /data/staging. Defaults: subject=PatientID,
# session=AccessionNumber, scan=SeriesDescription — which is exactly what the
# Orthanc deid hook writes (subject hash -> PatientID, session hash ->
# AccessionNumber). Project is forced with --constant-project-id.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: xnat-ingest-assign
  namespace: xnat-ingest
  labels:
    app: xnat-ingest
    component: assign
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: xnat-ingest
      component: assign
  template:
    metadata:
      labels:
        app: xnat-ingest
        component: assign
    spec:
      containers:
        - name: assign
          image: {{XNAT_INGEST_IMAGE}}
          command: ["xnat-ingest", "assign"]
          args:
            - "/data/grouped"        # INPUT_DIR (group-orthanc output)
            - "/data/staging"        # OUTPUT_DIR (upload reads this)
            - "--constant-project-id"
            - "{{PROJECT_ID}}"
            - "--loop"
            - "{{INGEST_LOOP_SECONDS}}"
          env:
            - name: AIS_LOG_FORMAT
              value: "json"
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          hostPath:
            path: /data/xnat-ingest
            type: DirectoryOrCreate
