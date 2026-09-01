{{/* ===================================================================== */}}
{{/* Naming                                                                */}}
{{/* ===================================================================== */}}

{{- define "edge.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "edge.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end -}}
{{- end }}

{{- define "edge.labels" -}}
helm.sh/chart: {{ include "edge.name" . }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "edge.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* PVC names. Two separate volumes on purpose — see values.yaml storage. */}}
{{- define "edge.pipelinePvc" -}}{{ include "edge.fullname" . }}-pipeline{{- end }}
{{- define "edge.facilityBackupPvc" -}}{{ include "edge.fullname" . }}-facility-backup{{- end }}


{{/* ===================================================================== */}}
{{/* Validation                                                            */}}
{{/*                                                                       */}}
{{/* Every check here is something that fails SILENTLY at runtime if it is */}}
{{/* wrong: no error, no crash, just data not moving or not protected.     */}}
{{/* Catching them at `helm template` time is the whole point.             */}}
{{/* ===================================================================== */}}
{{- define "edge.validate" -}}

  {{- /* Both upload modes at once = every session uploaded to XNAT twice. */ -}}
  {{- if not (has .Values.upload.mode (list "s3" "direct")) }}
    {{- fail (printf "upload.mode must be 's3' or 'direct', got %q" .Values.upload.mode) }}
  {{- end }}

  {{- if eq .Values.upload.mode "s3" }}
    {{- if not (include "edge.s3Endpoint" .) }}
      {{- fail "upload.mode=s3 needs an S3 endpoint, and none could be derived. Either pass the management site values file too (it carries hostnames.seaweedfs / domain.internal), or set upload.s3.endpoint explicitly." }}
    {{- end }}
    {{- /* No default. A shared bucket name is exactly the mistake this is
           preventing: SeaweedFS scopes identities per BUCKET with no
           prefix-level control, so two sites in one bucket can read and
           delete each other's staged imaging. The name has to be stated. */ -}}
    {{- if not (include "edge.s3Bucket" .) }}
      {{- fail "no staging bucket could be derived. Set it to THIS site's own staging bucket — the management chart names them ingest-<edge name>. There is deliberately no default: a shared bucket gives every site read and delete access to every other site's staged imaging, because SeaweedFS scopes identities per bucket and has no prefix-level scoping." }}
    {{- end }}

    {{- /* THE trap measured against SeaweedFS 3.99: AWS_CA_BUNDLE set to an
           empty string does NOT fall back to the system trust store — it
           disables certificate verification entirely and only logs
           "Unverified HTTPS request is being made". A request to a hostname
           the certificate does not cover then succeeds.

           THE CLIENT IS NOW RCLONE AND THAT SPECIFIC TRAP IS GONE: measured on
           rclone 1.75.0, RCLONE_CA_CERT="" behaves exactly like unset and
           still verifies against the system trust store. The guard stays,
           because the reason it is a HARD error did not depend on the
           downgrade. SeaweedFS here is signed by the internal CA, which no
           system trust store contains, so an https endpoint with no CA
           configured means every transfer fails the handshake at runtime, on
           an edge, after install reported success. Failing at render time is
           the cheap place to find that. */ -}}
    {{- if hasPrefix "https://" (include "edge.s3Endpoint" .) }}
      {{- if not .Values.upload.s3.caBundleSecret }}
        {{- fail (printf "upload.s3.endpoint is https (%s) but upload.s3.caBundleSecret is empty. Refusing to render: the SeaweedFS endpoint is signed by the fleet's internal CA, which is in no system trust store, so every upload would fail the TLS handshake at runtime. Set caBundleSecret, or use an http:// endpoint if this is an in-cluster service." (include "edge.s3Endpoint" .)) }}
      {{- end }}
    {{- end }}

    {{- /* THE OTHER HALF OF THE TLS STORY, and a separate key on purpose:
           caBundleSecret is who we TRUST, clientCertSecret is who we ARE.

           With the name empty, templates/upload.yaml renders `secretName:` with
           no value. That is valid YAML, so the render is green and every CI
           stage that parses it passes; the kubelet then refuses the volume and
           the uploader sits in CreateContainerConfigError. Naming the missing
           key here is much cheaper than reading a pod event on an edge. */ -}}
    {{- if and .Values.upload.s3.requireClientCert (not .Values.upload.s3.clientCertSecret) }}
      {{- fail "upload.s3.requireClientCert=true but upload.s3.clientCertSecret is empty. The uploader mounts that Secret to get its client certificate, so an empty name renders a volume with no source: helm succeeds, the manifest is valid YAML, and the uploader then sits in CreateContainerConfigError on the edge. It is delivered by the management cert-sync CronJob — name it (s3-client-tls unless the management site file says otherwise), or set requireClientCert=false." }}
    {{- end }}
  {{- end }}

{{- /* TWO ENGINES, ONE JOB. Running both means the Lua hook strips each
         instance on arrival and xnat-ingest then de-identifies what is already
         de-identified: the reid mapping it writes records the PSEUDONYMS as if
         they were the originals, so it looks like a working reversal path and
         reverses to nothing. */ -}}
  {{- if and .Values.orthanc.deid.enabled .Values.ingest.deidentify.enabled }}
    {{- fail "orthanc.deid.enabled and ingest.deidentify.enabled are both true. Pick one de-identification engine: the Orthanc Lua hook strips instances as they arrive; xnat-ingest deidentify runs as a stage between assign and upload. Running both makes the re-identification mapping record pseudonyms rather than originals, so it reverses to nothing while appearing to work." }}
  {{- end }}

  {{- /* Neither engine on is a legitimate choice — modalities that already
         de-identify, or staging into a trusted enclave — but it is never the
         RIGHT default, so it has to be said out loud. */ -}}
  {{- if and (not .Values.orthanc.deid.enabled) (not .Values.ingest.deidentify.enabled) }}
    {{- if not .Values.orthanc.deid.policyReviewed }}
      {{- fail "no de-identification engine is enabled (orthanc.deid.enabled=false and ingest.deidentify.enabled=false), so identifiable data would reach XNAT unchanged. If the modalities de-identify upstream and this is deliberate, set orthanc.deid.policyReviewed=true to acknowledge it." }}
    {{- end }}
  {{- end }}

  {{- /* The spec directory is what tells deidentify a format is handled. With no
         ConfigMap the volume renders with an empty source: helm succeeds, the
         manifest is valid YAML, and the pod then sits in
         CreateContainerConfigError on an edge nobody is watching. */ -}}
  {{- /* specFiles is what puts the '@' and the per-project directory on disk. A
       ConfigMap key cannot contain '@' and a ConfigMap mounts flat, so without
       the mapping the recipes land as bare keys in one directory, xnat-ingest
       matches none of them, and every session is skipped as "no applicable
       spec" — logged, but easy to read as "nothing to do". */ -}}
{{- if and .Values.ingest.deidentify.enabled .Values.ingest.deidentify.specConfigMap (not .Values.ingest.deidentify.specFiles) }}
  {{- fail "ingest.deidentify.specConfigMap is set but ingest.deidentify.specFiles is empty. A ConfigMap key cannot contain '@' and mounts flat, so the recipes would land as bare keys in one directory and xnat-ingest would match none of them, skipping every session. Map each key to the path it must appear at, e.g. specFiles: {default-dicom-series.json: \"__default__/medimage@dicom-series.json\"}." }}
{{- end }}

{{- if and .Values.ingest.deidentify.enabled (not .Values.ingest.deidentify.specs) (not .Values.ingest.deidentify.specConfigMap) }}
    {{- fail "ingest.deidentify.enabled=true but no recipes are configured. Set ingest.deidentify.specs in the site file (key = path under SPEC_DIR, value = the pydicom deid recipe) and the chart builds and mounts the ConfigMap for you — see charts/edge/files/deid-specs.example/. To manage the ConfigMap yourself instead, set ingest.deidentify.specConfigMap and specFiles. With neither, the volume renders with no source and the pod sits in CreateContainerConfigError on the edge." }}
  {{- end }}

  
  {{- /* De-identification is the control that stops identifiable data
         leaving the facility. A wrong-but-present profile looks identical to
         a right one from the outside, so a human has to say they read it. */ -}}
  {{- if .Values.orthanc.deid.enabled }}
    {{- if not .Values.orthanc.deid.policyReviewed }}
      {{- fail "orthanc.deid.enabled=true requires orthanc.deid.policyReviewed=true — confirm the de-identification profile and AET map match this site's policy before installing." }}
    {{- end }}
    {{- if not .Values.orthanc.deid.aetMap }}
      {{- fail "orthanc.deid.aetMap is empty: every modality would be quarantined as an unmapped AE title. Map at least one AET to an XNAT project." }}
    {{- end }}
    {{- /* An empty profile means /modify is handed nothing to change, so
           studies pass through with PHI intact and the pipeline looks
           perfectly healthy while doing the opposite of its job. There is no
           safe default to fall back to — a site's de-identification policy
           cannot be guessed. */ -}}
    {{- if not .Values.orthanc.deid.profile }}
      {{- fail "orthanc.deid.profile is empty: Orthanc /modify would be given nothing to change, so studies would reach XNAT with PHI intact and nothing would look wrong. Start from charts/edge/files/deidentification-profile.example.json and set it to this site's policy." }}
    {{- end }}
    {{- /* Auth on with no Secret named is the one shape that cannot work: the
         deployment mounts existingSecret non-optionally and Orthanc's
         RegisteredUsersFile points inside it, so an empty name leaves the pod
         unable to start with a message about a volume rather than about auth. */ -}}
  {{- if and .Values.orthanc.auth.enabled (not .Values.orthanc.auth.existingSecret) }}
    {{- fail "orthanc.auth.enabled=true but orthanc.auth.existingSecret is empty. That Secret must exist and carry THREE keys: users.json (what Orthanc checks, via RegisteredUsersFile), plus orthanc-user and orthanc-password (what group-orthanc authenticates with). If they disagree, Orthanc answers 401 and the pipeline stalls with data sitting in Orthanc." }}
  {{- end }}

  {{- if not .Values.orthanc.deid.existingSaltSecret }}
      {{- fail "orthanc.deid.existingSaltSecret is empty: the subject/session pseudonym hashes need a salt." }}
    {{- end }}
    {{- /* The hook writes the original to the facility backup and only then
           removes it from Orthanc. Without that volume there is no archive of
           record and no landing place for unmapped-AET quarantine. */ -}}
    {{- if not .Values.storage.facilityBackup.enabled }}
      {{- fail "orthanc.deid.enabled=true requires storage.facilityBackup.enabled=true — the de-identification hook writes originals there before modifying them, and quarantines unmapped-AET studies under it." }}
    {{- end }}
  {{- end }}

  {{- /* group-orthanc filters on the label the Lua hook applies. With deid
         off, nothing applies it, and the pipeline stalls with data sitting in
         Orthanc and no error anywhere — the worst kind of failure. */ -}}
  {{- if and .Values.ingest.orthancGroup.enabled (not .Values.orthanc.deid.enabled) }}
    {{- if .Values.ingest.orthancGroup.toProcessLabel }}
      {{- fail "ingest.orthancGroup.toProcessLabel is set but orthanc.deid.enabled=false. Nothing applies that label, so group-orthanc would filter out every study and the pipeline would stall silently. If you are switching to ingest.deidentify (the xnat-ingest engine), clearing toProcessLabel is the expected second step — the Lua hook applies that label as well as de-identifying, so turning it off removes both. Otherwise clear toProcessLabel, or re-enable orthanc.deid." }}
    {{- end }}
  {{- end }}

  {{- /* Reclaiming the operator's only copy. */ -}}
  {{- if and .Values.ingest.fileDrop.enabled (ne .Values.dataPolicy.originals.fileDrop.reclaim "never") }}
    {{- if not .Values.dataPolicy.enabled }}
      {{- /* inert anyway — allow it */ -}}
    {{- else }}
      {{- fail "dataPolicy.originals.fileDrop.reclaim is not 'never' while ingest.fileDrop.enabled=true. Files dropped into the watched directory have no Orthanc copy and no facility backup behind them; that directory is the only copy." }}
    {{- end }}
  {{- end }}

  {{- if and (eq .Values.topology "onprem") .Values.hostAliases.enabled }}
    {{- if and .Values.hostAliases.hostnames (not .Values.hostAliases.mgmtNodeIP) }}
      {{- fail "hostAliases.hostnames is set but hostAliases.mgmtNodeIP is empty." }}
    {{- end }}
  {{- end }}

  {{- /* A removed key that is still set must fail, not be ignored — silently
         dropping it is the exact defect this whole block is being cleaned of. */ -}}
  {{- if hasKey .Values.dataPolicy.derived.grouped "minAge" }}
    {{- fail "dataPolicy.derived.grouped.minAge was removed and setting it does nothing. `assign --unlink-source all` deletes each grouped tree at assign time, so a window measured from assign can never elapse; only trees assign FAILED to unlink reach the policy engine, and those are cleaned up immediately. Remove the key. If you want a post-upload recovery window, dataPolicy.derived.assigned.minAge is the one that works." }}
  {{- end }}

  {{- if not .Values.clusterLabel }}
    {{- fail "clusterLabel must be set: it is the per-site identifier on every log line and metric, and Grafana's `cluster` variable filters on it." }}
  {{- end }}
{{- end }}


{{/* ===================================================================== */}}
{{/* Shared pod fragments                                                  */}}
{{/* ===================================================================== */}}

{{/* onprem edges usually cannot resolve the management hostnames via site
     DNS, so pin them. Renders to nothing on cloud.

     BOTH the IP and the hostname list DERIVE from the management site file
     when the edge file does not state them, because this is the entry whose
     absence is hardest to diagnose: with no hostAlias the pod gets NXDOMAIN,
     the uploader treats it as an endpoint failure and preserves the local copy
     for the next attempt — correct behaviour that looks like nothing at all
     from the management side, which is watching for arrivals rather than for
     an absence. The edge fills its disk quietly.

     The list is every management hostname an edge pod actually dials. Grafana
     is deliberately NOT in it: nothing on the edge connects to Grafana, and a
     hostAlias for a host you never contact is a claim you cannot verify. */}}
{{- define "edge.hostAliases" -}}
{{- $ip := .Values.hostAliases.mgmtNodeIP | default .Values.domain.mgmtNodeIP }}
{{- $names := .Values.hostAliases.hostnames }}
{{- if not $names }}
  {{- $names = list }}
  {{- with (include "edge.seaweedfsHost" .) }}{{ $names = append $names . }}{{ end }}
  {{- if $.Values.observability.enabled }}
    {{- with (include "edge.lokiHost" $) }}{{ $names = append $names . }}{{ end }}
  {{- end }}
{{- end }}
{{- if and (eq .Values.topology "onprem") .Values.hostAliases.enabled $ip $names }}
hostAliases:
  - ip: {{ $ip | quote }}
    hostnames:
      {{- range $names }}
      - {{ . | quote }}
      {{- end }}
{{- end }}
{{- end }}

{{- define "edge.schedulingRules" -}}
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

{{/* The working volume, shared by every pipeline stage. All stages must see
     one filesystem or hardlink_or_copy degrades to a full copy (EXDEV). */}}
{{- define "edge.pipelineVolume" -}}
- name: pipeline
  persistentVolumeClaim:
    claimName: {{ include "edge.pipelinePvc" . }}
{{- end }}

{{- define "edge.pipelineVolumeMount" -}}
- name: pipeline
  mountPath: /data
{{- end }}

{{/* Structured logging. The alert rules and dashboards parse these fields
     directly, so this is a functional setting, not a formatting one. */}}
{{- define "edge.logEnv" -}}
- name: AIS_LOG_FORMAT
  value: {{ .Values.ingest.logFormat | quote }}
{{- end }}

{{/*
=============================================================================
Derived management-side endpoints
=============================================================================
Every value below can be worked out from facts the MANAGEMENT site file
already states — the domain, the published hostnames, the node IP, the bucket
prefix. Before these helpers each had to be typed a second time in the edge's
own values file, and a mismatch was silent in the worst way:

  * a wrong s3 endpoint or bucket  -> the uploader's head-bucket probe fails,
    it preserves the local copy and retries forever. Disk fills on the edge
    and the management side, which is watching for arrivals rather than
    absences, reports nothing wrong.
  * a hostname missing from hostAliases -> NXDOMAIN inside the pod, same
    outcome.
  * a wrong bucket that HAPPENS to exist -> worst case. The edge uploads
    successfully, the management uploader reads a different bucket, and both
    halves look healthy while nothing reaches XNAT.

So the edge file now only needs what is genuinely local to the edge — its AET
map, de-identification profile, storage paths. Pass the management site file
to the edge release as well and these resolve themselves:

    helm upgrade --install edge charts/edge \
        -f sites/<mgmt>/values.yaml -f sites/<edge>/values.yaml

An explicit value in the edge file still wins, for the case where a site
genuinely differs.
*/}}

{{- define "edge.seaweedfsHost" -}}
{{- if .Values.hostnames.seaweedfs }}{{ .Values.hostnames.seaweedfs }}
{{- else if .Values.domain.internal }}{{ printf "seaweedfs.%s" .Values.domain.internal }}
{{- end }}
{{- end }}

{{- define "edge.lokiHost" -}}
{{- if .Values.hostnames.loki }}{{ .Values.hostnames.loki }}
{{- else if .Values.domain.internal }}{{ printf "loki.%s" .Values.domain.internal }}
{{- end }}
{{- end }}

{{- define "edge.grafanaHost" -}}
{{- if .Values.hostnames.grafana }}{{ .Values.hostnames.grafana }}
{{- else if .Values.domain.internal }}{{ printf "grafana.%s" .Values.domain.internal }}
{{- end }}
{{- end }}

{{- define "edge.s3Endpoint" -}}
{{- if .Values.upload.s3.endpoint }}{{ .Values.upload.s3.endpoint }}
{{- else -}}
  {{- with (include "edge.seaweedfsHost" .) }}{{ printf "https://%s" . }}{{ end }}
{{- end }}
{{- end }}

{{- define "edge.lokiEndpoint" -}}
{{- if .Values.observability.loki.endpoint }}{{ .Values.observability.loki.endpoint }}
{{- else -}}
  {{- with (include "edge.lokiHost" .) }}{{ printf "https://%s" . }}{{ end }}
{{- end }}
{{- end }}

{{/*
The staging bucket. With seaweedfs.perSiteBuckets the management chart names
it <bucketPrefix>-<edge name> (charts/mgmt/templates/_helpers.tpl mgmt.edgeBucket),
and clusterLabel IS the edge name, so the same rule reproduces it exactly.

There is still deliberately NO default for the shared-bucket layout: a
defaulted shared bucket is the original isolation bug, since SeaweedFS matches
actions as "<action>:<bucket>" with no prefix scoping, so every edge sharing
one bucket can read and delete every other site's staged imaging. If a site
really is on the old shared layout it must say so explicitly.
*/}}
{{- define "edge.s3Bucket" -}}
{{- if .Values.upload.s3.bucket }}{{ .Values.upload.s3.bucket }}
{{- else if .Values.seaweedfs.perSiteBuckets -}}
{{ printf "%s-%s" (.Values.seaweedfs.bucketPrefix | default "ingest") .Values.clusterLabel }}
{{- end }}
{{- end }}

{{/*
=============================================================================
dataPolicy — duration to seconds, and the stage table the engine walks
=============================================================================
The engine is deliberately free of duration parsing: converting here means the
chart and the engine cannot disagree about what "24h" is, and a busybox shell
never has to do arithmetic on unit suffixes.

`forever` is NOT a duration and never becomes one. It renders as `-`, which the
engine treats as "no rule", so an unparseable or absent value can never be
mistaken for 0 (which would read as "expire immediately").
*/}}
{{- define "edge.durationSeconds" -}}
{{- $d := . | toString | trim -}}
{{- if or (eq $d "") (eq $d "forever") (eq $d "never") -}}
-
{{- else if not (regexMatch "^[0-9]+[smhdwy]?$" $d) -}}
{{- /* VALIDATE THE WHOLE STRING BEFORE TRIMMING A SUFFIX. Dispatching on the
       last character alone is silently wrong: "7 days" ends in "s", so it took
       the seconds branch, trimSuffix left "7 day", and int64 of that is 0 —
       "expire immediately" on an originals stage, from a typo. "one day" ends
       in "y" and did the same. Both were caught by the negative cases in
       scripts/ci/values.sh, which is why this validates first and fails loudly
       rather than defaulting. */ -}}
{{- fail (printf "dataPolicy: %q is not a duration I can parse (expected forever, a plain number of seconds, or a number with s/m/h/d/w/y such as 7d or 24h). An unparseable duration must NOT be treated as 0, which would read as 'expire immediately'." $d) -}}
{{- else if hasSuffix "s" $d -}}{{ trimSuffix "s" $d | int64 }}
{{- else if hasSuffix "m" $d -}}{{ mul (trimSuffix "m" $d | int64) 60 }}
{{- else if hasSuffix "h" $d -}}{{ mul (trimSuffix "h" $d | int64) 3600 }}
{{- else if hasSuffix "d" $d -}}{{ mul (trimSuffix "d" $d | int64) 86400 }}
{{- else if hasSuffix "w" $d -}}{{ mul (trimSuffix "w" $d | int64) 604800 }}
{{- else if hasSuffix "y" $d -}}{{ mul (trimSuffix "y" $d | int64) 31536000 }}
{{- else -}}{{ $d | int64 }}
{{- end -}}
{{- end }}

{{/*
The stage table: one line per declared stage, consumed by files/data-policy.sh.

  name <TAB> kind <TAB> location <TAB> minFreeDiskPercent <TAB> alertAfterSec <TAB> retain

TSV rather than JSON because the engine runs on busybox, where parsing JSON in
sh is a liability and `IFS` splitting is not. `-` means "no rule for this
field" everywhere.

quarantine has no location of its own: it is subPath UNDER facilityBackup, so
the two cannot drift and the alert can never name a directory nothing writes to.
*/}}
{{- define "edge.dataPolicyStages" -}}
{{- /* FULL .Values PATHS, NOT LOCAL ALIASES — scripts/ci/values-consumers.sh
       proves a key has a reader by grepping for `Values.<path>`, and an alias
       makes the dependency invisible to it. That check is the only thing
       standing between this block and another 14 dead keys.

       COLUMNS (tab-separated):
         1 name          2 kind (original|derived)   3 location
         4 minFreeDiskPercent   5 alertAfter seconds
         6 policy word (retain for originals, reclaim for derived)
         7 age seconds (retain for originals, minAge for derived)
         8 backend (filesystem | orthanc-rest)

       `backend` is what keeps the engine store-agnostic. A filesystem stage is
       walked directly; anything else is handed to an adapter. Orthanc needs one
       because its storage is UUID-named — a directory walk cannot tell which
       files belong to which session — and putting that knowledge inline would
       undo the independence that lets the de-identifier be replaced. */ -}}
{{- if .Values.dataPolicy.originals.facilityBackup.enabled }}
originals.facilityBackup	original	{{ .Values.dataPolicy.originals.facilityBackup.location }}	{{ .Values.dataPolicy.originals.facilityBackup.minFreeDiskPercent | default "-" }}	-	{{ .Values.dataPolicy.originals.facilityBackup.retain }}	{{ include "edge.durationSeconds" .Values.dataPolicy.originals.facilityBackup.retain }}	filesystem
originals.quarantine	original	{{ printf "%s/%s" (trimSuffix "/" .Values.dataPolicy.originals.facilityBackup.location) .Values.dataPolicy.originals.quarantine.subPath }}	-	{{ include "edge.durationSeconds" .Values.dataPolicy.originals.quarantine.alertAfter }}	{{ .Values.dataPolicy.originals.quarantine.retain }}	{{ include "edge.durationSeconds" .Values.dataPolicy.originals.quarantine.retain }}	filesystem
{{- end }}
{{- if .Values.ingest.fileDrop.enabled }}
originals.fileDrop	original	{{ .Values.dataPolicy.originals.fileDrop.location }}	-	-	{{ .Values.dataPolicy.originals.fileDrop.reclaim }}	{{ include "edge.durationSeconds" .Values.dataPolicy.originals.fileDrop.minAge }}	filesystem
{{- end }}
derived.orthancStorage	derived	{{ .Values.dataPolicy.derived.orthancStorage.location }}	-	-	{{ .Values.dataPolicy.derived.orthancStorage.reclaim }}	{{ include "edge.durationSeconds" .Values.dataPolicy.derived.orthancStorage.minAge }}	{{ .Values.dataPolicy.derived.orthancStorage.backend }}
derived.grouped	derived	{{ .Values.dataPolicy.derived.grouped.location }}	-	-	{{ .Values.dataPolicy.derived.grouped.reclaim }}	0	filesystem
derived.assigned	derived	{{ .Values.dataPolicy.derived.assigned.location }}	-	-	{{ .Values.dataPolicy.derived.assigned.reclaim }}	{{ include "edge.durationSeconds" .Values.dataPolicy.derived.assigned.minAge }}	filesystem
{{- if .Values.ingest.deidentify.enabled }}
derived.deidentified	derived	{{ include "edge.uploadSourceDir" . }}	-	-	{{ .Values.dataPolicy.derived.deidentified.reclaim }}	{{ include "edge.durationSeconds" .Values.dataPolicy.derived.deidentified.minAge }}	filesystem
{{- end }}
{{- end }}

{{/*
The uploader's fingerprint state directory.

ONE DEFINITION, TWO CONSUMERS. templates/upload.yaml sets STATE_DIR from it, and
templates/data-policy.yaml derives the `onUploaded` condition from it. If those
two ever disagree, the policy engine looks for upload markers in a directory the
uploader never writes to — every session then fails its condition, nothing is
ever reclaimed, and the only symptom is staging that quietly stops draining.
*/}}
{{- define "edge.uploaderStateDir" -}}
/data/LOGS/s3-uploader-state
{{- end }}

{{/*
The directory upload reads from.

assign writes /data/assigned. When the xnat-ingest deidentify stage is on it
sits between the two, reading /data/assigned and writing /data/deidentified,
so upload has to follow it — otherwise it would keep uploading the
pre-deidentification copy and the stage would be silently pointless.
*/}}
{{- define "edge.uploadSourceDir" -}}
{{- if .Values.ingest.deidentify.enabled }}/data/deidentified{{- else }}/data/assigned{{- end }}
{{- end }}
