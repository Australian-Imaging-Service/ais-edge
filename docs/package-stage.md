# Package stage: one zip per DICOM series

The package stage is optional and off by default. When a site turns it on,
each DICOM series goes to XNAT as one zip file plus one sample DICOM file,
instead of one file per image. Nothing else in the pipeline changes.

## What it does

- Reads the de-identified sessions in `/data/deidentified`.
- For each scan that holds a DICOM series, it writes two resources:
  - `DICOM-zip`: `archive.zip`, the whole series, stored without compression
    (one entry per image, same bytes as the de-identified files).
  - A sample resource with one DICOM file of the series. XNAT reads the scan
    headers from it. The resource label is the one XNAT expects for the
    series: `DICOM` for images, `secondary` for secondary captures, and so on.
- A scan without a DICOM series passes through unchanged. Session resources
  pass through unchanged.
- Writes the result to `/data/packaged`. The upload stage reads that tree.
- Removes the session from `/data/deidentified` once it is packaged.

In XNAT a scan then shows two resources, `DICOM-zip` with one file and
`DICOM` (or `secondary`) with one file, instead of one `DICOM` resource with
every image.

## When to turn it on

Turn it on when the XNAT project wants one zip per series, for example for
large series with thousands of images. Leave it off when the XNAT users work
with the individual DICOM files in XNAT.

## What it needs

**Status on 2026-10-21:** no released xnat-ingest image runs the default package stage.
The latest release is 0.16.2. It lacks the library support from
[xnat-ingest PR #216](https://github.com/Australian-Imaging-Service/xnat-ingest/pull/216).
The stage also needs xnat-ingest PRs #217, #218, #221 and #222.
PR #219 adds a guard; the chart locks already keep the producer passes apart.
The fileformats-extras `reproducible` option is released in fileformats-extras
0.22.3 ([PR #168](https://github.com/python-fileformats/fileformats/pull/168)). Vendor v0.1.2 is tagged. The live tests used a local integration image
with the pending fixes. Keep the stage off at a site until a release contains
all required features and that release has passed the site's validation.

- `deid.engine: ingest`. The stage runs after the xnat-ingest deidentify stage
  only.
- An xnat-ingest image with fileformats 0.22.1 and fileformats-medimage 0.15.4
  or later. xnat-ingest 0.16.2 does not have them. With the default spec
  (`reproducible=true`), that image stops at start with `ValueError: Invalid
  option 'reproducible'`. With a spec without the option, it fails on every
  series with `Incorrect type for field in 'in_file' field of create_zip
  interface`. Use the first release that includes [xnat-ingest PR
  #216](https://github.com/Australian-Imaging-Service/xnat-ingest/pull/216).
- The vendor package `fileformats-vendor-australianimagingservice` v0.1.2 or
  later. It holds the DICOM sample datatype and its converter, which takes the
  instance with the lowest SOPInstanceUID, so the sample of a series is the same
  file every run. v0.1.1 took the first entry of an unsorted list: a study
  staged again for a late series got a different sample, and the upload refused
  it as a different resource. The chart installs the package with `pip` in an
  init container of the package pod and of the upload pod
  (`ingest.extraPipPackages`). The node needs access to github.com for that
  install, or a mirror of the package. Vendor v0.1.2 has this fix (vendor PR #3,
  tagged on 2026-10-21). The pins below install it from that git tag.
  PyPI has the same version (`fileformats-vendor-australianimagingservice==0.1.2`)
  for sites that install from a package index or a mirror of it.
- fileformats-extras 0.22.3 or later, which has the `reproducible` option of the
  zip converter. The `DICOM-zip` spec sets `reproducible=true`: fixed entry
  timestamps and sorted entries, so the zip of unchanged files has the same
  bytes every time. An older fileformats-extras does not know the option. The
  package command then stops at start, before its first pass, with `ValueError:
  Invalid option 'reproducible' for target spec ...`. The pod restarts and stops
  the same way until the image is new enough.

## Turn it on

Add this to `sites/<site>/values.yaml`:

```yaml
ingest:
  package:
    enabled: true
  extraPipPackages:
    - "git+https://github.com/Australian-Imaging-Service/fileformats-vendor-australianimagingservice.git@v0.1.2"
    - "git+https://github.com/Australian-Imaging-Service/fileformats-vendor-australianimagingservice.git@v0.1.2#subdirectory=extras"
```

Upgrade the release with the same `helm upgrade` command the site uses for
every change. The chart then:

- starts the `<release>-package` pod and points the upload stage at
  `/data/packaged`;
- runs the package stage inside the writer lock, one pass per
  `ingest.package.interval` seconds (default 60), and runs the deidentify
  stage one pass per turn of the same lock, so the two never work on a
  session at the same time;
- sets `dataPolicy.derived.deidentified.reclaim: auto` to `onPackaged` (the
  package stage retires each session after it is packaged) and
  `dataPolicy.derived.packaged.reclaim: auto` to `onUploaded` (the staged
  reclaimer removes each packaged session after the upload).

Turning the stage on, off, or rolling it back needs no extra steps. The
deidentify stage holds its own lock, `/data/.locks/deidentified.lock`, for each
pass in both modes. The package stage takes that same lock, and then the
upload-tree lock, for each of its passes. A lock is held for the whole pass and
released by the kernel when a pod stops, so a pass of one stage never runs
beside a pass of the other: not in normal running, and not while an old pod of
either stage is finishing its last pass during the upgrade.
This holds for an upgrade from a release in which the package stage was off,
and for one in which it already used this lock. A test build from before this
lock protocol, whose package stage took only its own lock, is not ordered: stop
its package Deployment (scale it to 0 and let the running pass end) before you
upgrade from it. No released chart has shipped such a build.

The defaults in `charts/edge/values.yaml` under `ingest.package` are the ones
every site can keep: the source datatype `medimage/dicom-series`, the two
output resources, and `copyMode: hardlink_or_copy`.

## Check that it works

1. The pod runs:

   ```
   kubectl -n xnat-ingest get pods | grep package
   ```

   The `pip-install` init container must be `Completed`. If it is not, read its
   log: `kubectl -n xnat-ingest logs deploy/<release>-package -c pip-install`.
   `pathspec '<tag>' did not match any file(s) known to git` means that the pinned
   tag does not exist. `Could not resolve host` or a timeout means that the node
   cannot reach github.com. While the init container fails, the package
   container does not start, so `IngestStageError` does not fire. No other
   alert fires at once. `StageBacklogAgeing` fires only when the oldest
   session in `/data/deidentified` is older than
   `dataPolicy.reporter.stageAgeAlertAfter` (default 7d). So check the init
   container after each change to the package settings.

2. The stage reports each pass:

   ```
   kubectl -n xnat-ingest logs deploy/<release>-package -c package
   ```

   Every pass ends with `Packaging completed successfully`. After a study,
   the log shows one `Converting <scan>/DICOM resource from
   medimage/dicom-series to medimage/dicom-series+zip as 'DICOM-zip'` line
   per series.

3. In XNAT, open the session. Each scan has a `DICOM-zip` resource with
   `archive.zip` and a `DICOM` (or `secondary`) resource with one file.

4. The trees drain: `/data/deidentified` is empty after each pass and
   `/data/packaged` keeps each session until the staged-reclaimer proves each file
   in XNAT. With the defaults, that is the first run (hourly, at minute 17) after
   `dataPolicy.derived.stagedReclaimer.minAge` (1d). On a fresh install,
   `dataPolicy.enabled` is false and `dryRun` is true. The reclaimer then only
   logs, and `/data/packaged` does not drain. The stress test overlay runs the
   reclaimer every 4 minutes.

## Alerts

`IngestStageError` fires on an ERROR line from the package stage, for example
when the image is too old. The upload alerts cover the upload of the zips as
they cover every other upload.

## Notes

- Disk: while a session is packaged it exists twice, as the de-identified
  files and as the zip. Keep that headroom on the pipeline volume.
- Late series: when a series arrives after the study was uploaded, the whole
  study is staged again. The zip of an unchanged series is byte-identical to
  the first one, so the upload stage skips it as already uploaded, and the new
  series is uploaded beside it. This needs `reproducible=true` in the
  `DICOM-zip` spec and fileformats-extras 0.22.3 or later, which has the option (see
  What it needs).
  When XNAT lists no checksums, the uploader compares a zip by filename only.
  More images added to an already uploaded series can therefore leave the
  older zip in XNAT, even if Orthanc stages the changed study again.
  A larger zip is retained by the reclaimer's size check, but an equal-size
  content change is not detected without a digest. Preserve the source and
  resolve that conflict before accepting the new images as delivered.
- Part of a series arriving later (file drop only): when a file drop brings
  more images of a series that was already packaged, the new zip would hold
  fewer images than the packaged one. The stage refuses it, logs an error
  (`IngestStageError` fires) and keeps both the input and the packaged copy.
  This refusal needs xnat-ingest PR #221. Without it, a smaller replacement zip
  can lose members of the packaged copy. Drop the whole series again in one go.
  Orthanc re-stages the whole study only while it still holds the complete
  study. If Orthanc has already retired it, a later arrival can be staged
  alone. A series split across separate arrivals still needs complete-member
  and content checks.
- Turn it off: set `ingest.package.enabled: false` and upgrade the release.
  Do this only when `/data/packaged` is empty: the upload stage reads
  `/data/deidentified` again after the change and does not look at
  `/data/packaged`.
