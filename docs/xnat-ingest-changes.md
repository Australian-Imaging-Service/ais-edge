# Changes to the `xnat-ingest` fork

This document is intended for the upstream
[xnat-ingest](https://github.com/Australian-Imaging-Service/xnat-ingest)
maintainers. It describes every change we made to our fork
([`akshitbeniwal/xnat-ingest`](https://github.com/akshitbeniwal/xnat-ingest))
on top of the upstream `main`, what each change does, why we made it,
and the suggested shape of an upstream PR if the maintainers want to
merge any of it.

The changes are intentionally **minimal and additive**: nothing is
deleted, no core code paths are modified, no public CLI signatures
change. The fork's behaviour with all new env vars unset is bit-for-bit
identical to upstream.

## TL;DR

| Change | Files touched | Rationale |
|---|---|---|
| Add `JsonFormatter` activated by `AIS_LOG_FORMAT=json` | `xnat_ingest/helpers/logging.py` (single file, +37 lines, -8 lines) | Lets log-aggregation tools (Loki / Vector / Fluent Bit) parse log lines without grok / regex |

That's it. One file. One env var. Off by default.

## Branch on the fork

```
fork:    akshitbeniwal/xnat-ingest
upstream: Australian-Imaging-Service/xnat-ingest

main                              ◄── upstream/main, currently at a18842f
└── fix/loop-connection-resilience (already a separate PR; not this doc's subject)
└── feat/json-logging              (this doc)
```

Both `fix/loop-connection-resilience` and `feat/json-logging` are
already submitted upstream as separate PRs (or planned to be). They
do not depend on each other.

## What changed (file by file)

### `xnat_ingest/helpers/logging.py`

**Net diff: +37 lines, -8 lines.** No other file modified.

#### Added — `JsonFormatter` class

```python
class JsonFormatter(logging.Formatter):
    """One JSON object per line — designed for log-aggregation tools
    (Loki / Vector / Fluent Bit) to parse without grok/regex.

    Activated by setting AIS_LOG_FORMAT=json in the environment. Falls back
    to the default human-readable format otherwise. No CLI changes; no
    behavioural changes anywhere else in the codebase."""

    def format(self, record: logging.LogRecord) -> str:
        payload: ty.Dict[str, ty.Any] = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        # Anything attached via logger.info("...", extra={...}) passes through.
        reserved = set(logging.LogRecord("", 0, "", 0, "", None, None).__dict__) | {
            "message",
            "asctime",
        }
        for key, value in record.__dict__.items():
            if key in reserved or key.startswith("_"):
                continue
            try:
                json.dumps(value)
                payload[key] = value
            except (TypeError, ValueError):
                payload[key] = repr(value)
        return json.dumps(payload, default=str)
```

The formatter:
- Always emits `ts`, `level`, `logger`, `message`
- Adds `exception` (the formatted traceback) when an exception is logged
- Forwards any extra fields attached via `logger.info("...", extra={...})`
  — type-safe, falls back to `repr(value)` for non-JSON-serialisable values

#### Added — `_select_formatter` helper

```python
def _select_formatter(clean_format: bool) -> logging.Formatter:
    """Pick the formatter based on AIS_LOG_FORMAT (env-driven; default unchanged)."""
    if os.environ.get("AIS_LOG_FORMAT", "").lower() == "json":
        return JsonFormatter()
    if clean_format:
        return logging.Formatter("%(message)s")
    return logging.Formatter("%(asctime)s - %(name)s - %(levelname)s - %(message)s")
```

#### Changed — `set_logger_handling` (existing function)

Before:
```python
if clean_format:
    log_handle.setFormatter(logging.Formatter("%(message)s"))
else:
    log_handle.setFormatter(
        logging.Formatter(
            "%(asctime)s - %(name)s - %(levelname)s - %(message)s"
        )
    )
```

After:
```python
log_handle.setFormatter(_select_formatter(clean_format))
```

The two existing branches are preserved; the new env-driven JSON branch
is only taken when `AIS_LOG_FORMAT=json`.

#### Added — imports

```python
import json
import os
```

That's the entire change set.

## What we deliberately did NOT change

We considered and rejected the following so the patch stays minimal:

- **`prometheus_client` integration / `/metrics` endpoint.** Would
  require `prometheus_client` as a new optional dependency, plus
  scattered `counter.inc()` / `histogram.observe()` calls in
  `sort.py` and `upload.py`. We instead derive metrics from log lines
  on the consumer side via Vector's `log_to_metric` transform —
  zero changes to xnat-ingest.
- **Custom event-name fields.** Adding an `event=session_staged` style
  field to specific log calls would require touching `sort.py` and
  `upload.py`. We instead let Loki query the free-form `message` field.
  An upstream PR could add this later as additive `extra={"event": ...}`
  arguments without breaking compatibility — see "Future suggestions"
  below.
- **CLI flag `--log-format=json`.** Would require Click signature
  changes on `sort` and `upload`. The env-var approach achieves the
  same outcome with zero CLI surface change.

## Behaviour matrix

| `AIS_LOG_FORMAT` env | `clean_format` arg | Output format |
|---|---|---|
| unset / empty / anything-not-`json` | `False` (default) | `2026-04-29 06:14:07,000 - xnat-ingest - INFO - <msg>` (UNCHANGED upstream behaviour) |
| unset / empty / anything-not-`json` | `True` | `<msg>` only (UNCHANGED upstream behaviour) |
| `json` (case-insensitive) | any | `{"ts":"...","level":"INFO","logger":"xnat-ingest","message":"<msg>",...}` |

Existing tests pass because the default code path is unchanged.

## How to use the fork in a deployment

The image is published to **`ghcr.io/akshitbeniwal/xnat-ingest:logging-v1`**
and the package is public, so kubelet pulls it like any other image
(no auth, no `ctr` import dance).

The deployment manifests reference it via the `XNAT_INGEST_IMAGE`
config variable in `config/management.env`:

```bash
# Default (fork with JSON logging)
export XNAT_INGEST_IMAGE="ghcr.io/akshitbeniwal/xnat-ingest:logging-v1"

# Once upstream merges the JsonFormatter patch, switch the line to:
# export XNAT_INGEST_IMAGE="ghcr.io/australian-imaging-service/xnat-ingest:latest"
```

Re-run `./install.sh -y` (or `bash scripts/04-deploy-xnat-upload.sh` +
`bash scripts/07-deploy-edge-ingest.sh <edge-entry>`) and every pod
rolls onto the new image. **No other code changes**.

### Rebuilding + pushing the fork image (for fork maintainer only)

When iterating on the fork:

```bash
cd ~/tmp/xnat-ingest-fork
git checkout feat/json-logging
# ... edits ...
docker build -t ghcr.io/akshitbeniwal/xnat-ingest:logging-v1 .

# Login once with a PAT that has write:packages scope
echo "$GHCR_PAT" | docker login ghcr.io -u akshitbeniwal --password-stdin

docker push ghcr.io/akshitbeniwal/xnat-ingest:logging-v1
```

Then make the package public (one-time, on first push) at
https://github.com/akshitbeniwal?tab=packages → click the package →
Package settings → Change visibility → Public. Once public, kubelet
on every cluster pulls it anonymously.

## Suggested upstream PR shape

If the upstream maintainers are interested in merging this, the cleanest
PR is:

- **Title:** "Optional JSON log output via `AIS_LOG_FORMAT` env var"
- **Description:** quote this document's TL;DR + Behaviour matrix
- **One commit, one file** — `xnat_ingest/helpers/logging.py`
- **Tests** — add `tests/test_json_logging.py` with two cases:
  1. `AIS_LOG_FORMAT=json` → assert each log line parses as JSON with
     `ts/level/logger/message`
  2. unset → assert format unchanged from upstream

We're happy to provide the PR ourselves; let us know if upstream
prefers an alternate naming (e.g. `XNAT_INGEST_LOG_FORMAT`) — happy
to rename.

## Future enhancements (not in this PR — separate proposals)

These would be small, additive PRs upstream that we'd be happy to send
later if there's interest:

### 1. Pipeline-event tags via `extra={...}`

Replace existing log calls in `sort.py` / `upload.py` like:
```python
logger.info(f"Staging session {session.name}")
```
with:
```python
logger.info(
    f"Staging session {session.name}",
    extra={"event": "session_staged", "session": session.name,
           "files": len(session.files), "bytes": session.size},
)
```

The `JsonFormatter` already passes `extra` keys through. With this
change, Loki queries become `{event="session_staged"}` instead of
keyword-matching the message text.

### 2. Optional `prometheus_client` metrics

Add `prometheus_client` as an optional `[dev]` dependency and a small
`xnat_ingest/helpers/metrics.py` module that:
- Exposes `:9090/metrics` (port from env var, default off)
- Defines a few counters: `xnat_ingest_files_received_total`,
  `xnat_ingest_sessions_staged_total`,
  `xnat_ingest_xnat_uploaded_total{result="ok|fail"}`
- Has a histogram for `xnat_ingest_xnat_upload_duration_seconds`

Activated by setting `XNAT_INGEST_METRICS_PORT=9090` in the env.
Off by default (zero overhead when unset).

### 3. Structured DICOM SHA256 in staged events

When a session is staged, also compute SHA256 of each DICOM and emit
it in the structured log. Allows after-the-fact integrity verification
against XNAT.

```python
logger.info(
    "Staged DICOM",
    extra={"event": "dicom_staged", "sha256": dicom_sha256, ...},
)
```

## TODO — upstream bug found during operation (NOT yet patched in our fork)

### `upload` leaks ~6 MiB per `--loop` iteration → eventual host-level OOM

**Severity:** high (cascades restarts across an entire cluster, not just the
xnat-ingest pod).
**Discovered:** 2026-05-13, after 13 days of running our fork on the mgmt
cluster. **Not introduced by our fork** — present in upstream `main`.

#### Symptom

`xnat-ingest upload --loop 60 ...` grows memory perfectly linearly at
~335 MiB/hour with **no plateau** and **regardless of workload** (the
leak occurs even when every loop iteration finds zero new sessions to
upload — i.e. the pod is logically idle, just polling S3 and the XNAT
REST API). After ~30 hours the pod reaches ~10 GiB; on a 16 GiB host it
triggers a global host-OOM (`constraint=CONSTRAINT_NONE`) that the kernel
resolves by killing `xnat-ingest` and that simultaneously evicts every
other pod on the node via kubelet's memory-pressure threshold. Observed
4 such cascades in 13 days; cluster-wide pod restart counts in the
hundreds-to-thousands.

The `xnat-ingest sort` pod, which uses the same fork code and the same
`AIS_LOG_FORMAT=json` formatter, sits at 120 MiB stable for the same
14-hour window. So the leak is **specific to `upload`**, not shared
xnat-ingest code, and not our `JsonFormatter`.

#### Root cause (suspected, located in upstream `xnat_ingest/api/upload_.py`)

The `--loop` flag is implemented by `cli/upload.py:244` as a
`while True:` wrapper that re-enters the entire `upload()` function
every iteration. Inside `api/upload_.py` (referencing the upstream code
paths, line numbers from upstream `main` @ a18842f):

```python
def upload(...):
    xnat_repo = XnatRepo(
        ...
        cache_dir=Path(tempfile.mkdtemp()),                    # L93
        ...
    )
    if use_curl_jsession:
        ...
        xnat_repo.connection.session = xnat.connect(           # L109
            server, user=user, jsession=jsession, ...
        )
    with xnat_repo.connection:                                 # L116
        if input_dir.startswith("s3://"):
            if s3_cache_dir is None:
                s3_cache_dir = Path(tempfile.mkdtemp())        # L119
                ...
```

Three leaks per loop iteration:

1. `tempfile.mkdtemp()` at L93 creates `/tmp/tmp<random>` and never
   cleans it up. Same again at L119. We observed **1688 entries in
   `/tmp/`** after 14 hours = roughly `14 h × 60 iterations/h × 2 dirs`,
   confirming the rate.
2. `xnat.connect(...)` at L109 instantiates a new
   `xnat.session.XNATSession`, which on construction walks the XNAT REST
   schema and caches every project / subject / experiment object
   representation, plus a urllib3 connection pool. The old session from
   the previous iteration is never explicitly `.disconnect()`ed; the
   `with xnat_repo.connection:` context manager at L116 only closes
   `xnat_repo.connection`, not the `.session` attribute that was
   reassigned at L109. Python's GC cannot reclaim the old session
   because xnatpy holds module-level references to live sessions.
3. The `s3_cache_dir` at L119 is created inside the `if` branch but the
   caller never resets `s3_cache_dir = None` between iterations, so on
   iteration 2 the existing path is reused — yet new files keep
   accumulating inside it because the upstream `iterate_s3_sessions`
   helper does not prune.

Memory math: 5028 MiB / (14 h × 60 iterations/h) = **~6 MiB per
iteration**, which matches the expected size of one cached `XNATSession`
plus a fresh tempdir entry plus the per-iteration objects retained in
xnatpy's internal `_object_cache`.

#### Suggested upstream patch

`api/upload_.py` should manage per-iteration resources with `try/finally`
or `contextlib.ExitStack`:

```python
import contextlib, shutil, tempfile

def upload(...):
    with contextlib.ExitStack() as stack:
        cache_dir = Path(stack.enter_context(
            tempfile.TemporaryDirectory(prefix="xnat-ingest-cache-")
        ))
        s3_cache_dir = Path(stack.enter_context(
            tempfile.TemporaryDirectory(prefix="xnat-ingest-s3-")
        )) if input_dir.startswith("s3://") else None

        xnat_repo = XnatRepo(..., cache_dir=cache_dir, ...)

        if use_curl_jsession:
            jsession = sp.check_output([...]).decode("utf-8")
            xnat_repo.connection.session = xnat.connect(
                server, user=user, jsession=jsession, logger=logging.getLogger("xnat")
            )
            stack.callback(xnat_repo.connection.session.disconnect)

        with xnat_repo.connection:
            ...
```

The key changes:
1. `tempfile.TemporaryDirectory()` (context-managed) instead of
   `tempfile.mkdtemp()` — auto-removed when the `ExitStack` unwinds.
2. `stack.callback(...session.disconnect)` — explicit cleanup of the
   xnatpy session.
3. Either delete or null-out `s3_cache_dir` in the `cli/upload.py`
   `while True:` wrapper before re-entering `upload()`, OR pass a fresh
   one each iteration.

Expected impact: per-iteration memory delta drops from ~6 MiB to ~0;
xnat-ingest-upload stabilises at its startup footprint (~250 MiB).

#### Reproduction

```bash
# Minimum repro (no real XNAT or S3 needed for the leak rate to be visible):
xnat-ingest upload \
  s3://fake-bucket/staged \
  http://localhost:8080 \
  --loop 5 \
  --dont-require-manifest \
  --dont-verify-ssl
# RSS climbs linearly even though `iterate_s3_sessions` returns zero hits
# every iteration. ~30 MiB/min at --loop 5; scales with iteration frequency.
```

#### Workaround in our deployment until the patch lands

We're applying the **defensive** mitigation in our own manifests (not in
the fork): a `resources.limits.memory` on the upload pod so the kernel
kills the cgroup *before* it can exhaust host memory, plus
`--loop 1800` (30 minutes) to slow the leak rate 30×. The pod restarts
~once a day instead of taking the whole host down via cascade. See
`manifests/01-management/xnat-upload.yaml.tpl` for the limit values.

This is a band-aid; the upstream `try/finally` patch is the real fix.

#### Suggested upstream PR shape

- **Title:** "fix(upload): leak XNATSession + tempdirs every --loop iteration"
- **One commit, one file** — `xnat_ingest/api/upload_.py`
- **Tests:** add a regression test in `tests/test_loop_memory.py` that
  runs `upload()` 20 times with a mocked XNAT server and asserts RSS
  growth is bounded (e.g. <50 MiB).

We're happy to submit this PR ourselves once we've confirmed the patch
fully eliminates the growth in a multi-hour soak.

## Maintenance / sync with upstream

When upstream `main` advances, we rebase the fork:

```bash
git fetch upstream
git checkout feat/json-logging
git rebase upstream/main
git push --force-with-lease origin feat/json-logging
docker build -t xnat-ingest:logging-v1 .   # rebuild
# distribute via ctr import as above
```

The patch is small and unlikely to conflict — it's localised to a
single `helpers/` file untouched by most upstream PRs.

## Contact

Questions about this fork or its merge candidacy:
- Akshit Beniwal (UQ)
- Repo: https://github.com/akshitbeniwal/xnat-ingest
- Branch: `feat/json-logging`
- Image: `docker.io/library/xnat-ingest:logging-v1` (locally-built;
  not pushed to a public registry)
