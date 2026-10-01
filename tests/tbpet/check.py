"""TBPET's real Helm render and raw-filesystem CLI contract (no live services)."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

import yaml


root = Path(__file__).resolve().parents[2]
work = Path(sys.argv[1]).resolve()
docs = {
    d["metadata"]["name"]: d
    for d in yaml.safe_load_all((work / "render/edge-tbpet.yaml").read_text())
    if d
}
configs = {
    d["metadata"]["name"]: d["data"]
    for d in yaml.safe_load_all((work / "render/edge-tbpet.yaml").read_text())
    if d and d["kind"] == "ConfigMap"
}


def pod(name):
    obj = docs[f"edge-{name}"]
    spec = obj["spec"]
    if obj["kind"] == "CronJob":
        spec = spec["jobTemplate"]["spec"]
    return spec["template"]["spec"]


def container(name):
    return pod(name)["containers"][0]


def env(name):
    return {e["name"]: e.get("value", e.get("valueFrom")) for e in container(name).get("env", [])}


def option(args, flag, value):
    assert args[args.index(flag) + 1] == value, (flag, args)


pv = next(d for d in yaml.safe_load_all((work / "render/edge-tbpet.yaml").read_text())
          if d and d["kind"] == "PersistentVolume")
assert pv["spec"]["hostPath"]["path"] == "/data/ais-edge"
assert pv["spec"]["capacity"]["storage"] == "1500Gi"
assert pv["spec"]["storageClassName"] == "hostpath-pipeline"
assert pv["metadata"]["annotations"]["helm.sh/resource-policy"] == "keep"
assert pv["spec"]["persistentVolumeReclaimPolicy"] == "Retain"
pvc = next(d for d in yaml.safe_load_all((work / "render/edge-tbpet.yaml").read_text())
           if d and d["kind"] == "PersistentVolumeClaim")
assert pvc["metadata"]["name"] == "edge-pipeline"
assert pvc["metadata"]["annotations"]["helm.sh/resource-policy"] == "keep"
assert pvc["metadata"]["namespace"] == "ais-edge"
assert not any(d["kind"] == "StorageClass" for d in docs.values())
assert "edge-deidentify" not in docs and "edge-orthanc-routing" not in docs
assert "edge-upload" not in docs and "edge-staged-reclaimer" not in docs
assert not any(d["kind"] in ("StatefulSet", "Prometheus", "Alertmanager")
               or (d["kind"] == "DaemonSet" and name != "edge-data-policy")
               for name, d in docs.items())
for name in ("orthanc", "group-orthanc", "group-fs", "assign", "s3-uploader", "data-policy"):
    volumes = {v["name"]: v for v in pod(name)["volumes"]}
    mounts = {m["name"]: m for m in container(name)["volumeMounts"]}
    assert volumes["pipeline"]["persistentVolumeClaim"]["claimName"] == "edge-pipeline"
    assert mounts["pipeline"]["mountPath"] == "/data"
    assert "facility-backup" not in volumes
    if name in ("group-fs", "assign", "s3-uploader", "data-policy"):
        export = next(v for v in volumes.values()
                      if v.get("persistentVolumeClaim", {}).get("claimName") == "usyd-data-export")
        assert mounts[export["name"]]["mountPath"] == "/data/usyd-export"
        assert mounts[export["name"]]["readOnly"] is True
        assert export["persistentVolumeClaim"]["readOnly"] is True

orthanc = json.loads(configs["edge-orthanc-config"]["orthanc.json"])
assert orthanc["DicomAet"] == "USYD-TBPET"
assert orthanc["StableAge"] == 86400 and orthanc["StorageCompression"] is False
assert orthanc["AuthenticationEnabled"] is False
assert orthanc["ExtraMainDicomTags"]["Study"] == ["PatientComments"]
assert orthanc["LuaScripts"] == ["/etc/orthanc/scripts/stable-label.lua"]
assert 'local readyLabel = "xnat-ingest-ready"' in configs["edge-orthanc-scripts"]["stable-label.lua"]
assert orthanc["StorageDirectory"] == orthanc["IndexDirectory"] == "/data/orthanc-storage"
services = [d for d in yaml.safe_load_all((work / "render/edge-tbpet.yaml").read_text())
            if d and d["kind"] == "Service"]
assert {p["nodePort"] for d in services for p in d["spec"]["ports"]} == {31014, 30842}
for name in ("group-orthanc", "group-fs", "assign"):
    assert container(name)["image"].endswith(":0.15.6")
group = container("group-orthanc")["args"]
for flag, value in (("--to-process-label", "xnat-ingest-ready"),
                    ("--processed-label", "xnat-sorted"),
                    ("--wait-period", "86400"), ("--copy-mode", "hardlink_or_copy"),
                    ("--loop", "300")):
    option(group, flag, value)
assign = container("assign")["args"]
for flag, value in (("--project", "PatientComments"), ("--subject", "PatientID"),
                    ("--session", "AccessionNumber"), ("--scan", "SeriesDescription"),
                    ("--copy-mode", "hardlink_or_copy"), ("--loop", "300")):
    option(assign, flag, value)
fsenv = env("group-fs")
assert fsenv["INPUT_GLOB"] == "/data/usyd-export/TMP/RAW-DATA-EXPORT/**/*"
assert fsenv["WAIT_PERIOD"] == "86400" and fsenv["COPY_MODE"] == "symlink_or_copy"
assert fsenv["INTERVAL"] == "300"
assert fsenv["GROUP_SESSION_FIELD"] == "StudyInstanceUID"
assert fsenv["GROUP_SCAN_FIELD"] == "SeriesNumber"
assert len(fsenv["DATATYPES"].split(";")) == 9
assert container("group-fs")["command"] == ["bash", "/scripts/fs-walker.sh"]

upload = env("s3-uploader")
assert upload["AWS_ENDPOINT_URL"] == "https://s3.ap-southeast-2.amazonaws.com"
assert upload["AWS_DEFAULT_REGION"] == "ap-southeast-2"
assert upload["S3_BUCKET"] == "ais-s3-tbp-s3bucket-1afz0bzdw5jd6"
assert upload["S3_PREFIX"] == "STAGING-202607"
assert upload["ASSIGNED_DIR"] == "/data/assigned"
assert upload["RECLAIM"] == "onUploaded" and upload["DRY_RUN"] == "false"
assert upload["EVENT_DIR"] == upload["STATE_DIR"] + "/events"
for key in ("ACCESS_KEY_ID", "SECRET_ACCESS_KEY"):
    ref = upload["AWS_" + key]["secretKeyRef"]
    assert ref["name"] == "s3-edge-credentials"
    assert ref["key"] == ("access-key" if key == "ACCESS_KEY_ID" else "secret-key")
for name in ("s3-uploader", "watchdog"):
    e = env(name)
    for key in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"):
        assert e[key] == "http://10.26.16.251:7777/"
    assert e["NO_PROXY"] == e["no_proxy"] == (
        "localhost,127.0.0.1,::1,orthanc,.local,.svc,.cluster.local,"
        "10.1.0.0/16,10.152.183.0/24,192.168.0.0/24")
assert container("s3-uploader")["resources"] == {
    "requests": {"memory": "128Mi", "cpu": "25m"},
    "limits": {"memory": "512Mi", "cpu": "500m"},
}
assert container("s3-uploader")["image"] == "amazon/aws-cli:2.31.19"
assert not pod("s3-uploader").get("initContainers")
assert not any(k.startswith("RCLONE") for k in upload)
assert upload["INTERVAL"] == "300" and upload["SETTLE_MINUTES"] == "5"
for name in ("s3-uploader", "watchdog"):
    assert any(v.get("secret", {}).get("secretName") == "tbpet-egress-ca"
               for v in pod(name)["volumes"])
assert upload["AWS_CA_BUNDLE"] == "/etc/ssl/ais-edge/ca.crt"
assert "edge-samba" in docs and "edge-watchdog" in docs
assert container("samba")["volumeMounts"][0]["subPath"] == "."
assert docs["edge-watchdog"]["spec"]["schedule"] == "*/10 * * * *"
assert docs["edge-watchdog"]["spec"]["concurrencyPolicy"] == "Forbid"
watchdog = env("watchdog")
assert watchdog["WEBHOOK_URL"]["secretKeyRef"] == {"name": "discord-webhook", "key": "url"}
assert watchdog["HEARTBEAT_HOUR"] == "23"
assert watchdog["DISK_PERCENT"] == "80"
assert watchdog["PENDING_HOURS"] == watchdog["GROUPED_STUCK_HOURS"] == "6"
assert watchdog["CURL_CA_BUNDLE"] == "/etc/ssl/ais-edge/ca.crt"
stages = configs["edge-data-policy"]["stages.tsv"]
assert "onGrouped\t259200\torthanc-rest" in stages
assert "onUploaded\t0\tfilesystem" in stages
assert "originals.fileDrop\toriginal\t/data/usyd-export/TMP/RAW-DATA-EXPORT\t-\t-\tnever" in stages
assert env("data-policy")["ORTHANC_PROCESSED_LABEL"] == "xnat-sorted"
assert env("data-policy")["RECLAIM_ENABLED"] == "true"
assert env("data-policy")["DRY_RUN"] == "false"
print("PASS TBPET rendered storage, identity, labels, policy, AWS, CA and notifications")

# Exercise the real walker with synthetic files only. Capture its actual argv,
# not a hand-written approximation, then parse those in the released image.
for tool in ("find", "stat"):
    result = subprocess.run([tool, "--version"], capture_output=True, text=True)
    assert result.returncode == 0 and "GNU" in result.stdout, (
        f"{tool}: tests require the production GNU userland; put GNU tools first in PATH"
    )
runtime = work / "tbpet-runtime"
if runtime.exists():
    shutil.rmtree(runtime)
runtime.mkdir(exist_ok=True)
stub = runtime / "xnat-ingest"
stub.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
base = pathlib.Path(os.environ["TEST_WORK"])
with (base / "calls.jsonl").open("a") as f:
    f.write(json.dumps(args) + "\\n")
grouped = pathlib.Path(os.environ["GROUPED_DIR"])
assigned = pathlib.Path(os.environ["ASSIGNED_DIR"])
mode = os.environ["TEST_MODE"]
if args[0] == "group":
    d = grouped / "session"
    d.mkdir(exist_ok=True)
    if mode != "empty":
        (d / "__MANIFEST__.json").write_text("{}")
        (d / "raw").symlink_to(base / "source/study/raw")
    if mode == "failure":
        sys.exit(1)
else:
    d = assigned / "session"
    d.mkdir(exist_ok=True)
    (d / "raw").symlink_to(grouped / "session/raw")
""")
stub.chmod(0o755)
source = runtime / "source/study"
source.mkdir(parents=True, exist_ok=True)
(source / "raw").write_text("synthetic")
captured = []
for mode in ("empty", "failure", "success"):
    case = runtime / mode
    case.mkdir(exist_ok=True)
    calls = runtime / "calls.jsonl"
    calls.unlink(missing_ok=True)
    e = dict(os.environ, **{k: v for k, v in fsenv.items() if isinstance(v, str)})
    e.update(PATH=str(runtime) + os.pathsep + os.environ["PATH"],
             TEST_WORK=str(runtime), TEST_MODE=mode, GROUPED_DIR=str(case / "grouped"),
             ASSIGNED_DIR=str(case / "assigned"), DONE_LIST=str(case / "done"),
             INPUT_GLOB=str(runtime / "source/**/*"), INTERVAL="3600")
    with (case / "output.log").open("w") as log:
        proc = subprocess.Popen(["bash", str(root / "charts/edge/files/fs-walker.sh")],
                                env=e, stdout=log, stderr=log, start_new_session=True)
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                text = (case / "output.log").read_text()
                if any(s in text for s in ("will retry", "Done: study", "keeping grouped")):
                    break
                if proc.poll() is not None:
                    raise AssertionError(text)
                time.sleep(0.1)
            else:
                raise AssertionError("walker did not complete one iteration: " + text)
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
            proc.wait(timeout=5)
    args = [json.loads(line) for line in calls.read_text().splitlines()]
    if mode == "success":
        assert (case / "done").read_text() == "study\n", text
        link = case / "assigned/session/raw"
        assert link.is_symlink() and link.read_text() == "synthetic"
        assert link.resolve() == source / "raw"
        assert not list((case / "grouped").iterdir())
        captured.extend(args)
    else:
        assert not (case / "done").read_text(), text
        assert [a[0] for a in args] == ["group"], text
assert (source / "raw").read_text() == "synthetic"
print("PASS walker manifest guard, failed-group retry, symlink flattening, NFS originals retained")

# A successful S3 copy must persist its notification before local reclamation.
# Stub every network command; test the actual uploader/watchdog scripts.
for name, body in {
    "aws": """import json, os, pathlib, sys
p = pathlib.Path(os.environ["TEST_CASE"])
with (p / "aws.jsonl").open("a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1:3] == ["s3", "sync"] and os.environ["TEST_MODE"] == "changed":
    (p / "assigned/session/raw").resolve().write_text("changed during sync")
sys.exit(1 if sys.argv[1:3] == ["s3", "sync"] and os.environ["TEST_MODE"] == "copy-failed" else 0)
""",
    "sleep": """import os, pathlib, time
(pathlib.Path(os.environ["TEST_CASE"]) / "cycle-ended").touch()
time.sleep(3600)
""",
    "curl": """import json, os, pathlib, sys
p = pathlib.Path(os.environ["TEST_CASE"])
if "-d" in sys.argv:
    with (p / "posts.jsonl").open("a") as f:
        f.write(sys.argv[sys.argv.index("-d") + 1] + "\\n")
sys.exit(int(os.environ.get("WEBHOOK_TEST_FAIL", "0")))
""",
}.items():
    path = runtime / name
    path.write_text("#!/usr/bin/env python3\n" + body)
    path.chmod(0o755)

for mode in ("success", "copy-failed", "event-failed", "state-failed", "dry-run", "changed"):
    case = runtime / ("upload-" + mode)
    session = case / "assigned/session"
    session.mkdir(parents=True)
    (session / "raw").symlink_to(source / "raw")
    for name in ("__build__", "__other_internal__"):
        internal = case / "assigned" / name
        internal.mkdir()
        (internal / "keep").write_text("internal")
    events = case / "state/events"
    if mode == "event-failed":
        events.parent.mkdir()
        events.write_text("not a directory")
    if mode == "state-failed":
        (case / "state/session").mkdir(parents=True)
    e = dict(os.environ, PATH=str(runtime) + os.pathsep + os.environ["PATH"],
             TEST_CASE=str(case), TEST_MODE=mode, ASSIGNED_DIR=str(case / "assigned"),
             STATE_DIR=str(case / "state"), EVENT_DIR=str(events), PIPELINE_ROOT=str(case),
             EDGE_NAME="fixture", S3_BUCKET="synthetic", S3_PREFIX="fixture",
             INTERVAL="3600", SETTLE_MINUTES="0",
             RECLAIM="onUploaded", DRY_RUN=str(mode == "dry-run").lower())
    with (case / "output.log").open("w") as log:
        proc = subprocess.Popen(["bash", str(root / "charts/edge/files/s3-uploader.sh")],
                                env=e, stdout=log, stderr=log, start_new_session=True)
        try:
            deadline = time.monotonic() + 15
            while not (case / "cycle-ended").exists():
                if proc.poll() is not None or time.monotonic() > deadline:
                    raise AssertionError((case / "output.log").read_text())
                time.sleep(0.1)
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
            proc.wait(timeout=5)
    assert session.exists() == (mode != "success"), (mode, (case / "output.log").read_text())
    assert (source / "raw").read_text() == (
        "changed during sync" if mode == "changed" else "synthetic")
    calls = [json.loads(line) for line in (case / "aws.jsonl").read_text().splitlines()]
    copies = [args for args in calls if args[:2] == ["s3", "sync"]]
    assert len(copies) == 1
    assert "--delete" not in copies[0] and "--no-follow-symlinks" not in copies[0]
    assert copies[0][3] == "s3://synthetic/fixture/session/"
    assert (case / "assigned/__other_internal__/keep").read_text() == "internal"
    if mode in ("success", "dry-run"):
        event, = list(events.iterdir())
        assert event.read_text() == "session\n"
        if mode == "success":
            # Failed Discord delivery must retain the event despite the session
            # having gone. An in-flight atomic write is not an event yet.
            pending = events / "uncommitted.tmp"
            pending.write_text("not-yet-committed\n")
            e.update(UPLOAD_EVENT_DIR=str(events), UPLOAD_STATE_DIR=str(case / "state"),
                     WATCHDOG_STATE_DIR=str(case / "watchdog"), GROUPED_DIRS=str(case / "grouped"),
                     WEBHOOK_URL="https://unused.invalid", ORTHANC_URL="", HEARTBEAT_HOUR="")
            for fail in ("1", "0"):
                result = subprocess.run(
                    ["sh", str(root / "charts/edge/files/watchdog.sh")],
                    env=dict(e, WEBHOOK_TEST_FAIL=fail), capture_output=True, text=True, timeout=15)
                assert result.returncode == int(fail), result.stderr
                assert event.exists() == (fail == "1")
                assert pending.exists()
            posts = (case / "posts.jsonl").read_text()
            assert "most recent snapshot synced to S3" in posts
            assert "not-yet-committed" not in posts
    else:
        assert not (case / "state/session").is_file()
        if mode == "state-failed":
            event, = list(events.iterdir())
            assert event.read_text() == "session\n"
        elif events.is_dir():
            assert not list(events.iterdir())
print("PASS upload failures/dry-run preserve data; events survive reclaim and retry Discord; __* excluded")

assert shutil.which("docker"), "Docker required to verify the released 0.15.6 CLI"
image = container("group-fs")["image"]
cases = captured + [container(n)["command"][1:] + container(n)["args"]
                    for n in ("group-orthanc", "assign")]
probe = """
import importlib.metadata, json, os, sys, click
from xnat_ingest.cli import cli
from fileformats.core import from_mime
data = json.load(sys.stdin)
assert importlib.metadata.version("xnat-ingest") == "0.15.6"
root = click.Context(cli)
for args in data["cases"]:
    # click only checks directories for some positional args. All synthetic.
    for arg in args:
        if arg.startswith("/") and "*" not in arg:
            os.makedirs(arg, exist_ok=True)
    cmd = cli.get_command(root, args[0])
    with cmd.make_context(args[0], args[1:], parent=root) as ctx:
        if args[0] == "group":
            for field, expected in (("session", "StudyInstanceUID"), ("scan", "SeriesNumber")):
                spec, = ctx.params[field]
                assert spec.specifier == expected
                for datatype in data["datatypes"]:
                    assert issubclass(from_mime(datatype), spec.datatype), (field, datatype)
            assert ctx.params["on_resource_clash"]
print("PASS 0.15.6 actual walker and rendered argv; session/scan mappings cover all nine datatypes")
"""
subprocess.run(["docker", "run", "--rm", "-i", "--entrypoint", "python3", image, "-c", probe],
               input=json.dumps({"cases": cases, "datatypes": fsenv["DATATYPES"].split(";")}),
               text=True, check=True, timeout=180)
shutil.rmtree(runtime)
