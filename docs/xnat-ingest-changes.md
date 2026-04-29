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
