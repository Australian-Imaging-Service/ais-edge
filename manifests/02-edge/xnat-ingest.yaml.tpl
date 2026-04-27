apiVersion: v1
kind: Namespace
metadata:
  name: xnat-ingest
---
# S3 credentials for the edge node — scoped to write+list on the ingest bucket only.
# These are the credentials defined for this CLUSTER_NAME in edge-nodes.env.
# Loss of this key cannot read XNAT data, cannot read other sites' data, and
# cannot bypass the bucket-level scoping enforced by SeaweedFS.
apiVersion: v1
kind: Secret
metadata:
  name: s3-edge-credentials
  namespace: xnat-ingest
type: Opaque
stringData:
  access-key: "{{S3_EDGE_ACCESS_KEY}}"
  secret-key: "{{S3_EDGE_SECRET_KEY}}"
---
# Sort pod: watches /data/incoming for new DICOM files, parses metadata,
# stages them under /data/staging/PROJECT.SUBJECT.VISIT/, deletes from incoming.
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
          image: ghcr.io/australian-imaging-service/xnat-ingest:latest
          command: ["xnat-ingest", "sort"]
          args:
            - "/data/incoming"
            - "/data/staging"
            - "--project-id"
            - "{{PROJECT_ID}}"
            - "--loop"
            - "{{INGEST_LOOP_SECONDS}}"
            - "--wait-period"
            - "{{INGEST_WAIT_PERIOD}}"
            - "--delete"
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          hostPath:
            path: /data/xnat-ingest
            type: DirectoryOrCreate
---
# S3 uploader: watches /data/staging for completed sessions, mirrors them
# to SeaweedFS via the S3 API using `mc mirror`. mc handles multipart upload,
# parallel chunks, checksums, and retry — same protocol as MinIO, AWS S3.
#
# Credentials on edge: write+list only on one bucket. Cannot read other
# sites' data, cannot reach XNAT.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: s3-uploader
  namespace: xnat-ingest
  labels:
    app: xnat-ingest
    component: s3-uploader
spec:
  replicas: 1
  selector:
    matchLabels:
      app: xnat-ingest
      component: s3-uploader
  template:
    metadata:
      labels:
        app: xnat-ingest
        component: s3-uploader
    spec:
      containers:
        - name: uploader
          image: minio/mc:latest
          env:
            - name: S3_ENDPOINT
              value: "http://{{MGMT_NODE_IP}}:{{S3_NODEPORT}}"
            - name: S3_BUCKET
              value: "{{S3_BUCKET}}"
            - name: S3_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: s3-edge-credentials
                  key: access-key
            - name: S3_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: s3-edge-credentials
                  key: secret-key
          command: ["/bin/sh", "-c"]
          args:
            - |
              echo "S3 uploader starting..."
              echo "Endpoint: ${S3_ENDPOINT}"
              echo "Bucket:   ${S3_BUCKET}"

              # mc speaks vanilla S3 — works against MinIO, SeaweedFS, AWS S3, etc.
              mc alias set edge "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}"

              while true; do
                for session_dir in /data/staging/*/; do
                  session_name=$(basename "$session_dir")

                  # Skip internal staging directories created by xnat-ingest sort
                  case "$session_name" in
                    __build__|__invalid__|__metadata__|"*") continue ;;
                  esac

                  echo "$(date -Iseconds) Uploading session: $session_name"

                  # mc mirror: rsync-for-S3. Multipart, parallel, resumable.
                  if mc mirror --overwrite "$session_dir" \
                      "edge/${S3_BUCKET}/staged/${session_name}/"; then
                    echo "$(date -Iseconds) SUCCESS: $session_name uploaded"
                    rm -rf "$session_dir"
                  else
                    echo "$(date -Iseconds) FAILED: $session_name — retry next cycle"
                  fi
                done

                sleep 30
              done
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          hostPath:
            path: /data/xnat-ingest
            type: DirectoryOrCreate
