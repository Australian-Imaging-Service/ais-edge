# =============================================================================
# Loki helm-chart values  —  log store (single-binary monolithic mode)
# =============================================================================
# Used by: scripts/02d-install-observability.sh
#   helm install loki grafana/loki -n observability -f <rendered-this-file>
#
# Sizing rationale: a single-node tier-1 appliance sending JSON log lines
# through one Vector DaemonSet. Single-binary "monolithic" deployment handles
# this load easily — the distributed mode (read/write/backend split) only pays
# off above ~50 GB/day.
#
# Storage: FILESYSTEM. Chunks (the actual gzipped log data), the tsdb index,
# and the ruler runtime state all live on a single local-path PVC mounted at
# /var/loki. No S3 / object-store hop — this is a self-contained single node.
#
# Auth: single-tenant, no multi-tenancy. Vector pushes to the in-cluster Loki
# Service over plain HTTP (traffic never leaves the node). Loki's synthetic
# tenant ID is `fake` when auth_enabled is false.
#
# Retention: {{OBSERVABILITY_RETENTION_DAYS}} days, enforced by the compactor
# deleting expired chunks/index off the filesystem.
# =============================================================================
deploymentMode: SingleBinary

loki:
  auth_enabled: false               # single tenant (`fake`), no bearer needed

  # tsdb index + filesystem object store. object_store: filesystem tells Loki
  # to keep chunks on the local PV instead of an S3 bucket.
  schemaConfig:
    configs:
      - from: 2024-04-01
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h

  # storage.type: filesystem (NOT in the object-storage set) makes the chart's
  # commonStorageConfig helper emit a `common.storage.filesystem` block using
  # these directories on the mounted PV.
  storage:
    type: filesystem
    filesystem:
      chunks_directory: /var/loki/chunks
      rules_directory: /var/loki/rules

  # Explicit storage_config so the tsdb shipper + filesystem object client
  # write everything under the persistent /var/loki mount.
  storage_config:
    tsdb_shipper:
      active_index_directory: /var/loki/tsdb-index
      cache_location: /var/loki/tsdb-cache
    filesystem:
      directory: /var/loki/chunks

  limits_config:
    retention_period: {{LOKI_RETENTION_HOURS}}h
    reject_old_samples: true
    reject_old_samples_max_age: 168h
    max_global_streams_per_user: 10000
    ingestion_rate_mb: 16
    ingestion_burst_size_mb: 32

  # Compactor drives retention. delete_request_store: filesystem so the
  # retention-delete requests are persisted on the same local PV.
  compactor:
    working_directory: /var/loki/compactor
    retention_enabled: true
    retention_delete_delay: 2h
    retention_delete_worker_count: 150
    delete_request_store: filesystem

  commonConfig:
    replication_factor: 1

  # =========================================================================
  # Ruler — runs LogQL alert rules on a schedule and emits firing alerts
  # to Alertmanager. This is how log-derived pipeline alerts (stalled/parked
  # sessions, upload failures, XNATUploadSuccess, disk usage) reach the
  # existing email/Slack receivers.
  #
  # storage.type: local + rulerConfig.storage.local.directory point the ruler
  # at the ConfigMap-mounted rule files on the local filesystem (no S3).
  #
  # Rule files are mounted as a ConfigMap at /etc/loki/rules/fake/ — `fake`
  # is Loki's tenant ID when auth_enabled is false. singleBinary mounts the
  # loki-ruler-rules ConfigMap there (see extraVolumes below).
  #
  # Alertmanager URL points at the kube-prometheus-stack alertmanager Service.
  # =========================================================================
  rulerConfig:
    storage:
      type: local
      local:
        directory: /etc/loki/rules
    rule_path: /var/loki/rules-runtime
    alertmanager_url: http://kube-prometheus-stack-alertmanager.observability.svc.cluster.local:9093
    enable_alertmanager_v2: true
    enable_api: true
    ring:
      kvstore:
        store: inmemory

singleBinary:
  replicas: 1
  resources:
    requests:  { cpu: 200m, memory: 512Mi }
    limits:    { cpu: 2,    memory: 2Gi }
  # Persist ALL Loki data (chunks, tsdb index, compactor, ruler runtime) on a
  # local-path PVC so logs survive pod restarts. The chart mounts this PVC at
  # /var/loki, which is exactly where storage_config/compactor point above.
  persistence:
    enabled: true
    size: 20Gi
    storageClass: local-path
  # Mount the loki-ruler-rules ConfigMap at /etc/loki/rules/fake/ — the
  # ruler reads each YAML file there as a rule group. `fake` is Loki's
  # synthetic tenant ID when auth_enabled is false.
  extraVolumes:
    - name: rules
      configMap:
        name: loki-ruler-rules
  extraVolumeMounts:
    - name: rules
      mountPath: /etc/loki/rules/fake
      readOnly: true

# Disable distributed-mode deployments (we use SingleBinary)
read:    { replicas: 0 }
write:   { replicas: 0 }
backend: { replicas: 0 }

# Disable sub-charts we don't need — chunks live on the local filesystem, no
# object storage, so no bundled MinIO and no chunk/results caches.
minio:
  enabled: false
chunksCache:
  enabled: false
resultsCache:
  enabled: false

# No external gateway — Vector pushes to the Loki Service directly in-cluster.
gateway:
  enabled: false

# Loki internal Service (ClusterIP). Vector and Grafana reach it at
# http://loki.observability.svc.cluster.local:3100 — no ingress, no TLS.
service:
  type: ClusterIP

monitoring:
  serviceMonitor:
    enabled: true
    labels:
      release: kube-prometheus-stack
  selfMonitoring:
    enabled: false
  lokiCanary:
    enabled: false

test:
  enabled: false
