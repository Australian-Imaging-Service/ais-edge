apiVersion: v1
kind: Namespace
metadata:
  name: xnat-ingest
---
apiVersion: v1
kind: Secret
metadata:
  name: minio-edge-credentials
  namespace: xnat-ingest
type: Opaque
stringData:
  access-key: "{{MINIO_EDGE_ACCESS_KEY}}"
  secret-key: "{{MINIO_EDGE_SECRET_KEY}}"
---
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
# S3 uploader: watches /data/staging for staged sessions,
# uploads them to MinIO using mc (MinIO client), then removes local copy.
# Only has MinIO WRITE-ONLY credentials — cannot read or access XNAT.
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
            - name: MINIO_ENDPOINT
              value: "http://{{MGMT_NODE_IP}}:{{MINIO_NODEPORT}}"
            - name: MINIO_BUCKET
              value: "{{MINIO_BUCKET}}"
            - name: MINIO_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: minio-edge-credentials
                  key: access-key
            - name: MINIO_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: minio-edge-credentials
                  key: secret-key
          command: ["/bin/sh", "-c"]
          args:
            - |
              echo "S3 uploader starting..."
              echo "MinIO endpoint: ${MINIO_ENDPOINT}"
              echo "Bucket: ${MINIO_BUCKET}"

              # Configure mc alias
              mc alias set edge "${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}"

              while true; do
                for session_dir in /data/staging/*/; do
                  session_name=$(basename "$session_dir")

                  # Skip internal directories
                  case "$session_name" in
                    __build__|__invalid__|__metadata__|"*") continue ;;
                  esac

                  echo "$(date -Iseconds) Uploading session: $session_name"

                  # mc mirror: copies directory tree to S3, preserves structure
                  # --overwrite: replace if exists
                  if mc mirror --overwrite "$session_dir" "edge/${MINIO_BUCKET}/staged/${session_name}/"; then
                    echo "$(date -Iseconds) SUCCESS: $session_name uploaded to S3"
                    echo "$(date -Iseconds) Removing local copy..."
                    rm -rf "$session_dir"
                  else
                    echo "$(date -Iseconds) FAILED: $session_name — will retry next cycle"
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
