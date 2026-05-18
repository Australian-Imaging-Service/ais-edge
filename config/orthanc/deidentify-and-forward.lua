-- AIS-Edge Orthanc deidentify-and-forward hook.
--
-- OnStoredInstance: facility-backup the original, /modify against the
--   deidentification profile, delete the original (keep the deid'd one).
-- OnStableStudy:    PUT `xnat-ingest-ready` label on the study.
--
-- Inputs (mounted at /etc/orthanc/):
--   routing.json                     AET -> { project } map + default paths
--   deidentification-profile.json    Replace / Keep blocks for /modify
--   AIS_DEID_HMAC_SALT (env)         secret salt for SubjectHash/SessionHash
--
-- See docs/components/orthanc.md for failure-recovery + operations notes.

local ROUTING_FILE = os.getenv("AIS_ROUTING_FILE") or "/etc/orthanc/routing.json"
local HMAC_SALT    = os.getenv("AIS_DEID_HMAC_SALT") or error("AIS_DEID_HMAC_SALT not set")

local function loadJsonFile(path)
  local f = assert(io.open(path, "r"))
  local content = f:read("*a")
  f:close()
  return ParseJson(content)
end

-- Salted djb2. NOT cryptographic; jodogne/orthanc-plugins doesn't expose
-- ComputeMd5/Sha1 in Lua. For HMAC-grade switch to jodogne/orthanc-python.
local function hmacShort(value, length)
  local input = HMAC_SALT .. "|" .. value
  local h1, h2 = 5381, 0
  for i = 1, #input do
    local c = string.byte(input, i)
    h1 = ((h1 * 33) + c) % 4294967296                -- djb2
    h2 = ((h2 * 31) + c + (h1 % 256)) % 4294967296   -- second mix for more entropy
  end
  local hex = string.format("%08X%08X", h1, h2)
  while #hex < (length or 12) do hex = hex .. hex end
  return string.sub(hex, 1, length or 12):upper()
end

local function shellQuote(s)
  return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- Atomic durable write: bytes -> <path>.tmp, fsync, rename to <path>.
local function writeAtomic(path, bytes)
  local dir = string.match(path, "(.*)/[^/]+$")
  local tmp = path .. ".tmp"
  if dir then os.execute("mkdir -p " .. shellQuote(dir)) end

  local f, err = io.open(tmp, "wb")
  if not f then
    print("ERROR opening " .. tmp .. ": " .. (err or "unknown"))
    return false
  end
  f:write(bytes)
  f:close()

  os.execute("sync " .. shellQuote(tmp) .. " 2>/dev/null")
  local ok, _, rc = os.execute("mv -f " .. shellQuote(tmp) .. " " .. shellQuote(path))
  if not ok and rc ~= 0 then
    print("ERROR renaming " .. tmp .. " -> " .. path)
    os.remove(tmp)
    return false
  end
  return true
end

local function applyPlaceholders(profile, tags, project)
  local subjectHash = hmacShort(tags.PatientID or "")
  local sessionHash = hmacShort((tags.PatientID or "") .. "|" .. (tags.StudyInstanceUID or ""))
  local birthYear   = string.sub(tags.PatientBirthDate or "19000101", 1, 4)

  local subs = {
    ["${ProjectCode}"]   = project,
    ["${SubjectHash}"]   = subjectHash,
    ["${SessionHash}"]   = sessionHash,
    ["${BirthYearOnly}"] = birthYear
  }

  for tag, template in pairs(profile.Replace or {}) do
    if type(template) == "string" then
      local resolved = template
      for placeholder, value in pairs(subs) do
        resolved = string.gsub(resolved, placeholder, value)
      end
      profile.Replace[tag] = resolved
    end
  end

  return profile, subjectHash, sessionHash
end

function OnStoredInstance(instanceId, tags, metadata, origin)
  -- Skip our own /modify outputs (origin "Lua") to avoid re-deiding deid'd output.
  if origin.RequestOrigin ~= "DicomProtocol" then return end

  local routing  = loadJsonFile(ROUTING_FILE)
  local calledAet = origin.CalledAet or "UNKNOWN"
  local mapping   = routing.AETMap[calledAet]
  if mapping == nil then
    print("REJECT: no project mapped for CalledAET " .. calledAet)
    RestApiDelete("/instances/" .. instanceId)
    return
  end

  local profile   = loadJsonFile(routing.Defaults.DeidentificationProfileFile)
  local backupDir = routing.Defaults.FacilityBackupDir
  local mode      = profile.DeidMode or "modify"

  -- Facility backup with original identifiers.
  local origBytes  = RestApiGet("/instances/" .. instanceId .. "/file")
  local backupPath = backupDir .. "/" ..
                     (tags.PatientID or "UNKNOWN") .. "/" ..
                     (tags.StudyInstanceUID or "UNKNOWN") .. "/" ..
                     (tags.SeriesInstanceUID or "UNKNOWN") .. "/" ..
                     (tags.SOPInstanceUID or instanceId) .. ".dcm"
  if not writeAtomic(backupPath, origBytes) then
    print("ABORT: facility backup write failed for " .. instanceId)
    return
  end

  local subjectHash, sessionHash
  profile, subjectHash, sessionHash = applyPlaceholders(profile, tags, mapping.project)
  profile.DeidMode = nil  -- ais-only field; /modify rejects unknown fields
  local endpoint = "/instances/" .. instanceId .. "/" ..
                   (mode == "anonymize" and "anonymize" or "modify")

  -- /instances/{id}/modify returns DICOM bytes (NOT JSON) and does NOT store
  -- the result. We delete the original then POST the bytes back to /instances
  -- so the deid'd copy lands in Orthanc storage. The profile's Keep block
  -- preserves StudyInstanceUID so it joins the same Study.
  local ok, modifiedBytes = pcall(RestApiPost, endpoint, DumpJson(profile, true))
  if not ok or modifiedBytes == nil or modifiedBytes == "" then
    print("ABORT: " .. endpoint .. " failed: " .. tostring(modifiedBytes))
    return
  end
  RestApiDelete("/instances/" .. instanceId)  -- must delete before POST or UID collides
  local storeOk, storeResp = pcall(RestApiPost, "/instances", modifiedBytes)
  if not storeOk or storeResp == nil or storeResp == "" then
    print("ABORT: POST /instances failed: " .. tostring(storeResp))
    return
  end
  local parsed = ParseJson(storeResp)
  if parsed == nil or parsed["ID"] == nil then
    print("ABORT: POST /instances response has no ID: " .. tostring(storeResp))
    return
  end
  local newId = parsed["ID"]

  print(DumpJson({
    ts          = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    component   = "orthanc-deid",
    event       = "instance_deidentified",
    mode        = mode,
    calledAet   = calledAet,
    project     = mapping.project,
    session     = mapping.project .. "." .. subjectHash .. "." .. sessionHash,
    originalId  = instanceId,
    newId       = newId,
    backupPath  = backupPath
  }, false))
end

function OnStableStudy(studyId, tags, metadata)
  -- Fires StableAge seconds after the last instance arrives. By now
  -- OnStoredInstance has run for every instance; the study contains only
  -- deid'd copies. Label idempotently so sort picks it up (filters
  -- --orthanc-label xnat-ingest-ready and --orthanc-skip-label xnat-ingest-skip).
  RestApiPut("/studies/" .. studyId .. "/labels/xnat-ingest-ready", "")

  print(DumpJson({
    ts        = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    component = "orthanc-deid",
    event     = "study_labeled_ready",
    studyId   = studyId,
    label     = "xnat-ingest-ready"
  }, false))
end
