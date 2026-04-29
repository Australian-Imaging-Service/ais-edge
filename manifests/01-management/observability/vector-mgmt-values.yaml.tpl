# =============================================================================
# Vector helm-chart values  —  log shipper on the management node
# =============================================================================
# Used by: scripts/02d-install-observability.sh
#   helm install vector-mgmt vector/vector -n observability -f <rendered-this-file>
#
# Vector tails kubelet log files (/var/log/pods/<ns>_<pod>_<uid>/<ctr>/N.log)
# on each node, parses JSON automatically, enriches with kubernetes_logs
# metadata (namespace, pod, container, node, labels), and pushes batches
# of events to Loki over HTTPS.
#
# Why not hostNetwork: Vector's only network needs are outbound (to
# Loki). It does NOT need to bind any host port. dnsPolicy: ClusterFirst
# (default) is fine — Loki resolves through cluster DNS to a ClusterIP.
#
# hostPath /var/log/pods is read-only. The pod runs as a non-root user
# with read-only root filesystem. Standard log-collector pattern.
#
# Templating: our render() replaces {{KEY}} (no spaces). Vector itself
# expands {{ field_name }} (WITH spaces) at runtime. The two don't
# collide because of the spaces.
# =============================================================================

role: Agent                          # one Vector pod per node (DaemonSet)
hostNetwork: false                   # explicit — Vector does NOT need it
dnsPolicy: ClusterFirst

# Hardened security context — Vector reads logs but never writes anywhere.
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 65534
  runAsGroup: 65534
  fsGroup: 65534
  seccompProfile:
    type: RuntimeDefault
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]

tolerations:
  - operator: Exists

resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits:   { cpu: 1,    memory: 512Mi }

dataDir: /vector-data-dir

extraVolumes:
  - name: pod-logs
    hostPath: { path: /var/log/pods }
  - name: containerd-logs
    hostPath: { path: /var/log/containers }
extraVolumeMounts:
  - name: pod-logs
    mountPath: /var/log/pods
    readOnly: true
  - name: containerd-logs
    mountPath: /var/log/containers
    readOnly: true

customConfig:
  data_dir: /vector-data-dir
  api:
    enabled: false

  sources:
    kubelet_logs:
      type: kubernetes_logs
      auto_partial_merge: true

  transforms:
    # Inject the cluster identity so Loki queries can scope by edge site.
    add_cluster_label:
      type: remap
      inputs: [kubelet_logs]
      source: |
        .cluster = "{{CLUSTER_LABEL}}"

    # If the log message is JSON, parse it and merge the keys into the event.
    parse_json_messages:
      type: remap
      inputs: [add_cluster_label]
      source: |
        parsed, err = parse_json(.message)
        if err == null && is_object(parsed) {
          . = merge(., parsed)
        }

    # Counter pipeline — convert log events to Prometheus metrics.
    pipeline_counter:
      type: log_to_metric
      inputs: [parse_json_messages]
      metrics:
        - type: counter
          field: event
          name: events_total
          tags:
            event:     "{{ event }}"
            cluster:   "{{ cluster }}"
            component: "{{ component }}"

  sinks:
    loki:
      type: loki
      inputs: [parse_json_messages]
      endpoint: http://loki.observability.svc.cluster.local:3100
      encoding:
        codec: json
      labels:
        cluster: "{{ cluster }}"
        namespace: "{{ kubernetes.pod_namespace }}"
        pod: "{{ kubernetes.pod_name }}"
        container: "{{ kubernetes.container_name }}"
        app: "{{ kubernetes.pod_labels.app }}"
        component: "{{ kubernetes.pod_labels.component }}"
        level: "{{ level }}"
      remove_label_fields: true
      out_of_order_action: accept
      compression: gzip
      batch:
        max_bytes: 1048576
        timeout_secs: 1

    pipeline_metrics:
      type: prometheus_exporter
      inputs: [pipeline_counter]
      address: 0.0.0.0:9598
      default_namespace: ais_pipeline

# Expose the Prometheus exporter as a Service for kube-prometheus-stack
# to scrape via ServiceMonitor.
service:
  enabled: true
  type: ClusterIP
  ports:
    - name: prom-exporter
      port: 9598
      targetPort: 9598
      protocol: TCP

serviceMonitor:
  enabled: true
  additionalLabels:
    release: kube-prometheus-stack
