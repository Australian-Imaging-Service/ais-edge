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
      # Phase 2: pod-level /etc/hosts so any in-pod tool can resolve the
      # management hostnames without external DNS.
      hostAliases:
        - ip: "{{MGMT_NODE_IP}}"
          hostnames:
            - "{{SEAWEEDFS_HOSTNAME}}"
            - "{{K0S_API_HOSTNAME}}"
            - "{{KONNECTIVITY_HOSTNAME}}"
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
# Phase 2:
#   - S3_ENDPOINT switched to https://{{SEAWEEDFS_HOSTNAME}} (port 443)
#   - The CA bundle Secret "ca-bundle" is mounted at /root/.mc/certs/CAs/
#     so mc trusts the seaweedfs-tls cert (issued by ais-edge-ca-issuer)
#   - hostAliases resolves the SNI hostname to MGMT_NODE_IP
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
      hostAliases:
        - ip: "{{MGMT_NODE_IP}}"
          hostnames:
            - "{{SEAWEEDFS_HOSTNAME}}"
            - "{{K0S_API_HOSTNAME}}"
            - "{{KONNECTIVITY_HOSTNAME}}"
      containers:
        - name: uploader
          image: minio/mc:latest
          env:
            - name: S3_ENDPOINT
              value: "https://{{SEAWEEDFS_HOSTNAME}}"
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
            # mc reads PEM files in /root/.mc/certs/CAs/ as additional trust roots
            - name: ca-bundle
              mountPath: /root/.mc/certs/CAs
              readOnly: true
      volumes:
        - name: data
          hostPath:
            path: /data/xnat-ingest
            type: DirectoryOrCreate
        - name: ca-bundle
          secret:
            secretName: ca-bundle
            optional: true
