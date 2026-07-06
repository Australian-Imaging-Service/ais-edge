apiVersion: v1
kind: Namespace
metadata:
  name: xnat-ingest
---
# Sort pod: REST-pulls deid'd instances from Orthanc and hardlinks the DICOM
# files from Orthanc's storage tree (/data/orthanc-storage) into staging
# (/data/staging/PROJECT.SUBJECT.VISIT/). Hardlink requires the same
# filesystem, which is why the Orthanc pod and this pod share the same
# /data hostPath (/data/xnat-ingest on the host).
#
# TIER-1 (single node): there is no S3 hop anymore. On this one machine the
# xnat-ingest-upload pod reads the SAME /data/staging directory directly and
# uploads to XNAT. The old s3-uploader (mc mirror -> SeaweedFS) is gone.
#
# Label contract with Orthanc:
#   --orthanc-label xnat-ingest-ready     only consider studies with this label
#                                         (added by the Lua deid hook on success)
#   --orthanc-skip-label xnat-ingest-skip skip studies already staged
#                                         (sort adds this label after hardlink)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: xnat-ingest-sort
  namespace: xnat-ingest
  labels:
    app: xnat-ingest
    component: sort
spec:
  replicas: 1
  selector:
    matchLabels:
      app: xnat-ingest
      component: sort
  template:
    metadata:
      labels:
        app: xnat-ingest
        component: sort
    spec:
      containers:
        - name: sort
          # Default points at our fork on ghcr.io with the JSON-logging
          # patch. Override XNAT_INGEST_IMAGE in config/management.env to
          # switch (e.g. to upstream once merged).
          image: {{XNAT_INGEST_IMAGE}}
          command: ["xnat-ingest", "sort"]
          args:
            - "/data/staging"
            - "--orthanc-url"
            - "http://orthanc.xnat-ingest.svc.cluster.local:8042"
            - "--orthanc-storage-dir"
            - "/data/orthanc-storage"
            - "--orthanc-label"
            - "xnat-ingest-ready"
            - "--orthanc-skip-label"
            - "xnat-ingest-skip"
            - "--project-id"
            - "{{PROJECT_ID}}"
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
