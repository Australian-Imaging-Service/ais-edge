# Orthanc DICOM receiver + deid hook.
#
# Role at the edge:
#   1. DIMSE SCP on host port 4242 (AET=AISEDGE) — modalities push studies here.
#   2. Lua OnStoredInstance applies the deidentification profile selected by
#      routing.json, writes the ORIGINAL to /facility-backup, deletes the
#      original from Orthanc, keeps the deid'd instance in Orthanc storage.
#   3. Lua OnStableStudy (after StableAge=30s silence) PUTs the
#      `ais-deid-done` label on the study.
#   4. xnat-ingest sort REST-pulls labelled studies and hardlinks instances
#      from /data/orthanc-storage into /data/staging.
#
# ConfigMaps (orthanc-config, orthanc-scripts, orthanc-routing,
# orthanc-deidentification-profile) are created by
# scripts/07c-deploy-edge-orthanc.sh via `kubectl create configmap
# --from-file` so the source-of-truth lives in config/orthanc/ and we
# don't have to YAML-indent the file contents.
---
apiVersion: v1
kind: Secret
metadata:
  name: orthanc-deid-salt
  namespace: xnat-ingest
type: Opaque
stringData:
  AIS_DEID_HMAC_SALT: "{{AIS_DEID_HMAC_SALT}}"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orthanc
  namespace: xnat-ingest
  labels:
    app: orthanc
    component: dicom-receiver
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: orthanc
      component: dicom-receiver
  template:
    metadata:
      labels:
        app: orthanc
        component: dicom-receiver
    spec:
      containers:
        - name: orthanc
          image: {{ORTHANC_IMAGE}}
          args: ["/etc/orthanc"]
          ports:
            - name: dicom
              containerPort: 4242
              hostPort: 4242    # exposed on edge node IP for local-LAN modalities
            - name: http
              containerPort: 8042
          env:
            - name: AIS_DEID_HMAC_SALT
              valueFrom:
                secretKeyRef:
                  name: orthanc-deid-salt
                  key: AIS_DEID_HMAC_SALT
            - name: AIS_ROUTING_FILE
              value: /etc/orthanc/routing.json
          volumeMounts:
            - name: config
              mountPath: /etc/orthanc/orthanc.json
              subPath: orthanc.json
              readOnly: true
            - name: scripts
              mountPath: /etc/orthanc/scripts
              readOnly: true
            - name: routing
              mountPath: /etc/orthanc/routing.json
              subPath: routing.json
              readOnly: true
            - name: deidentification-profile
              mountPath: /etc/orthanc/deidentification-profile.json
              subPath: deidentification-profile.json
              readOnly: true
            # Shared with xnat-ingest sort. Same hostPath on both pods so
            # hardlinks from /data/orthanc-storage to /data/staging resolve
            # to the same inode (cross-fs hardlink would EXDEV).
            - name: data
              mountPath: /data
            - name: facility-backup
              mountPath: /facility-backup
      volumes:
        - name: config
          configMap:
            name: orthanc-config
        - name: scripts
          configMap:
            name: orthanc-scripts
            defaultMode: 0755
        - name: routing
          configMap:
            name: orthanc-routing
        - name: deidentification-profile
          configMap:
            name: orthanc-deidentification-profile
        - name: data
          hostPath:
            path: /data/xnat-ingest
            type: DirectoryOrCreate
        - name: facility-backup
          hostPath:
            path: /data/facility-backup
            type: DirectoryOrCreate
---
# ClusterIP for sort to reach Orthanc's REST API. DICOM port (4242) is
# exposed via hostPort on the Deployment, not via this Service.
apiVersion: v1
kind: Service
metadata:
  name: orthanc
  namespace: xnat-ingest
spec:
  type: ClusterIP
  selector:
    app: orthanc
    component: dicom-receiver
  ports:
    - name: http
      port: 8042
      targetPort: 8042
