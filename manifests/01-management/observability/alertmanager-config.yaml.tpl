# =============================================================================
# Alertmanager configuration  —  email primary, optional Slack secondary
# =============================================================================
# Applied as a Secret named alertmanager-aisedge-config in the
# observability namespace. The kube-prometheus-stack chart's
# alertmanagerSpec.configSecret refers to this name.
#
# Routing tree:
#   severity=critical  →  email + slack (if Slack configured)
#   severity=warning   →  email only
#   severity=info      →  slack only (or dropped if no Slack)
#
# All values come from config/management.env so site IT can change the
# inbox or webhook without touching YAML.
# =============================================================================
global:
  resolve_timeout: 5m
  smtp_smarthost: "{{ALERT_SMTP_HOST}}:{{ALERT_SMTP_PORT}}"
  smtp_from: "{{ALERT_EMAIL_FROM}}"
  smtp_auth_username: "{{ALERT_SMTP_USERNAME}}"
  smtp_auth_password: "{{ALERT_SMTP_PASSWORD}}"
  smtp_require_tls: {{ALERT_SMTP_REQUIRE_TLS}}

route:
  group_by: ["alertname", "cluster"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
  receiver: email-primary       # default — every alert hits the inbox
  routes:
    # Per-alert override: XNATUploadSuccess is severity=info (so the
    # default routing tree below would send it to Slack), but operators
    # want an email confirmation for every successful XNAT push for
    # audit / peace-of-mind reasons. Putting this matcher first
    # overrides the `severity=info → slack-only` route below.
    - matchers:
        - alertname = "XNATUploadSuccess"
      receiver: email-primary
      continue: false
    - matchers:
        - severity = "info"
      receiver: slack-only
      continue: false
    - matchers:
        - severity = "critical"
      receiver: email-and-slack
      continue: false

receivers:
  - name: email-primary
    email_configs:
      - to: "{{ALERT_EMAIL_TO}}"
        send_resolved: true

  - name: email-and-slack
    email_configs:
      - to: "{{ALERT_EMAIL_TO}}"
        send_resolved: true
    slack_configs:
      - api_url: "{{ALERT_SLACK_WEBHOOK}}"
        channel: "#ais-edge-alerts"
        send_resolved: true
        title: "{{ .CommonLabels.alertname }} — {{ .CommonLabels.severity }}"
        text: |
          {{ range .Alerts }}
          *{{ .Labels.alertname }}* — `{{ .Labels.cluster }}`
          {{ .Annotations.summary }}
          {{ .Annotations.description }}
          {{ end }}

  - name: slack-only
    slack_configs:
      - api_url: "{{ALERT_SLACK_WEBHOOK}}"
        channel: "#ais-edge-alerts"
        send_resolved: false

inhibit_rules:
  # If a node is down, suppress per-pod alerts on that node.
  - source_matchers:
      - alertname = "ManagementClusterDown"
    target_matchers:
      - severity =~ "warning|info"
    equal: ["cluster"]

templates: []
