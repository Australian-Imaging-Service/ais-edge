# =============================================================================
# Loki helm-chart values  —  log store (single-binary monolithic mode)
# =============================================================================
# Used by: scripts/02d-install-observability.sh
#   helm install loki grafana/loki -n observability -f <rendered-this-file>
#
# Sizing rationale: one mgmt + a few edges sending JSON log lines through
# Vector. Single-binary "monolithic" deployment handles this load fine —
# the distributed mode (read/write/backend split) only pays off above
# ~50 GB/day. Switch later if scale grows.
#
# Storage: chunks (the actual log data, gzipped) go to SeaweedFS via the S3
# API. The boltdb-shipper index stays on a small local PV (chart default).
#
# Auth: no Loki-side multi-tenancy. We rely on:
#   - the bearer-token Secret on each edge that Vector uses to push, and
#   - nginx-ingress on the management host doing TLS termination on
#     loki.aisedge.local (cert signed by ais-edge-ca).
#
# Retention: 30 days (per config/management.env: OBSERVABILITY_RETENTION_DAYS).
# =============================================================================
deploymentMode: SingleBinary

loki:
  auth_enabled: false               # we gate at the ingress with a bearer

  schemaConfig:
    configs:
      - from: 2024-04-01
        store: tsdb
        object_store: s3
        schema: v13
        index:
          prefix: loki_index_
          period: 24h

  storage:
    type: s3
    bucketNames:
      chunks:    "{{LOGS_BUCKET}}"
      ruler:     "{{LOGS_BUCKET}}"
      admin:     "{{LOGS_BUCKET}}"
    s3:
      endpoint: http://seaweedfs.seaweedfs.svc.cluster.local:8333
      region: us-east-1            # SeaweedFS ignores this; required by SDK
      s3ForcePathStyle: true       # SeaweedFS speaks path-style addressing
      insecure: true               # in-cluster plain HTTP (does not leave node)
      accessKeyId: "{{LOKI_S3_ACCESS_KEY}}"
      secretAccessKey: "{{LOKI_S3_SECRET_KEY}}"

  limits_config:
    retention_period: {{LOKI_RETENTION_HOURS}}h
    reject_old_samples: true
    reject_old_samples_max_age: 168h
    max_global_streams_per_user: 10000
    ingestion_rate_mb: 16
    ingestion_burst_size_mb: 32

  compactor:
    working_directory: /var/loki/compactor
    retention_enabled: true
    retention_delete_delay: 2h
    retention_delete_worker_count: 150
    delete_request_store: s3

  commonConfig:
    replication_factor: 1

  # =========================================================================
  # Ruler — runs LogQL alert rules on a schedule and emits firing alerts
  # to Alertmanager. This replaces a separate Prometheus path for any
  # log-derived alerts (which a mgmt-side Prometheus could not collect from
  # the edge child clusters across the konnectivity boundary anyway).
  #
  # Rule files are mounted as a ConfigMap at /etc/loki/rules/fake/ — `fake`
  # is Loki's tenant ID when auth_enabled is false. The sidecar container
  # in the loki Helm chart watches ConfigMaps with the configured label
  # and writes them into that path so this stays declarative.
  #
  # Alertmanager URL points at the existing kube-prometheus-stack
  # alertmanager Service; receivers (email/Slack) configured via
  # ALERT_* env vars in config/management.env continue to handle these.
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
  persistence:
    enabled: true
    size: 10Gi
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

# Disable sub-charts we don't need (chunks already on S3)
minio:
  enabled: false
chunksCache:
  enabled: false
resultsCache:
  enabled: false

gateway:
  enabled: false                  # we expose Loki via nginx-ingress directly

# Loki itself — internal Service (ClusterIP). External access is via the
# observability-ingress.yaml.tpl with SNI = loki.aisedge.local.
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
