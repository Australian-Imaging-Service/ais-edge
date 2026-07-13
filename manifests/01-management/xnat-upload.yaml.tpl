apiVersion: v1
kind: Namespace
metadata:
  name: xnat-upload
---
apiVersion: v1
kind: Secret
metadata:
  name: xnat-credentials
  namespace: xnat-upload
type: Opaque
stringData:
  server: "{{XNAT_URL}}"
  username: "{{XNAT_USER}}"
  password: "{{XNAT_PASS}}"
---
# TIER-1 (single node): the upload pod reads the LOCAL staging directory that
# xnat-ingest assign writes to on this same machine (host /data/xnat-ingest,
# mounted at /data, so /data/staging == host /data/xnat-ingest/staging) and
# uploads sessions to XNAT over HTTPS. There is NO SeaweedFS / S3 hop anymore:
# no s3:// source, no S3 credentials, no AWS_ENDPOINT_URL. xnat-ingest upload
# accepts a local filesystem path as its source (same binary, different first
# positional arg).
apiVersion: apps/v1
kind: Deployment
metadata:
  name: xnat-ingest-upload
  namespace: xnat-upload
  labels:
    app: xnat-ingest
    component: upload
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: xnat-ingest
      component: upload
  template:
    metadata:
      labels:
        app: xnat-ingest
        component: upload
    spec:
      containers:
        - name: upload
          image: {{XNAT_INGEST_IMAGE}}
          command: ["xnat-ingest", "upload"]
          args:
            - "/data/staging"          # LOCAL source dir written by assign (was s3://.../staged)
            - "$(XINGEST_HOST)"
            - "--always-include"
            - "all"
            - "--loop"
            - "60"
            - "--dont-require-manifest"
            - "--dont-verify-ssl"       # XNAT presents a private/self-signed cert
          env:
            - name: XINGEST_HOST
              valueFrom:
                secretKeyRef:
                  name: xnat-credentials
                  key: server
            - name: XINGEST_USER
              valueFrom:
                secretKeyRef:
                  name: xnat-credentials
                  key: username
            - name: XINGEST_PASS
              valueFrom:
                secretKeyRef:
                  name: xnat-credentials
                  key: password
            # Emit one JSON object per log line so Vector indexes
            # ts/level/logger/message without regex parsing.
            - name: AIS_LOG_FORMAT
              value: "json"
          volumeMounts:
            # Same host dir assign writes to. /data/staging in-container ==
            # host /data/xnat-ingest/staging. Must be byte-identical to the
            # assign pod's mount or upload reads an empty dir.
            - name: data
              mountPath: /data
      volumes:
        - name: data
          hostPath:
            path: /data/xnat-ingest
            type: DirectoryOrCreate
