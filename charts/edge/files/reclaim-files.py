#!/usr/bin/env python3
# =============================================================================
# reclaim-files.py: the filesystem backend of reclaim-staged.sh (tier-1).
# =============================================================================
# reclaim-staged.sh calls --batch once per run; direct session calls remain supported. It deletes a resource only
# when XNAT holds each file of it with the same size, and only the files it proved.
# Exit: 0 removed something, 10 kept, 11 skipped (too young or dry run).
# Any other exit is an error; the caller logs reclaim_failed.
#
# PROOF, per file: the ONE row of the experiment's file listing in the resource the
# uploader maps this folder to, with the same path in it. Then HEAD its URI: only
# 200 with a Content-Length equal to the local size passes. The mapping is the
# uploader's (xnat-ingest 0.16 get_xnat_resource): the same scan id; for a DICOM
# series, the ONE label that xnat_resource_label_from_sop_class gives for the SOP
# classes in the resource's __METADATA__.json (loaded from the installed
# xnat-ingest, so it is the pinned rule); for a non-DICOM folder, its name. All
# files must be in one XNAT resource. Not mapped, so kept: a series split by
# modality (<id>-<modality>), a single DICOM image, and a series whose metadata
# has no SOPClassUID key (the uploader would read the headers).
# CAUTION: the listing alone is not proof. XNAT keeps a row for a file it lost.
# CAUTION: this proves presence and size, NOT content.
#
# DELETE, per session, inside the upload-tree writer lock, while a wrapped writer
# holds <tree>.alive, and only if names and file identities did not change.
# =============================================================================
import base64
import fcntl
import http.client
import importlib.util
import json
import os
import re
import ssl
import stat
import sys
import time
import tempfile
import urllib.parse
from datetime import datetime

E = os.environ
STORAGE = "filesystem"
PROOF = "xnat"
ROOT = E["STAGED_ROOT"].rstrip("/")
DRY_RUN = E.get("DRY_RUN", "true") == "true"
MIN_AGE_S = int(E["MIN_AGE_S"])
TIMEOUT = float(E.get("HTTP_TIMEOUT", "30"))
LOCK_WAIT = float(E.get("LOCK_WAIT", "600"))   # seconds to wait for a writer pass
SIDECARS = {"__MANIFEST__.json", "MANIFEST.json", "__METADATA__.json"}
DICOM_SERIES = {"medimage/dicom-series", "medimage/dicom-dir", "medimage/dicom-collection"}


def sop_label(sop_class_uids):
    """The uploader's own rule, from the installed xnat-ingest. Loaded from its
    file: the module imports only typing, and the package import is not needed."""
    try:
        pkg = importlib.util.find_spec("xnat_ingest")
        path = os.path.join(pkg.submodule_search_locations[0], "helpers", "xnat_scan_types.py")
        spec = importlib.util.spec_from_file_location("xnat_scan_types", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.xnat_resource_label_from_sop_class(sop_class_uids)
    except Exception as e:
        raise Keep("unmapped_resource", f"cannot load the uploader's label rule: {e}")
MANIFESTS = ("__MANIFEST__.json", "MANIFEST.json")
REMOVED, KEPT, SKIPPED = 0, 10, 11


def jlog(event, session, message, **extra):
    """One JSON line, the same shape as jlog() in reclaim-staged.sh."""
    rec = {"ts": datetime.now().astimezone().isoformat(timespec="seconds"),
           "component": "s3-reclaimer", "cluster": E.get("CLUSTER_LABEL", ""),
           "event": event, "session": session, "message": message[:400], **extra}
    print(json.dumps(rec, separators=(",", ":")), flush=True)


class Keep(Exception):
    """Keep the data. reason is the slug that reclaim_kept carries."""

    def __init__(self, reason, message):
        super().__init__(message)
        self.reason = reason


def walk(top):
    """{relpath: "dir" or file identity}. A write, truncate, replace or new hard
    link changes the identity. A link or special file stops the walk."""
    out = {}
    for dirpath, dirnames, filenames in os.walk(top):
        for name in dirnames + filenames:
            path = os.path.join(dirpath, name)
            st = os.lstat(path)
            if stat.S_ISDIR(st.st_mode):
                out[os.path.relpath(path, top)] = "dir"
            elif stat.S_ISREG(st.st_mode):
                out[os.path.relpath(path, top)] = (st.st_dev, st.st_ino, st.st_size,
                                                   st.st_mtime_ns, st.st_ctime_ns)
            else:
                raise Keep("unknown_entry", f"{path} is not a regular file or folder")
    return out


def newest_ctime(top):
    # ctime, not mtime: assign hard-links files, so mtime is Orthanc's old write
    # time, while each new link updates ctime.
    return max([os.lstat(top).st_ctime] + [os.lstat(os.path.join(d, n)).st_ctime
                                           for d, ds, fs in os.walk(top) for n in ds + fs])


class Resource:
    """One resource folder, as it was before the proof."""

    def __init__(self, scan_id, path):
        self.scan_id, self.path = scan_id, path
        self.entries = walk(path)
        if any(n.startswith(".") or "/." in n for n in self.entries):
            raise Keep("unknown_entry", f"{path} has a hidden entry")
        files = [n for n, i in self.entries.items() if i != "dir"]
        self.sidecars = [n for n in files if n in SIDECARS]
        self.data = {n: self.entries[n] for n in files if n not in SIDECARS}
        self.sums, self.label = self.manifest() if self.data else ({}, None)
        extra = sorted(set(self.data) - set(self.sums))
        if extra:
            raise Keep("manifest_incomplete", f"{path}/{extra[0]} is named by no manifest")

    def manifest(self):
        """The checksums, and the XNAT label the uploader gives this folder."""
        # The manifest can name more files than are here after a stopped delete;
        # the proof then covers those too.
        for name in MANIFESTS:
            if name in self.sidecars:
                try:
                    with open(os.path.join(self.path, name)) as f:
                        m = json.load(f)
                    sums = {str(k): str(v) for k, v in m["checksums"].items()}
                except Exception:
                    raise Keep("manifest_unreadable", f"cannot read {self.path}/{name}")
                return sums, self.xnat_label(str(m.get("datatype", "")))
        raise Keep("manifest_unreadable", f"{self.path} has data files and no manifest")

    def xnat_label(self, datatype):
        name = os.path.basename(self.path)
        if datatype in DICOM_SERIES:
            # The uploader reads SOPClassUID from this sidecar. When the KEY is
            # absent it reads the DICOM headers instead, which this does not:
            # keep. An explicit empty value makes the uploader keep the name.
            try:
                with open(os.path.join(self.path, "__METADATA__.json")) as f:
                    meta = json.load(f)
            except FileNotFoundError:
                raise Keep("unmapped_resource", f"{self.path} has no __METADATA__.json; the uploader would read the headers")
            except Exception:
                raise Keep("manifest_unreadable", f"cannot read {self.path}/__METADATA__.json")
            if "SOPClassUID" not in meta:
                raise Keep("unmapped_resource", f"{self.path}: no SOPClassUID in __METADATA__.json; the uploader would read the headers")
            return sop_label(meta["SOPClassUID"]) if meta["SOPClassUID"] else name
        if datatype.endswith("+zip"):
            # A zipped series (the package stage's DICOM-zip) is one archive
            # file. The uploader keeps the folder name for it: it is neither a
            # DICOM collection nor a DICOM image, so no header decides.
            return name
        if datatype.startswith("medimage/dicom"):
            # Includes a single DICOM image: the uploader takes its label from
            # the image header and refuses a folder that differs. Not mapped.
            raise Keep("unmapped_resource", f"{self.path}: DICOM datatype {datatype} is not mapped")
        return name   # not DICOM: the uploader keeps the folder name

    def prove(self, xnat, index):
        """Raise Keep unless XNAT holds every file that the manifest names, all in
        the one resource that the uploader maps this folder to."""
        resources = set()
        for rel in sorted(self.sums):
            rows = [r for r in index.get(rel, ()) if r[0] == self.scan_id and r[1] == self.label]
            where = f"{self.path}/{rel}"
            if not rows and any(r[0].startswith(self.scan_id + "-") for r in index.get(rel, ())):
                raise Keep("unmapped_resource", f"{where}: XNAT holds it in a scan split by modality; not mapped")
            if len(rows) != 1:
                raise Keep("incomplete_in_xnat" if not rows else "xnat_ambiguous",
                           f"{where}: {len(rows)} rows in scan {self.scan_id}, resource {self.label}")
            _, _, rid, uri, digest = rows[0]
            resources.add(rid)
            if len(resources) > 1:
                raise Keep("xnat_ambiguous", f"{self.path}: its files are in more than one XNAT resource")
            if digest and digest != self.sums[rel]:
                raise Keep("digest_mismatch", f"{where}: the XNAT digest is not the manifest MD5")
            size = xnat.head_size(uri)
            if rel in self.data and size != self.data[rel][2]:
                raise Keep("size_mismatch", f"{where}: XNAT has {size} bytes, the local file {self.data[rel][2]}")

    def remove(self):
        """Inside the lock. Data first, the manifest last, then the folders."""
        if walk(self.path) != self.entries:
            raise Keep("changed_during_check", f"{self.path} changed after the proof")
        for rel in sorted(self.data) + sorted(self.sidecars, key=lambda n: n in MANIFESTS):
            os.unlink(os.path.join(self.path, rel))
        dirs = [n for n, i in self.entries.items() if i == "dir"]
        for rel in sorted(dirs, key=len, reverse=True) + ["."]:
            os.rmdir(os.path.normpath(os.path.join(self.path, rel)))   # refuses a non-empty folder


class Xnat:
    """Reuse transport and authentication, never response data. Do not follow redirects."""

    def __init__(self):
        url = urllib.parse.urlsplit(E["XNAT_SERVER"])
        self.prefix = url.path.rstrip("/")
        if url.scheme == "https":
            ctx = ssl.create_default_context()
            if E.get("XNAT_VERIFY_SSL", "true") != "true":
                ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
            self.conn = http.client.HTTPSConnection(url.hostname, url.port, timeout=TIMEOUT, context=ctx)
        else:
            self.conn = http.client.HTTPConnection(url.hostname, url.port, timeout=TIMEOUT)
        token = base64.b64encode(f"{E.get('XNAT_USER', '')}:{E.get('XNAT_PASS', '')}".encode()).decode()
        self.basic = {"Authorization": "Basic " + token}
        self.owned = False
        self.headers = ({"Cookie": "JSESSIONID=" + E["XNAT_JSESSION"]}
                        if E.get("XNAT_JSESSION") else dict(self.basic))

    def raw_request(self, method, path, query="", headers=None):
        path = urllib.parse.quote(urllib.parse.unquote(path), safe="/:@")
        if self.prefix and not path.startswith(self.prefix + "/"):
            path = self.prefix + path
        auth = self.headers if headers is None else headers
        try:
            self.conn.request(method, path + ("?" + query if query else ""),
                              headers={**auth, "Cache-Control": "no-cache", "Pragma": "no-cache"})
            resp = self.conn.getresponse()
            body = resp.read()
        except (OSError, http.client.HTTPException) as exc:
            self.conn.close()
            raise Keep("xnat_check_failed", f"{method} {path}: {exc}")
        return resp.status, resp.headers, body

    @staticmethod
    def cookie(headers):
        match = re.search(r"JSESSIONID=([^;\s]+)", " ".join(headers.get_all("Set-Cookie") or []))
        return match.group(1) if match else None

    def login(self):
        if self.owned:
            self.close()  # a permission failure can leave the old login valid
        status, headers, body = self.raw_request("GET", "/data/JSESSION", headers=self.basic)
        token = self.cookie(headers)
        if token is None:
            token = body.decode(errors="replace").strip()
        if status != 200 or not re.fullmatch(r"[A-Za-z0-9._-]{1,256}", token):
            raise Keep("xnat_check_failed", f"XNAT re-authentication failed: HTTP {status}")
        self.headers, self.owned = {"Cookie": "JSESSIONID=" + token}, True
        jlog("xnat_session_opened", "", "reusing one XNAT session for this run")

    def request(self, method, path, query=""):
        status, headers, body = self.raw_request(method, path, query)
        if method != "DELETE" and (status in (401, 403) or 300 <= status < 400):
            # One bounded refresh. An auth response is never an absence result.
            self.login()
            status, headers, body = self.raw_request(method, path, query)
            if status in (401, 403) or 300 <= status < 400:
                raise Keep("xnat_check_failed", f"{method} {path}: HTTP {status} after re-authentication")
        elif "Authorization" in self.headers:
            token = self.cookie(headers)
            if token:
                self.headers, self.owned = {"Cookie": "JSESSIONID=" + token}, True
        return status, headers, body

    def close(self):
        # A signal can interrupt an in-flight response. Logout needs a fresh
        # transport even when that old connection is still Request-sent.
        self.conn.close()
        if self.owned:
            try:
                status, _, _ = self.raw_request("DELETE", "/data/JSESSION")
                if status != 200:
                    jlog("xnat_session_close_failed", "",
                         f"the XNAT logout returned HTTP {status}; XNAT keeps this session until it times out")
            except Keep as exc:
                jlog("xnat_session_close_failed", "", str(exc))
        self.conn.close()
        self.owned = False

    def rows(self, path, what, absent=None):
        status, _, body = self.request("GET", path, "format=json")
        if status == 404 and absent:
            raise Keep(absent, f"{what}: HTTP 404, not found at lookup")
        if status != 200:
            raise Keep("xnat_check_failed", f"{what}: HTTP {status}")
        try:
            rows = json.loads(body)["ResultSet"]["Result"]
            if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
                raise ValueError("invalid rows")
            return rows
        except Exception:
            raise Keep("xnat_check_failed", f"{what}: the answer is not the expected JSON")

    def file_index(self, project, subject, visit):
        want = (visit, f"{subject}_{visit}")
        exps = [r["ID"] for r in self.rows(f"/data/projects/{project}/subjects/{subject}/experiments",
                                           "experiment lookup", absent="incomplete_in_xnat")
                if r.get("label") in want or r.get("ID") in want]
        if not exps:
            raise Keep("incomplete_in_xnat", "XNAT has no experiment for this session")
        if len(exps) != 1:
            raise Keep("xnat_ambiguous", "XNAT lists more than one experiment for this session")
        # The file catalog may outlive the experiment or its file bodies. Check
        # the experiment endpoint before the catalog, then still HEAD each file.
        status, _, body = self.request("GET", f"/data/experiments/{exps[0]}", "format=json")
        if status == 404:
            raise Keep("incomplete_in_xnat", "experiment endpoint: HTTP 404, not found at lookup")
        if status != 200:
            raise Keep("xnat_check_failed", f"experiment endpoint: HTTP {status}")
        try:
            experiment = json.loads(body)
            if not isinstance(experiment, dict) or not experiment:
                raise ValueError("invalid experiment")
        except Exception:
            raise Keep("xnat_check_failed", "experiment endpoint: the answer is not the expected JSON")
        index = {}
        for row in self.rows(f"/data/experiments/{exps[0]}/scans/ALL/files", "file listing"):
            match = re.match(r"^.*?/scans/([^/]+)/resources/([^/]+)/files/(.+)$", row.get("URI") or "")
            if match:
                scan, res, rel = (urllib.parse.unquote(g) for g in match.groups())
                label, rid = str(row.get("collection") or res), str(row.get("cat_ID") or res)
                index.setdefault(rel, []).append((scan, label, rid, row["URI"], str(row.get("digest") or "")))
        return index

    def head_size(self, uri):
        status, headers, _ = self.request("HEAD", uri)
        length = headers.get("Content-Length", "")
        if status == 404:
            raise Keep("incomplete_in_xnat", f"HEAD {uri}: 404, XNAT lists the file and does not have it")
        if status != 200 or not length.isdigit():
            raise Keep("xnat_check_failed", f"HEAD {uri}: HTTP {status}, Content-Length {length!r}")
        return int(length)


class WriterLock:
    """The pass lock, exclusive, and proof that a wrapped writer runs now: it holds
    a SHARED lock on .alive for its life. Only genuine contention (EWOULDBLOCK)
    counts; a lock error is never evidence."""

    def __enter__(self):
        lock, alive = E.get("WRITER_LOCK", ""), E.get("WRITER_ALIVE", "")
        if not lock or not alive:
            raise Keep("lock_error", "WRITER_LOCK or WRITER_ALIVE is not set")
        self.fd = self.open(lock, os.O_RDWR | os.O_CREAT)
        deadline = time.monotonic() + LOCK_WAIT
        try:
            while not self.try_lock(self.fd, lock):
                if time.monotonic() >= deadline:
                    raise Keep("lock_timeout", f"a writer pass held {lock} for {LOCK_WAIT:.0f}s")
                time.sleep(0.5)
            afd = self.open(alive, os.O_RDONLY, missing="writer_not_alive")
            try:
                got = self.try_lock(afd, alive)
            finally:
                os.close(afd)   # also releases .alive if we got it
            if got:
                raise Keep("writer_not_alive", f"no process holds {alive}: a writer without the lock may run")
        except Keep:
            os.close(self.fd)
            raise
        return self

    def __exit__(self, *exc):
        os.close(self.fd)   # releases the pass lock

    @staticmethod
    def open(path, flags, missing="lock_error"):
        try:
            return os.open(path, flags, 0o644)
        except FileNotFoundError:
            raise Keep(missing, f"{path} does not exist" + (": no wrapped writer has run" if missing != "lock_error" else ""))
        except OSError as e:
            raise Keep("lock_error", f"{path}: {e}")

    @staticmethod
    def try_lock(fd, path):
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            return False
        except OSError as e:
            raise Keep("lock_error", f"{path}: {e}")


def only_sidecars(path, act):
    """True if the folder holds sidecars only. With act=True, also remove it."""
    if not all(n in SIDECARS for n in os.listdir(path)):
        return False
    if act:
        for n in os.listdir(path):
            os.unlink(os.path.join(path, n))
        os.rmdir(path)
    return True


def tidy(sdir, unknown, act):
    """Scan folders with only sidecars, then the session folder if it has only
    sidecars. With act=False only say whether there is something to remove."""
    found = False
    for scan in sorted(os.listdir(sdir)):
        spath = os.path.join(sdir, scan)
        if scan in SIDECARS or scan in unknown or os.path.islink(spath) or not os.path.isdir(spath):
            continue
        found = only_sidecars(spath, act) or found
    return only_sidecars(sdir, act) or found


def reclaim(session, *, s3=None, xnat=None):
    sdir = os.path.join(ROOT, session)
    parts = session.split(".")
    if len(parts) != 3 or not all(parts) or not os.path.isdir(sdir):
        raise Keep("unsafe_prefix_name", "not a project.subject.visit session folder")
    now = int(E.get("RECLAIM_NOW") or time.time())   # RECLAIM_NOW: tests only (ctime cannot be set back)
    age = now - int(newest_ctime(sdir))
    if age < MIN_AGE_S:
        jlog("reclaim_skipped", session,
             f"last written {age}s ago, minAge is {E.get('MIN_AGE')} ({MIN_AGE_S}s) from {E.get('MIN_AGE_KEY')}",
             age_s=age)
        return SKIPPED
    if E.get("VERIFY_XNAT", "true") != "true":
        raise Keep("verify_disabled", "verifyAgainstXnat=false: the filesystem backend deletes only what XNAT proves")

    # Snapshot. A scan folder is <id>.<type>. Its dot entries are the uploader's
    # batches: never deleted here, as one can hold the only link to unproved data.
    resources, kept, unknown, batches = [], [], [], []
    for scan in sorted(os.listdir(sdir)):
        spath = os.path.join(sdir, scan)
        if scan in SIDECARS:
            continue
        if scan.startswith(".") or "." not in scan or os.path.islink(spath) or not os.path.isdir(spath):
            unknown.append(scan)
            continue
        for res in sorted(os.listdir(spath)):
            rpath = os.path.join(spath, res)
            if res in SIDECARS:
                continue
            if res.startswith("."):
                batches.append(rpath)
                continue
            try:
                if os.path.islink(rpath) or not os.path.isdir(rpath):
                    raise Keep("unknown_entry", f"{rpath} is not a resource folder")
                resources.append(Resource(scan.split(".", 1)[0], rpath))
            except Keep as k:
                kept.append(k)

    # Proof, outside the lock.
    if resources:
        owned_xnat = xnat is None
        xnat = xnat or Xnat()
        try:
            index = xnat.file_index(*parts)
            for res in list(resources):
                try:
                    res.prove(xnat, index)
                except Keep as k:
                    kept.append(k)
                    resources.remove(res)
        finally:
            if owned_xnat:
                xnat.close()
    nfiles = sum(len(r.data) for r in resources)
    if resources and not kept and not unknown:
        jlog("reclaim_confirmed", session,
             f"XNAT holds each of the {nfiles} file(s) of this session with the same size (HEAD); content is not verified",
             resources=len(resources), have=nfiles)
    if not resources and not tidy(sdir, unknown, act=False):
        return report_kept(session, kept, unknown, batches, 0)
    if DRY_RUN:
        jlog("reclaim_skipped", session, f"dataPolicy dryRun/disabled: would have removed {len(resources)} proven resource(s)",
             resources=len(resources), kept_resources=len(kept))
        return SKIPPED

    # Delete, inside the lock.
    removed = 0
    with WriterLock():
        for res in resources:
            try:
                res.remove()
            except Keep as k:
                kept.append(k)
                continue
            removed += 1
            jlog("reclaim_resource_removed", session, f"removed {res.path}: {len(res.data)} file(s) proved in XNAT",
                 files=len(res.data))
        tidy(sdir, unknown, act=True)
        gone = not os.path.lexists(sdir)
    if not gone:
        report_kept(session, kept, unknown, batches, removed)
        return REMOVED if removed else KEPT
    if not nfiles and not removed:
        # No data files are left to deliver. Say so, or SessionStagedNotConfirmedInXNAT
        # fires 48h later for a folder that is gone on purpose.
        jlog("reclaim_confirmed", session, "the session folder holds no data files: nothing left to deliver",
             resources=0, have=0, empty=True)
    jlog("reclaim_removed", session, f"removed {sdir}", resources=removed)
    return REMOVED


def report_kept(session, kept, unknown, batches, removed):
    reasons = (kept + [Keep("unknown_entry", f"{session}/{u} is not a scan folder") for u in unknown]
               + [Keep("upload_batch_present", f"{b}: an upload is running, or a stopped one left it; "
                       "it can hold the only link to unproved data, so it stays") for b in batches]
               + [Keep("not_settled", "the session folder still holds entries this run did not prove")])
    jlog("reclaim_kept", session, str(reasons[0]), reason=reasons[0].reason,
         removed_resources=removed, kept_resources=len(kept) + len(unknown) + len(batches))
    return KEPT


BATCH_UNAVAILABLE = 20  # pre-flight style abort already logged by the worker
BATCH_S3 = False


def session_names(s3=None):
    """Discover names only. The per-session snapshot must be taken later."""
    with os.scandir(ROOT) as entries:
        for entry in entries:
            if entry.is_dir(follow_symlinks=False) and not entry.name.startswith("__"):
                yield entry.name


def batch():
    """One worker and shared connections; no listing or proof survives a session."""
    s3 = None
    xnat = Xnat() if PROOF == "xnat" and E.get("VERIFY_XNAT", "true") == "true" else None
    counts = dict(examined=0, removed=0, kept=0, skipped=0)
    if BATCH_S3:
        counts["empty"] = 0
    # Finish discovery before the first delete, as the shell did. Spool names to
    # disk instead of retaining every prefix or every session's objects in RAM.
    try:
        with tempfile.TemporaryFile(mode="w+t") as names:
            try:
                for name in session_names(s3):
                    names.write(json.dumps(name) + "\n")
            except Exception as exc:
                message = f"listing staging failed: {exc}; nothing examined"
                jlog("reclaim_unavailable", "", message, reason="staging_list_failed")
                names.seek(0)
                for number, line in enumerate(names):
                    if number >= int(E.get("UNAVAILABLE_SESSION_CAP", "500")):
                        jlog("reclaim_unavailable", "", "staged session report reached the cap",
                             reason="staging_list_failed", truncated=True)
                        break
                    jlog("reclaim_unavailable", json.loads(line),
                         "staged, and this run could not decide anything about it: " + message,
                         reason="staging_list_failed")
                return BATCH_UNAVAILABLE
            names.seek(0)
            for line in names:
                session = json.loads(line)
                if not session:
                    continue
                counts["examined"] += 1
                if session == ".reclaim-state":
                    continue
                if not re.fullmatch(r"[A-Za-z0-9._-]+", session) or session.startswith((".", "-", "__")):
                    jlog("reclaim_kept", session,
                         "prefix name is not a plain [A-Za-z0-9._-] session id — refusing to pass it on",
                         reason="unsafe_prefix_name")
                    counts["kept"] += 1
                    continue
                cap = int(E.get("MAX_REMOVALS", "50"))
                if counts["removed"] >= cap:
                    jlog("reclaim_skipped", "", f"per-run removal cap of {cap} reached — remaining sessions left for the next run")
                    break
                try:
                    rc = reclaim(session, s3=s3, xnat=xnat)
                except Keep as exc:
                    jlog("reclaim_kept", session, str(exc), reason=exc.reason)
                    rc = KEPT
                except Exception as exc:
                    # Equivalent to a failed child process: keep the remaining
                    # data and make this session's failure visible.
                    jlog("reclaim_failed", session, f"reclaim-files.py stopped for this session: {type(exc).__name__}: {exc}")
                    rc = KEPT
                key = {0: "removed", 10: "kept", 11: "skipped", 12: "empty"}.get(rc)
                if key not in counts:
                    jlog("reclaim_failed", session, f"reclaim-files.py stopped with exit {rc}; nothing more was done for this session")
                    key = "kept"
                counts[key] += 1
        jlog("reclaim_finished", "", " ".join(f"{k}={v}" for k, v in counts.items()), **counts)
        return 0
    finally:
        if xnat is not None:
            xnat.close()
        if s3 is not None:
            s3.close()


def main():
    if sys.argv[1] == "--batch":
        return batch()
    session = sys.argv[1]
    try:
        return reclaim(session)
    except Keep as k:
        jlog("reclaim_kept", session, str(k), reason=k.reason)
        return KEPT


if __name__ == "__main__":
    # A stop can interrupt an HTTP operation or a sequence of conditional
    # deletes. Raising runs the writer-lock and XNAT cleanup finally blocks.
    # Each unlink/DeleteObject is atomic; the manifest is removed last.
    import signal
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda signum, frame: sys.exit(128 + signum))
    sys.exit(main())
