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
  name: minio-credentials
  namespace: xnat-upload
type: Opaque
stringData:
  access-key: "{{MINIO_ROOT_USER}}"
  secret-key: "{{MINIO_ROOT_PASSWORD}}"
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
          image: ghcr.io/australian-imaging-service/xnat-ingest:latest
          command: ["xnat-ingest", "upload"]
          args:
            - "s3://{{MINIO_BUCKET}}/staged"
            - "$(XINGEST_HOST)"
            - "--always-include"
            - "all"
            - "--loop"
            - "60"
            - "--dont-require-manifest"
            - "--dont-verify-ssl"
            - "--store-credentials"
            - "$(MINIO_ACCESS_KEY)"
            - "$(MINIO_SECRET_KEY)"
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
            - name: MINIO_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: minio-credentials
                  key: access-key
            - name: MINIO_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: minio-credentials
                  key: secret-key
            - name: AWS_ENDPOINT_URL
              value: "http://minio.minio.svc.cluster.local:9000"
            - name: AWS_DEFAULT_REGION
              value: "us-east-1"
