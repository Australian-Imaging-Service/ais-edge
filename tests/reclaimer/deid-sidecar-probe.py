"""Runs INSIDE the pinned accessionflow image (see deid-sidecar.sh).

    python3 deid-sidecar-probe.py <allowlist|-> <reclaim-files.py>...

1. Write one labelled session: scan 1 is an MR series (2 instances), scan 2 is a
   secondary capture (1 instance). Synthetic headers, no real data.
2. Run the real `accessionflow deidentify` on it, with `--metadata-allowlist
   <allowlist>` (the value the chart renders), and once without the option
   (the control).
3. Ask each reclaim-files.py for the XNAT label of each output resource.

Prints one line per check: OK<TAB>text or BAD<TAB>text.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from fileformats.medimage import DicomSeries
from pydicom.dataset import FileDataset, FileMetaDataset
from pydicom.uid import ExplicitVRLittleEndian, MRImageStorage, SecondaryCaptureImageStorage

import attrs
from accessionflow.model.accession import Accession
from accessionflow.model.acquisition import Acquisition

ALLOW, COPIES = sys.argv[1], sys.argv[2:]
STUDY = "1.2.826.0.1.3680043.10.999.1"
SESSION = "PROJ.SUBJ.SESS"
WANT = {"1": "DICOM", "2": "secondary"}   # scan id -> the label the uploader gives


def say(ok, text):
    print(("OK\t" if ok else "BAD\t") + text, flush=True)


def instance(path, sop_class, modality, series, number):
    meta = FileMetaDataset()
    meta.TransferSyntaxUID = ExplicitVRLittleEndian
    meta.MediaStorageSOPClassUID = sop_class
    meta.MediaStorageSOPInstanceUID = f"{STUDY}.{series}.{number}"
    ds = FileDataset(str(path), {}, file_meta=meta, preamble=b"\0" * 128)
    tags = dict(SOPClassUID=sop_class, SOPInstanceUID=meta.MediaStorageSOPInstanceUID,
                StudyInstanceUID=STUDY, SeriesInstanceUID=f"{STUDY}.{series}",
                PatientName="SYNTHETIC^PROBE", PatientID="SYNTHETIC", Modality=modality,
                SeriesNumber=series, InstanceNumber=number, StudyID="PROJ", AccessionNumber="SESS",
                Rows=1, Columns=1, BitsAllocated=16, BitsStored=16, HighBit=15,
                PixelRepresentation=0, SamplesPerPixel=1, PhotometricInterpretation="MONOCHROME2",
                PixelData=b"\0\0")
    for key, value in tags.items():
        setattr(ds, key, value)
    ds.save_as(path, enforce_file_format=True)
    return path


def labels(copy, out):
    """{scan id: label or 'kept:<reason>'} for every resource folder in the output."""
    # Some copies read these at import time (tier-1). ROOT is set below.
    os.environ.setdefault("STAGED_ROOT", str(out))
    os.environ.setdefault("MIN_AGE_S", "0")
    spec = importlib.util.spec_from_file_location(f"rc{abs(hash((copy, str(out))))}", copy)
    rc = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rc)
    rc.ROOT = str(out)
    got = {}
    session = out / SESSION
    for manifest in sorted(session.glob("*/*/__MANIFEST__.json")):
        rel = manifest.parent.relative_to(session).as_posix()
        scan_id = rel.split("/")[0].split(".")[0]
        try:
            if hasattr(rc, "LocalStore"):   # main: one Resource class for folders and S3 prefixes
                resource = rc.Resource(scan_id, rel, rc.LocalStore(SESSION))
            else:                           # tier-1: folders only
                resource = rc.Resource(scan_id, str(session / rel))
            got[scan_id] = resource.label
        except rc.Keep as exc:
            got[scan_id] = f"kept:{exc.reason}"
    return got


with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    raw = root / "raw"
    raw.mkdir()
    mr = [instance(raw / f"mr{n}.dcm", MRImageStorage, "MR", 1, n) for n in (1, 2)]
    sc = [instance(raw / "sc1.dcm", SecondaryCaptureImageStorage, "OT", 2, 1)]
    # 0.20.0 renamed Accession.scans to Accession.acquisitions, with no alias. The probe runs
    # in the pinned image, so it asks the class for the name it has (0.19.0 still works).
    acq = "acquisitions" if "acquisitions" in attrs.fields_dict(Accession) else "scans"
    session = Accession(uid=STUDY, labels={"project": "PROJ", "subject": "SUBJ", "session": "SESS"},
                        **{acq: [Acquisition(id="1", type="MR", resources={"DICOM": DicomSeries(mr)}),
                                 Acquisition(id="2", type="SC", resources={"DICOM": DicomSeries(sc)})]})
    incoming = root / "assigned"
    incoming.mkdir()
    session.save(incoming)
    recipes = root / "recipes"
    (recipes / "__default__" / "medimage").mkdir(parents=True)
    (recipes / "__default__" / "medimage" / "dicom-series").write_text("FORMAT dicom\n\n%header\n\nREMOVE PatientName\n")

    for case, extra in (("chart", [] if ALLOW == "-" else ["--metadata-allowlist", ALLOW]), ("control", [])):
        out = root / case
        run = subprocess.run(["accessionflow", "deidentify", str(incoming), str(out), str(recipes), *extra],
                             capture_output=True, text=True)
        if run.returncode != 0 or not (out / SESSION).is_dir():
            say(False, f"{case}: accessionflow deidentify failed (exit {run.returncode}): {(run.stderr or run.stdout)[-300:]}")
            continue
        keys = sorted({k for p in (out / SESSION).glob("*/*/__METADATA__.json") for k in json.loads(p.read_text())})
        for copy in COPIES:
            got = labels(copy, out)
            name = copy.rsplit("/", 2)[-2] + "/" + copy.rsplit("/", 1)[-1]
            if case == "chart":
                say(got == WANT, f"{name} reads the deidentify output of the chart's allowlist {ALLOW!r} "
                                 f"(sidecar keys {keys}): labels {got}, want {WANT}")
            else:
                say(got.get("1") == "kept:unmapped_resource",
                    f"control: without --metadata-allowlist, {name} keeps the MR series (got {got.get('1')!r}); "
                    "if this fails, the probe no longer tells the two cases apart")
