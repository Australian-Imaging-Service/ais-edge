# =============================================================================
# kube-prometheus-stack helm-chart values  —  Prometheus + Grafana +
#                                              Alertmanager + kube-state-metrics
# =============================================================================
# Used by: scripts/02d-install-observability.sh
#   helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
#     -n observability -f <rendered-this-file>
#
# What's enabled:
#   prometheusOperator         (the controller that turns CRDs into deployments)
#   prometheus                 (the time-series database; single replica, local PV)
#   alertmanager               (alert dedup + routing; reads our config Secret)
#   grafana                    (dashboards; local admin user from config)
#   kubeStateMetrics           (K8s object state -> Prom metrics)
#
# What's disabled:
#   prometheusNodeExporter     (host metrics; would need hostNetwork — opt-in
#                               later; cAdvisor in kubelet covers most of it)
#   defaultRules.create        (we ship our own alerts/*.yaml from this repo
#                               so they're version-controlled with the code)
# =============================================================================

defaultRules:
  create: false                    # we ship our own PrometheusRule files

prometheus:
  prometheusSpec:
    retention: {{PROM_RETENTION_DAYS}}d
    retentionSize: ""              # disk-bound by PVC size below
    scrapeInterval: 30s
    evaluationInterval: 30s

    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          storageClassName: local-path
          resources:
            requests:
              storage: 20Gi

    # Scrape ANY ServiceMonitor / PodMonitor / PrometheusRule in any namespace
    # that has label release=kube-prometheus-stack. This lets us drop
    # ServiceMonitors next to our app manifests and have them auto-picked-up.
    serviceMonitorSelector:
      matchLabels:
        release: kube-prometheus-stack
    podMonitorSelector:
      matchLabels:
        release: kube-prometheus-stack
    ruleSelector:
      matchLabels:
        release: kube-prometheus-stack
    serviceMonitorNamespaceSelector: {}
    podMonitorNamespaceSelector:    {}
    ruleNamespaceSelector:          {}

    resources:
      requests: { cpu: 250m, memory: 1Gi }
      limits:   { cpu: 2,    memory: 4Gi }

alertmanager:
  enabled: true
  alertmanagerSpec:
    # We render our config from ALERT_* env vars at install time and apply
    # it as a Secret with this name; alertmanagerSpec.configSecret tells the
    # operator to mount that instead of the chart's empty default.
    configSecret: alertmanager-aisedge-config
    storage:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          storageClassName: local-path
          resources:
            requests:
              storage: 2Gi
    resources:
      requests: { cpu: 50m, memory: 128Mi }
      limits:   { cpu: 500m, memory: 512Mi }

grafana:
  enabled: true
  admin:
    existingSecret: grafana-admin-credentials
    userKey: admin-user
    passwordKey: admin-password
  defaultDashboardsEnabled: true   # ships generic K8s dashboards out of the box
  service:
    type: ClusterIP                # exposed via nginx-ingress, not direct
  persistence:
    enabled: true
    type: pvc
    storageClassName: local-path
    accessModes: ["ReadWriteOnce"]
    size: 5Gi

  # PVC is RWO, so a rolling update deadlocks: the new pod can't init-chown
  # the volume while the old pod still holds it, and the old pod won't
  # terminate until the new one is Ready. Recreate strategy avoids the
  # deadlock — brief downtime during upgrades is fine for an internal tool.
  deploymentStrategy:
    type: Recreate

  # Disable the init-chown-data init container. Once Grafana has run once,
  # subdirs like pdf/csv/png are mode 700 owned by 472:472. The init
  # container runs as root with capabilities drop:ALL, add:[CHOWN] — without
  # CAP_DAC_OVERRIDE root can't traverse those 700 dirs, so `chown -R` errors
  # with Permission denied. Ownership is already correct, so the chown is a
  # no-op anyway. fsGroup on the pod handles initial ownership for new PVCs.
  initChownData:
    enabled: false

  # Datasources — Loki and Prometheus pre-wired.
  # Explicit uid: 'loki' so dashboards in dashboards/*.json that reference
  # `"datasource": {"type": "loki", "uid": "loki"}` resolve correctly.
  # (The KPS chart's built-in Prometheus datasource already has uid:
  # prometheus, so dashboards referencing that work out of the box.)
  #
  # deleteDatasources — Grafana's provisioner addresses datasources by UID
  # internally. If a previous install (or chart upgrade) created `Loki`
  # with an auto-generated UID, the row persists in grafana.db on the PVC.
  # Re-provisioning the same name with a new explicit UID then errors with
  # "Datasource provisioning error: data source not found" because the
  # provisioner can't find the new UID in the DB. Listing the name here
  # tells Grafana to delete the existing row by name first, so the explicit
  # UID can be applied cleanly. Safe to keep — it's a no-op on fresh DBs.
  deleteDatasources:
    - name: Loki
      orgId: 1
  additionalDataSources:
    - name: Loki
      uid: loki
      type: loki
      access: proxy
      url: http://loki.observability.svc.cluster.local:3100
      isDefault: false
      jsonData:
        maxLines: 5000

  # Dashboards auto-loaded from a sidecar that watches ConfigMaps with
  # this label. We apply each JSON file in dashboards/ as such a ConfigMap.
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      labelValue: "1"
      searchNamespace: observability
      folderAnnotation: grafana_dashboard_folder
      provider:
        foldersFromFilesStructure: true
    datasources:
      enabled: true

  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: 1,    memory: 1Gi }

# Host-level metrics we deliberately disable (avoid hostNetwork on edges
# AND mgmt for symmetry; cAdvisor in kubelet still gives us pod metrics).
prometheus-node-exporter:
  enabled: false
nodeExporter:
  enabled: false

# kube-state-metrics — exports the state of K8s objects (pods, deployments,
# pvcs, certificates) as Prometheus metrics. Required for many alerts.
kubeStateMetrics:
  enabled: true
kube-state-metrics:
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits:   { cpu: 200m, memory: 256Mi }

# Disable scraping of components that are managed by k0s and not exposed
# in the way upstream charts assume.
kubeApiServer:           { enabled: true }
kubeControllerManager:   { enabled: false }   # k0s embeds; not exposed as Service
kubeScheduler:           { enabled: false }   # same
kubeProxy:               { enabled: false }   # not exposed by k0s
kubeEtcd:                { enabled: false }   # k0smotron etcd is per-edge-cluster
kubelet:                 { enabled: true  }   # cAdvisor metrics + kubelet itself
coreDns:                 { enabled: true  }
