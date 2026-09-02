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
           the certificate does not cover then succeeds. So an https endpoint
           with no CA configured must be a hard render error, never a default. */ -}}
    {{- if hasPrefix "https://" (include "edge.s3Endpoint" .) }}
      {{- if not .Values.upload.s3.caBundleSecret }}
        {{- fail (printf "upload.s3.endpoint is https (%s) but upload.s3.caBundleSecret is empty. Refusing to render: an empty AWS_CA_BUNDLE silently DISABLES TLS verification rather than falling back to the system trust store. Set caBundleSecret, or use an http:// endpoint if this is an in-cluster service." (include "edge.s3Endpoint" .)) }}
      {{- end }}
    {{- end }}
  {{- end }}

  {{- /* THE "BOTH ENGINES" GUARD WAS REMOVED, NOT LOST. It failed when
       orthanc.deid.enabled and ingest.deidentify.enabled were both true. With
       deid.engine that state is unrepresentable: one key selects one engine, so
       there is nothing left to detect. The property it protected - that the
       re-identification map records originals rather than pseudonyms, which is
       what running both would have broken - is now structural. */ -}}

  {{- /* THE ENGINE SWITCH IS THE ONE THING THAT MUST BE A KNOWN VALUE. An
         unrecognised word would select neither engine, and "neither" is a
         configuration that ships identifiable data to XNAT. Checked here rather
         than in the helper so the message names the key and the alternatives. */ -}}
  {{- $engine := include "edge.deidEngine" . }}
  {{- if not (has $engine (list "orthanc" "ingest" "none")) }}
    {{- fail (printf "deid.engine must be one of orthanc, ingest or none, got %q. orthanc runs the Lua hook at the front door; ingest runs the xnat-ingest deidentify stage between assign and upload; none is for sites whose modalities de-identify upstream and requires orthanc.deid.policyReviewed=true." $engine) }}
  {{- end }}
  {{- /* `eq $engine "none"`, NOT "neither of the two I know". The broad form
         meant a TYPO satisfied it: deid.engine=ingset failed with a message
         asserting the operator had chosen none, which they had not, while the
         message written for an unknown value sat 96 lines below and was never
         reached. Which one they got depended on policyReviewed, whose default
         is false, so the wrong message was the one most people would see. The
         enum check above runs first, so the value is known by this point. */ -}}
  {{- if eq $engine "none" }}
    {{- if not .Values.orthanc.deid.policyReviewed }}
      {{- fail "deid.engine=none, so nothing in this pipeline de-identifies anything and identifiable data would reach XNAT unchanged. If the modalities de-identify upstream and this is deliberate, set orthanc.deid.policyReviewed=true to acknowledge it." }}
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
{{- if and (eq (include "edge.deidEngine" .) "ingest") .Values.ingest.deidentify.specConfigMap (not .Values.ingest.deidentify.specFiles) }}
  {{- fail "ingest.deidentify.specConfigMap is set but ingest.deidentify.specFiles is empty. A ConfigMap mounts its keys flat in one directory, but xnat-ingest's load_specs walks <spec-dir>/<category>/<format> and SKIPS anything at the top level that is not a directory, so flat keys match nothing and every session fails with 'No deidentification specs found'. Map each key to the path it must appear at, e.g. specFiles: {default-dicom-series: \"__default__/medimage/dicom-series\"}." }}
{{- end }}

{{- if and (eq (include "edge.deidEngine" .) "ingest") (not .Values.ingest.deidentify.specs) (not .Values.ingest.deidentify.specConfigMap) }}
    {{- fail "deid.engine=ingest but no recipes are configured. Set ingest.deidentify.specs in the site file (key = path under SPEC_DIR, value = the pydicom deid recipe) and the chart builds and mounts the ConfigMap for you — see charts/edge/files/deid-specs.example/. To manage the ConfigMap yourself instead, set ingest.deidentify.specConfigMap and specFiles. With neither, the volume renders with no source and the pod sits in CreateContainerConfigError on the edge." }}
  {{- end }}

  {{- /* De-identification is the control that stops identifiable data
         leaving the facility. A wrong-but-present profile looks identical to
         a right one from the outside, so a human has to say they read it. */ -}}
  {{- if (eq (include "edge.deidEngine" .) "orthanc") }}
    {{- if not .Values.orthanc.deid.policyReviewed }}
      {{- fail "deid.engine=orthanc requires orthanc.deid.policyReviewed=true — confirm the de-identification profile and AET map match this site's policy before installing." }}
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
    {{- /* THE PROFILE IS A CONTRACT WITH THE ASSIGN STAGE, not just a privacy
           policy. assign reads project, subject and session from these three
           tags and has no other source for them. Drop one while tightening
           the profile — the obvious thing to do, since they look like trial
           metadata nobody asked for — and de-identification still reports
           success, upload never sees the study, and every session stalls at
           assign with "missing metadata fields". The pipeline looks healthy
           from both ends and the cause is in a file nobody edited that day. */ -}}
    {{- $replace := (.Values.orthanc.deid.profile).Replace | default dict }}
    {{- $missing := list }}
    {{- range $tag := list "ClinicalTrialProtocolID" "ClinicalTrialSubjectID" "ClinicalTrialTimePointID" }}
      {{- if not (get $replace $tag) }}
        {{- $missing = append $missing $tag }}
      {{- end }}
    {{- end }}
    {{- if $missing }}
      {{- fail (printf "orthanc.deid.profile.Replace is missing %s. The assign stage reads project, subject and session from ClinicalTrialProtocolID, ClinicalTrialSubjectID and ClinicalTrialTimePointID — with any one absent, de-identification still succeeds and every session then stalls at assign with 'missing metadata fields'. Restore the tag(s) with their ${ProjectCode}/${SubjectHash}/${SessionHash} values." (join ", " $missing)) }}
    {{- end }}
    {{- /* XNAT rejects a project ID outside this charset at upload time, per
           session, long after the study has been de-identified and grouped.
           The AET map is where the ID is chosen, so it is where a typo is
           still cheap to fix. */ -}}
    {{- range $aet, $cfg := .Values.orthanc.deid.aetMap }}
      {{- $project := ($cfg).project | default "" }}
      {{- if not $project }}
        {{- fail (printf "orthanc.deid.aetMap.%s has no project. Every study from that AE title would be de-identified and then have nowhere to go." $aet) }}
      {{- end }}
      {{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9_-]*$" $project) }}
        {{- fail (printf "orthanc.deid.aetMap.%s.project is %q, which XNAT will not accept. Project IDs must start alphanumeric and contain only letters, digits, underscore and hyphen — no spaces, dots or slashes. XNAT rejects it per session at upload, after de-identification has already succeeded." $aet $project) }}
      {{- end }}
    {{- end }}
    {{- /* The hook writes the original to the facility backup and only then
           removes it from Orthanc. Without that volume there is no archive of
           record and no landing place for unmapped-AET quarantine. */ -}}
    {{- if not .Values.storage.facilityBackup.enabled }}
      {{- fail "deid.engine=orthanc requires storage.facilityBackup.enabled=true — the de-identification hook writes originals there before modifying them, and quarantines unmapped-AET studies under it." }}
    {{- end }}
  {{- end }}


  {{- /* The two booleans this replaced were read by 24 call sites that all had
         to agree with each other and with the label and the tag mapping. Setting
         them now does nothing, so they must fail rather than be ignored. */ -}}
  {{- if hasKey .Values.orthanc.deid "enabled" }}
    {{- fail "orthanc.deid.enabled has been replaced by the single key deid.engine. Set deid.engine=orthanc for the Lua hook, or deid.engine=ingest for the xnat-ingest stage; the chart derives the hook, the stage, the group label and the reclaim condition from it, which is what stops them disagreeing." }}
  {{- end }}
  {{- if hasKey .Values.ingest.deidentify "enabled" }}
    {{- fail "ingest.deidentify.enabled has been replaced by the single key deid.engine. Set deid.engine=ingest to run the xnat-ingest de-identification stage." }}
  {{- end }}

  {{- /* THE SECOND THING THE LUA HOOK SUPPLIES, and the one that is easy to
         miss because the failure looks like a data problem rather than a
         configuration one.

         assign reads project, subject and session from the ClinicalTrial*
         tags. Nothing in a DICOM stream carries those: the Lua hook WRITES
         them, from the AE-title map. With the hook off, no study has them, so
         assign resolves nothing and files every session under __invalid__ with
         INVALID_MISSING_CLINICALTRIAL... in the name.

         Measured on a live edge before this guard existed: 531 instances
         grouped correctly, landed in assigned/__invalid__, and the deidentify
         stage then reported "Found 0 sessions" for ever. Because the hook is
         off, those files still hold their PHI, so the end state is
         identifiable data at rest in a directory no stage will ever pick up,
         with nothing failing loudly enough to notice.

         There is deliberately no default substitute. Which real tags carry
         project, subject and session is a site decision, and guessing one
         would route studies into the wrong XNAT project. */ -}}
  {{- if (eq (include "edge.deidEngine" .) "ingest") }}
    {{- $mapping := .Values.ingest.assign.tagMapping }}
    {{- $luaOnly := list }}
    {{- range $key, $tag := $mapping }}
      {{- if hasPrefix "ClinicalTrial" $tag }}
        {{- $luaOnly = append $luaOnly (printf "%s=%s" $key $tag) }}
      {{- end }}
    {{- end }}
    {{- if $luaOnly }}
      {{- fail (printf "deid.engine=ingest, but ingest.assign.tagMapping still reads %s. Those tags are written by the Orthanc Lua hook, which is off in this configuration, so no study will carry them: assign resolves no ids and files every session under __invalid__, where no later stage looks. With the hook off nothing has de-identified the data at that point either, so it sits there identifiable. Set ingest.assign.tagMapping to tags this site's modalities actually populate (for example project: StudyID, subject: PatientID, session: AccessionNumber)." (join ", " $luaOnly)) }}
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

  {{- /* onUploaded ANYWHERE needs someone to write the uploader's markers, and
         upload.mode=direct renders no s3-uploader at all. values.yaml says so
         in a comment beside the key; a comment is not a guard, and the failure
         it describes is the silent one this repo keeps finding. */ -}}
  {{- if eq .Values.upload.mode "direct" }}
    {{- /* DELIBERATELY NOT `assigned` AS WELL. The same argument applies to it,
           and the shipped tier-1 site files declare assigned.reclaim=onUploaded,
           so failing on that would refuse this chart's own default install. It
           is an unsatisfiable declaration rather than a dangerous one: the tree
           is kept either way, and StageBacklogAgeing now reports it instead of
           it growing unwatched. Correcting that default to `never` is a
           separate, deliberate change. */ -}}
    {{- if eq .Values.dataPolicy.derived.deidentified.reclaim "onUploaded" }}
      {{- fail "dataPolicy.derived.deidentified.reclaim=onUploaded with upload.mode=direct. That condition is satisfied by a marker under the uploader's state directory, and the ONLY thing that writes there is the s3-uploader, which this upload mode does not render. Nothing could ever satisfy it: the tree would be kept for ever while the policy read as though it were being cleaned. Use never if you intend to keep it." }}
    {{- end }}
  {{- end }}

  {{- /* The reclaim word for /data/assigned depends on WHO reads that tree, and
         that is decided by the engine. Under the ingest engine the uploader
         reads /data/deidentified, so its markers describe that tree and nothing
         ever satisfies onUploaded for this one: the assigned copy of every
         session would accumulate while the policy looked correct. */ -}}
  {{- if and (eq (include "edge.deidEngine" .) "ingest") (eq .Values.dataPolicy.derived.assigned.reclaim "onUploaded") }}
    {{- fail "deid.engine=ingest with dataPolicy.derived.assigned.reclaim=onUploaded. Under this engine the uploader reads /data/deidentified, so the markers it writes describe THAT tree and onUploaded can never be satisfied for /data/assigned — every session's assigned copy would accumulate on the edge disk while the policy read as if it were being cleaned. Use onDeidentified, which lets the deidentify stage retire each session as soon as it has written a complete copy, or never if you intend to keep them." }}
  {{- end }}

  {{- /* onDeidentified retires /data/assigned at handoff, so both of these are
         configurations where the operator has asked for something the mechanism
         cannot deliver. Refusing beats accepting and quietly not doing it. */ -}}
  {{- if eq .Values.dataPolicy.derived.assigned.reclaim "onDeidentified" }}
    {{- if not (eq (include "edge.deidEngine" .) "ingest") }}
      {{- fail "dataPolicy.derived.assigned.reclaim=onDeidentified but deid.engine is not ingest. That condition is satisfied by the deidentify STAGE unlinking its own input, and the stage does not render, so nothing would ever retire /data/assigned and it would grow without bound. Use onUploaded, which the data-policy engine can satisfy from the uploader's markers when the uploader reads this tree, or enable the stage." }}
    {{- end }}
    {{- $minAge := include "edge.durationSeconds" .Values.dataPolicy.derived.assigned.minAge }}
    {{- if and (ne $minAge "-") (gt (int64 $minAge) 0) }}
      {{- fail (printf "dataPolicy.derived.assigned.minAge=%v is set alongside reclaim=onDeidentified. A recovery window measured on this tree can never elapse under that condition: the deidentify stage deletes each session the moment it has written a complete copy, so there is nothing left for the window to protect. Set minAge to 0, or use onUploaded if you want a window." .Values.dataPolicy.derived.assigned.minAge) }}
    {{- end }}
  {{- end }}

  {{- /* TIER-1 REACHES GRAFANA BY NodePort — there is no ingress here, so this
         number is the only way in. Kubernetes only accepts one from the
         service node-port range, and the rejection comes from the API server
         at apply time with a message about the Service, several minutes into
         an install that has already built the cluster and applied the
         secrets. Cheaper to refuse before any of that. */ -}}
  {{- if .Values.observability.stack.enabled }}
    {{- $np := ((index .Values "kube-prometheus-stack").grafana.service).nodePort }}
    {{- if $np }}
      {{- if or (lt (int $np) 30000) (gt (int $np) 32767) }}
        {{- fail (printf "kube-prometheus-stack.grafana.service.nodePort is %v, outside Kubernetes' node-port range 30000-32767. The API server rejects the Service, so Grafana gets no address at all — and on tier-1 the NodePort is the only way to reach it." $np) }}
      {{- end }}
    {{- end }}
  {{- end }}

  {{- /* THE RULER POSTS TO ALERTMANAGER BY NAME, and that name is built from
         kube-prometheus-stack's fullnameOverride. The two are set in separate
         subchart blocks with nothing tying them together, so overriding one
         is the natural thing to do and breaks the other.
         The failure is silent in the way that matters: Loki keeps evaluating
         its rules and keeps firing them, into a URL that does not resolve. No
         object is unhealthy, no pod restarts, Grafana still draws the graphs
         — and every log-based alert (upload failure, auth failure, disk low,
         quarantine) simply never arrives. */ -}}
  {{- if .Values.observability.stack.enabled }}
    {{- $kps := (index .Values "kube-prometheus-stack").fullnameOverride | default "" }}
    {{- $url := (((.Values.loki).loki).rulerConfig).alertmanager_url | default "" }}
    {{- if and $kps $url }}
      {{- $want := printf "http://%s-alertmanager." $kps }}
      {{- if not (hasPrefix $want $url) }}
        {{- fail (printf "loki.loki.rulerConfig.alertmanager_url is %q but kube-prometheus-stack.fullnameOverride is %q, so the Alertmanager Service is named %s-alertmanager. The ruler would post every log-based alert to a hostname that does not resolve — nothing looks unhealthy and no alert ever arrives. Set the URL to start %q, or restore the fullnameOverride." $url $kps $kps $want) }}
      {{- end }}
    {{- end }}
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
{{- else if .Values.observability.stack.enabled -}}
  {{- /* TIER-1: Loki runs in this same cluster, so plain http to the Service.
         No mTLS and no SNI — nothing leaves the node, so there is no transport
         to protect and no management CA to verify against. `ais-loki` is the
         subchart's fullnameOverride, pinned in values.yaml for exactly this
         reason: the name has to be predictable from here. */ -}}
  {{- printf "http://ais-loki.%s.svc.cluster.local:3100" .Release.Namespace }}
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
{{- if (eq (include "edge.deidEngine" .) "ingest") }}
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
{{- /*
THE ONE PLACE THE DE-IDENTIFICATION ENGINE IS CHOSEN.

Everything that used to be set by hand and had to agree — which hook runs,
which stage renders, whether group-orthanc filters on a label, which tree the
uploader reads and who is allowed to retire /data/assigned — is derived from
this single value, because getting any one of them out of step produced a
pipeline that rendered cleanly and then did not work. Measured on a live edge
before this existed: enabling the stage without also clearing toProcessLabel
and re-pointing tagMapping filed 531 instances under __invalid__, still
carrying their PHI, with the deidentify stage reporting "Found 0 sessions" for
ever.

Valid values are checked in edge.validate, not here, so an unknown one fails
with a message rather than silently selecting neither engine.
*/}}
{{- define "edge.deidEngine" -}}
{{- .Values.deid.engine | default "orthanc" -}}
{{- end }}

{{- define "edge.orthancDeidEnabled" -}}
{{- eq (include "edge.deidEngine" .) "orthanc" -}}
{{- end }}

{{- define "edge.ingestDeidEnabled" -}}
{{- eq (include "edge.deidEngine" .) "ingest" -}}
{{- end }}

{{- define "edge.uploadSourceDir" -}}
{{- if (eq (include "edge.deidEngine" .) "ingest") }}/data/deidentified{{- else }}/data/assigned{{- end }}
{{- end }}

{{- /*
THE DELETE AUTHORITY FOR THAT SAME TREE, chosen by the SAME condition.

The uploader is pointed at edge.uploadSourceDir, so with ais-deid enabled it
reads /data/deidentified. Its RECLAIM variable used to be read straight from
dataPolicy.derived.assigned.reclaim regardless, so the uploader took its
permission to delete from the policy for a DIFFERENT tree: it would delete
/data/deidentified on the strength of the assigned stage's `onUploaded`, while
the operator's declared policy for the deidentified tree said `never`.

Path drift was already prevented by deriving the directory from one helper.
This is the same argument applied to the policy: whichever tree the uploader is
reading, the authority to delete it comes from THAT tree's own key.

Only the ais-deid case changes. With de-identification in Orthanc, which is how
every site is configured, both branches resolve to the assigned key exactly as
before.
*/}}
{{- define "edge.uploadReclaim" -}}
{{- if (eq (include "edge.deidEngine" .) "ingest") }}{{ .Values.dataPolicy.derived.deidentified.reclaim }}{{- else }}{{ .Values.dataPolicy.derived.assigned.reclaim }}{{- end }}
{{- end }}
