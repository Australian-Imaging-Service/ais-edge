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

- `deid.engine: ingest`. The stage runs after the xnat-ingest deidentify
  stage only.
- An xnat-ingest image with fileformats 0.22.1 and fileformats-medimage 0.15.4
  or later. xnat-ingest 0.16.2 does not have them: with that image the stage
  fails on every series with `Incorrect type for field in 'in_file' field of
  create_zip interface`. Use the first release that includes
  [xnat-ingest PR #216](https://github.com/Australian-Imaging-Service/xnat-ingest/pull/216).
- The vendor package `fileformats-vendor-australianimagingservice` v0.1.2 or
  later. It holds the DICOM sample datatype and its converter, which takes the
  instance with the lowest SOPInstanceUID, so the sample of a series is the
  same file every run. v0.1.1 took the first entry of an unsorted list: a study
  staged again for a late series got a different sample, and the upload refused
  it as a different resource. The chart installs the package with `pip` in an
  init container of the package pod and of the upload pod
  (`ingest.extraPipPackages`). The node needs access to github.com for that
  install, or a mirror of the package.
- A fileformats-extras release with the `reproducible` option of the zip
  converter. The `DICOM-zip` spec sets `reproducible=true`: fixed entry
  timestamps and sorted entries, so the zip of unchanged files has the same
  bytes every time. An older fileformats-extras refuses the option: the stage
  logs `Invalid option 'reproducible'` and fails until the image is new enough.

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

   The `pip-install` init container must be `Completed`. If it fails, the
   node cannot reach github.com.

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
   `/data/packaged` is empty after the upload and the next staged-reclaimer
   run (every 4 minutes).

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
  `DICOM-zip` spec and a fileformats-extras release that has the option (see
  What it needs).
- Part of a series arriving later (file drop only): when a file drop brings
  more images of a series that was already packaged, the new zip would hold
  fewer images than the packaged one. The stage refuses it, logs an error
  (`IngestStageError` fires) and keeps both the input and the packaged copy.
  Drop the whole series again in one go. Through Orthanc this does not
  happen: a late series stages the whole study again.
- Turn it off: set `ingest.package.enabled: false` and upgrade the release.
  Do this only when `/data/packaged` is empty: the upload stage reads
  `/data/deidentified` again after the change and does not look at
  `/data/packaged`.
