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
# "(or dropped if no Slack)" IS A BUG, NOT A DESIGN, and it is fixed in the
# chart rather than here. On a site with no webhook this file routes every
# severity=info alert — CARotationDue among them — to a receiver that cannot
# deliver, so the alert is destroyed and the only trace is an error line in
# the Alertmanager pod log. charts/mgmt/files/alertmanager-config.yaml drops
# the Slack receivers entirely when no webhook Secret is configured and sends
# info to email instead; see docs/components/alertmanager.md.
#
# It is deliberately NOT patched here. This tree is the imperative installer's
# copy, rendered by scripts/02d-install-observability.sh with a different
# substitution mechanism and exercised by none of the CI in scripts/ci-*.sh. A
# second, untested implementation of the fix is worth less than an accurate
# pointer to the one that is tested. Deploy the chart.
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
    # Quarantine alerts: send the FIRING mail, but never a "[RESOLVED]" one.
    # The expression only measures "no new rejections in the last 5 minutes",
    # which is NOT the same as the problem being fixed — the rejected studies
    # are still sitting in <FacilityBackupDir>/__unmapped_aet__/<AET>/ until
    # an operator maps the AET and re-sends them. A "Resolved" mail here
    # would be false reassurance. (Resolving on "quarantine directory is
    # empty" would need a component that reports that state; Alertmanager and
    # the Loki ruler only ever see logs, never the filesystem.)
    - matchers:
        - alertname = "DICOMRejectedUnmappedAET"
      receiver: email-no-resolved
      continue: false
    - matchers:
        - alertname = "XNATUploadSuccess"
      receiver: email-upload-success
      # Group by session so each session that lands in XNAT is its own
      # notification group: a new session emails straight away, while the
      # same session — which the uploader keeps re-logging every --loop pass
      # while it remains in the S3 staging prefix — is held off by
      # repeat_interval instead of emailing every cycle.
      group_by: ["alertname", "cluster", "session"]
      group_wait: 10s          # land in the inbox promptly after the upload
      group_interval: 5m
      repeat_interval: 24h     # one email per session, not one per loop
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

  # Upload-success is an EVENT ("this session landed in XNAT"), not a
  # condition that clears. send_resolved: false stops the pointless
  # "[RESOLVED]" follow-up ~5 min later (resolve_timeout) — the operator
  # only wants the single "upload completed" mail.
  # Firing-only email. For alerts whose "resolved" state would be misleading
  # (see the DICOMRejectedUnmappedAET route above).
  - name: email-no-resolved
    email_configs:
      - to: "{{ALERT_EMAIL_TO}}"
        send_resolved: false

  - name: email-upload-success
    email_configs:
      - to: "{{ALERT_EMAIL_TO}}"
        send_resolved: false
        headers:
          Subject: 'AIS-Edge: XNAT upload completed — {{ .CommonLabels.session }}'

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
