#!/usr/bin/env python3
"""Requeue a session that the label stage saved in assigned/__invalid__.

Runs INSIDE the edge's label (assign) pod, which mounts the pipeline at /data.
The chart ships it there: ConfigMap <release>-requeue-tool, mounted read-only at
/opt/ais-edge. No copy of the repository is needed. On the edge node, the edge
command (scripts/files/ais-requeue, installed in /usr/local/bin) runs it:

    sudo ais-requeue list

With kubectl access to the edge, the same command is:

    kubectl -n xnat-ingest exec deploy/<release>-assign -c assign -- \
        python3 /opt/ais-edge/requeue-invalid.py list

scripts/requeue-invalid.sh in the repository runs the same commands. It can also
run on a copy of the tree (--root) for tests.

    requeue-invalid.py [--root /data] list
    requeue-invalid.py [--root /data] show <folder>
    requeue-invalid.py [--root /data] [--operator NAME] requeue <folder>
            [--project V] [--subject V] [--session V] [--allow-existing]

THE SCRIPT NEVER GUESSES A LABEL. The label stage could not resolve a label
because a DICOM tag was empty. A person finds the correct value in the
hospital's records (RIS/PACS), then gives it here. The script only makes the
move safe and repeatable:
  - the folder must be a name as `list` prints it: a plain child of
    assigned/__invalid__, not a path, '.', '..' or a symbolic link (show checks
    this too). A sudo rule for the edge command relies on this;
  - only the missing labels can be given, and each must be a legal label. The
    parts of the name that it keeps must be legal labels too;
  - it refuses when a session with the new name is already in assigned/ or
    deidentified/ (unless --allow-existing: the same study, by intent);
  - it does not touch grouped/. A grouped/ copy of the same study is more data
    for it (a late series; collate orthanc stages the whole study again). The
    label stage skips that copy while the session is in __invalid__ ("already
    saved as invalid"), so it never clears by itself, and removing it can lose
    data. requeue moves the folder, and says that the next label pass puts the
    copy in __invalid__ again, to requeue with the same values (seen on
    accessionflow 0.20.0, api/label_api.py: the skip is a `continue`, so the
    copy is not unlinked);
  - it moves the folder under the label stage's writer lock, checks that the
    folder left __invalid__, and appends an audit line to LOGS/requeue-audit.jsonl.

The labels come from the folder name only (accessionflow reads the label values
from the name; __labels__ in the sidecar names the levels). No file is edited:
not the metadata, not the DICOM headers. The procedure and every way to run it:
docs/recovering-invalid-sessions.md.
Exit: 0 done, 2 refused or bad use, 3 folder not found, 4 lock not obtained.
"""
import argparse
import fcntl
import getpass
import json
import os
import re
import socket
import sys
import time

LABEL_RE = re.compile(r"^[A-Za-z0-9_-]+$")          # what the label stage writes
NAME_RE = re.compile(r"^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$")  # <project>.<subject>.<session>
MISSING_RE = re.compile(r"^INVALID_MISSING_([A-Z0-9_]+?)_[A-Za-z0-9]{8}$")
LEVELS = ("project", "subject", "session")
SHOW = ("PatientID", "StudyDate", "StudyTime", "StudyDescription", "Modality",
        "AccessionNumber", "StudyInstanceUID")


def die(code, msg):
    print(f"requeue-invalid: {msg}", file=sys.stderr)
    sys.exit(code)


def invalid_dir(root):
    return os.path.join(root, "assigned", "__invalid__")


def checked_folder(args, require_name=False):
    """The folder as a path that is a direct child of assigned/__invalid__, or exit.

    CONFINED, for a sudo rule that allows only this command: the folder must be a
    plain child name, as `list` prints it. An absolute path, a slash, '.' or '..',
    or a symbolic link is refused, and the real path must stay inside __invalid__.
    With require_name, all three parts of the name must be legal labels: the parts
    that requeue keeps go into the new name too.
    """
    name = args.folder
    if (not name or "/" in name or "\x00" in name or name in (".", "..")
            or os.path.basename(name) != name):
        die(2, f"{name!r} is not a folder name: give the name only, as `list` prints it")
    if require_name and not NAME_RE.match(name):
        die(2, f"{name!r} is not <project>.<subject>.<session> with letters, digits, '_' and '-' only; "
               "requeue it by hand (see the docs)")
    base = invalid_dir(args.root)
    path = os.path.join(base, name)
    if os.path.islink(path):
        die(2, f"{name!r} is a symbolic link; it is not requeued (check it by hand)")
    if not os.path.isdir(path):
        die(3, f"no folder {name!r} in assigned/__invalid__")
    if os.path.dirname(os.path.realpath(path)) != os.path.realpath(base):
        die(2, f"{name!r} resolves outside assigned/__invalid__")
    return path


def folder_parts(name):
    parts = name.split(".")
    if len(parts) != 3:
        return None
    return dict(zip(LEVELS, parts))


def missing_fields(parts):
    out = {}
    for level, value in parts.items():
        m = MISSING_RE.match(value)
        if m:
            out[level] = m.group(1)
    return out


def sidecar(path):
    try:
        with open(os.path.join(path, "__METADATA__.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def flat(value):
    if isinstance(value, list):
        seen = [str(v) for v in value if v not in (None, "")]
        return ", ".join(dict.fromkeys(seen)) or "(empty)"
    return "(empty)" if value in (None, "") else str(value)


def cmd_list(args):
    base = invalid_dir(args.root)
    names = sorted(n for n in os.listdir(base) if os.path.isdir(os.path.join(base, n))) if os.path.isdir(base) else []
    if not names:
        print("nothing in assigned/__invalid__")
        return 0
    now = time.time()
    print(f"{'folder':70} {'missing':24} {'files':>5} {'age':>8}")
    for n in names:
        p = os.path.join(base, n)
        parts = folder_parts(n)
        miss = ", ".join(f"{lvl}={tag}" for lvl, tag in missing_fields(parts).items()) if parts else "unparsable name"
        files = sum(len(fs) for _, _, fs in os.walk(p))
        age_h = (now - os.stat(p).st_mtime) / 3600
        print(f"{n:70} {miss:24} {files:>5} {age_h:>7.1f}h")
    return 0


def cmd_show(args):
    p = checked_folder(args)
    parts = folder_parts(args.folder) or {}
    meta = sidecar(p)
    print(f"folder:   {args.folder}")
    print(f"labels:   " + ", ".join(f"{k}={v}" for k, v in parts.items()))
    print(f"missing:  " + (", ".join(f"{lvl} (DICOM {tag})" for lvl, tag in missing_fields(parts).items()) or "none"))
    print("Look up the missing value with these study details (patient data: keep it on this terminal):")
    for key in SHOW:
        print(f"  {key:18} {flat(meta.get(key))}")
    return 0


def cmd_requeue(args):
    src = checked_folder(args, require_name=True)
    parts = folder_parts(args.folder)
    missing = missing_fields(parts)
    given = {lvl: getattr(args, lvl) for lvl in LEVELS if getattr(args, lvl) is not None}
    if not missing:
        die(2, f"{args.folder!r} has no INVALID_MISSING_ label: nothing to replace")
    for lvl, value in given.items():
        if lvl not in missing:
            die(2, f"--{lvl} given, but the {lvl} label is not missing ({parts[lvl]!r}); only missing labels can be set")
        if not LABEL_RE.match(value) or value.startswith("INVALID_MISSING_"):
            die(2, f"--{lvl} {value!r} is not a legal label: use letters, digits, '_' and '-' only")
    absent = [lvl for lvl in missing if lvl not in given]
    if absent:
        die(2, "the folder misses " + ", ".join(f"{lvl} (DICOM {missing[lvl]})" for lvl in absent)
            + "; give " + " ".join(f"--{lvl} <value>" for lvl in absent))
    new = ".".join(given.get(lvl, parts[lvl]) for lvl in LEVELS)
    meta = sidecar(src)
    uid = meta.get("__uid__") or ""
    study = flat(meta.get("StudyInstanceUID"))
    # assigned/: a rename cannot merge, so --allow-existing does not help there.
    if os.path.exists(os.path.join(args.root, "assigned", new)):
        die(2, f"assigned/{new} already exists. A folder cannot be merged into a session that waits in "
               "assigned/. If it is the same study (more data for it), wait until that session moves on, then "
               "requeue again (docs/recovering-invalid-sessions.md: more data for the same study); "
               "otherwise check the value")
    if os.path.exists(os.path.join(args.root, "deidentified", new)) and not args.allow_existing:
        die(2, f"deidentified/{new} already exists. If it is the same study (more data for it), rerun with "
               "--allow-existing; otherwise check the value")
    # MORE DATA FOR THE SAME STUDY: a note after the move, not a refusal. See the docstring.
    grouped_name = "_." + (uid if uid else study.replace(".", "_"))
    waiting = None
    if (uid or study != "(empty)") and "/" not in grouped_name and "\x00" not in grouped_name:
        if os.path.exists(os.path.join(args.root, "grouped", grouped_name)):
            waiting = f"grouped/{grouped_name}"
    lockdir = os.path.join(args.root, ".locks")
    os.makedirs(lockdir, exist_ok=True)
    fd = os.open(os.path.join(lockdir, "assigned.lock"), os.O_CREAT | os.O_RDWR, 0o644)
    deadline = time.time() + args.lock_wait
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.time() > deadline:
                die(4, f"assigned.lock is held (a label pass is running) for more than {args.lock_wait}s; try again")
            time.sleep(1)
    try:
        # AGAIN UNDER THE LOCK: the folder must still be the same plain directory.
        if os.path.islink(src) or not os.path.isdir(src):
            die(2, f"assigned/__invalid__/{args.folder} changed while waiting for the lock; nothing moved")
        dst = os.path.join(args.root, "assigned", new)
        if os.path.exists(dst) and not args.allow_existing:
            die(2, f"assigned/{new} appeared while waiting for the lock; nothing moved")
        if os.path.exists(dst):
            die(2, f"assigned/{new} exists; a folder cannot be merged into it here. Wait until that "
                   "session moves on, then requeue again")
        os.rename(src, dst)
        if os.path.exists(src) or not os.path.isdir(dst):
            die(2, f"move not confirmed: check assigned/__invalid__/{args.folder} and assigned/{new}")
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
    audit = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "event": "invalid_requeued",
             "operator": args.operator, "from": args.folder, "to": new,
             "set": {lvl: given[lvl] for lvl in given}, "study_uid": study, "grouped_waiting": waiting}
    logs = os.path.join(args.root, "LOGS")
    os.makedirs(logs, exist_ok=True)
    with open(os.path.join(logs, "requeue-audit.jsonl"), "a") as f:
        f.write(json.dumps(audit) + "\n")
    print(json.dumps(audit))
    print(f"requeued: assigned/{new}. Next: watch the uploader log for this session, then check it in XNAT.")
    if waiting:
        print(f"NOTE: {waiting} has more data for this study. The label stage did not take it while the "
              "folder was in __invalid__/. Do not remove it. On its next pass, the label stage puts it in "
              "__invalid__/ again (InvalidSessionAssigned fires again). Then run `list`, and requeue the new "
              "folder with the same values (docs/recovering-invalid-sessions.md: more data for the same study).")
    return 0


def main():
    # allow_abbrev=False: "--ro" must not mean --root. ais-requeue sets --root and
    # --operator itself, and an abbreviation could override them.
    ap = argparse.ArgumentParser(description="Requeue a session from assigned/__invalid__ (see the docstring).",
                                 allow_abbrev=False)
    ap.add_argument("--root", default="/data")
    ap.add_argument("--operator", default=f"{getpass.getuser()}@{socket.gethostname()}")
    ap.add_argument("--lock-wait", type=int, default=600)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list", allow_abbrev=False)
    s = sub.add_parser("show", allow_abbrev=False)
    s.add_argument("folder")
    r = sub.add_parser("requeue", allow_abbrev=False)
    r.add_argument("folder")
    for lvl in LEVELS:
        r.add_argument(f"--{lvl}")
    r.add_argument("--allow-existing", action="store_true")
    args = ap.parse_args()
    return {"list": cmd_list, "show": cmd_show, "requeue": cmd_requeue}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
