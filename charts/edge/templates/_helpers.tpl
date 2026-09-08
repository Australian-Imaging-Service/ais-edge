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
  {{- /* A GUARD MUST BE GATED ON WHAT CONSUMES THE VALUE, not on what the value
         is named after. Both of these were gated on deid.engine=orthanc because
         they sit under the `orthanc:` values key, and neither is consumed on that
         condition. Both became reachable when ingest became the default.

         ORTHANC_USER / ORTHANC_PASSWORD are mounted on `if .Values.orthanc.auth
         .enabled` alone (ingest-pipeline.yaml:84), with no engine test: the group
         stage and the data-policy engine both call the REST API whoever does the
         de-identifying. Measured: 2 references under EVERY engine.

         AIS_DEID_HMAC_SALT is mounted on `or (engine == "orthanc")
         storage.facilityBackup.enabled` (orthanc-deployment.yaml:99), which is
         the condition the Lua hook loads on, and the backup is enabled by
         default.

         With either secret name empty the manifest renders a secretKeyRef with
         NO NAME. helm is happy, the objects are valid YAML, and the pod fails at
         start with CreateContainerConfigError. For the salt that pod is Orthanc
         itself, so nothing can be received at all. */ -}}
  {{- if and .Values.orthanc.auth.enabled (not .Values.orthanc.auth.existingSecret) }}
        {{- fail "orthanc.auth.enabled=true but orthanc.auth.existingSecret is empty. That Secret must exist and carry THREE keys: users.json, which is mounted into /etc/orthanc and must be a config fragment of the form {\"RegisteredUsers\":{\"<user>\":\"<password>\"}}, plus orthanc-user and orthanc-password, which group-orthanc AND the data-policy store reclaim both authenticate with. If users.json disagrees with orthanc-password, Orthanc answers 401: group-orthanc crash-loops and the Orthanc store is silently never reclaimed. If you do not want the store reclaim authenticating at all, the other way out is dataPolicy.derived.orthancStorage.backend=filesystem." }}
  {{- end }}
  {{- if and (or (eq (include "edge.deidEngine" .) "orthanc") .Values.storage.facilityBackup.enabled) (not .Values.orthanc.deid.existingSaltSecret) }}
      {{- fail "orthanc.deid.existingSaltSecret is empty: the subject/session pseudonym hashes need a salt." }}
  {{- end }}

  {{- /* THE FACILITY BACKUP IS REQUIRED UNDER BOTH ENGINES, and it used to be
         gated as though it were an orthanc-only concern. It became reachable
         when ingest became the default, which is how the gating was found.

         The hook loads on:  or (engine == "orthanc") (facilityBackup.enabled)

         so the two ways to get here fail DIFFERENTLY, and the message says both:

         orthanc + disabled -> the hook LOADS and writes the original at
           deidentify-and-forward.lua:124, before it consults DeidEnabled at :148,
           and returns if that write fails:
               if not writeAtomic(backupPath, origBytes) then
                 print("ABORT: facility backup write failed for " .. instanceId)
                 return
           Every instance is dropped at the front door while the modality is told
           the transfer succeeded. Loud in its own way: the pipeline stops.

         ingest + disabled -> the hook is NOT LOADED at all. Nothing drops.
           Studies arrive, are grouped, de-identified by the ingest stage and
           uploaded, and the site looks entirely healthy. What silently does not
           exist is the archive of record and the unmapped-AET quarantine, because
           the hook is the only thing that writes either. That is the worse of the
           two: it looks like a working system until someone needs the original.

         engine=none is exempt: the hook is not loaded and there is nothing to
         archive from, since nothing de-identifies either. */ -}}
  {{- if ne (include "edge.deidEngine" .) "none" }}
    {{- if not .Values.storage.facilityBackup.enabled }}
      {{- fail (printf "storage.facilityBackup.enabled=false is not supported under deid.engine=%s. Under deid.engine=orthanc the Lua hook loads, writes every original to that volume BEFORE anything else, and returns if the write fails, so every incoming instance is dropped at the front door while the sending modality is told the transfer succeeded. Under deid.engine=ingest the hook is not loaded at all, so nothing is dropped and nothing complains: what is silently missing is the archive of record and the unmapped-AET quarantine, because the hook is the only thing that writes either. Enable it." (include "edge.deidEngine" .)) }}
    {{- end }}
  {{- end }}

  {{- /* ALERTS THAT GO NOWHERE. Ported from charts/mgmt on main, where this has
         been guarded for a while; it never reached this branch, which is the one
         where it matters more. Tier-1 runs its OWN Alertmanager and there is no
         management plane behind it, so this is the only delivery path there is.

         Empty emailTo renders Alertmanager with receiver "null": every rule still
         evaluates, every alert still fires, and none is delivered. Nothing errors.
         That includes the alerts saying studies have stopped reaching XNAT.

         It is easy to believe this is configured, because the secrets file makes
         you fill in REPLACE_SMTP_USERNAME and REPLACE_SMTP_APP_PASSWORD. Those
         are the credential for talking to the relay. These say who gets the mail.
         Two halves, two files, and only one of them was ever enforced.

         Gated on stack.enabled as well as observability.enabled: this branch can
         run the pipeline with no local stack at all, and then there is no
         Alertmanager to configure. */ -}}
  {{- if and .Values.observability.enabled .Values.observability.stack.enabled }}
    {{- if not .Values.observability.stack.alerting.emailTo }}
      {{- fail "observability.stack.alerting.emailTo is empty: alerts would be evaluated and then discarded, which looks exactly like a healthy site. Alertmanager renders with receiver \"null\" and every alert goes nowhere, including the ones reporting that studies have stopped reaching XNAT. Filling in the alertmanager-smtp Secret is not enough on its own: that is the credential for the relay, this is who receives the mail." }}
    {{- end }}
    {{- if not .Values.observability.stack.alerting.smtpHost }}
      {{- fail "observability.stack.alerting.smtpHost is empty — no alert could be delivered. Set it alongside observability.stack.alerting.emailTo." }}
    {{- end }}
  {{- end }}


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

  {{- /* THE RENAME, and it hard-fails rather than being honoured quietly.
         policyReviewed moved to deid.policyReviewed because it
         gates EVERY engine, not just the Lua one: under deid.engine=ingest the
         old path asked an operator to confirm orthanc.deid.profile while the
         recipe that actually ran was ingest.deidentify.specs. A site hit that
         in the field. Accepting the old key as an alias would leave the
         confusion in place at exactly the sites that already have it, and a
         gate that moves without the operator noticing is a policy nobody
         re-read. So name the new path and stop. Checked before the engine enum
         so an un-migrated file gets this message rather than one about a key
         it has never heard of. */ -}}
  {{- if hasKey (default (dict) .Values.orthanc.deid) "policyReviewed" }}
    {{- fail "orthanc.deid.policyReviewed has MOVED to deid.policyReviewed. It gates every deid.engine, ingest and none included, so it no longer sits under orthanc. Move the key to the top-level `deid:` block next to `engine:`, and delete it from orthanc.deid." }}
  {{- end }}

  {{- /* THE ENGINE SWITCH IS THE ONE THING THAT MUST BE A KNOWN VALUE. An
         unrecognised word would select neither engine, and "neither" is a
         configuration that ships identifiable data to XNAT. Checked here rather
         than in the helper so the message names the key and the alternatives. */ -}}
  {{- $engine := include "edge.deidEngine" . }}
  {{- if not (has $engine (list "orthanc" "ingest" "none")) }}
    {{- fail (printf "deid.engine must be one of orthanc, ingest or none, got %q. orthanc runs the Lua hook at the front door; ingest runs the xnat-ingest deidentify stage between assign and upload; none is for sites whose modalities de-identify upstream and requires deid.policyReviewed=true." $engine) }}
  {{- end }}
  {{- /* `eq $engine "none"`, NOT "neither of the two I know". The broad form
         meant a TYPO satisfied it: deid.engine=ingset failed with a message
         asserting the operator had chosen none, which they had not, while the
         message written for an unknown value sat 96 lines below and was never
         reached. Which one they got depended on policyReviewed, whose default
         is false, so the wrong message was the one most people would see. The
         enum check above runs first, so the value is known by this point. */ -}}
  {{- if eq $engine "none" }}
    {{- if not .Values.deid.policyReviewed }}
      {{- fail "deid.engine=none, so nothing in this pipeline de-identifies anything and identifiable data would reach XNAT unchanged. If the modalities de-identify upstream and this is deliberate, set deid.policyReviewed=true to acknowledge it." }}
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

  {{- /* THE MIRROR OF THE GUARD ABOVE, and the one that was missing. Recipes
         supplied while some OTHER engine is selected are not a smaller mistake
         than recipes missing: they are discarded in silence.

         ingest-pipeline.yaml gates the deid-specs ConfigMap on the engine
         (line 258) and the whole deidentify Deployment on it again (line 282),
         and deid.engine defaults to "orthanc". So a site that pastes recipes
         into values.yaml and leaves the engine alone gets:

           helm rc=0, 0 deid-specs ConfigMaps, 0 deidentify Deployments,
           the recipe text absent from the render, and no warning anywhere.

         MEASURED on the shipped example site with only specs added. The Orthanc
         Lua profile keeps running, so de-identification still happens; what is
         lost is the CHANGE the operator believed they had made. That is the
         dangerous shape: a tightened recipe added after an ethics review reads
         as applied and is not. */ -}}
{{- if ne (include "edge.deidEngine" .) "ingest" }}
  {{- $supplied := list }}
  {{- if .Values.ingest.deidentify.specs }}{{- $supplied = append $supplied "specs" }}{{- end }}
  {{- if .Values.ingest.deidentify.specConfigMap }}{{- $supplied = append $supplied "specConfigMap" }}{{- end }}
  {{- if .Values.ingest.deidentify.specFiles }}{{- $supplied = append $supplied "specFiles" }}{{- end }}
  {{- if $supplied }}
    {{- fail (printf "ingest.deidentify.%s is set, but deid.engine=%s. Those recipes belong to the xnat-ingest de-identification stage, which only renders under deid.engine=ingest, so nothing would mount them and no deidentify pod would exist: the chart would install cleanly and your recipe would never run. De-identification would still happen, via the Orthanc Lua profile in orthanc.deid.profile, which is a DIFFERENT recipe. Either set deid.engine=ingest to use what you have written here, or edit orthanc.deid.profile instead, which is what the selected engine reads." (join ", ingest.deidentify." $supplied) (include "edge.deidEngine" .)) }}
  {{- end }}
{{- end }}

  {{- /* De-identification is the control that stops identifiable data
         leaving the facility. A wrong-but-present profile looks identical to
         a right one from the outside, so a human has to say they read it. */ -}}
    {{- /* BOTH ENGINES, not just the Lua one. This gate used to fire only under
           deid.engine=orthanc. That was survivable while orthanc was the default
           and the ingest engine made the operator write a recipe by hand: writing
           it WAS the deliberate act. Now that ingest is the default and the
           shipped example carries a recipe, that act disappears, and a site could
           scaffold, install and start sending studies under a de-identification
           policy nobody had read. The confirmation belongs to shipping PHI to
           XNAT, not to which component does the stripping. */ -}}
    {{- if has (include "edge.deidEngine" .) (list "orthanc" "ingest") }}
      {{- if not .Values.deid.policyReviewed }}
        {{- fail (printf "deid.engine=%s requires deid.policyReviewed=true. Read the recipe this engine will apply (ingest.deidentify.specs for the ingest engine, orthanc.deid.profile for the Lua one) and the AET map, confirm they are this site's policy, then set it. Nothing downstream re-checks what was removed." (include "edge.deidEngine" .)) }}
      {{- end }}
    {{- end }}

  {{- if (eq (include "edge.deidEngine" .) "orthanc") }}
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
        {{- /* group-orthanc IMPLEMENTS only one copy mode: xnat-ingest raises
               outright. api/group_api.py:252 refuses any copy_mode other than
               hardlink_or_copy for the Orthanc path:

                 NotImplementedError: 'unlink_source', copy_mode' and 'raise_errors'
                 are not yet implemented for Orthanc grouping.

               It is a RUNTIME raise, so the pod renders, schedules, starts and then
               CrashLoops with a message that does not name the setting that caused
               it. MEASURED against 0.15.0; the same raise is in 0.13.1, so this is a
               long-standing footgun rather than a version regression. The other
               stages do accept the full range, which is what makes this key look
               safe to change. */ -}}
        {{- if and (eq (include "edge.deidEngine" .) "orthanc") (ne .Values.ingest.orthancGroup.copyMode "hardlink_or_copy") }}
          {{- fail (printf "ingest.orthancGroup.copyMode=%s is not supported. xnat-ingest's Orthanc grouping accepts ONLY hardlink_or_copy and raises NotImplementedError for anything else, at run time, so the group-orthanc pod would CrashLoop with a message that does not name this setting. Set it back to hardlink_or_copy. The other stages (fileDrop, assign, deidentify, associate) do accept the full range." .Values.ingest.orthancGroup.copyMode) }}
        {{- end }}

        {{- /* PREREQUISITES FOR orthanc.auth.enabled=true, ASSERTED AT RENDER.


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

  {{- /* onUploaded needs someone to establish that the session reached XNAT.
         Under upload.mode=s3 that is the s3-uploader's marker. Under direct
         there is no s3-uploader, so for a long time nothing could satisfy it:
         UPLOAD_STATE_DIR defaults to /data/LOGS/s3-uploader-state and stayed
         empty for ever, the condition never came true, and the uploader re-sent
         the same session every loop while XNAT answered "already exists with
         different checksums".

         The staged reclaimer CronJob now satisfies it, for ONE tree: the
         terminal one the uploader actually drains, which it re-checks against
         XNAT itself. So the guard is no longer "onUploaded is impossible under
         direct", it is "onUploaded is impossible for a tree nothing watches".

         PORTED FROM main, where this was fixed first. The reclaimer and its
         script were written for upload.mode=direct and landed on the branch
         whose default mode is s3, so THIS branch - the one that only ever runs
         direct - was the one left without them. */ -}}
  {{- if eq .Values.upload.mode "direct" }}
    {{- $terminal := include "edge.uploadSourceDir" . }}
    {{- /* DELIBERATELY NOT `assigned` AS WELL when it is the terminal tree: the
           shipped tier-1 site files declare assigned.reclaim=onUploaded and the
           reclaimer now satisfies exactly that. Under deid.engine=ingest the
           assigned tree is NOT terminal, and the separate guard above already
           requires onDeidentified there. */ -}}
    {{- if and (eq (include "edge.deidentifiedReclaim" .) "onUploaded") (ne $terminal "/data/deidentified") }}
      {{- fail (printf "dataPolicy.derived.deidentified.reclaim=onUploaded with upload.mode=direct and deid.engine=%s. Under direct upload the only thing that can establish `uploaded` is the staged reclaimer CronJob, and it watches the tree the uploader drains, which under this engine is %s, not /data/deidentified. Nothing would ever satisfy the condition: the tree would be kept for ever while the policy read as though it were being cleaned. Use never if you intend to keep it, or deid.engine=ingest if it should be the tree that is uploaded." (include "edge.deidEngine" .) $terminal) }}
    {{- end }}
  {{- end }}

  {{- /* The reclaim word for /data/assigned depends on WHO reads that tree, and
         that is decided by the engine. Under the ingest engine the uploader
         reads /data/deidentified, so its markers describe that tree and nothing
         ever satisfies onUploaded for this one: the assigned copy of every
         session would accumulate while the policy looked correct. */ -}}
  {{- if and (eq (include "edge.deidEngine" .) "ingest") (eq (include "edge.assignedReclaim" .) "onUploaded") }}
    {{- fail "deid.engine=ingest with dataPolicy.derived.assigned.reclaim=onUploaded. Under this engine the uploader reads /data/deidentified, so the markers it writes describe THAT tree and onUploaded can never be satisfied for /data/assigned — every session's assigned copy would accumulate on the edge disk while the policy read as if it were being cleaned. Use onDeidentified, which lets the deidentify stage retire each session as soon as it has written a complete copy, or never if you intend to keep them." }}
  {{- end }}

  {{- /* onDeidentified retires /data/assigned at handoff, so both of these are
         configurations where the operator has asked for something the mechanism
         cannot deliver. Refusing beats accepting and quietly not doing it. */ -}}
  {{- if eq (include "edge.assignedReclaim" .) "onDeidentified" }}
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
THE RECLAIM WORD FOLLOWS THE ENGINE, so the operator does not have to keep two
keys in step with a third.

Which tree the uploader drains is decided by deid.engine, and the correct reclaim
word for each tree follows from that. Making the operator restate it was a
standing invitation to get it wrong: every combination of engine and these two
keys has a guard below, and four of the six combinations are refusals. That is a
lot of machinery to protect a value nobody has a reason to choose independently.

`auto`, the default, resolves to the right word for the selected engine:

    engine    assigned          deidentified
    ingest    onDeidentified    onUploaded     (uploader reads /data/deidentified)
    orthanc   onUploaded        never          (uploader reads /data/assigned)

An explicit value is still honoured, and still guarded, for a site that wants to
keep a tree it would otherwise retire.
*/}}
{{- define "edge.assignedReclaim" -}}
{{- $v := .Values.dataPolicy.derived.assigned.reclaim -}}
{{- if ne $v "auto" }}{{ $v }}
{{- else if eq (include "edge.deidEngine" .) "ingest" }}onDeidentified
{{- else }}onUploaded{{ end }}
{{- end }}

{{- define "edge.deidentifiedReclaim" -}}
{{- $v := .Values.dataPolicy.derived.deidentified.reclaim -}}
{{- if ne $v "auto" }}{{ $v }}
{{- else if eq (include "edge.deidEngine" .) "ingest" }}onUploaded
{{- else }}never{{ end }}
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
derived.assigned	derived	{{ .Values.dataPolicy.derived.assigned.location }}	-	-	{{ include "edge.assignedReclaim" . }}	{{ include "edge.durationSeconds" .Values.dataPolicy.derived.assigned.minAge }}	filesystem
{{- if (eq (include "edge.deidEngine" .) "ingest") }}
derived.deidentified	derived	{{ include "edge.uploadSourceDir" . }}	-	-	{{ include "edge.deidentifiedReclaim" . }}	{{ include "edge.durationSeconds" .Values.dataPolicy.derived.deidentified.minAge }}	filesystem
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
{{- if (eq (include "edge.deidEngine" .) "ingest") }}{{ include "edge.deidentifiedReclaim" . }}{{- else }}{{ include "edge.assignedReclaim" . }}{{- end }}
{{- end }}
