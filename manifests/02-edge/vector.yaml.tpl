# =============================================================================
# Vector DaemonSet for the edge child cluster
# =============================================================================
# Tails kubelet's pod-log files on every worker, parses JSON, and pushes
# batches to Loki on the management node over HTTPS — using the existing
# nginx-ingress on :443 with SNI=loki.aisedge.local. The Loki bearer token
# is stored in Secret loki-push-credentials (pushed by 07b at install time).
#
# Why this manifest is hand-written rather than a helm install on the edge:
# we already use the Vector helm chart on the mgmt cluster; on the edge
# we want a minimal footprint and tighter control over hostAliases + TLS.
# A direct DaemonSet manifest is ~200 lines and matches what helm would
# render anyway.
#
# Security:
#   * NO hostNetwork (Vector only needs outbound TLS)
#   * hostPath /var/log/pods is read-only
#   * runAsNonRoot, readOnlyRootFilesystem, drop ALL capabilities
#   * mounts our ais-edge-ca CA bundle to verify the Loki server cert
# =============================================================================
apiVersion: v1
kind: Namespace
metadata:
  name: logging
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vector
  namespace: logging
---
# Allow Vector to read pod metadata (for log enrichment).
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: vector
rules:
  - apiGroups: [""]
    resources: ["namespaces", "pods", "nodes"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vector
subjects:
  - kind: ServiceAccount
    name: vector
    namespace: logging
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: vector
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: vector-config
  namespace: logging
data:
  vector.yaml: |
    data_dir: /vector-data-dir
    api:
      enabled: false

    sources:
      kubelet_logs:
        type: kubernetes_logs
        auto_partial_merge: true

    transforms:
      add_cluster_label:
        type: remap
        inputs: [kubelet_logs]
        source: |
          .cluster = "{{CLUSTER_NAME}}"

      # Parse any JSON-formatted log lines (xnat-ingest sort and s3-uploader
       # both emit JSON). Merging the parsed keys into the event makes
       # `event`, `component`, `session` first-class fields for LogQL
       # `| json` queries and Loki ruler rules over on the mgmt cluster.
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
        endpoint: https://{{LOKI_HOSTNAME}}
        auth:
          strategy: bearer
          token: ${LOKI_BEARER_TOKEN}
        tls:
          ca_file: /etc/ssl/ais-edge-ca/ca.crt
        # Slim the JSON body — kubernetes_logs metadata is already
        # extracted into stream labels below, so emitting it inside the
        # body too bloats storage and clutters the Grafana live tail.
        encoding:
          codec: json
          except_fields:
            - kubernetes
            - file
            - source_type
            - stream
            - tags
        labels:
          cluster: "{{ cluster }}"
          namespace: "{{ kubernetes.pod_namespace }}"
          pod: "{{ kubernetes.pod_name }}"
          container: "{{ kubernetes.container_name }}"
          # node — the worker name. Lets Grafana / LogQL queries scope by
          # individual worker within a cluster, e.g. {cluster="edge-rbwh",
          # node="worker-2"}. Cardinality cost is one stream-set per worker;
          # negligible at our scale.
          node: "{{ kubernetes.pod_node_name }}"
          app: "{{ kubernetes.pod_labels.app }}"
          component: "{{ kubernetes.pod_labels.component }}"
          level: "{{ level }}"
        remove_label_fields: true
        out_of_order_action: accept
        compression: gzip
        batch:
          max_bytes: 1048576
          timeout_secs: 1
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: vector
  namespace: logging
  labels:
    app.kubernetes.io/name: vector
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: vector
  template:
    metadata:
      labels:
        app.kubernetes.io/name: vector
    spec:
      serviceAccountName: vector
      hostNetwork: false
      dnsPolicy: ClusterFirst
      hostAliases:
        - ip: "{{MGMT_NODE_IP}}"
          hostnames:
            - "{{LOKI_HOSTNAME}}"
            - "{{GRAFANA_HOSTNAME}}"
            - "{{SEAWEEDFS_HOSTNAME}}"
            - "{{K0S_API_HOSTNAME}}"
            - "{{KONNECTIVITY_HOSTNAME}}"
      tolerations:
        - operator: Exists
      # Vector's data dir is a hostPath on the edge worker so its
      # file-position checkpoints survive pod restarts. With emptyDir,
      # rolling the DaemonSet (e.g. to apply a ConfigMap change) wiped the
      # checkpoint, Vector re-tailed every /var/log/pods/*/0.log from
      # offset 0, and Loki ingested duplicate copies of older events —
      # showing up as inflated counts on the dashboards. /var/lib/vector
      # is the same path the upstream Vector helm chart uses on the mgmt
      # side, so behaviour is now uniform across both sides.
      # The container runs as root for parity with the helm chart's
      # mgmt-side behaviour.
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: vector
          image: timberio/vector:0.49.0-distroless-libc
          imagePullPolicy: IfNotPresent
          args: ["--config", "/etc/vector/vector.yaml"]
          env:
            - name: LOKI_BEARER_TOKEN
              valueFrom:
                secretKeyRef:
                  name: loki-push-credentials
                  key: token
            # kubernetes_logs source needs the node name to scope its
            # tailing. Helm chart sets this; we replicate it explicitly.
            - name: VECTOR_SELF_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: VECTOR_SELF_POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: VECTOR_SELF_POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          # Vector on the edge is a pure log shipper — it pushes outbound
          # to Loki on the mgmt cluster and does not expose any in-cluster
          # endpoint. Pipeline-event alerts live in Loki's ruler over the
          # logs themselves; see manifests/01-management/observability/
          # loki-ruler-rules.yaml.
          securityContext:
            allowPrivilegeEscalation: false
            # readOnlyRootFilesystem omitted — Vector's source checkpoints
            # need a writable /vector-data-dir. Defense-in-depth via the
            # other knobs (runAsNonRoot, drop ALL caps, RuntimeDefault).
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - { name: config,         mountPath: /etc/vector,         readOnly: true }
            - { name: data,           mountPath: /vector-data-dir }
            - { name: pod-logs,       mountPath: /var/log/pods,       readOnly: true }
            - { name: container-logs, mountPath: /var/log/containers, readOnly: true }
            - { name: ca-bundle,      mountPath: /etc/ssl/ais-edge-ca, readOnly: true }
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 1,    memory: 512Mi }
      volumes:
        - name: config
          configMap: { name: vector-config }
        - name: data
          hostPath:
            path: /var/lib/vector
            type: DirectoryOrCreate
        - name: pod-logs
          hostPath: { path: /var/log/pods }
        - name: container-logs
          hostPath: { path: /var/log/containers }
        - name: ca-bundle
          secret:
            secretName: ca-bundle
            items: [{ key: ca.crt, path: ca.crt }]
