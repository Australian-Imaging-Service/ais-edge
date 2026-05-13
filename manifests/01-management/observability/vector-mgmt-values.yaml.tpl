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

# Vector reads logs and writes its own checkpoint state to a hostPath
# (/var/lib/vector by default). The hostPath is owned by root, so we
# leave the container running as root rather than fighting the chart
# defaults. Defense-in-depth via dropping all capabilities + seccomp;
# the only host filesystem touched is /var/lib/vector (Vector-only) and
# /var/log/pods (read-only).
podSecurityContext:
  seccompProfile:
    type: RuntimeDefault
securityContext:
  allowPrivilegeEscalation: false
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
    # This lets fields like `event`, `component`, `session` become first-class
    # for LogQL `| json` queries and Loki ruler rules downstream.
    parse_json_messages:
      type: remap
      inputs: [add_cluster_label]
      source: |
        parsed, err = parse_json(.message)
        if err == null && is_object(parsed) {
          . = merge!(., parsed)
        }

  sinks:
    loki:
      type: loki
      inputs: [parse_json_messages]
      endpoint: http://loki.observability.svc.cluster.local:3100
      # Slim down the JSON body before shipping. The `kubernetes_logs`
      # source enriches every event with a fat metadata block (file path,
      # container_id, image, node_labels, pod_ips, pod_uid, etc.) that
      # we already extract into Loki stream labels in `labels:` below.
      # Re-emitting it inside each log line bloats storage and makes the
      # Live tail panel in Grafana unreadable. except_fields drops them
      # from the body but the sink still has the full event in scope, so
      # the label templates below resolve correctly.
      encoding:
        codec: json
        except_fields:
          - kubernetes
          - file
          - source_type
          - stream
          - tags
      labels:
        cluster: "{{`{{ cluster }}`}}"
        namespace: "{{`{{ kubernetes.pod_namespace }}`}}"
        pod: "{{`{{ kubernetes.pod_name }}`}}"
        container: "{{`{{ kubernetes.container_name }}`}}"
        app: "{{`{{ kubernetes.pod_labels.app }}`}}"
        component: "{{`{{ kubernetes.pod_labels.component }}`}}"
        level: "{{`{{ level }}`}}"
      remove_label_fields: true
      out_of_order_action: accept
      compression: gzip
      batch:
        max_bytes: 1048576
        timeout_secs: 1

# Vector on the management cluster only pushes logs OUT to Loki — it does
# not expose any in-cluster endpoint. Disable the chart's default Service
# and the (silently broken) serviceMonitor knob. Pipeline-event alerts run
# inside Loki's ruler over the same logs; see manifests/01-management/
# observability/loki-ruler-rules.yaml for the rule definitions.
service:
  enabled: false
serviceMonitor:
  enabled: false
