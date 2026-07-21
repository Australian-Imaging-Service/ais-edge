{{/*
Chart name.
*/}}
{{- define "edge.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
PVC name — defaults to "ais-edge" (via values.yaml) but can be overridden
per-release so multiple installs can coexist in the same cluster.
*/}}
{{- define "edge.pvcName" -}}
{{- .Values.pvcName }}
{{- end }}

{{/*
Common labels applied to every resource.
*/}}
{{- define "edge.labels" -}}
helm.sh/chart: {{ include "edge.name" . }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "edge.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
DICOM tag mapping env vars — included in sort, upload, and associate pods.
*/}}
{{- define "edge.dicomTagEnv" -}}
- name: XINGEST_PROJECT
  value: {{ .Values.xnatIngest.dicomTagMapping.project | quote }}
- name: XINGEST_SUBJECT
  value: {{ .Values.xnatIngest.dicomTagMapping.subject | quote }}
- name: XINGEST_SESSION_LABEL
  value: {{ .Values.xnatIngest.dicomTagMapping.sessionLabel | quote }}
- name: XINGEST_SESSION_UID
  value: {{ .Values.xnatIngest.dicomTagMapping.sessionUid | quote }}
{{- end }}

{{/*
Common xnat-ingest env vars shared by all three pods.
*/}}
{{- define "edge.xnatIngestCommonEnv" -}}
- name: XINGEST_DEIDENTIFY
  value: {{ .Values.xnatIngest.deidentify | quote }}
- name: XINGEST_SPACES_TO_UNDERSCORES
  value: {{ .Values.xnatIngest.spacesToUnderscores | quote }}
{{- end }}

{{/*
Shared volume definitions for xnat-ingest pods.
*/}}
{{- define "edge.xnatIngestVolumes" -}}
volumes:
- name: storage
  persistentVolumeClaim:
    claimName: {{ include "edge.pvcName" . }}
{{- end }}

{{/*
Shared volumeMount for xnat-ingest pods.
*/}}
{{- define "edge.xnatIngestVolumeMount" -}}
- name: storage
  mountPath: /data
{{- end }}
