#!/usr/bin/env python3
# =============================================================================
# reclaim-files.py: the per-session deleter of reclaim-staged.sh.
# =============================================================================
# reclaim-staged.sh calls this once per session name. STORAGE=filesystem: the
# session is a folder of the upload tree (tier-1, and direct mode on main).
# STORAGE=s3: the session is a prefix of the staging bucket (the mgmt reclaimer).
# Exit: 0 removed something, 10 kept, 11 skipped (too young or dry run), 12 nothing
# there. Any other exit is an error; the caller logs reclaim_failed.
# `--list` prints the session prefixes of the bucket; `--probe` checks it answers.
#
# PROOF, per file: the ONE row of the experiment's file listing in the resource the
# uploader maps this folder to, with the same path in it. Then HEAD its URI: only
# 200 with a Content-Length equal to the staged size passes. The mapping is the
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
# PROOF=s3 (the edge in S3 mode, STORAGE=filesystem): the bucket is the next copy,
# so each local file is proven by its object: the session prefix is listed once,
# and the file passes when the object with its key has the file's size and an
# ETag equal to the MD5 of the bytes read now, or the multipart form of it for
# S3_CHUNK_SIZE or rclone's 5 MiB default. The identity of the file (inode, size,
# times) is taken before the hash and checked after it. A resource is removed only
# when its data files and its sidecars pass; the session's and the scans' own
# sidecars (the parent __METADATA__.json files) must pass too when anything is
# removed, and their identities are checked again inside the lock, before any
# data goes and before each is unlinked. The age has TWO clocks here: the newest
# local ctime AND the newest object's LastModified in the bucket must both be
# older than minAge, so a backlog of old files copied today still waits its
# window. A file that fails gets a repair request for the uploader (a file named
# for the session under RECOPY_DIR; not in a dry run) and the session is kept;
# XNAT is not consulted.
#
# DELETE, per session. A folder: inside the upload-tree writer lock, while a
# wrapped writer holds <tree>.alive, and only if names and file identities did not
# change; data first, the manifest last, empty folders after. A prefix: one
# DeleteObject per object with If-Match set to the ETag this run listed before the
# proof, data first, the manifest last; an object that changed answers 412 and
# stays. Folders in the bucket are never deleted: a filer folder delete can drop a
# child written after its check, and the uploader's listing skips empty folders.
# =============================================================================
import base64
import contextlib
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
import urllib.parse
from datetime import datetime

E = os.environ
STORAGE = E.get("STORAGE", "filesystem")
PROOF = E.get("PROOF", "xnat")   # xnat: the row and HEAD in XNAT; s3: the object and MD5 in S3 (edge, S3 mode)
ROOT = E.get("STAGED_ROOT", "").rstrip("/")
DRY_RUN = E.get("DRY_RUN", "true") == "true"
MIN_AGE_S = int(E.get("MIN_AGE_S", "0"))
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
REMOVED, KEPT, SKIPPED, EMPTY = 0, 10, 11, 12


def jlog(event, session, message, **extra):
    """One JSON line, the same shape as jlog() in reclaim-staged.sh."""
    # proof: what a decision rests on (xnat or s3). SessionStagedNotConfirmedInXNAT
    # counts only an XNAT proof as delivery; the edge's bucket proof is not one.
    rec = {"ts": datetime.now().astimezone().isoformat(timespec="seconds"),
           "component": "s3-reclaimer", "cluster": E.get("CLUSTER_LABEL", ""), "proof": PROOF,
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


def parse_size(text):
    """A Kubernetes-style quantity (64Mi, 5M, 1048576) in bytes."""
    m = re.fullmatch(r"\s*(\d+)\s*([KMGT]i?)?\s*", text or "")
    if not m:
        raise Keep("bad_chunk_size", f"S3_CHUNK_SIZE={text!r} is not a size")
    unit = {"": 1, "K": 10 ** 3, "M": 10 ** 6, "G": 10 ** 9, "T": 10 ** 12,
            "Ki": 1 << 10, "Mi": 1 << 20, "Gi": 1 << 30, "Ti": 1 << 40}[m.group(2) or ""]
    return int(m.group(1)) * unit


def identity(path):
    """The file identity the delete path rechecks: a regular file, or Keep."""
    st = os.lstat(path)
    if not stat.S_ISREG(st.st_mode):
        raise Keep("unknown_entry", f"{path} is not a regular file")
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)


def hashes(path, part_sizes):
    """One pass over the file: the MD5 of the whole, and for each part size the
    multipart ETag form, md5(part md5s)-<parts>, as S3 lists a multipart upload."""
    import hashlib, math
    block = math.gcd(*part_sizes)
    whole, parts = hashlib.md5(), {p: ([], hashlib.md5(), 0) for p in part_sizes}
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(block), b""):
            whole.update(chunk)
            for p, (done, cur, filled) in parts.items():
                cur.update(chunk)
                filled += len(chunk)
                if filled >= p:
                    done.append(cur.digest()); cur, filled = hashlib.md5(), 0
                parts[p] = (done, cur, filled)
    forms = {}
    for p, (done, cur, filled) in parts.items():
        if filled:
            done.append(cur.digest())
        forms[p] = f"{hashlib.md5(b''.join(done)).hexdigest()}-{len(done)}"
    return whole.hexdigest(), forms


def list_prefix(s3, bucket, prefix, what):
    """{rel: (ETag, size, LastModified epoch)} of the objects under prefix, from a
    COMPLETE listing, or Keep. Every page must carry an explicit IsTruncated, every
    truncated page a new continuation token, and the last page IsTruncated false:
    botocore stops quietly on a truncated page that has no token (codex-191, codex-193),
    and a listing that ended that way hides the objects of the pages it did not reach.
    This run deletes on what it lists, so an incomplete listing keeps everything. A key
    listed twice with different attributes, or outside the prefix, keeps as well."""
    out, tokens, complete = {}, set(), False
    try:
        for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix):
            if complete or not isinstance(page.get("IsTruncated"), bool):
                raise Keep("listing_incomplete", f"{what}: a page without a completion marker")
            if page["IsTruncated"]:
                token = page.get("NextContinuationToken")
                if not isinstance(token, str) or not token or token in tokens:
                    raise Keep("listing_incomplete", f"{what}: a truncated page without a new continuation token")
                tokens.add(token)
            else:
                complete = True
            for o in page.get("Contents") or []:
                key = o["Key"]
                if not key.startswith(prefix):
                    raise Keep("listing_incomplete", f"{what}: {key} is outside the prefix asked for")
                rel = key[len(prefix):]
                if not rel or rel.endswith("/"):
                    continue
                rec = (o["ETag"].strip('"'), int(o["Size"]), o["LastModified"].timestamp())
                if rel in out and out[rel] != rec:
                    raise Keep("listing_incomplete", f"{what}: {rel} listed twice with different attributes")
                out[rel] = rec
    except Keep:
        raise
    except Exception as e:
        raise Keep("listing_failed", f"cannot list {prefix}: {e}")
    if not complete:
        raise Keep("listing_incomplete", f"{what}: the listing ended without its last page")
    return out


class S3Proof:
    """PROOF=s3: the local files of one session, proven by their objects in the
    staging bucket (see the header). The prefix is listed once; a file that fails
    gets a repair request, and the Keep says so."""

    def __init__(self, session):
        import boto3
        from botocore.config import Config
        cert = E.get("S3_CLIENT_CERT")   # mTLS on the upload path: the same pair the uploader uses
        self.s3 = boto3.client("s3", config=Config(client_cert=(cert, E["S3_CLIENT_KEY"])) if cert else None)
        self.bucket, self.session = E["S3_BUCKET"], session
        self.prefix = f"{E.get('S3_PREFIX', 'staged').strip('/')}/{session}/"
        self.parts = sorted({parse_size(E.get("S3_CHUNK_SIZE", "64Mi")), 5 << 20})
        self.requested = False
        self.objects = list_prefix(self.s3, self.bucket, self.prefix, "the proof's listing")   # rel: (etag, size, modified epoch)

    def newest(self):
        """When the newest object of the session reached the bucket (None: no object)."""
        return max((m for _, _, m in self.objects.values()), default=None)

    def refresh(self, rels):
        """INSIDE THE LOCK, before the first unlink: list the prefix again and require
        every object this run proved (rels) to be there as it was listed before the
        proof: the same ETag, size AND LastModified. The proof ran outside the lock,
        so between it and the lock the uploader can copy the session again (the same
        bytes: identical ETag, a fresh LastModified, so the bucket clock restarts) or
        the management reclaimer or a fault can remove or rewrite an object. A proof
        from before either is stale. A missing or different object asks for a repair;
        a fresh one is kept without a request (the next run proves it when it is old
        enough). The lock does not hold the bucket still; this makes the proof and
        the delete belong to the same observed generation of the objects, no more."""
        live = list_prefix(self.s3, self.bucket, self.prefix, "the listing inside the lock")
        for rel in sorted(rels):
            was, now = self.objects.get(rel), live.get(rel)
            if now is None:
                raise self.repair("not_in_s3", f"{rel}: the object went between the proof and the lock")
            if now[:2] != was[:2]:
                raise self.repair("s3_mismatch", f"{rel}: the object changed between the proof and the lock")
            if now[2] != was[2]:
                raise Keep("s3_changed_after_proof", f"{rel}: the object was written again between the proof and the lock "
                                                     f"(the same bytes, a new LastModified); the bucket clock restarts")

    def prove(self, path, rel):
        """The local file at path, whose key is <session>/<rel>: Keep unless its
        object has its size and the MD5 of its bytes."""
        before = identity(path)
        whole, forms = hashes(path, self.parts)
        if identity(path) != before:
            raise Keep("changed_during_check", f"{rel} changed while it was hashed")
        obj = self.objects.get(rel)
        if obj is None:
            raise self.repair("not_in_s3", f"{rel}: no object in the bucket")
        etag, size, _ = obj
        if size != before[2]:
            raise self.repair("s3_mismatch", f"{rel}: the object has {size} bytes, the file {before[2]}")
        if etag == whole or etag in forms.values():
            return
        if "-" in etag and etag.rsplit("-", 1)[1].isdigit():
            raise Keep("unknown_layout", f"{rel}: a multipart object in parts of a size this run does not compute ({etag}); an operator must check it")
        raise self.repair("s3_mismatch", f"{rel}: the object's ETag is not the MD5 of the file")

    def repair(self, reason, message):
        """A request for the uploader to copy the session again, once per run and
        session, never in a dry run. Returns the Keep to raise."""
        d = E.get("RECOPY_DIR")
        if DRY_RUN or not d or self.requested:
            return Keep(reason, message)
        self.requested = True
        try:
            os.makedirs(d, exist_ok=True)
            tmp = os.path.join(d, f".{self.session}.tmp")
            with open(tmp, "w") as f:
                f.write(f"{datetime.now().astimezone().isoformat(timespec='seconds')} {reason} {message}\n")
            if os.path.exists(os.path.join(d, self.session)):
                os.unlink(tmp)   # an earlier request stands; the uploader serves it
            else:
                os.rename(tmp, os.path.join(d, self.session))
            jlog("recopy_requested", self.session, f"asked the uploader to copy the session again: {message}", reason=reason)
        except OSError as e:
            return Keep("recopy_request_failed", f"{message}; and the repair request could not be written: {e}")
        return Keep(reason, f"{message}; re-copy requested")


def newest_ctime(top):
    # ctime, not mtime: assign hard-links files, so mtime is Orthanc's old write
    # time, while each new link updates ctime.
    return max([os.lstat(top).st_ctime] + [os.lstat(os.path.join(d, n)).st_ctime
                                           for d, ds, fs in os.walk(top) for n in ds + fs])


def sidecar_digest(path):
    """MD5 of a small sidecar's bytes, bound to its identity before and after the read."""
    import hashlib
    before = identity(path)
    with open(path, "rb") as f:
        digest = hashlib.md5(f.read()).hexdigest()
    if identity(path) != before:
        raise Keep("changed_during_check", f"{path} changed while it was read")
    return digest


class LocalStore:
    """A session folder of the upload tree. Paths are relative to it."""

    def __init__(self, session):
        self.path = os.path.join(ROOT, session)
        if not os.path.isdir(self.path):
            raise Keep("unsafe_prefix_name", "not a session folder")

    def newest(self):
        return newest_ctime(self.path)

    def names(self, rel=""):
        """{name: "dir" | "file" | "other"} of the folder's direct entries."""
        out = {}
        for n in os.listdir(os.path.join(self.path, rel)):
            p = os.path.join(self.path, rel, n)
            out[n] = "other" if os.path.islink(p) else "dir" if os.path.isdir(p) else "file" if os.path.isfile(p) else "other"
        return out

    def entries(self, rel):
        return walk(os.path.join(self.path, rel))

    @staticmethod
    def size(identity):
        return identity[2]

    def read(self, rel):
        with open(os.path.join(self.path, rel), "rb") as f:
            return f.read()

    def lock(self):
        return WriterLock()

    def remove(self, res):
        """Inside the lock. Data first, the manifest last, then the folders. The
        identities of every entry, and the bytes of the sidecars, as at the snapshot."""
        top = os.path.join(self.path, res.rel)
        if walk(top) != res.entries:
            raise Keep("changed_during_check", f"{res.rel} changed after the proof")
        for rel, digest in res.sidecar_sums.items():
            if sidecar_digest(os.path.join(top, rel)) != digest:
                raise Keep("changed_during_check", f"{res.rel}/{rel} was rewritten after the proof")
        for rel in sorted(res.data) + sorted(res.sidecars, key=lambda n: n in MANIFESTS):
            os.unlink(os.path.join(top, rel))
        dirs = [n for n, i in res.entries.items() if i == "dir"]
        for rel in sorted(dirs, key=len, reverse=True) + ["."]:
            os.rmdir(os.path.normpath(os.path.join(top, rel)))   # refuses a non-empty folder

    def parent_sidecars(self, scans):
        """{rel: (identity, MD5)} of the sidecar FILES at the session root and at the
        root of each scan folder named: the session's and the scans' own metadata,
        which tidy() unlinks last. The bytes are hashed as well as the identity: the
        kernel stamps mtime and ctime at tick granularity (milliseconds), so a
        same-size rewrite within the tick of the previous write has the same
        identity (codex-188's probe); these files are small. A sidecar that is not a
        regular file keeps the session."""
        out = {}
        for base in [""] + list(scans):
            for n in sorted(os.listdir(os.path.join(self.path, base))):
                if n in SIDECARS:
                    rel = f"{base}/{n}" if base else n
                    path = os.path.join(self.path, rel)
                    out[rel] = (identity(path), sidecar_digest(path))
        return out

    def tidy(self, resources, kept_rels, batches, unknown, act, proven=None):
        """Scan folders with only sidecars, then the session folder if it has only
        sidecars. With act=False only say whether there is something to remove. A
        kept resource or a batch is a folder with files, so its scopes are never
        "only sidecars"; the lists are for the prefix store. proven: the parent
        sidecars this run snapshotted and proved ({rel: identity}); a sidecar not
        in it, or whose identity changed, then keeps the session. None is the one
        deliberate case: a leftover folder that held no data at the start of the
        run, whose sidecars describe nothing."""
        found = False
        for scan in sorted(os.listdir(self.path)):
            spath = os.path.join(self.path, scan)
            if scan in SIDECARS or scan in unknown or os.path.islink(spath) or not os.path.isdir(spath):
                continue
            found = only_sidecars(spath, act, proven, scan) or found
        return only_sidecars(self.path, act, proven, "") or found

    def gone(self):
        return not os.path.lexists(self.path)


class S3Store:
    """A session prefix of the staging bucket. The objects are listed ONCE, before
    the proof; a delete names the ETag of that listing (If-Match), so an object
    rewritten after it stays. Folders are never deleted."""

    def __init__(self, session):
        import boto3   # endpoint, keys, region and CA bundle from the AWS_* environment
        self.s3 = boto3.client("s3")
        self.bucket = E["S3_BUCKET"]
        self.prefix = f"{E.get('S3_PREFIX', 'staged').strip('/')}/{session}/"
        self.objects = list_prefix(self.s3, self.bucket, self.prefix, "the snapshot")   # rel: (etag, size, modified epoch)
        self.deleted, self.live = set(), None

    def newest(self):
        return max(m for _, _, m in self.objects.values())

    def names(self, rel=""):
        base = rel + "/" if rel else ""
        out = {}
        for key in self.objects:
            if key.startswith(base):
                head = key[len(base):].split("/", 1)
                out[head[0]] = "dir" if len(head) > 1 else "file"
        return out

    def entries(self, rel):
        out = {}
        for key, identity in self.objects.items():
            if key.startswith(rel + "/"):
                sub = key[len(rel) + 1:]
                for i in range(1, sub.count("/") + 1):
                    out["/".join(sub.split("/")[:i])] = "dir"
                out[sub] = identity
        return out

    @staticmethod
    def size(identity):
        return identity[1]

    def read(self, rel):
        """A sidecar, bound to the listing: GetObject with If-Match set to the listed
        ETag, and the answer's ETag and length checked. A sidecar rewritten after the
        listing is a changed object, never a mapping to prove against."""
        from botocore.exceptions import ClientError
        if rel not in self.objects:
            raise FileNotFoundError(rel)
        etag, size, _ = self.objects[rel]
        try:
            r = self.s3.get_object(Bucket=self.bucket, Key=self.prefix + rel, IfMatch=etag)
            body = r["Body"].read()
        except ClientError as e:
            code = e.response.get("Error", {}).get("Code", "")
            raise Keep("object_changed" if code == "PreconditionFailed" else "listing_failed",
                       f"{self.prefix}{rel}: GetObject {code or e}")
        if r.get("ETag", "").strip('"') != etag or len(body) != size:
            raise Keep("object_changed", f"{self.prefix}{rel}: the object read is not the object listed")
        return body

    def lock(self):
        return contextlib.nullcontext()   # nothing writes a finished object; If-Match guards each delete

    def delete(self, rel):
        from botocore.exceptions import ClientError
        try:
            self.s3.delete_object(Bucket=self.bucket, Key=self.prefix + rel, IfMatch=self.objects[rel][0])
        except ClientError as e:
            code = e.response.get("Error", {}).get("Code", "")
            raise Keep("object_changed" if code == "PreconditionFailed" else "delete_failed",
                       f"{self.prefix}{rel}: DeleteObject {code or e}")
        except Exception as e:
            raise Keep("delete_failed", f"{self.prefix}{rel}: {e}")
        self.deleted.add(rel)

    def remove(self, res):
        for rel in sorted(res.data) + sorted(res.sidecars, key=lambda n: n in MANIFESTS):
            self.delete(f"{res.rel}/{rel}")

    def relist(self):
        """Every key under the prefix now, folder entries included (a late folder is a
        late arrival too), from a complete listing."""
        listed = list_prefix(self.s3, self.bucket, self.prefix, "the listing before the sidecars go")
        try:
            folders = {o["Key"][len(self.prefix):]
                       for page in self.s3.get_paginator("list_objects_v2").paginate(Bucket=self.bucket, Prefix=self.prefix)
                       for o in page.get("Contents") or [] if o["Key"].endswith("/")}
        except Exception as e:
            raise Keep("listing_failed", f"cannot list {self.prefix} again: {e}")
        return set(listed) | folders

    def tidy(self, resources, kept_rels, batches, unknown, act, proven=None):
        """Sidecars with nothing left to describe (proven is the folder store's; here
        every delete is bound to the listing by If-Match). A sidecar is recognised by where
        it is, never by its name alone: at the root of a resource this run
        recognised, at the root of a scan folder, or at the session root. Every
        other object is data. Nothing under an unknown entry, a batch folder or a
        kept resource is touched, and such an entry keeps its scan and the session
        too. A resource-root sidecar goes when the resource's data objects are all
        gone; a scan-root one when nothing else is left under the scan; a
        session-root one when nothing else is left. With act=False only say whether
        there is something to remove. Before any is removed, the prefix is listed
        again: a key not in the snapshot is a late arrival, and everything stays. A
        key that arrives after that listing keeps its data objects; the session
        metadata may be gone by then (the uploader loads it only when present)."""
        if act:
            self.live = self.relist()
            late = sorted(self.live - set(self.objects))
            if late:
                raise Keep("late_arrival", f"{self.prefix}{late[0]} arrived after the snapshot; the sidecars stay")
        left = set(self.objects) - self.deleted
        excluded = [p + "/" for p in list(unknown) + list(batches) + list(kept_rels)]
        under = lambda k, prefixes: any(k.startswith(p) for p in prefixes)
        scope = lambda k: k.rsplit("/", 1)[0] + "/" if "/" in k else ""
        known = lambda s: s == "" or (s.count("/") == 1 and "." in s[:-1]) or s[:-1] in resources
        sidecar = lambda k: k.split("/")[-1] in SIDECARS and known(scope(k)) and not under(k, excluded)
        blocked = {""} if excluded else set()
        for k in left:
            if not sidecar(k):   # data, or an excluded entry: it keeps its scan and the session
                parts = k.split("/")
                blocked |= {"/".join(parts[:i]) + "/" for i in range(1, min(len(parts), 3))} | {""}
        victims = [k for k in left if sidecar(k) and scope(k) not in blocked]
        if act:
            for k in sorted(victims, key=lambda k: (-k.count("/"), k.split("/")[-1] in MANIFESTS, k)):
                self.delete(k)
        return bool(victims)

    def gone(self):
        """Nothing is left of what was seen: the snapshot, or the later listing
        when there was one. A key that arrived after the last listing is not seen."""
        seen = self.live if self.live is not None else set(self.objects)
        return not (seen - self.deleted)


def only_sidecars(path, act, proven=None, base=""):
    """True if the folder holds sidecars only. With act=True, also remove it: each
    sidecar must then be one the run snapshotted and proved (in proven, keyed by
    its path from the session root) with the same identity, unless proven is None."""
    names = sorted(os.listdir(path))
    if not all(n in SIDECARS for n in names):
        return False
    if act:
        if proven is not None:
            for n in names:
                rel = f"{base}/{n}" if base else n
                if rel not in proven:
                    raise Keep("changed_during_check", f"{rel} appeared after the proof")
                if identity(os.path.join(path, n)) != proven[rel][0]:
                    raise Keep("changed_during_check", f"{rel} changed after the proof")
        for n in names:
            os.unlink(os.path.join(path, n))
        os.rmdir(path)
    return True


class Resource:
    """One resource folder, as it was before the proof."""

    def __init__(self, scan_id, rel, store):
        self.scan_id, self.rel, self.store = scan_id, rel, store
        self.entries = store.entries(rel)
        if any(n.startswith(".") or "/." in n for n in self.entries):
            raise Keep("unknown_entry", f"{rel} has a hidden entry")
        files = [n for n, i in self.entries.items() if i != "dir"]
        self.sidecars = [n for n in files if n in SIDECARS]
        # The sidecars' bytes, rechecked before the delete (a folder store): the kernel
        # stamps file times at tick granularity, so a same-size rewrite within the tick
        # of the previous write keeps its identity. These files are small. Data files
        # are bound by identity: the age gate puts every identity at least minAge
        # before any later write, which lands in a later tick.
        self.sidecar_sums = {n: sidecar_digest(os.path.join(store.path, rel, n)) for n in self.sidecars} if isinstance(store, LocalStore) else {}
        self.data = {n: self.entries[n] for n in files if n not in SIDECARS}
        self.sizes = {n: store.size(i) for n, i in self.data.items()}
        self.sums, self.label = self.manifest() if self.data else ({}, None)
        extra = sorted(set(self.data) - set(self.sums))
        if extra:
            raise Keep("manifest_incomplete", f"{rel}/{extra[0]} is named by no manifest")

    def manifest(self):
        """The checksums, and the XNAT label the uploader gives this folder."""
        # The manifest can name more files than are here after a stopped delete;
        # the proof then covers those too.
        for name in MANIFESTS:
            if name in self.sidecars:
                try:
                    m = json.loads(self.store.read(f"{self.rel}/{name}"))
                    sums = {str(k): str(v) for k, v in m["checksums"].items()}
                except Keep:
                    raise   # the store's own reason, e.g. an object changed after the listing
                except Exception:
                    raise Keep("manifest_unreadable", f"cannot read {self.rel}/{name}")
                return sums, self.xnat_label(str(m.get("datatype", "")))
        raise Keep("manifest_unreadable", f"{self.rel} has data files and no manifest")

    def xnat_label(self, datatype):
        name = os.path.basename(self.rel)
        if datatype in DICOM_SERIES:
            # The uploader reads SOPClassUID from this sidecar. When the KEY is
            # absent it reads the DICOM headers instead, which this does not:
            # keep. An explicit empty value makes the uploader keep the name.
            try:
                meta = json.loads(self.store.read(f"{self.rel}/__METADATA__.json"))
            except FileNotFoundError:
                raise Keep("unmapped_resource", f"{self.rel} has no __METADATA__.json; the uploader would read the headers")
            except Keep:
                raise
            except Exception:
                raise Keep("manifest_unreadable", f"cannot read {self.rel}/__METADATA__.json")
            if "SOPClassUID" not in meta:
                raise Keep("unmapped_resource", f"{self.rel}: no SOPClassUID in __METADATA__.json; the uploader would read the headers")
            return sop_label(meta["SOPClassUID"]) if meta["SOPClassUID"] else name
        if datatype.endswith("+zip"):
            # A zipped series (the package stage's DICOM-zip) is one archive
            # file. The uploader keeps the folder name for it: it is neither a
            # DICOM collection nor a DICOM image, so no header decides.
            return name
        if datatype.startswith("medimage/dicom"):
            # Includes a single DICOM image: the uploader takes its label from
            # the image header and refuses a folder that differs. Not mapped.
            raise Keep("unmapped_resource", f"{self.rel}: DICOM datatype {datatype} is not mapped")
        return name   # not DICOM: the uploader keeps the folder name

    def prove_s3(self, proof):
        """Raise Keep unless every file of this folder (data and sidecars) is in the
        bucket with its size and the MD5 of its bytes."""
        for rel in sorted(self.data) + sorted(self.sidecars):
            proof.prove(os.path.join(self.store.path, self.rel, rel), f"{self.rel}/{rel}")

    def prove(self, xnat, index):
        """Raise Keep unless XNAT holds every file that the manifest names, all in
        the one resource that the uploader maps this folder to."""
        resources = set()
        for rel in sorted(self.sums):
            rows = [r for r in index.get(rel, ()) if r[0] == self.scan_id and r[1] == self.label]
            where = f"{self.rel}/{rel}"
            if not rows and any(r[0].startswith(self.scan_id + "-") for r in index.get(rel, ())):
                raise Keep("unmapped_resource", f"{where}: XNAT holds it in a scan split by modality; not mapped")
            if len(rows) != 1:
                raise Keep("incomplete_in_xnat" if not rows else "xnat_ambiguous",
                           f"{where}: {len(rows)} rows in scan {self.scan_id}, resource {self.label}")
            _, _, rid, uri, digest = rows[0]
            resources.add(rid)
            if len(resources) > 1:
                raise Keep("xnat_ambiguous", f"{self.rel}: its files are in more than one XNAT resource")
            if digest and digest != self.sums[rel]:
                raise Keep("digest_mismatch", f"{where}: the XNAT digest is not the manifest MD5")
            size = xnat.head_size(uri)
            if rel in self.sizes and size != self.sizes[rel]:
                raise Keep("size_mismatch", f"{where}: XNAT has {size} bytes, the staged file {self.sizes[rel]}")


class Xnat:
    """GET and HEAD on one connection. Redirects are never followed."""

    def __init__(self):
        url = urllib.parse.urlsplit(E["XNAT_SERVER"])
        self.prefix = url.path.rstrip("/")
        if url.scheme == "https":
            ctx = ssl.create_default_context()   # the system trust store, as curl uses
            if E.get("XNAT_VERIFY_SSL", "true") != "true":
                ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
            self.conn = http.client.HTTPSConnection(url.hostname, url.port, timeout=TIMEOUT, context=ctx)
        else:
            self.conn = http.client.HTTPConnection(url.hostname, url.port, timeout=TIMEOUT)
        self.owned = False   # True when this helper opened the session and must end it
        if E.get("XNAT_JSESSION"):   # the run's one XNAT session, from reclaim-staged.sh
            self.headers = {"Cookie": "JSESSIONID=" + E["XNAT_JSESSION"]}
        else:
            token = base64.b64encode(f"{E.get('XNAT_USER', '')}:{E.get('XNAT_PASS', '')}".encode())
            self.headers = {"Authorization": "Basic " + token.decode()}

    def request(self, method, path, query=""):
        path = urllib.parse.quote(urllib.parse.unquote(path), safe="/:@")
        if self.prefix and not path.startswith(self.prefix + "/"):
            path = self.prefix + path
        try:
            self.conn.request(method, path + ("?" + query if query else ""), headers=self.headers)
            resp = self.conn.getresponse()
            body = resp.read()
        except (OSError, http.client.HTTPException) as e:
            self.conn.close()
            raise Keep("xnat_check_failed", f"{method} {path}: {e}")
        if "Authorization" in self.headers:
            # XNAT opens a session for each request that logs in. Keep the first
            # one, or a run would leave a session behind for every file it checks.
            m = re.search(r"JSESSIONID=([^;\s]+)", " ".join(resp.headers.get_all("Set-Cookie") or []))
            if m:
                self.headers, self.owned = {"Cookie": "JSESSIONID=" + m.group(1)}, True
        return resp.status, resp.headers, body

    def close(self):
        """End the session this helper opened; the run's own session is not ours."""
        if self.owned:
            try:
                self.request("DELETE", "/data/JSESSION")
            except Keep:
                pass
        self.conn.close()

    def rows(self, path, what, absent=None):
        """The rows of a listing. absent: the reason when XNAT answers 404, which says
        the thing is not there at lookup (a session not uploaded yet). Without it, a
        404 is a failed check, as any other code."""
        status, _, body = self.request("GET", path, "format=json")
        if status == 404 and absent:
            raise Keep(absent, f"{what}: HTTP 404, not found at lookup")
        if status != 200:
            raise Keep("xnat_check_failed", f"{what}: HTTP {status}")
        try:
            return json.loads(body)["ResultSet"]["Result"]
        except Exception:
            raise Keep("xnat_check_failed", f"{what}: the answer is not the expected JSON")

    def file_index(self, project, subject, visit):
        """{relpath: [(scan id, resource label, resource id, URI, digest)]} for the session."""
        want = (visit, f"{subject}_{visit}")
        exps = [r["ID"] for r in self.rows(f"/data/projects/{project}/subjects/{subject}/experiments",
                                           "experiment lookup", absent="incomplete_in_xnat")
                if r.get("label") in want or r.get("ID") in want]
        if not exps:
            raise Keep("incomplete_in_xnat", "XNAT has no experiment for this session")
        index = {}
        for r in self.rows(f"/data/experiments/{exps[0]}/scans/ALL/files", "file listing"):
            m = re.match(r"^.*?/scans/([^/]+)/resources/([^/]+)/files/(.+)$", r.get("URI") or "")
            if m:
                scan, res, rel = (urllib.parse.unquote(g) for g in m.groups())
                # XNAT 1.9 names the resource by its numeric id in the URI and
                # lists the label as "collection" and the id as "cat_ID".
                label, rid = str(r.get("collection") or res), str(r.get("cat_ID") or res)
                index.setdefault(rel, []).append((scan, label, rid, r["URI"], str(r.get("digest") or "")))
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


def reclaim(session):
    parts = session.split(".")
    if len(parts) != 3 or not all(parts):
        raise Keep("unsafe_prefix_name", "not a project.subject.visit session name")
    store = LocalStore(session) if STORAGE == "filesystem" else S3Store(session)
    if STORAGE != "filesystem" and not store.objects:
        return EMPTY   # a prefix with no objects: the uploader's listing skips it too
    now = int(E.get("RECLAIM_NOW") or time.time())   # RECLAIM_NOW: tests only (ctime cannot be set back)
    age = now - int(store.newest())
    if age < MIN_AGE_S:
        jlog("reclaim_skipped", session,
             f"last written {age}s ago, minAge is {E.get('MIN_AGE')} ({MIN_AGE_S}s) from {E.get('MIN_AGE_KEY')}",
             age_s=age)
        return SKIPPED
    if PROOF == "xnat" and E.get("VERIFY_XNAT", "true") != "true":
        raise Keep("verify_disabled", "verifyAgainstXnat=false: this deleter removes only what XNAT proves")
    proof = None
    if PROOF == "s3":
        # THE SECOND CLOCK. The files are proven against the bucket copy, and the
        # mgmt reclaimer's clock starts when the objects reach it; this one must
        # too, or a backlog of old files copied today is retired at once, with no
        # window in which a fault in the copy can still be seen. The listing is
        # this run's one snapshot of the prefix; a listing error keeps the session.
        proof = S3Proof(session)
        newest = proof.newest()
        s3_age = None if newest is None else now - int(newest)
        if s3_age is not None and s3_age < MIN_AGE_S:
            jlog("reclaim_skipped", session,
                 f"the newest object of this session reached the bucket {s3_age}s ago, minAge is {E.get('MIN_AGE')} "
                 f"({MIN_AGE_S}s) from {E.get('MIN_AGE_KEY')}; the local copy was last written {age}s ago",
                 age_s=age, s3_age_s=s3_age)
            return SKIPPED

    # Snapshot. A scan folder is <id>.<type>. Its dot entries are the uploader's
    # batches: never deleted here, as one can hold the only link to unproved data.
    resources, kept, kept_rels, unknown, batches, scans = [], [], [], [], [], []
    for scan, kind in sorted(store.names().items()):
        if scan in SIDECARS:
            continue
        if scan.startswith(".") or "." not in scan or kind != "dir":
            unknown.append(scan)
            continue
        scans.append(scan)
        for res, rkind in sorted(store.names(scan).items()):
            rel = f"{scan}/{res}"
            if res in SIDECARS:
                continue
            if res.startswith("."):
                batches.append(rel)
                continue
            try:
                if rkind != "dir":
                    raise Keep("unknown_entry", f"{rel} is not a resource folder")
                resources.append(Resource(scan.split(".", 1)[0], rel, store))
            except Keep as k:
                kept.append(k)
                kept_rels.append(rel)
    # The parent sidecars (the session's and each scan's own metadata) as they are
    # now. tidy() unlinks them last, so the same set with the same identities is
    # required again inside the lock, before any data goes and before each is
    # unlinked. Under PROOF=s3 each is proven in the bucket as well, below. A
    # session that holds no data file at all is the one case without this bind:
    # its sidecars describe nothing (an earlier run removed the data and stopped).
    held_data = any(r.data for r in resources) or bool(kept_rels)
    parents = store.parent_sidecars(scans) if STORAGE == "filesystem" else {}

    # Proof, outside the lock. proved: the keys this run proved, rechecked in the lock.
    proved = set()
    if resources and PROOF == "s3":
        try:
            for res in list(resources):
                try:
                    res.prove_s3(proof)
                    proved |= {f"{res.rel}/{rel}" for rel in list(res.data) + list(res.sidecars)}
                except Keep as k:
                    kept.append(k)
                    kept_rels.append(res.rel)
                    resources.remove(res)
            # the parent sidecars go with the last resource of their folder (tidy):
            # each must be in the bucket before any data of the session is removed
            for rel in sorted(parents):
                if resources:
                    proof.prove(os.path.join(store.path, rel), rel)
                    if identity(os.path.join(store.path, rel)) != parents[rel][0]:
                        raise Keep("changed_during_check", f"{rel} changed after the snapshot")
                    proved.add(rel)
        except Keep as k:   # a parent sidecar: nothing of the session is removed
            kept.append(k)
            kept_rels += [r.rel for r in resources]
            resources = []
    elif resources:
        xnat = Xnat()
        try:
            index = xnat.file_index(*parts)
            for res in list(resources):
                try:
                    res.prove(xnat, index)
                except Keep as k:
                    kept.append(k)
                    kept_rels.append(res.rel)
                    resources.remove(res)
        finally:
            xnat.close()
    nfiles = sum(len(r.data) for r in resources)
    if resources and not kept and not unknown:
        if PROOF == "s3":
            jlog("reclaim_confirmed", session,
                 f"the bucket holds each of the {nfiles} file(s) of this session with the MD5 of its bytes (ETag) and its size",
                 resources=len(resources), have=nfiles)
        else:
            jlog("reclaim_confirmed", session,
                 f"XNAT holds each of the {nfiles} file(s) of this session with the same size (HEAD); content is not verified",
                 resources=len(resources), have=nfiles)
    seen = [r.rel for r in resources] + kept_rels
    # Nothing proven: a session that still holds data is reported kept as it is; one
    # that holds none may still have leftover sidecar folders to tidy.
    if not resources and (held_data or not store.tidy(seen, kept_rels, batches, unknown, act=False)):
        return report_kept(session, kept, unknown, batches, 0)
    if DRY_RUN:
        jlog("reclaim_skipped", session, f"dataPolicy dryRun/disabled: would have removed {len(resources)} proven resource(s)",
             resources=len(resources), kept_resources=len(kept))
        return SKIPPED

    # Delete, inside the lock (a folder) or with If-Match per object (a prefix). A
    # refused or failed delete ends every delete of this session for this run.
    removed, stopped = 0, False
    with store.lock():
        # The parent sidecars first: the same set, with the same identities, as at
        # the snapshot, or nothing goes. The resources are rechecked by remove().
        # Then the bucket again (PROOF=s3): every proved object as it was listed,
        # or the proof is stale and nothing goes.
        if STORAGE == "filesystem" and held_data:
            try:
                if store.parent_sidecars(scans) != parents:
                    raise Keep("changed_during_check", "the session's or a scan's metadata changed after the proof")
                if PROOF == "s3" and resources:
                    proof.refresh(proved)
            except Keep as k:
                kept.append(k)
                kept_rels += [r.rel for r in resources]
                report_kept(session, kept, unknown, batches, 0)
                return KEPT
        for res in resources:
            try:
                store.remove(res)
            except Keep as k:
                kept.append(k)
                kept_rels.append(res.rel)
                stopped = True
                break
            removed += 1
            jlog("reclaim_resource_removed", session,
                 f"removed {res.rel}: {len(res.data)} file(s) proved in {'the bucket' if PROOF == 's3' else 'XNAT'}",
                 files=len(res.data))
        if not stopped:
            try:
                store.tidy(seen, kept_rels, batches, unknown, act=True, proven=parents if held_data else None)
            except Keep as k:
                kept.append(k)
                stopped = True
        gone = not stopped and not kept and not unknown and not batches and store.gone()
    if not gone:
        report_kept(session, kept, unknown, batches, removed)
        return REMOVED if removed else KEPT
    if not nfiles and not removed:
        # No data files are left to deliver (leftover sidecars, retired without a
        # proof: they describe nothing). Say so, or SessionStagedNotConfirmedInXNAT
        # fires 48h later for a session that is gone on purpose.
        jlog("reclaim_confirmed", session, "the session holds no data files: nothing left to deliver",
             resources=0, have=0, empty=True)
    jlog("reclaim_removed", session, f"removed {session}", resources=removed)
    return REMOVED


def report_kept(session, kept, unknown, batches, removed):
    reasons = (kept + [Keep("unknown_entry", f"{session}/{u} is not a scan folder") for u in unknown]
               + [Keep("upload_batch_present", f"{b}: an upload is running, or a stopped one left it; "
                       "it can hold the only link to unproved data, so it stays") for b in batches]
               + [Keep("not_settled", "the session still holds entries this run did not prove")])
    jlog("reclaim_kept", session, str(reasons[0]), reason=reasons[0].reason,
         removed_resources=removed, kept_resources=len(kept) + len(unknown) + len(batches))
    return KEPT


def bucket_sessions():
    """The session names under the staging prefix, one per line (`--list`)."""
    import boto3
    s3, prefix = boto3.client("s3"), E.get("S3_PREFIX", "staged").strip("/") + "/"
    names, tokens, complete = [], set(), False
    try:
        for page in s3.get_paginator("list_objects_v2").paginate(Bucket=E["S3_BUCKET"], Prefix=prefix, Delimiter="/"):
            # the same complete-listing rule as list_prefix(): a run that misses a page misses sessions
            if complete or not isinstance(page.get("IsTruncated"), bool):
                raise ValueError("a page without a completion marker")
            if page["IsTruncated"]:
                token = page.get("NextContinuationToken")
                if not isinstance(token, str) or not token or token in tokens:
                    raise ValueError("a truncated page without a new continuation token")
                tokens.add(token)
            else:
                complete = True
            for p in page.get("CommonPrefixes") or []:
                names.append(p["Prefix"][len(prefix):].rstrip("/"))
        if not complete:
            raise ValueError("the listing ended without its last page")
    except Exception as e:
        print(f"cannot list {prefix} completely: {e}", file=sys.stderr)
        return 1
    for n in names:
        print(n)


def cleaner_gate():
    """`--gate`: the bucket must carry both filer attributes, set by the activation
    procedure (scripts/cleaner-activation.sh) or by the bucket Job for a bucket it
    created: the empty-folder cleaner opted out, and the attestation that the drain
    and the SeaweedFS restart happened after it. Prints the reason and exits 1 else."""
    import urllib.request
    url = f"{E['FILER_ENDPOINT'].rstrip('/')}/buckets/?limit=1000"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"Accept": "application/json"}), timeout=TIMEOUT) as r:
            entries = json.load(r).get("Entries") or []
    except Exception as e:
        print(f"filer_unreadable {url}: {e}")
        return 1
    ext = next((e.get("Extended") or {} for e in entries if e.get("FullPath", "").rstrip("/").endswith("/" + E["S3_BUCKET"])), None)
    if ext is None:
        print(f"filer_unreadable bucket {E['S3_BUCKET']} is not in the filer's bucket listing")
        return 1
    value = lambda k: base64.b64decode(ext.get(k) or "").decode(errors="replace")
    if value("Seaweed-X-Amz-Allow-Empty-Folders") != "true":
        print("cleaner_not_disabled the bucket has no Seaweed-X-Amz-Allow-Empty-Folders=true attribute: SeaweedFS may remove folders behind this run")
        return 1
    if not value("Seaweed-X-Ais-Cleaner-Drained"):
        print("cleaner_not_drained the bucket has no Seaweed-X-Ais-Cleaner-Drained attribute: run scripts/cleaner-activation.sh first")
        return 1
    return 0


def main():
    if sys.argv[1] == "--list":
        return bucket_sessions()
    if sys.argv[1] == "--probe":
        import boto3
        try:
            boto3.client("s3").head_bucket(Bucket=E["S3_BUCKET"])
        except Exception as e:
            print(e)
            return 1
        return 0
    if sys.argv[1] == "--gate":
        return cleaner_gate()
    session = sys.argv[1]
    try:
        return reclaim(session)
    except Keep as k:
        jlog("reclaim_kept", session, str(k), reason=k.reason)
        return KEPT


if __name__ == "__main__":
    sys.exit(main())
