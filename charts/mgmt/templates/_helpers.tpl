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
  {{- end }}

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
