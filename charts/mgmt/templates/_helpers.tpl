{{/* ===================================================================== */}}
{{/* Naming                                                                */}}
{{/* ===================================================================== */}}

{{- define "mgmt.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mgmt.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end -}}
{{- end }}

{{- define "mgmt.labels" -}}
helm.sh/chart: {{ include "mgmt.name" . }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "mgmt.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
mgmt.labels minus everything that changes on release (helm.sh/chart,
app.kubernetes.io/version).

USE ON ANY OBJECT WHOSE LABELS BECOME SOMEBODY ELSE'S SELECTOR — a version
bump then stops a Service matching pods it already created, and a
StatefulSet's selector is immutable so it can never catch up. This took the
edge offline once (a chart bump silently disconnected a site, nothing
restarted or logged an error); full incident + the CI guard against it:
scripts/ci/render.sh, "no version-bearing label reaches a selector".
Same reasoning moved ais-edge.org/exposure to an annotation — see
templates/edge-clusters.yaml.
*/}}
{{- define "mgmt.selectorSafeLabels" -}}
app.kubernetes.io/name: {{ include "mgmt.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
The label Prometheus uses to DISCOVER PrometheusRule and ServiceMonitor
objects. Every rule and monitor this chart creates must carry it, and it must
match what the kube-prometheus-stack subchart is configured to select.

This exists because the imperative installer hardcoded
`release: kube-prometheus-stack` in five separate files. As a subchart the
release name is ours, so a hardcoded literal would mean Prometheus silently
loads none of our rules — no error, no alert, just an alerting stack that
never fires again.
*/}}
{{- define "mgmt.prometheusReleaseLabel" -}}
{{- default .Release.Name .Values.observability.prometheusReleaseLabel }}
{{- end }}

{{/* Hostnames: explicit value wins, otherwise <prefix>.<domain.internal>. */}}
{{- define "mgmt.host" -}}
{{- $ctx := index . 0 -}}{{- $key := index . 1 -}}{{- $prefix := index . 2 -}}
{{- $explicit := index $ctx.Values.hostnames $key -}}
{{- if $explicit -}}{{ $explicit }}{{- else -}}{{ $prefix }}.{{ $ctx.Values.domain.internal }}{{- end -}}
{{- end }}

{{- define "mgmt.seaweedfsHost" -}}{{ include "mgmt.host" (list . "seaweedfs" "seaweedfs") }}{{- end }}
{{- define "mgmt.grafanaHost"   -}}{{ include "mgmt.host" (list . "grafana" "grafana") }}{{- end }}
{{- define "mgmt.lokiHost"      -}}{{ include "mgmt.host" (list . "loki" "loki") }}{{- end }}
{{- define "mgmt.k0sApiHost"    -}}{{ include "mgmt.host" (list . "k0sApi" "k0s") }}{{- end }}
{{- define "mgmt.konnectivityHost" -}}{{ include "mgmt.host" (list . "konnectivity" "konnectivity") }}{{- end }}

{{/* In-cluster S3 endpoint. Plain http on purpose: it never leaves the
     cluster, and it avoids every edge of the custom-CA path. Edges use the
     https Ingress instead. */}}
{{- define "mgmt.s3InternalEndpoint" -}}
http://{{ include "mgmt.fullname" . }}-seaweedfs.{{ .Release.Namespace }}.svc.cluster.local:8333
{{- end }}

{{/* The ClusterIssuer that fronts the INTERNAL CA.

     Normally it is named from certManager.issuer, but when the operator
     selects Let's Encrypt that name belongs to the ACME issuer and the CA path
     — which still exists, because the edge trust anchor is distributed from it
     — falls back to the fixed name `ais-edge-ca`. templates/cert-issuers.yaml
     computed this inline; it is a define now because observability.yaml has to
     issue the Loki push client certificates from the SAME issuer, and two
     copies of a ternary is exactly how the client certs would end up signed by
     a CA the push Ingress does not verify against. */}}
{{- define "mgmt.caIssuerName" -}}
{{- ternary "ais-edge-ca" .Values.certManager.issuer (hasPrefix "letsencrypt-" .Values.certManager.issuer) -}}
{{- end }}

{{/* The management-side Secret holding ONE edge's Loki push client
     certificate, as issued by cert-manager and as read by cert-sync.

     Argument is the edge NAME, not the context.

     NOT release-prefixed, deliberately. This name is written a second time, by
     hand, in each site's certSync.secrets[].source.name as the literal
     "<edge>-loki-client" — the site file cannot know the release name, and a
     name that moved with the release would leave cert-sync reading a Secret
     that does not exist and every edge without a client certificate. Same
     reasoning as loki-tls / grafana-tls / ais-edge-ca. cert-sync.yaml checks
     the two spellings still agree, and refuses to render if they do not. */}}
{{- define "mgmt.lokiClientCertSecret" -}}
{{- printf "%s-loki-client" . -}}
{{- end }}


{{/* ===================================================================== */}}
{{/* Validation — all of these fail silently at runtime if wrong           */}}
{{/* ===================================================================== */}}
{{- define "mgmt.validate" -}}

  {{- if not .Values.domain.internal }}
    {{- fail "domain.internal must be set — every management hostname and TLS SAN derives from it." }}
  {{- end }}
  {{- if not .Values.domain.mgmtNodeIP }}
    {{- fail "domain.mgmtNodeIP must be set — it is the address edges resolve the management hostnames to." }}
  {{- end }}

  {{- /* A duplicate clusterLabel merges two sites' logs and metrics into one
         stream. Nothing errors; the dashboards just quietly show the wrong
         numbers and per-site alerts fire for the wrong site. */ -}}
  {{- $seen := dict -}}
  {{- range .Values.edges }}
    {{- if not .name }}{{- fail "every entry in `edges` needs a name" }}{{- end }}
    {{- if hasKey $seen .name }}{{- fail (printf "duplicate edge name %q — edge names must be unique, they become the cluster label, the k0smotron Cluster name and the S3 identity" .name) }}{{- end }}
    {{- $_ := set $seen .name true -}}
    {{- if not .s3SecretRef }}
      {{- fail (printf "edge %q has no s3SecretRef — the chart references S3 credentials by Secret name and never inlines them" .name) }}
    {{- end }}
    {{- /* The name becomes the commonName of that edge's Loki push client
           certificate AND one branch of the auth-tls-match-cn regex on the
           push Ingress (templates/observability.yaml). A regex metacharacter
           in it would widen what the Ingress accepts rather than error — `.`
           alone turns one site's branch into a wildcard. A DNS-1123 label is
           already required of this string by Kubernetes (it is the Cluster
           name and the namespace), so this rejects nothing that could ever
           have been installed; it just rejects it at render time, where the
           consequence is visible. */ -}}
    {{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" .name) }}
      {{- fail (printf "edge name %q is not a DNS-1123 label (lowercase alphanumerics and '-'). It is used verbatim as the k0smotron Cluster name and the namespace, and it is embedded in the auth-tls-match-cn regex on the Loki push Ingress — a regex metacharacter there silently WIDENS which client certificates are accepted instead of failing." .name) }}
    {{- end }}
  {{- end }}

  {{- /* The other two halves of the mTLS push contract are guarded WHERE THEY
         ARE RENDERED, not here: "certSync is switched off entirely" in
         observability.yaml next to the client Certificates, and "certSync
         carries no client certificate for this edge" in cert-sync.yaml after
         that file's own per-entry checks. Putting either here made every
         certSync negative case fail with THIS message instead of the specific
         one, because a guard in validate.yaml runs before the file whose
         values it is judging. */ -}}

  {{- if .Values.observability.enabled }}
    {{- if and (eq .Values.observability.loki.storage "s3") (not .Values.seaweedfs.enabled) }}
      {{- fail "observability.loki.storage=s3 requires seaweedfs.enabled=true. Use storage: filesystem for a standalone management node." }}
    {{- end }}
    {{- if not .Values.observability.alerting.emailTo }}
      {{- fail "observability.alerting.emailTo is empty: alerts would be evaluated and then discarded, which looks exactly like a healthy system." }}
    {{- end }}
    {{- if not .Values.observability.alerting.smtpHost }}
      {{- fail "observability.alerting.smtpHost is empty — no alert could be delivered." }}
    {{- end }}
  {{- end }}

  {{- if .Values.xnatUpload.enabled }}
    {{- if not .Values.xnatUpload.xnatSecretRef }}
      {{- fail "xnatUpload.xnatSecretRef must name a Secret with server/username/password." }}
    {{- end }}
  {{- end }}

  {{- if and .Values.k0smotron.enabled .Values.edges }}
    {{- if eq .Values.k0smotron.persistence.type "emptyDir" }}
      {{- fail "k0smotron.persistence.type=emptyDir means a control-plane pod restart discards the child cluster's datastore. Use pvc." }}
    {{- end }}
  {{- end }}

  {{- /* The vector subchart's customConfig is passed through verbatim — Helm
         does not template subchart values, so the Loki address in it is a
         literal that no `.Release` reference can keep honest. It drifted once
         already: it named the namespace the imperative installer used, and
         after Loki became a subchart in the release namespace the sink
         resolved to nothing. Vector retries a failing sink forever without
         exiting, so management logs simply stopped arriving and every
         dashboard kept working off the edges' logs. Check it here. */ -}}
  {{- if .Values.observability.enabled }}
    {{- $ep := dig "customConfig" "sinks" "loki" "endpoint" "" .Values.vector }}
    {{- if $ep }}
      {{- $wantSvc := .Values.loki.fullnameOverride | default (printf "%s-loki" .Release.Name) }}
      {{- $host := regexReplaceAll "^https?://" $ep "" | splitList ":" | first }}
      {{- $parts := splitList "." $host }}
      {{- $svc := index $parts 0 }}
      {{- if ne $svc $wantSvc }}
        {{- fail (printf "vector.customConfig.sinks.loki.endpoint is %q, but this release's Loki Service is %q. Vector would retry a name that does not resolve and management logs would never reach Loki, silently." $ep $wantSvc) }}
      {{- end }}
      {{- if gt (len $parts) 1 }}
        {{- $ns := index $parts 1 }}
        {{- if ne $ns .Release.Namespace }}
          {{- fail (printf "vector.customConfig.sinks.loki.endpoint is %q, which names namespace %q, but this release installs Loki into %q. Use the bare service name %q so it resolves via the pod's search domain." $ep $ns .Release.Namespace $wantSvc) }}
        {{- end }}
      {{- end }}
    {{- end }}
  {{- end }}

  {{- if eq .Values.certManager.issuer "letsencrypt-prod" }}
    {{- if not .Values.certManager.acme.email }}
      {{- fail "certManager.issuer=letsencrypt-prod requires certManager.acme.email." }}
    {{- end }}
    {{- if not .Values.certManager.acme.dns01Solver }}
      {{- fail "Let's Encrypt needs a DNS-01 solver here: the management hostnames are not reachable for HTTP-01, and a wildcard-resolver domain such as nip.io cannot be validated at all. Configure certManager.acme.dns01Solver, or use issuer: ais-edge-ca." }}
    {{- end }}
  {{- end }}
{{- end }}


{{/* ===================================================================== */}}
{{/* Shared fragments                                                      */}}
{{/* ===================================================================== */}}
{{- define "mgmt.schedulingRules" -}}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
SeaweedFS FILER HTTP endpoint (port 8888), as opposed to the S3 gateway
endpoint (8333) above.

These are genuinely different services on the same pod and they are not
interchangeable: the S3 gateway cannot remove a directory ENTRY, which is the
whole reason the reclaimer needs the filer. Measured on SeaweedFS 3.99:
  DELETE /buckets/<bucket>/<prefix>/<session>?recursive=true  -> 204, entry gone
  aws s3 rm --recursive <same>                                -> "PRE <session>/" remains
*/}}
{{- define "mgmt.filerInternalEndpoint" -}}
http://{{ include "mgmt.fullname" . }}-seaweedfs.{{ .Release.Namespace }}.svc.cluster.local:8888
{{- end }}

{{/* ===================================================================== */}}
{{/* Per-site bucket naming                                                */}}
{{/* ===================================================================== */}}
{{/*
The staging bucket for one edge site.

WHY ONE BUCKET PER SITE. SeaweedFS matches an identity's actions as
"<action>:<bucket>", so `Write:<bucket>/*` is BUCKET-WIDE — there is no
prefix-level scoping. Measured on the live cluster: the edge-dev key lists
ingest-bucket fine and gets AccessDenied on logs-bucket, so the bucket is the
enforcement boundary, and only the bucket. While every site shared one bucket,
any edge key could read, list and delete every other site's staged imaging.

A bucket per site makes that boundary line up with the trust boundary. It also
means the uploader and reclaimer are per-site, which removes a fleet-wide
single point of failure: one site's poison session, stuck multipart or expired
credential no longer stops delivery for everybody.

`seaweedfs.buckets.ingest` remains as the SHARED bucket for sites that have
not been migrated yet, so this can roll out one site at a time.
*/}}
{{- define "mgmt.edgeBucket" -}}
{{- $ctx := index . 0 -}}{{- $edge := index . 1 -}}
{{- if $edge.bucket -}}
{{- $edge.bucket }}
{{- else if $ctx.Values.seaweedfs.perSiteBuckets -}}
{{- printf "%s-%s" $ctx.Values.seaweedfs.bucketPrefix $edge.name | trunc 63 | trimSuffix "-" }}
{{- else -}}
{{- $ctx.Values.seaweedfs.buckets.ingest }}
{{- end -}}
{{- end }}

{{/* Every distinct staging bucket in use, so the bucket-creation hook and the
     admin identity cover them all without duplicating the naming rule. */}}
{{- define "mgmt.allIngestBuckets" -}}
{{- $ctx := . -}}
{{- $seen := dict -}}
{{- range $ctx.Values.edges }}
  {{- $b := include "mgmt.edgeBucket" (list $ctx .) -}}
  {{- $_ := set $seen $b true -}}
{{- end }}
{{- if not $ctx.Values.seaweedfs.perSiteBuckets }}
  {{- $_ := set $seen $ctx.Values.seaweedfs.buckets.ingest true -}}
{{- end }}
{{- keys $seen | sortAlpha | join " " }}
{{- end }}
