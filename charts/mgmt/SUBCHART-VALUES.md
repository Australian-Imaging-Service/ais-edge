# Subchart values required by `templates/observability.yaml`

Written by the observability port. **I did not edit `values.yaml` — the values owner
should paste the blocks below in.** Everything here is a straight port of

* `manifests/01-management/observability/kube-prometheus-stack-values.yaml.tpl`
* `manifests/01-management/observability/loki-values.yaml.tpl`
* `manifests/01-management/observability/vector-mgmt-values.yaml.tpl`

with the `{{PLACEHOLDER}}` substitutions resolved and the hardcoded
`release: kube-prometheus-stack` landmine removed.

---

## 0. The constraint that shapes all of this

**Helm does not template `values.yaml`.** A subchart value cannot say
`{{ .Release.Name }}-something` and expect it to resolve — *unless the subchart itself
runs `tpl` over that particular field*. Three fields below rely on subchart-side `tpl`
and are marked **[tpl]**; everything else must be a plain literal that is kept in step
with a parent value by hand.

`templates/observability.yaml` therefore renders a **render-time consistency check** for
every coupling it can see. Each check is skipped while the corresponding block is absent,
so nothing fails until these values are actually added. Get one wrong and the install
stops with a message naming both sides — which is the point: every one of these
mismatches is otherwise completely silent.

### MUST-MATCH table

| Subchart value | must equal | consequence if it drifts |
|---|---|---|
| `kube-prometheus-stack.alertmanager.alertmanagerSpec.configSecret` | literal `alertmanager-aisedge-config` | Alertmanager runs the chart's default config; every alert routed to a null receiver |
| `kube-prometheus-stack.alertmanager.alertmanagerSpec.secrets` | contains `observability.alerting.smtpSecretRef` (and `slackWebhookSecretRef` if set) | `smtp_auth_password_file` points at a path that does not exist; every mail fails at send time |
| `kube-prometheus-stack.grafana.admin.existingSecret` | `observability.grafana.adminSecretRef` | Grafana boots with a random generated password nobody holds |
| `kube-prometheus-stack.prometheus.prometheusSpec.*Selector` | `observability.prometheusReleaseLabel` | **the landmine**: Prometheus loads none of our PrometheusRules or ServiceMonitors, silently |
| `loki.singleBinary.extraVolumes[].configMap.name` | literal `loki-ruler-rules` | Loki pod cannot schedule (missing volume) |
| `loki.loki.storage.bucketNames.*` | `seaweedfs.buckets.logs` | Loki writes chunks into a bucket that does not exist |
| `loki.loki.limits_config.retention_period` | `dataPolicy.telemetry.loki.retain` | the site has two different answers to "how long are logs kept" |
| `kube-prometheus-stack.prometheus.prometheusSpec.retention` | `dataPolicy.telemetry.prometheus.retain` | same, for metrics |
| `vector.customConfig.transforms.add_cluster_label.source` | `clusterLabel` | mgmt logs land under the wrong `cluster` label; dashboards and per-site rules miss them |

---

## 1. `kube-prometheus-stack:`

```yaml
kube-prometheus-stack:
  # We ship our own alerts from files/prometheus-rules/, version-controlled
  # with the code that emits the events they alert on.
  defaultRules:
    create: false

  prometheus:
    prometheusSpec:
      # MUST MATCH dataPolicy.telemetry.prometheus.retain.
      retention: 15d
      retentionSize: ""            # disk-bound by the PVC below
      scrapeInterval: 30s
      evaluationInterval: 30s

      # DELETED ON PURPOSE — do not re-add:
      #   ruleSelector:          {matchLabels: {release: kube-prometheus-stack}}
      #   serviceMonitorSelector:{matchLabels: {release: kube-prometheus-stack}}
      #   podMonitorSelector:    {matchLabels: {release: kube-prometheus-stack}}
      # Those literals were correct only because the installer's release was
      # named kube-prometheus-stack. As a subchart the release is ours.
      # Leaving the selectors empty keeps *SelectorNilUsesHelmValues at its
      # default (true), which makes kube-prometheus-stack template
      # `release: <parent release name>` into the selectors — exactly what
      # mgmt.prometheusReleaseLabel defaults to, so the two track each other
      # automatically with no literal to forget.
      #
      # If (and only if) kube-prometheus-stack is installed as a SEPARATE
      # release, set observability.prometheusReleaseLabel to that release's
      # name AND set the three *SelectorNilUsesHelmValues to false with
      # explicit matching selectors. templates/observability.yaml refuses to
      # render if you do one without the other.
      ruleNamespaceSelector: {}          # all namespaces
      serviceMonitorNamespaceSelector: {}
      podMonitorNamespaceSelector: {}

      storageSpec:
        volumeClaimTemplate:
          metadata:
            annotations:
              # Holds the metrics history. `helm uninstall` must not take it.
              helm.sh/resource-policy: keep
          spec:
            accessModes: ["ReadWriteOnce"]
            storageClassName: local-path       # see "missing values keys" below
            resources:
              requests:
                storage: 20Gi

      resources:
        requests: {cpu: 250m, memory: 1Gi}
        limits:   {cpu: 2,    memory: 4Gi}

  alertmanager:
    enabled: true
    alertmanagerSpec:
      # MUST MATCH the literal in templates/observability.yaml.
      configSecret: alertmanager-aisedge-config
      # Mounted at /etc/alertmanager/secrets/<name>/<key>. This is how the
      # SMTP password and Slack webhook reach Alertmanager WITHOUT ever being
      # templated into a manifest — the config uses smtp_auth_password_file /
      # api_url_file. MUST CONTAIN observability.alerting.smtpSecretRef, plus
      # slackWebhookSecretRef when Slack is configured.
      secrets:
        - alertmanager-smtp
      storage:
        volumeClaimTemplate:
          metadata:
            annotations:
              helm.sh/resource-policy: keep    # silence/notification state
          spec:
            accessModes: ["ReadWriteOnce"]
            storageClassName: local-path
            resources:
              requests:
                storage: 2Gi
      resources:
        requests: {cpu: 50m,  memory: 128Mi}
        limits:   {cpu: 500m, memory: 512Mi}

  grafana:
    enabled: true
    admin:
      # MUST MATCH observability.grafana.adminSecretRef.
      existingSecret: grafana-admin-credentials
      userKey: admin-user
      passwordKey: admin-password
    defaultDashboardsEnabled: true
    service:
      type: ClusterIP                  # published through nginx-ingress only
    persistence:
      enabled: true
      type: pvc
      storageClassName: local-path
      accessModes: ["ReadWriteOnce"]
      size: 5Gi
      annotations:
        helm.sh/resource-policy: keep

    # The PVC is RWO, so a rolling update deadlocks: the new pod cannot mount
    # the volume while the old pod holds it, and the old pod will not
    # terminate until the new one is Ready.
    deploymentStrategy:
      type: Recreate

    # Once Grafana has run, subdirs like pdf/ are mode 700 owned by 472:472.
    # The init container runs as root with drop:ALL, add:[CHOWN] — without
    # CAP_DAC_OVERRIDE it cannot traverse them and `chown -R` fails. Ownership
    # is already correct; fsGroup handles fresh PVCs.
    initChownData:
      enabled: false

    # [tpl] kube-prometheus-stack renders additionalDataSources through `tpl`
    # (its values.yaml documents this), so these Go templates DO resolve — and
    # they must, because the Loki Service name contains the release name.
    # VERIFY BEFORE INSTALL:
    #   helm template <rel> charts/mgmt | grep -A2 'name: Loki' | grep url
    # If the url comes out containing a literal `{{`, this chart version does
    # not tpl the field; replace it with the literal service name instead.
    deleteDatasources:
      # Grafana's provisioner addresses datasources by UID. A previous install
      # may have left a `Loki` row with a generated UID in grafana.db on the
      # PVC; re-provisioning the same name with an explicit UID then fails
      # with "data source not found". Deleting by name first is a no-op on a
      # fresh DB.
      - name: Loki
        orgId: 1
    additionalDataSources:
      - name: Loki
        uid: loki           # dashboards/*.json reference {"type":"loki","uid":"loki"}
        type: loki
        access: proxy
        url: http://{{ .Release.Name }}-loki.{{ .Release.Namespace }}.svc.cluster.local:3100
        isDefault: false
        jsonData:
          maxLines: 5000

    sidecar:
      dashboards:
        enabled: true
        label: grafana_dashboard
        labelValue: "1"
        # searchNamespace DELETED. It was `observability`, a literal that
        # cannot follow .Release.Namespace. The default — the namespace
        # Grafana itself runs in — is already the release namespace, which is
        # where templates/observability.yaml creates the dashboard ConfigMaps.
        folderAnnotation: grafana_dashboard_folder
        provider:
          foldersFromFilesStructure: true
      datasources:
        enabled: true

    resources:
      requests: {cpu: 100m, memory: 256Mi}
      limits:   {cpu: 1,    memory: 1Gi}

  # Host metrics: off on mgmt for symmetry with the edges (no hostNetwork).
  # cAdvisor in the kubelet still provides pod-level metrics.
  prometheus-node-exporter:
    enabled: false
  nodeExporter:
    enabled: false

  # Required by the SeaweedFSDown / EdgeWorkerDisconnected / EdgePodCrashLoop
  # rules in files/prometheus-rules/.
  kubeStateMetrics:
    enabled: true
  kube-state-metrics:
    resources:
      requests: {cpu: 50m,  memory: 128Mi}
      limits:   {cpu: 200m, memory: 256Mi}

  # k0s embeds or does not expose these the way the upstream chart assumes.
  kubeApiServer:         {enabled: true}
  kubeControllerManager: {enabled: false}
  kubeScheduler:         {enabled: false}
  kubeProxy:             {enabled: false}
  kubeEtcd:              {enabled: false}   # k0smotron etcd is per child cluster
  kubelet:               {enabled: true}
  coreDns:               {enabled: true}
```

---

## 2. `loki:`

```yaml
loki:
  deploymentMode: SingleBinary

  loki:
    auth_enabled: false          # gated at the Ingress instead

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
      # MUST MATCH seaweedfs.buckets.logs.
      bucketNames:
        chunks: logs-bucket
        ruler:  logs-bucket
        admin:  logs-bucket
      s3:
        # [tpl] the loki chart renders its config through `tpl`, so this
        # resolves. It MUST equal the mgmt.s3InternalEndpoint helper
        # (http://<fullname>-seaweedfs.<ns>.svc:8333). Plain http on purpose:
        # it never leaves the node.
        endpoint: http://{{ .Release.Name }}-seaweedfs.{{ .Release.Namespace }}.svc.cluster.local:8333
        region: us-east-1        # ignored by SeaweedFS, required by the SDK
        s3ForcePathStyle: true
        insecure: true
        # NO CREDENTIALS HERE. `${...}` is expanded by Loki itself at startup
        # (see -config.expand-env below), not by Helm, so the key never
        # appears in a rendered manifest or in git.
        accessKeyId: ${LOKI_S3_ACCESS_KEY}
        secretAccessKey: ${LOKI_S3_SECRET_KEY}

    limits_config:
      # MUST MATCH dataPolicy.telemetry.loki.retain.
      retention_period: 30d
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

    # The ruler evaluates the LogQL alert rules in files/loki-ruler-rules.yaml
    # and pushes firing alerts to the kube-prometheus-stack Alertmanager. It
    # runs here rather than in Prometheus because mgmt Prometheus cannot scrape
    # edge pods across the one-way konnectivity tunnel, and because the source
    # of truth for these alerts is the JSON event, not a derived metric.
    rulerConfig:
      storage:
        type: local
        local:
          directory: /etc/loki/rules
      rule_path: /var/loki/rules-runtime
      # [tpl] kube-prometheus-stack names this Service
      # <release>-kube-prometheus-stack-alertmanager. If KPS is installed as a
      # separate release, hardcode that release's Service name instead.
      alertmanager_url: http://{{ .Release.Name }}-kube-prometheus-stack-alertmanager.{{ .Release.Namespace }}.svc.cluster.local:9093
      enable_alertmanager_v2: true
      enable_api: true
      ring:
        kvstore:
          store: inmemory

  singleBinary:
    replicas: 1
    resources:
      requests: {cpu: 200m, memory: 512Mi}
      limits:   {cpu: 2,    memory: 2Gi}
    persistence:
      enabled: true
      # observability.loki.persistenceSize (20Gi), NOT the 10Gi the shell
      # installer used — the values contract is the authority.
      size: 20Gi
      storageClass: local-path
      annotations:
        helm.sh/resource-policy: keep
    # Turns the S3 key into env vars WITHOUT putting it in values: the Secret
    # named here is observability.loki.s3SecretRef, and its keys are mapped to
    # the env var names the config above interpolates.
    extraArgs:
      - -config.expand-env=true
    extraEnv:
      - name: LOKI_S3_ACCESS_KEY
        valueFrom:
          secretKeyRef: {name: loki-s3-credentials, key: access-key}
      - name: LOKI_S3_SECRET_KEY
        valueFrom:
          secretKeyRef: {name: loki-s3-credentials, key: secret-key}
    # MUST MATCH the ConfigMap name in templates/observability.yaml. `fake` is
    # Loki's tenant ID when auth_enabled is false; the ruler reads every YAML
    # file in that directory as a rule group.
    extraVolumes:
      - name: rules
        configMap:
          name: loki-ruler-rules
    extraVolumeMounts:
      - name: rules
        mountPath: /etc/loki/rules/fake
        readOnly: true

  # Distributed-mode deployments off; we run SingleBinary.
  read:    {replicas: 0}
  write:   {replicas: 0}
  backend: {replicas: 0}

  minio:        {enabled: false}   # chunks live in SeaweedFS
  chunksCache:  {enabled: false}
  resultsCache: {enabled: false}
  gateway:      {enabled: false}   # exposed through nginx-ingress directly
  service:      {type: ClusterIP}

  monitoring:
    serviceMonitor:
      enabled: true
      # NOT tpl'd by the loki chart — write the RELEASE NAME literally, the
      # same string mgmt.prometheusReleaseLabel resolves to. Getting this
      # wrong costs only Loki's own self-metrics; no alert rule depends on
      # them, so it fails quietly rather than dangerously.
      labels:
        release: ais-mgmt          # <- the release name
    selfMonitoring: {enabled: false}
    lokiCanary:     {enabled: false}

  test:
    enabled: false
```

---

## 3. `vector:`

```yaml
vector:
  role: Agent                      # DaemonSet, one per node
  hostNetwork: false               # Vector only makes outbound connections
  dnsPolicy: ClusterFirst

  # Vector's checkpoint dir is a root-owned hostPath, so the container stays
  # root; defence in depth is drop-ALL + seccomp. The only host paths touched
  # are /var/lib/vector and /var/log/pods (read-only).
  podSecurityContext:
    seccompProfile: {type: RuntimeDefault}
  securityContext:
    allowPrivilegeEscalation: false
    capabilities: {drop: ["ALL"]}

  tolerations:
    - operator: Exists             # ship logs from tainted nodes too

  resources:
    requests: {cpu: 100m, memory: 128Mi}
    limits:   {cpu: 1,    memory: 512Mi}

  dataDir: /vector-data-dir

  extraVolumes:
    - name: pod-logs
      hostPath: {path: /var/log/pods}
    - name: containerd-logs
      hostPath: {path: /var/log/containers}
  extraVolumeMounts:
    - {name: pod-logs,        mountPath: /var/log/pods,       readOnly: true}
    - {name: containerd-logs, mountPath: /var/log/containers, readOnly: true}

  customConfig:
    data_dir: /vector-data-dir
    api: {enabled: false}

    sources:
      kubelet_logs:
        type: kubernetes_logs
        auto_partial_merge: true

    transforms:
      # MUST MATCH clusterLabel. Written as a literal because values.yaml is
      # not templated.
      add_cluster_label:
        type: remap
        inputs: [kubelet_logs]
        source: |
          .cluster = "mgmt"

      # Promotes `event`, `component`, `session` etc. to first-class fields so
      # the Loki ruler's `| json | event="upload_completed"` works.
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
        # Same-cluster push, so plain http and no bearer token — unlike the
        # edges, which come in over the Ingress.
        # LITERAL: <release>-loki.<release namespace>. Not tpl'd (see the
        # warning below), so it has to be edited per site. Getting it wrong
        # means mgmt's own logs never reach Loki — the edges keep working, so
        # the dashboards look alive and only the `cluster="mgmt"` streams go
        # missing.
        endpoint: http://ais-mgmt-loki.observability.svc.cluster.local:3100
        # Vector >=0.49 requires label templates to have a literal prefix
        # ("template confinement") unless this is set. Symptom without it:
        # sink build error "template references event fields but has no
        # literal string prefix".
        dangerously_allow_unconfined_template_resolution: true
        encoding:
          codec: json
          # kubernetes_logs attaches a fat metadata block to every event. It
          # is already promoted to stream labels below; re-emitting it inside
          # each line bloats storage and makes Grafana's live tail unreadable.
          # The sink still sees the full event, so the label templates resolve.
          except_fields: [kubernetes, file, source_type, stream, tags]
        # >>> READ THIS BEFORE PASTING <<<
        # These are VECTOR field templates, not Helm. Write them exactly as
        # shown, with NO backtick escaping. The source manifest
        # (vector-mgmt-values.yaml.tpl) has them written as
        # `{{` + `{{ cluster }}` + `}}`, which is Helm escape syntax that the
        # shell installer's render() does not understand — see "defects" in
        # the port report.
        # VERIFY BEFORE INSTALL, because an eaten template is silent — every
        # mgmt log line loses its labels and the ruler rules stop matching:
        #   helm template <rel> charts/mgmt | grep -A3 'labels:' | grep cluster
        # must print `cluster: "{{ cluster }}"`. If it prints `cluster: ""`,
        # this vector chart version runs `tpl` over customConfig; in that case
        # wrap each value as "{{`{{ cluster }}`}}".
        labels:
          cluster:   "{{ cluster }}"
          namespace: "{{ kubernetes.pod_namespace }}"
          pod:       "{{ kubernetes.pod_name }}"
          container: "{{ kubernetes.container_name }}"
          node:      "{{ kubernetes.pod_node_name }}"
          app:       "{{ kubernetes.pod_labels.app }}"
          component: "{{ kubernetes.pod_labels.component }}"
          level:     "{{ level }}"
        remove_label_fields: true
        out_of_order_action: accept
        compression: gzip
        batch:
          max_bytes: 1048576
          timeout_secs: 1

  # mgmt Vector only pushes out; it exposes nothing in-cluster. The chart's
  # serviceMonitor knob is silently broken anyway.
  service:       {enabled: false}
  serviceMonitor: {enabled: false}
```

`namespace`/`cluster`/`app`/`component` are the labels every Loki ruler rule selects on.
Renaming or dropping one disables the matching alerts with no error anywhere.

---

## 4. Values keys `observability.yaml` needed and could not find

None of these were invented — the templates work without them, with the fallback noted.

| Wanted key | Used for | Fallback in place today |
|---|---|---|
| `observability.alerting.smtpUsername` | `smtp_auth_username` in the Alertmanager config. Alertmanager has **no** `smtp_auth_username_file`, so unlike the password it cannot come from the mounted Secret; it has to be a plain value. | Substituted as `""` (no SMTP auth), which is what an unset `ALERT_SMTP_USERNAME` did in the shell installer. **A relay that requires auth will reject every mail until this key exists.** |
| `observability.storageClassName` | the four observability PVCs (Prometheus 20Gi, Alertmanager 2Gi, Grafana 5Gi, Loki 20Gi) | the literal `local-path` in the blocks above, as in the source. Note `k0smotron.persistence.storageClassName` exists but is scoped to control planes. |
| `observability.prometheus.persistenceSize`, `.grafana.persistenceSize`, `.alerting.persistenceSize` | the same PVCs — only Loki has `observability.loki.persistenceSize` | literals above |
| `observability.vector.image` / `.resources` | the mgmt Vector DaemonSet. `charts/edge` has `observability.vector.*`; the mgmt side has nothing, so the subchart defaults are used | chart defaults + the `resources` block above |
| `observability.grafana.ingress.proxyBodySize`, `observability.loki.ingress.proxyBodySize` | the two Ingress annotations | literals `16m` / `50m` in `templates/observability.yaml`, as in the source. `ingressNginx.proxyBodySize` (50g) is the SeaweedFS multipart setting and is far too large for these two. |
