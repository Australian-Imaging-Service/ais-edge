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
apiVersion: v1
kind: Secret
metadata:
  name: s3-credentials
  namespace: xnat-upload
type: Opaque
stringData:
  access-key: "{{S3_ADMIN_ACCESS_KEY}}"
  secret-key: "{{S3_ADMIN_SECRET_KEY}}"
---
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
          # Default points at our fork on ghcr.io with the AIS_LOG_FORMAT=json
          # patch. Override XNAT_INGEST_IMAGE
          # in config/management.env when upstream merges to switch back to
          # ghcr.io/australian-imaging-service/xnat-ingest:latest.
          image: {{XNAT_INGEST_IMAGE}}
          command: ["xnat-ingest", "upload"]
          args:
            - "s3://{{S3_BUCKET}}/staged"
            - "$(XINGEST_HOST)"
            - "--always-include"
            - "all"
            - "--loop"
            - "60"
            - "--dont-require-manifest"
            - "--dont-verify-ssl"
            - "--store-credentials"
            - "$(S3_ACCESS_KEY)"
            - "$(S3_SECRET_KEY)"
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
            - name: S3_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: s3-credentials
                  key: access-key
            - name: S3_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: s3-credentials
                  key: secret-key
            # Point boto3 at the in-cluster SeaweedFS service
            - name: AWS_ENDPOINT_URL
              value: "http://seaweedfs.seaweedfs.svc.cluster.local:8333"
            - name: AWS_DEFAULT_REGION
              value: "us-east-1"
            # Emit one JSON object per log line so Vector indexes
            # ts/level/logger/message without regex parsing.
            - name: AIS_LOG_FORMAT
              value: "json"
