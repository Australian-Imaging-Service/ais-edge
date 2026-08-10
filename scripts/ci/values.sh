#!/usr/bin/env bash
# =============================================================================
# The values matrix — the single definition of every case CI renders.
# =============================================================================
# Sourced by scripts/ci/render.sh and scripts/ci/negative.sh. Running it
# directly just writes the values files and lists the cases, which is useful
# for reproducing one case by hand:
#
#   scripts/ci/values.sh
#   helm template mgmt charts/mgmt -f $CI_VALUES_DIR/mgmt-base.yaml \
#                                  -f $CI_VALUES_DIR/mgmt-two-edges.yaml
#
# WHY THE VALUES LIVE HERE AND NOT IN charts/*/ci-values.yaml
# A values file next to the chart looks like a supported configuration and
# gets copied into a site. These are test fixtures; they belong to the test.
#
# NOTHING IN HERE IS A CREDENTIAL. Every case references Secrets by name only,
# exactly as the charts require. If a future case appears to need a password,
# the chart has a bug, not the fixture.
# =============================================================================
set -euo pipefail

# shellcheck source=scripts/ci/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

V="$CI_VALUES_DIR"
mkdir -p "$V"

# =============================================================================
# Base values — the minimum each chart needs to render at all.
# =============================================================================
# These are NOT "chart defaults": both charts deliberately refuse to render
# with several keys unset (domain, clusterLabel, the S3 bucket, the deid
# policy acknowledgement), because a default for any of them would be a wrong
# answer that installs cleanly. The base file supplies exactly those, and
# nothing else, so `<chart>-defaults` really is the shipped configuration plus
# the operator's mandatory answers.

cat >"$V/mgmt-base.yaml" <<'EOF'
domain:
  internal: ci.198-51-100-10.nip.io
  mgmtNodeIP: "198.51.100.10"
observability:
  alerting:
    emailFrom: ais-edge-ci@example.invalid
    emailTo: ops@example.invalid
    smtpHost: smtp.example.invalid
edges:
  # exposure: nodePort with EXPLICIT ports, which is what the chart requires —
  # the ports are deliberately not derived from list position.
  - name: edge-alpha
    nodeIP: 198.51.100.21
    s3SecretRef: edge-alpha-s3
    exposure: nodePort
    apiNodePort: 30443
    konnectivityNodePort: 30132
EOF

cat >"$V/edge-base.yaml" <<'EOF'
clusterLabel: edge-alpha
hostAliases:
  enabled: true
  mgmtNodeIP: "198.51.100.10"
  hostnames: ["seaweedfs.ci.198-51-100-10.nip.io", "loki.ci.198-51-100-10.nip.io"]
upload:
  mode: s3
  s3:
    endpoint: "https://seaweedfs.ci.198-51-100-10.nip.io"
    bucket: ingest-edge-alpha
    caBundleSecret: ca-bundle
orthanc:
  deid:
    enabled: true
    policyReviewed: true
    aetMap:
      SIEMENS_3T: {project: CI_RESEARCH}
    profile:
      DeidMode: "Basic"
      Force: true
      RemovePrivateTags: true
      Keep: ["StudyInstanceUID", "SeriesInstanceUID"]
      Replace:
        PatientName: "ANON"
EOF

# =============================================================================
# POSITIVE overlays — combinations that must RENDER.
# =============================================================================

# -- mgmt ---------------------------------------------------------------------

# A second site. Every per-edge object (Cluster, S3 identity, bucket, uploader
# Deployment, reclaimer CronJob, Ingress host) is ranged from this list, so one
# entry never exercises the naming that two entries collide on.
cat >"$V/mgmt-two-edges.yaml" <<'EOF'
edges:
  - name: edge-alpha
    nodeIP: 198.51.100.21
    s3SecretRef: edge-alpha-s3
    exposure: nodePort
    apiNodePort: 30443
    konnectivityNodePort: 30132
  - name: edge-beta
    nodeIP: 198.51.100.22
    s3SecretRef: edge-beta-s3
    exposure: nodePort
    apiNodePort: 30444
    konnectivityNodePort: 30133
EOF

# The other exposure mode: ClusterIP behind the ssl-passthrough Ingress, no
# cluster-wide port to track. Both modes have to render, because the chart
# supports a fleet with one site on each during a migration.
cat >"$V/mgmt-sni-exposure.yaml" <<'EOF'
edges:
  - name: edge-alpha
    nodeIP: 198.51.100.21
    s3SecretRef: edge-alpha-s3
    exposure: sni
  - name: edge-beta
    nodeIP: 198.51.100.22
    s3SecretRef: edge-beta-s3
    exposure: nodePort
    apiNodePort: 30444
    konnectivityNodePort: 30133
EOF

cat >"$V/mgmt-observability-off.yaml" <<'EOF'
observability:
  enabled: false
EOF

# dataPolicy on and dryRun off: the reclaimer's real code path.
cat >"$V/mgmt-datapolicy-on.yaml" <<'EOF'
dataPolicy:
  enabled: true
  dryRun: false
EOF

# A management node with no SeaweedFS: Loki on a filesystem PVC, no uploader,
# no reclaimer. This is the tier-1 shape, and it is the case where the
# loki.storage / seaweedfs.enabled coupling has to hold.
cat >"$V/mgmt-no-seaweedfs.yaml" <<'EOF'
seaweedfs:
  enabled: false
xnatUpload:
  enabled: false
observability:
  loki:
    storage: filesystem
dataPolicy:
  derived:
    s3Staged:
      reclaim: never
EOF

# The shared-bucket layout, kept only so sites can migrate one at a time.
cat >"$V/mgmt-shared-bucket.yaml" <<'EOF'
seaweedfs:
  perSiteBuckets: false
EOF

# Let's Encrypt staging with a DNS-01 solver. Exercises the ACME ClusterIssuer
# branch, which is otherwise never rendered.
cat >"$V/mgmt-letsencrypt.yaml" <<'EOF'
certManager:
  issuer: letsencrypt-staging
  acme:
    email: ci@example.invalid
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    dns01Solver:
      route53:
        region: ap-southeast-2
        accessKeyIDSecretRef: {name: route53-credentials, key: access-key-id}
        secretAccessKeySecretRef: {name: route53-credentials, key: secret-access-key}
EOF

# -- edge ---------------------------------------------------------------------

# Tier-1: no management plane, no S3, no CA plumbing.
cat >"$V/edge-upload-direct.yaml" <<'EOF'
upload:
  mode: direct
observability:
  enabled: false
EOF

cat >"$V/edge-observability-on.yaml" <<'EOF'
observability:
  enabled: true
  loki:
    endpoint: "https://loki.ci.198-51-100-10.nip.io"
    clientCertSecret: loki-push-client-tls
    caBundleSecret: ca-bundle
EOF

cat >"$V/edge-samba-on.yaml" <<'EOF'
samba:
  enabled: true
  existingSecret: samba-credentials
EOF

# fileDrop with reclaim left at 'never' — the only combination the chart
# permits, and the point of the guard the negative case below covers.
cat >"$V/edge-filedrop-on.yaml" <<'EOF'
ingest:
  fileDrop:
    enabled: true
EOF

cat >"$V/edge-datapolicy-on.yaml" <<'EOF'
dataPolicy:
  enabled: true
  dryRun: false
EOF

# De-identification off. Requires clearing toProcessLabel, because nothing
# applies that label with the hook disabled.
cat >"$V/edge-deid-off.yaml" <<'EOF'
orthanc:
  deid:
    enabled: false
ingest:
  orthancGroup:
    toProcessLabel: ""
EOF

cat >"$V/edge-cloud.yaml" <<'EOF'
topology: cloud
hostAliases:
  enabled: false
EOF

# Slack configured. The ONLY case that renders the Slack half of the
# Alertmanager config: slackWebhookSecretRef switches the severity=info and
# severity=critical routes onto the Slack receivers AND splices
# files/alertmanager-slack-receivers.yaml in. Without a case here that branch
# ships untested — which is how every info alert came to be routed at a
# webhook file no Secret ever provided.
#
# alertmanagerSpec.secrets has to be restated in full: the guard in
# templates/observability.yaml requires the webhook Secret to be mounted, and
# Helm REPLACES lists rather than merging them, so naming only the new one
# would drop alertmanager-smtp and trip the SMTP guard first.
cat >"$V/mgmt-slack.yaml" <<'EOF'
observability:
  alerting:
    slackWebhookSecretRef: alertmanager-slack
kube-prometheus-stack:
  alertmanager:
    alertmanagerSpec:
      secrets:
        - alertmanager-smtp
        - alertmanager-slack
EOF

# =============================================================================
# NEGATIVE overlays — each one injects exactly ONE defect.
# =============================================================================
# Each is applied on top of a base that is already in the positive matrix, so
# the only thing that can make the render fail is the injected defect. The
# expected-substring in the case table is what turns "it failed" into "it
# failed for the reason we claim", which is the difference between a test and
# a coincidence.
#
# `key: null` rather than `key: {}` where a map has to be CLEARED: Helm
# coalesces maps, so an empty map in an overlay leaves the base value intact
# and the case would silently pass for the wrong reason.

# -- mgmt ---------------------------------------------------------------------
printf 'domain:\n  internal: ""\n'                        >"$V/neg-mgmt-no-domain.yaml"
printf 'domain:\n  mgmtNodeIP: ""\n'                      >"$V/neg-mgmt-no-nodeip.yaml"

cat >"$V/neg-mgmt-duplicate-edges.yaml" <<'EOF'
edges:
  - name: edge-alpha
    s3SecretRef: edge-alpha-s3
    exposure: sni
  - name: edge-alpha
    s3SecretRef: edge-alpha-s3
    exposure: sni
EOF

cat >"$V/neg-mgmt-edge-no-name.yaml" <<'EOF'
edges:
  - nodeIP: 198.51.100.21
    s3SecretRef: edge-alpha-s3
    exposure: sni
EOF

cat >"$V/neg-mgmt-edge-no-s3secret.yaml" <<'EOF'
edges:
  - name: edge-alpha
    nodeIP: 198.51.100.21
    exposure: sni
EOF

# An edge name that is not a DNS-1123 label. The `.` is the point: the name is
# interpolated into the auth-tls-match-cn regex on the Loki push Ingress, where
# a metacharacter WIDENS what is accepted instead of erroring.
cat >"$V/neg-mgmt-edge-name-not-label.yaml" <<'EOF'
edges:
  - name: edge.alpha
    nodeIP: 198.51.100.21
    s3SecretRef: edge-alpha-s3
    exposure: sni
EOF

# ---- k0smotron exposure ------------------------------------------------------
# The bug these guard against: a NodePort derived from an edge's POSITION in
# the list moves to another site's number when the list is reordered, while
# helm.sh/resource-policy: keep leaves the old Service holding the old one.
cat >"$V/neg-mgmt-edge-no-nodeport.yaml" <<'EOF'
edges:
  - name: edge-alpha
    s3SecretRef: edge-alpha-s3
    exposure: nodePort
EOF

cat >"$V/neg-mgmt-nodeport-out-of-range.yaml" <<'EOF'
edges:
  - name: edge-alpha
    s3SecretRef: edge-alpha-s3
    exposure: nodePort
    apiNodePort: 8443
    konnectivityNodePort: 30132
EOF

cat >"$V/neg-mgmt-nodeport-collision.yaml" <<'EOF'
edges:
  - name: edge-alpha
    s3SecretRef: edge-alpha-s3
    exposure: nodePort
    apiNodePort: 30443
    konnectivityNodePort: 30132
  - name: edge-beta
    s3SecretRef: edge-beta-s3
    exposure: nodePort
    apiNodePort: 30443
    konnectivityNodePort: 30133
EOF

cat >"$V/neg-mgmt-bad-exposure.yaml" <<'EOF'
edges:
  - name: edge-alpha
    s3SecretRef: edge-alpha-s3
    exposure: loadBalancer
EOF

cat >"$V/neg-mgmt-sni-with-nodeport.yaml" <<'EOF'
edges:
  - name: edge-alpha
    s3SecretRef: edge-alpha-s3
    exposure: sni
    apiNodePort: 30443
EOF

# Two sites claiming one hostname: nginx routes by SNI, so one site's workers
# would reach the other site's control plane.
cat >"$V/neg-mgmt-duplicate-hostname.yaml" <<'EOF'
edges:
  - name: edge-alpha
    s3SecretRef: edge-alpha-s3
    exposure: sni
    apiHost: k0s.ci.198-51-100-10.nip.io
  - name: edge-beta
    s3SecretRef: edge-beta-s3
    exposure: sni
    apiHost: k0s.ci.198-51-100-10.nip.io
EOF

# The fleet-wide hostnames that produced the collision in the first place.
cat >"$V/neg-mgmt-fleetwide-hostnames.yaml" <<'EOF'
hostnames:
  k0sApi: k0s.ci.198-51-100-10.nip.io
EOF

# The vector subchart's customConfig is not templated by Helm, so the Loki
# address in it is a literal nothing keeps in step with the release. Both
# halves of the drift are covered: the namespace it names, and the Service.
cat >"$V/neg-mgmt-vector-loki-wrong-ns.yaml" <<'EOF'
vector:
  customConfig:
    sinks:
      loki:
        endpoint: http://mgmt-loki.observability.svc.cluster.local:3100
EOF

cat >"$V/neg-mgmt-vector-loki-wrong-svc.yaml" <<'EOF'
vector:
  customConfig:
    sinks:
      loki:
        endpoint: http://loki:3100
EOF

cat >"$V/neg-mgmt-loki-s3-no-seaweedfs.yaml" <<'EOF'
seaweedfs:
  enabled: false
observability:
  loki:
    storage: s3
EOF

printf 'observability:\n  alerting:\n    emailTo: ""\n'   >"$V/neg-mgmt-no-emailto.yaml"
printf 'observability:\n  alerting:\n    smtpHost: ""\n'  >"$V/neg-mgmt-no-smtphost.yaml"
printf 'xnatUpload:\n  xnatSecretRef: ""\n'               >"$V/neg-mgmt-no-xnatsecret.yaml"
printf 'k0smotron:\n  persistence:\n    type: emptyDir\n' >"$V/neg-mgmt-k0smotron-emptydir.yaml"

cat >"$V/neg-mgmt-le-no-email.yaml" <<'EOF'
certManager:
  issuer: letsencrypt-prod
  acme:
    email: ""
    dns01Solver:
      route53: {region: ap-southeast-2}
EOF

cat >"$V/neg-mgmt-le-no-dns01.yaml" <<'EOF'
certManager:
  issuer: letsencrypt-prod
  acme:
    email: ci@example.invalid
    dns01Solver: null
EOF

# Staging issuer still pointed at the production ACME directory: the case
# where "I am testing" spends the real rate limit.
cat >"$V/neg-mgmt-le-staging-prod-url.yaml" <<'EOF'
certManager:
  issuer: letsencrypt-staging
  acme:
    email: ci@example.invalid
    server: https://acme-v02.api.letsencrypt.org/directory
    dns01Solver:
      route53: {region: ap-southeast-2}
EOF

printf 'certManager:\n  ca:\n    commonName: "Some Other CA"\n' >"$V/neg-mgmt-ca-commonname.yaml"
printf 'certManager:\n  ca:\n    mode: bogus\n'                 >"$V/neg-mgmt-ca-bad-mode.yaml"
printf 'certManager:\n  clusterResourceNamespace: ""\n'         >"$V/neg-mgmt-no-cm-namespace.yaml"

cat >"$V/neg-mgmt-ca-intermediate-no-secret.yaml" <<'EOF'
certManager:
  ca:
    mode: intermediate
    intermediate:
      secretRef: ""
EOF

printf 'ingressNginx:\n  sslPassthrough: false\n'         >"$V/neg-mgmt-no-sslpassthrough.yaml"

cat >"$V/neg-mgmt-reclaimer-no-uploader.yaml" <<'EOF'
xnatUpload:
  enabled: false
EOF

cat >"$V/neg-mgmt-reclaimer-no-seaweedfs.yaml" <<'EOF'
seaweedfs:
  enabled: false
observability:
  loki:
    storage: filesystem
EOF

# The subchart-coupling guards. Each of these is a value that looks harmless
# on its own and silently disconnects a whole subsystem.
cat >"$V/neg-mgmt-am-configsecret.yaml" <<'EOF'
kube-prometheus-stack:
  alertmanager:
    alertmanagerSpec:
      configSecret: some-other-secret
EOF

cat >"$V/neg-mgmt-am-smtp-not-mounted.yaml" <<'EOF'
kube-prometheus-stack:
  alertmanager:
    alertmanagerSpec:
      secrets: null
EOF

cat >"$V/neg-mgmt-grafana-secret-mismatch.yaml" <<'EOF'
kube-prometheus-stack:
  grafana:
    admin:
      existingSecret: not-the-one-the-chart-creates
EOF

cat >"$V/neg-mgmt-loki-ruler-not-mounted.yaml" <<'EOF'
loki:
  singleBinary:
    extraVolumes: null
EOF

# The landmine from the imperative installer: a rule selector hardcoded to a
# release name that is no longer ours.
cat >"$V/neg-mgmt-prom-release-label.yaml" <<'EOF'
observability:
  prometheusReleaseLabel: kube-prometheus-stack
EOF

# ---- cert-sync ---------------------------------------------------------------
# cert-sync is the job that stops an edge from silently holding an expired
# certificate after cert-manager renews it on the management side. Its guards
# are therefore guards on the thing that makes the renewal visible at all, and
# two of them (the CA namespace and the tls.key refusal) are the difference
# between "syncs nothing forever" and "distributes the fleet CA private key".


# POSITIVE counterpart: Clusters managed outside the chart is a supported and
# correct configuration, and it is the one stream-2-ab-dev actually runs.
printf 'k0smotron:\n  enabled: false\n'                   >"$V/mgmt-k0smotron-external.yaml"
printf 'certSync:\n  secrets: null\n'                     >"$V/neg-mgmt-certsync-no-secrets.yaml"
printf 'certSync:\n  schedule: "@daily"\n'                >"$V/neg-mgmt-certsync-schedule-macro.yaml"
printf 'certSync:\n  schedule: "23 3 * * 1"\n'            >"$V/neg-mgmt-certsync-schedule-weekly.yaml"

# An entry with no destination.namespace. There is deliberately no default, so
# this must be an error rather than a Secret written where nothing reads it.
cat >"$V/neg-mgmt-certsync-no-destination.yaml" <<'EOF'
certSync:
  secrets:
    - source:
        namespace: cert-manager
        name: ais-edge-ca-secret
        keys: {ca.crt: ca.crt}
      destination:
        name: ca-bundle
EOF

# No `keys` map: the whole-Secret copy that would put the fleet CA private key
# on every edge.
cat >"$V/neg-mgmt-certsync-no-keys.yaml" <<'EOF'
certSync:
  secrets:
    - source:
        namespace: cert-manager
        name: ais-edge-ca-secret
      destination: {namespace: logging, name: ca-bundle}
EOF

# The CA Secret sourced from the wrong namespace. cert-manager writes it into
# its --cluster-resource-namespace; one namespace away it exists and never
# syncs, and every run logs sync_failed rather than erroring.
# The certSync entry that delivers the edge S3 credential names its source as
# "<edge>-s3", but cert-sync substitutes <edge> and nothing else — so an edge
# whose s3SecretRef points somewhere else would have the credential synced from
# a Secret that does not exist. sync_failed every six hours, the edge never
# receives s3-edge-credentials, and its uploader sits in
# CreateContainerConfigError; none of the three symptoms names the cause.
cat >"$V/neg-mgmt-certsync-s3-name-mismatch.yaml" <<'EOF'
edges:
  - name: edge-alpha
    nodeIP: "10.0.0.2"
    s3SecretRef: some-other-name
    uploadSecretRef: seaweedfs-upload
    exposure: sni
certSync:
  secrets:
    - source:
        namespace: cert-manager
        name: ais-edge-ca-secret
        keys: {ca.crt: ca.crt}
      destination: {namespace: xnat-ingest, name: ca-bundle, type: Opaque}
    - source:
        namespace: ais-mgmt
        name: "<edge>-s3"
        keys: {access-key: access-key, secret-key: secret-key}
      destination: {namespace: xnat-ingest, name: s3-edge-credentials, type: Opaque}
EOF

cat >"$V/neg-mgmt-certsync-ca-wrong-ns.yaml" <<'EOF'
certSync:
  secrets:
    - source:
        namespace: ais-mgmt
        name: ais-edge-ca-secret
        keys: {ca.crt: ca.crt}
      destination: {namespace: logging, name: ca-bundle}
EOF

# Copying tls.key out of the CA Secret: every edge could then mint a
# certificate for any hostname in the fleet.
cat >"$V/neg-mgmt-certsync-tls-key.yaml" <<'EOF'
certSync:
  secrets:
    - source:
        namespace: cert-manager
        name: ais-edge-ca-secret
        keys:
          ca.crt: ca.crt
          tls.key: tls.key
      destination: {namespace: logging, name: ca-bundle}
EOF

# mTLS on the push path with no distribution mechanism at all: cert-manager
# issues every client certificate on the management cluster and nothing carries
# any of them to a site.
printf 'certSync:\n  enabled: false\n'                    >"$V/neg-mgmt-loki-mtls-no-certsync.yaml"

# certSync is on and well-formed, but carries only the CA bundle. The push
# Ingress still demands a client certificate, so every edge fails the handshake
# — and the alerts that would report it are built from the logs that stop.
cat >"$V/neg-mgmt-loki-mtls-no-client-cert.yaml" <<'EOF'
certSync:
  secrets:
    - source:
        namespace: cert-manager
        name: ais-edge-ca-secret
        keys: {ca.crt: ca.crt}
      destination: {namespace: logging, name: ca-bundle, type: Opaque}
EOF

# | , = are the delimiters of the spec file cert-sync.sh parses, so a name
# containing one is read as a different instruction rather than rejected.
cat >"$V/neg-mgmt-certsync-delimiter-in-name.yaml" <<'EOF'
certSync:
  secrets:
    - source:
        namespace: cert-manager
        name: ais-edge-ca-secret
        keys: {ca.crt: ca.crt}
      destination: {namespace: logging, name: "ca-bundle,extra"}
EOF

cat >"$V/neg-mgmt-certsync-delimiter-in-key.yaml" <<'EOF'
certSync:
  secrets:
    - source:
        namespace: cert-manager
        name: ais-edge-ca-secret
        keys: {ca.crt: "ca.crt=x"}
      destination: {namespace: logging, name: ca-bundle}
EOF

# A CronJob name over 52 characters is rejected by the API server partway
# through an upgrade, because the controller appends a timestamp to derive Job
# names. "mgmt-cert-sync-" is 15, so the edge name below takes it to 57.
cat >"$V/neg-mgmt-certsync-cronjob-name-too-long.yaml" <<'EOF'
edges:
  - name: edge-with-a-name-long-enough-to-overflow-it
    s3SecretRef: edge-long-s3
    exposure: sni
EOF

# -- edge ---------------------------------------------------------------------
printf 'upload:\n  mode: both\n'                          >"$V/neg-edge-bad-mode.yaml"
printf 'upload:\n  s3:\n    endpoint: ""\n'               >"$V/neg-edge-s3-no-endpoint.yaml"
# perSiteBuckets derives <bucketPrefix>-<clusterLabel>, which is safe and is
# now the normal path — so an empty bucket alone is no longer an error. What
# must still be refused is the SHARED-bucket layout with no explicit name: a
# defaulted shared bucket is the original isolation bug, because SeaweedFS
# scopes identities per bucket with no prefix scoping, so every site sharing
# one bucket can read and delete every other site's staged imaging.
printf 'seaweedfs:\n  perSiteBuckets: false\nupload:\n  s3:\n    bucket: ""\n' >"$V/neg-edge-s3-no-bucket.yaml"
printf 'upload:\n  s3:\n    caBundleSecret: ""\n'         >"$V/neg-edge-https-no-ca.yaml"
printf 'orthanc:\n  deid:\n    policyReviewed: false\n'   >"$V/neg-edge-deid-not-reviewed.yaml"
printf 'orthanc:\n  deid:\n    aetMap: null\n'            >"$V/neg-edge-deid-empty-aetmap.yaml"
printf 'orthanc:\n  deid:\n    profile: null\n'           >"$V/neg-edge-deid-empty-profile.yaml"
printf 'orthanc:\n  deid:\n    existingSaltSecret: ""\n'  >"$V/neg-edge-deid-no-salt.yaml"

cat >"$V/neg-edge-deid-no-facilitybackup.yaml" <<'EOF'
storage:
  facilityBackup:
    enabled: false
EOF

# group-orthanc filtering on a label nothing applies: the pipeline stalls with
# no error anywhere.
cat >"$V/neg-edge-orphan-toprocesslabel.yaml" <<'EOF'
orthanc:
  deid:
    enabled: false
EOF

# Reclaiming the operator's only copy.
cat >"$V/neg-mgmt-quarantine-retain.yaml" <<'EOF'
dataPolicy:
  originals:
    quarantine:
      retain: 90d
EOF

cat >"$V/neg-mgmt-telemetry-retain.yaml" <<'EOF'
dataPolicy:
  telemetry:
    prometheus: {retain: 90d}
EOF

cat >"$V/neg-edge-grouped-minage.yaml" <<'EOF'
dataPolicy:
  derived:
    grouped:
      minAge: 3600
EOF

# An unparseable duration must FAIL the render, never default to 0. Zero would
# read as "expire immediately", which on an originals stage means discarding the
# archive of record because someone typed "7 days" instead of "7d".
cat >"$V/neg-edge-bad-duration.yaml" <<'EOF'
dataPolicy:
  derived:
    assigned:
      minAge: "7 days"
EOF

# Same guard on the management side. Both charts read the SAME dataPolicy block
# from the site file, so a duration the two disagree about would mean the edge
# and the reclaimer enforcing different windows from one line of config.
cat >"$V/neg-mgmt-bad-duration.yaml" <<'EOF'
dataPolicy:
  originals:
    quarantine:
      alertAfter: "one day"
EOF

cat >"$V/neg-edge-filedrop-reclaim.yaml" <<'EOF'
dataPolicy:
  enabled: true
  originals:
    fileDrop:
      reclaim: onIngested
ingest:
  fileDrop:
    enabled: true
EOF

printf 'hostAliases:\n  mgmtNodeIP: ""\n'                 >"$V/neg-edge-hostaliases-no-ip.yaml"
printf 'clusterLabel: ""\n'                               >"$V/neg-edge-no-clusterlabel.yaml"


# =============================================================================
# Case tables
# =============================================================================
# Format, tab-separated:
#   positive   name <TAB> chart-dir <TAB> space-separated values basenames
#   negative   name <TAB> chart-dir <TAB> values basenames <TAB> expected text
#
# The expected text is matched against the COMBINED stdout+stderr of
# `helm template`. It is a distinctive fragment of the guard's own message —
# long enough that a different guard firing cannot satisfy it by accident.

ci_positive_cases() {
  cat <<'EOF'
mgmt-defaults	charts/mgmt	mgmt-base.yaml
mgmt-k0smotron-external	charts/mgmt	mgmt-base.yaml mgmt-k0smotron-external.yaml
mgmt-two-edges	charts/mgmt	mgmt-base.yaml mgmt-two-edges.yaml
mgmt-sni-exposure	charts/mgmt	mgmt-base.yaml mgmt-sni-exposure.yaml
mgmt-observability-off	charts/mgmt	mgmt-base.yaml mgmt-observability-off.yaml
mgmt-datapolicy-on	charts/mgmt	mgmt-base.yaml mgmt-datapolicy-on.yaml
mgmt-no-seaweedfs	charts/mgmt	mgmt-base.yaml mgmt-no-seaweedfs.yaml
mgmt-shared-bucket	charts/mgmt	mgmt-base.yaml mgmt-shared-bucket.yaml
mgmt-letsencrypt	charts/mgmt	mgmt-base.yaml mgmt-letsencrypt.yaml
mgmt-slack	charts/mgmt	mgmt-base.yaml mgmt-slack.yaml
mgmt-two-edges-datapolicy	charts/mgmt	mgmt-base.yaml mgmt-two-edges.yaml mgmt-datapolicy-on.yaml
edge-defaults	charts/edge	edge-base.yaml
edge-upload-direct	charts/edge	edge-base.yaml edge-upload-direct.yaml
edge-observability-on	charts/edge	edge-base.yaml edge-observability-on.yaml
edge-samba-on	charts/edge	edge-base.yaml edge-samba-on.yaml
edge-filedrop-on	charts/edge	edge-base.yaml edge-filedrop-on.yaml
edge-datapolicy-on	charts/edge	edge-base.yaml edge-datapolicy-on.yaml
edge-deid-off	charts/edge	edge-base.yaml edge-deid-off.yaml
edge-cloud	charts/edge	edge-base.yaml edge-cloud.yaml
edge-direct-datapolicy	charts/edge	edge-base.yaml edge-upload-direct.yaml edge-datapolicy-on.yaml
edge-everything-on	charts/edge	edge-base.yaml edge-observability-on.yaml edge-samba-on.yaml edge-filedrop-on.yaml edge-datapolicy-on.yaml
EOF
}

ci_negative_cases() {
  cat <<'EOF'
neg-mgmt-no-domain	charts/mgmt	mgmt-base.yaml neg-mgmt-no-domain.yaml	domain.internal must be set
neg-mgmt-no-nodeip	charts/mgmt	mgmt-base.yaml neg-mgmt-no-nodeip.yaml	domain.mgmtNodeIP must be set
neg-mgmt-duplicate-edges	charts/mgmt	mgmt-base.yaml neg-mgmt-duplicate-edges.yaml	duplicate edge name
neg-mgmt-edge-no-name	charts/mgmt	mgmt-base.yaml neg-mgmt-edge-no-name.yaml	needs a name
neg-mgmt-edge-no-s3secret	charts/mgmt	mgmt-base.yaml neg-mgmt-edge-no-s3secret.yaml	has no s3SecretRef
neg-mgmt-edge-name-not-label	charts/mgmt	mgmt-base.yaml neg-mgmt-edge-name-not-label.yaml	is not a DNS-1123 label
neg-mgmt-edge-no-nodeport	charts/mgmt	mgmt-base.yaml neg-mgmt-edge-no-nodeport.yaml	has no apiNodePort
neg-mgmt-nodeport-out-of-range	charts/mgmt	mgmt-base.yaml neg-mgmt-nodeport-out-of-range.yaml	outside the cluster's NodePort range
neg-mgmt-nodeport-collision	charts/mgmt	mgmt-base.yaml neg-mgmt-nodeport-collision.yaml	is requested by both
neg-mgmt-bad-exposure	charts/mgmt	mgmt-base.yaml neg-mgmt-bad-exposure.yaml	has exposure
neg-mgmt-sni-with-nodeport	charts/mgmt	mgmt-base.yaml neg-mgmt-sni-with-nodeport.yaml	is exposure: sni but also sets
neg-mgmt-duplicate-hostname	charts/mgmt	mgmt-base.yaml neg-mgmt-duplicate-hostname.yaml	is claimed by both
neg-mgmt-fleetwide-hostnames	charts/mgmt	mgmt-base.yaml neg-mgmt-fleetwide-hostnames.yaml	no longer read
neg-mgmt-vector-loki-wrong-ns	charts/mgmt	mgmt-base.yaml neg-mgmt-vector-loki-wrong-ns.yaml	but this release installs Loki into
neg-mgmt-vector-loki-wrong-svc	charts/mgmt	mgmt-base.yaml neg-mgmt-vector-loki-wrong-svc.yaml	but this release's Loki Service is
neg-mgmt-loki-s3-no-seaweedfs	charts/mgmt	mgmt-base.yaml neg-mgmt-loki-s3-no-seaweedfs.yaml	requires seaweedfs.enabled=true
neg-mgmt-no-emailto	charts/mgmt	mgmt-base.yaml neg-mgmt-no-emailto.yaml	emailTo is empty
neg-mgmt-no-smtphost	charts/mgmt	mgmt-base.yaml neg-mgmt-no-smtphost.yaml	smtpHost is empty
neg-mgmt-no-xnatsecret	charts/mgmt	mgmt-base.yaml neg-mgmt-no-xnatsecret.yaml	xnatSecretRef must name a Secret
neg-mgmt-k0smotron-emptydir	charts/mgmt	mgmt-base.yaml neg-mgmt-k0smotron-emptydir.yaml	persistence.type=emptyDir
neg-mgmt-le-no-email	charts/mgmt	mgmt-base.yaml neg-mgmt-le-no-email.yaml	requires certManager.acme.email
neg-mgmt-le-no-dns01	charts/mgmt	mgmt-base.yaml neg-mgmt-le-no-dns01.yaml	DNS-01 solver
neg-mgmt-le-staging-prod-url	charts/mgmt	mgmt-base.yaml neg-mgmt-le-staging-prod-url.yaml	still points at the PRODUCTION directory
neg-mgmt-ca-commonname	charts/mgmt	mgmt-base.yaml neg-mgmt-ca-commonname.yaml	certManager.ca.commonName
neg-mgmt-ca-bad-mode	charts/mgmt	mgmt-base.yaml neg-mgmt-ca-bad-mode.yaml	certManager.ca.mode must be
neg-mgmt-ca-intermediate-no-secret	charts/mgmt	mgmt-base.yaml neg-mgmt-ca-intermediate-no-secret.yaml	intermediate.secretRef is empty
neg-mgmt-no-cm-namespace	charts/mgmt	mgmt-base.yaml neg-mgmt-no-cm-namespace.yaml	clusterResourceNamespace is empty
neg-mgmt-no-sslpassthrough	charts/mgmt	mgmt-base.yaml neg-mgmt-no-sslpassthrough.yaml	sslPassthrough=false
neg-mgmt-reclaimer-no-uploader	charts/mgmt	mgmt-base.yaml neg-mgmt-reclaimer-no-uploader.yaml	xnatUpload.enabled=false
neg-mgmt-reclaimer-no-seaweedfs	charts/mgmt	mgmt-base.yaml neg-mgmt-reclaimer-no-seaweedfs.yaml	seaweedfs.enabled=false
neg-mgmt-am-configsecret	charts/mgmt	mgmt-base.yaml neg-mgmt-am-configsecret.yaml	configSecret must be
neg-mgmt-am-smtp-not-mounted	charts/mgmt	mgmt-base.yaml neg-mgmt-am-smtp-not-mounted.yaml	alertmanagerSpec.secrets must include
neg-mgmt-grafana-secret-mismatch	charts/mgmt	mgmt-base.yaml neg-mgmt-grafana-secret-mismatch.yaml	generated random password
neg-mgmt-loki-ruler-not-mounted	charts/mgmt	mgmt-base.yaml neg-mgmt-loki-ruler-not-mounted.yaml	extraVolumes must mount
neg-mgmt-prom-release-label	charts/mgmt	mgmt-base.yaml neg-mgmt-prom-release-label.yaml	would load none
neg-mgmt-certsync-no-secrets	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-no-secrets.yaml	certSync.secrets is empty
neg-mgmt-certsync-schedule-macro	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-schedule-macro.yaml	must be a 5-field cron expression
neg-mgmt-certsync-schedule-weekly	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-schedule-weekly.yaml	runs less often than daily
neg-mgmt-certsync-no-destination	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-no-destination.yaml	needs source.name, destination.namespace
neg-mgmt-certsync-no-keys	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-no-keys.yaml	has no `keys` map
neg-mgmt-certsync-s3-name-mismatch	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-s3-name-mismatch.yaml	but that edge's s3SecretRef is
neg-mgmt-certsync-ca-wrong-ns	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-ca-wrong-ns.yaml	but cert-manager writes it into
neg-mgmt-certsync-tls-key	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-tls-key.yaml	copies key tls.key out of
neg-mgmt-certsync-delimiter-in-name	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-delimiter-in-name.yaml	contains one of | , =
neg-mgmt-certsync-delimiter-in-key	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-delimiter-in-key.yaml	key mapping ca.crt=ca.crt=x
neg-mgmt-certsync-cronjob-name-too-long	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-cronjob-name-too-long.yaml	the API server rejects CronJob names over 52
neg-mgmt-loki-mtls-no-certsync	charts/mgmt	mgmt-base.yaml neg-mgmt-loki-mtls-no-certsync.yaml	but certSync.enabled=false
neg-mgmt-loki-mtls-no-client-cert	charts/mgmt	mgmt-base.yaml neg-mgmt-loki-mtls-no-client-cert.yaml	no certSync.secrets entry copies
neg-edge-bad-mode	charts/edge	edge-base.yaml neg-edge-bad-mode.yaml	upload.mode must be
neg-edge-s3-no-endpoint	charts/edge	edge-base.yaml neg-edge-s3-no-endpoint.yaml	needs an S3 endpoint, and none could be derived
neg-edge-s3-no-bucket	charts/edge	edge-base.yaml neg-edge-s3-no-bucket.yaml	no staging bucket could be derived
neg-edge-https-no-ca	charts/edge	edge-base.yaml neg-edge-https-no-ca.yaml	silently DISABLES TLS verification
neg-edge-deid-not-reviewed	charts/edge	edge-base.yaml neg-edge-deid-not-reviewed.yaml	requires orthanc.deid.policyReviewed=true
neg-edge-deid-empty-aetmap	charts/edge	edge-base.yaml neg-edge-deid-empty-aetmap.yaml	aetMap is empty
neg-edge-deid-empty-profile	charts/edge	edge-base.yaml neg-edge-deid-empty-profile.yaml	profile is empty
neg-edge-deid-no-salt	charts/edge	edge-base.yaml neg-edge-deid-no-salt.yaml	existingSaltSecret is empty
neg-edge-deid-no-facilitybackup	charts/edge	edge-base.yaml neg-edge-deid-no-facilitybackup.yaml	requires storage.facilityBackup.enabled=true
neg-edge-orphan-toprocesslabel	charts/edge	edge-base.yaml neg-edge-orphan-toprocesslabel.yaml	Nothing applies that label
neg-edge-filedrop-reclaim	charts/edge	edge-base.yaml neg-edge-filedrop-reclaim.yaml	that directory is the only copy
neg-edge-hostaliases-no-ip	charts/edge	edge-base.yaml neg-edge-hostaliases-no-ip.yaml	hostAliases.mgmtNodeIP is empty
neg-edge-no-clusterlabel	charts/edge	edge-base.yaml neg-edge-no-clusterlabel.yaml	clusterLabel must be set
neg-edge-bad-duration	charts/edge	edge-base.yaml neg-edge-bad-duration.yaml	is not a duration I can parse
neg-mgmt-bad-duration	charts/mgmt	mgmt-base.yaml neg-mgmt-bad-duration.yaml	is not a duration I can parse
neg-edge-grouped-minage	charts/edge	edge-base.yaml neg-edge-grouped-minage.yaml	was removed and setting it does nothing
neg-mgmt-telemetry-retain	charts/mgmt	mgmt-base.yaml neg-mgmt-telemetry-retain.yaml	were removed: Helm cannot template a subchart
neg-mgmt-quarantine-retain	charts/mgmt	mgmt-base.yaml neg-mgmt-quarantine-retain.yaml	the only supported value is
EOF
}

# Run directly: write the files and list what was defined.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  echo "values written to $V"
  echo
  echo "positive cases:"; ci_positive_cases | cut -f1 | sed 's/^/  /'
  echo "negative cases:"; ci_negative_cases | cut -f1 | sed 's/^/  /'
fi
