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
# Sort pod: REST-pulls deid'd instances from Orthanc, hardlinks the DICOM
# files from Orthanc's storage tree (/data/orthanc-storage) into staging
# (/data/staging/PROJECT.SUBJECT.VISIT/). Hardlink requires same filesystem,
# which is why the Orthanc pod and this pod share the same /data hostPath.
#
# Label contract with Orthanc:
#   --orthanc-label xnat-ingest-ready   only consider instances with this label
#                                   (added by the Lua deid hook on success)
#   --orthanc-skip-label xnat-ingest-skip   skip instances already staged
#                                   (sort adds this label after hardlink)
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
      # Pod-level /etc/hosts so any in-pod tool can resolve the
      # management hostnames without external DNS.
      hostAliases:
        - ip: "{{MGMT_NODE_IP}}"
          hostnames:
            - "{{SEAWEEDFS_HOSTNAME}}"
            - "{{K0S_API_HOSTNAME}}"
            - "{{KONNECTIVITY_HOSTNAME}}"
            - "{{LOKI_HOSTNAME}}"
            - "{{GRAFANA_HOSTNAME}}"
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
            - "{{LOKI_HOSTNAME}}"
            - "{{GRAFANA_HOSTNAME}}"
      containers:
        - name: uploader
          image: minio/mc:latest
          env:
            - name: S3_ENDPOINT
              value: "https://{{SEAWEEDFS_HOSTNAME}}"
            - name: S3_BUCKET
              value: "{{S3_BUCKET}}"
            - name: EDGE_NAME
              value: "{{CLUSTER_NAME}}"
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
              # Each meaningful pipeline event is emitted as one line of JSON
              # so the central log collector (Vector) can parse it without
              # regexes. Schema: {ts, component, edge, event, session?, ...}
              jlog() {
                # $1=event, $2=session (optional), $3=msg (optional), $4=extra-json (optional)
                printf '{"ts":"%s","component":"s3-uploader","edge":"%s","event":"%s","session":"%s","message":"%s"%s}\n' \
                  "$(date -Iseconds)" "${EDGE_NAME}" "$1" "${2:-}" "${3:-}" "${4:-}"
              }

              jlog startup "" "s3-uploader starting endpoint=${S3_ENDPOINT} bucket=${S3_BUCKET}"

              # mc speaks vanilla S3 — works against MinIO, SeaweedFS, AWS S3, etc.
              mc alias set edge "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}" >/dev/null \
                && jlog alias_configured "" "mc alias set edge OK" \
                || jlog alias_failed "" "mc alias set edge FAILED"

              while true; do
                for session_dir in /data/staging/*/; do
                  session_name=$(basename "$session_dir")

                  # Skip internal staging directories created by xnat-ingest sort
                  case "$session_name" in
                    __build__|__invalid__|__metadata__|"*") continue ;;
                  esac

                  # The minio/mc image is distroless — only `mc`, busybox shell,
                  # and a small set of coreutils. `awk` and `find` are NOT
                  # included, so the previous `awk '{print $1}'` and `find ...`
                  # both errored with "not found" and the structured event
                  # carried bytes:0/files:0 even on successful uploads.
                  # These shell-builtin equivalents work in the bare busybox sh:
                  #   * du -sb prints "<bytes><tab><path>" — strip the tail with
                  #     parameter expansion to keep just the number.
                  #   * file count is total `du -a` lines (files+dirs) minus
                  #     `du` lines (dirs only); both `du` and `wc -l` are
                  #     present in the image since the original `find | wc -l`
                  #     pipeline was failing on `find`, not `wc`.
                  bytes_raw=$(du -sb "$session_dir" 2>/dev/null)
                  bytes=${bytes_raw%%[[:space:]]*}
                  bytes=${bytes:-0}
                  # `files` is the total count of S3 objects uploaded for this
                  # session (DICOMs + the auto-generated MANIFEST.json + any
                  # other per-session metadata). `dicoms` is the subset that
                  # are DICOM image files (.dcm / .DCM). Both fields are
                  # exposed in the event so dashboard / alert authors can
                  # pick the right one — "DICOMs received" should query
                  # dicoms; "S3 objects written" should query files.
                  #
                  # The minio/mc image is distroless: only `mc`, bash, and
                  # coreutils (du, wc, cut, etc.). awk/find/grep/sed are NOT
                  # present, so the DICOM-extension filter is implemented as
                  # a POSIX shell `case` pattern fed by a while-read pipe
                  # rather than `grep`.
                  total_lines=$(du -a "$session_dir" 2>/dev/null | wc -l)
                  dir_lines=$(du "$session_dir" 2>/dev/null | wc -l)
                  files=$((total_lines - dir_lines))
                  [ "$files" -lt 0 ] && files=0
                  dicoms=$(du -a "$session_dir" 2>/dev/null \
                    | while IFS= read -r line; do
                        case "$line" in
                          *.dcm|*.DCM) echo 1 ;;
                        esac
                      done | wc -l)
                  dicoms=${dicoms:-0}
                  jlog upload_started "$session_name" "" ",\"bytes\":${bytes},\"files\":${files},\"dicoms\":${dicoms}"

                  start_ts=$(date +%s)

                  # mc mirror: rsync-for-S3. Multipart, parallel, resumable.
                  # --json makes mc itself emit one JSON line per object
                  # transferred, indexed by Vector alongside our own events.
                  if mc --json mirror --overwrite "$session_dir" \
                      "edge/${S3_BUCKET}/staged/${session_name}/"; then
                    duration=$(( $(date +%s) - start_ts ))
                    jlog upload_completed "$session_name" "" \
                      ",\"bytes\":${bytes:-0},\"files\":${files:-0},\"dicoms\":${dicoms:-0},\"duration_s\":${duration}"
                    rm -rf "$session_dir"
                  else
                    duration=$(( $(date +%s) - start_ts ))
                    jlog upload_failed "$session_name" "mc mirror non-zero exit; will retry next cycle" \
                      ",\"bytes\":${bytes:-0},\"files\":${files:-0},\"dicoms\":${dicoms:-0},\"duration_s\":${duration}"
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
