#!/usr/bin/env python3
"""Fresh per-session proofs with reused connections. All endpoints are local fakes."""
import contextlib
import hashlib
import http.server
import importlib.util
import io
import json
import os
import socket
import signal
import sys
from pathlib import Path
import tempfile
import threading
import unittest
from datetime import datetime, timezone
from unittest.mock import patch
from botocore.exceptions import ClientError

HELPER = Path(__file__).resolve().parents[2] / "charts/edge/files/reclaim-files.py"


def load_helper():
    spec = importlib.util.spec_from_file_location("batch_helper", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeS3:
    def __init__(self, sessions):
        self.names = sessions
        self.objects = {}
        self.calls = []
        self.before_list = self.before_delete = None
        self.closed = False
        for session in sessions:
            prefix = "staged/" + session + "/1.scan/TEXT/"
            body = b"source bytes"
            self.objects[prefix + "f.txt"] = body
            self.objects[prefix + "__MANIFEST__.json"] = json.dumps(
                {"datatype": "text/plain", "checksums": {"f.txt": hashlib.md5(body).hexdigest()}}
            ).encode()

    def get_paginator(self, name):
        assert name == "list_objects_v2"
        return self

    def paginate(self, **kwargs):
        prefix = kwargs["Prefix"]
        self.calls.append(("list", prefix, kwargs.get("Delimiter")))
        if self.before_list:
            self.before_list(prefix, kwargs.get("Delimiter"))
        if kwargs.get("Delimiter"):
            yield {"IsTruncated": False, "CommonPrefixes": [{"Prefix": "staged/" + n + "/"} for n in self.names]}
        else:
            yield {"IsTruncated": False, "Contents": [
                {"Key": k, "ETag": '"' + hashlib.md5(v).hexdigest() + '"', "Size": len(v),
                 "LastModified": datetime(2020, 1, 1, tzinfo=timezone.utc)}
                for k, v in self.objects.items() if k.startswith(prefix)
            ]}

    def get_object(self, **kwargs):
        body = self.objects[kwargs["Key"]]
        etag = hashlib.md5(body).hexdigest()
        assert kwargs["IfMatch"] == etag
        return {"Body": io.BytesIO(body), "ETag": etag}

    def delete_object(self, **kwargs):
        self.calls.append(("delete", kwargs["Key"], kwargs.get("IfMatch")))
        if self.before_delete:
            self.before_delete(kwargs["Key"])
        current = self.objects.get(kwargs["Key"])
        if current is None or hashlib.md5(current).hexdigest() != kwargs.get("IfMatch"):
            raise ClientError({"Error": {"Code": "PreconditionFailed"}}, "DeleteObject")
        del self.objects[kwargs["Key"]]

    def close(self):
        self.closed = True


class FakeXnat:
    def __init__(self):
        self.calls, self.tokens, self.logins, self.logouts = [], {"initial"}, 0, 0
        self.expire_after, self.expired = None, False
        self.missing_files, self.missing_experiments = set(), set()
        self.auth_code = self.bad_status = None
        self.non_json = False
        self.login_failure = self.disconnect = False
        self.block_head = None
        self.head_started = threading.Event()
        state = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def answer(self, code, data=b"", headers=()):
                self.send_response(code)
                self.send_header("Content-Length", str(len(data)))
                for k, v in headers:
                    self.send_header(k, v)
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(data)

            def handle_any(self):
                path = self.path.split("?")[0]
                state.calls.append((self.command, path, self.headers.get("Cache-Control")))
                token = self.headers.get("Cookie", "").removeprefix("JSESSIONID=")
                basic = self.headers.get("Authorization") == "Basic dTpw"
                if state.expire_after and len(state.calls) >= state.expire_after and not state.expired:
                    state.tokens.clear(); state.expired = True
                if state.disconnect:
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
                if basic:
                    state.logins += 1
                    if state.login_failure:
                        return self.answer(401, b"denied")
                    token = "renewed" + str(state.logins)
                    state.tokens.add(token)
                    return self.answer(200, token.encode(), [("Set-Cookie", "JSESSIONID=" + token)])
                if token not in state.tokens:
                    code = state.auth_code or 401
                    return self.answer(code, b"login required", [("Location", "/login")])
                if self.command == "DELETE":
                    state.tokens.discard(token); state.logouts += 1
                    return self.answer(200)
                if state.bad_status:
                    return self.answer(state.bad_status)
                if state.non_json:
                    return self.answer(200, b"not JSON")
                parts = path.split("/")
                if path.endswith("/experiments"):
                    subj = parts[5]
                    data = {"ResultSet": {"Result": [{"ID": subj, "label": "visit"}]}}
                elif path.endswith("/scans/ALL/files"):
                    subj = parts[3]
                    data = {"ResultSet": {"Result": [{"URI": f"/data/experiments/{subj}/scans/1/resources/TEXT/files/f.txt",
                                                      "collection": "TEXT", "cat_ID": "TEXT"}]}}
                elif self.command == "HEAD":
                    if state.block_head is not None:
                        state.head_started.set()
                        state.block_head.wait(5)
                    return self.answer(404 if parts[3] in state.missing_files else 200, b"source bytes")
                else:
                    if parts[-1] in state.missing_experiments:
                        return self.answer(404)
                    data = {"items": [{"data_fields": {"ID": parts[-1]}}]}
                return self.answer(200, json.dumps(data).encode())

            do_GET = do_HEAD = do_DELETE = handle_any

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()


class BatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.xnat = FakeXnat()
        self.env = patch.dict(os.environ, STORAGE="s3", PROOF="xnat", STAGED_ROOT=self.temp.name,
                              MIN_AGE_S="0", DRY_RUN="false", VERIFY_XNAT="true", S3_BUCKET="test",
                              MAX_REMOVALS="50", XNAT_SERVER=f"http://127.0.0.1:{self.xnat.server.server_port}",
                              XNAT_USER="u", XNAT_PASS="p", XNAT_JSESSION="initial")
        self.env.start()
        self.mod = load_helper()
        self.s3 = FakeS3(["proj.first.visit", "proj.second.visit"])

    def tearDown(self):
        self.env.stop(); self.xnat.close(); self.temp.cleanup()

    def run_batch(self):
        output = io.StringIO()
        with patch.object(self.mod, "make_s3_client", return_value=self.s3) as factory, contextlib.redirect_stdout(output):
            code = self.mod.batch()
        self.assertEqual(factory.call_count, 1)
        self.assertTrue(self.s3.closed)
        self.events = [json.loads(line) for line in output.getvalue().splitlines()]
        return code

    def test_one_client_fresh_lists_and_proofs(self):
        self.assertEqual(self.run_batch(), 0)
        self.assertFalse(self.s3.objects)
        self.assertEqual(sum(c == ("list", "staged/", None) for c in self.s3.calls), 1)
        for subject in ("first", "second"):
            paths = [p for method, p, cache in self.xnat.calls]
            self.assertIn(f"/data/experiments/{subject}", paths)
            self.assertIn(f"/data/experiments/{subject}/scans/1/resources/TEXT/files/f.txt", paths)
        self.assertTrue(all(cache == "no-cache" for method, path, cache in self.xnat.calls))
        self.assertTrue(all(c[2] for c in self.s3.calls if c[0] == "delete"))
        self.assertEqual(self.events[-1]["removed"], 2)

    def test_xnat_file_lost_after_discovery_keeps_later_session(self):
        def mutate(prefix, delimiter):
            if prefix == "staged/proj.second.visit/":
                self.xnat.missing_files.add("second")
        self.s3.before_list = mutate
        self.assertEqual(self.run_batch(), 0)
        self.assertTrue(any("proj.second.visit" in k and k.endswith("f.txt") for k in self.s3.objects))
        self.assertFalse(any("proj.first.visit" in k for k in self.s3.objects))

    def test_experiment_404_precedes_even_a_stale_file_catalog(self):
        self.xnat.missing_experiments.add("second")
        self.run_batch()
        self.assertTrue(any("proj.second.visit" in k for k in self.s3.objects))
        self.assertNotIn("/data/experiments/second/scans/ALL/files", [c[1] for c in self.xnat.calls])

    def test_rewrite_between_listing_and_delete_is_retained(self):
        def mutate(key):
            if key.endswith("f.txt"):
                self.s3.objects[key] = b"new generation"
        self.s3.before_delete = mutate
        self.run_batch()
        self.assertEqual(sum(v == b"new generation" for v in self.s3.objects.values()), 2)
        self.assertEqual(self.events[-1]["removed"], 0)

    def test_new_key_between_listing_and_delete_is_not_deleted(self):
        def mutate(key):
            self.s3.objects[key.rsplit("/", 1)[0] + "/late.txt"] = b"late arrival"
        self.s3.before_delete = mutate
        self.run_batch()
        self.assertEqual(sum(k.endswith("late.txt") for k in self.s3.objects), 2)
        self.assertFalse(any(c[0] == "delete" and c[1].endswith("late.txt") for c in self.s3.calls))

    def test_expired_cookie_401_403_redirect_renews_and_closes(self):
        for code in (401, 403, 302):
            with self.subTest(code=code):
                self.s3 = FakeS3(["proj.first.visit", "proj.second.visit"])
                self.xnat.calls.clear(); self.xnat.tokens = {"initial"}
                self.xnat.expire_after = 5; self.xnat.expired = False
                self.xnat.auth_code = code; self.xnat.logins = self.xnat.logouts = 0
                self.run_batch()
                self.assertFalse(self.s3.objects)
                self.assertEqual(self.xnat.logins, 1)
                self.assertEqual(self.xnat.logouts, 1)

    def test_5xx_and_non_json_keep_every_object(self):
        for bad in ("5xx", "json"):
            with self.subTest(bad=bad):
                self.s3 = FakeS3(["proj.first.visit", "proj.second.visit"])
                self.xnat.bad_status = 503 if bad == "5xx" else None
                self.xnat.non_json = bad == "json"
                self.run_batch()
                self.assertEqual(len(self.s3.objects), 4)
                self.assertFalse(any(c[0] == "delete" for c in self.s3.calls))

    def test_stop_during_proof_closes_the_renewed_login(self):
        self.xnat.expire_after = 1
        self.xnat.block_head = threading.Event()
        def stop_when_reading():
            if self.xnat.head_started.wait(5):
                os.kill(os.getpid(), signal.SIGTERM)
        sender = threading.Thread(target=stop_when_reading, daemon=True)
        previous = signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))
        sender.start()
        try:
            with self.assertRaises(SystemExit) as stopped:
                self.run_batch()
            self.assertEqual(stopped.exception.code, 143)
            self.assertEqual((self.xnat.logins, self.xnat.logouts), (1, 1))
        finally:
            signal.signal(signal.SIGTERM, previous)
            self.xnat.block_head.set()
            sender.join(timeout=6)

    def test_failed_reauthentication_keeps_objects_and_is_bounded(self):
        self.xnat.tokens.clear()
        self.xnat.login_failure = True
        self.run_batch()
        self.assertEqual(self.xnat.logins, 2)  # one attempt for each session
        self.assertEqual(len(self.s3.objects), 4)
        self.assertEqual(self.events[-1]["kept"], 2)
        self.assertFalse(any(c[0] == "delete" for c in self.s3.calls))

    def test_midrun_transport_error_is_not_proof(self):
        def disconnect(prefix, delimiter):
            if prefix == "staged/proj.second.visit/":
                self.xnat.disconnect = True
        self.s3.before_list = disconnect
        self.run_batch()
        self.assertEqual(len(self.s3.objects), 2)
        self.assertTrue(all("proj.second.visit" in k for k in self.s3.objects))
        self.assertTrue(any(e.get("reason") == "xnat_check_failed" for e in self.events))

    def test_dry_run_and_cap(self):
        self.mod.DRY_RUN = True
        self.run_batch()
        self.assertEqual(len(self.s3.objects), 4)
        self.assertEqual(self.events[-1]["skipped"], 2)
        self.mod.DRY_RUN = False
        os.environ["MAX_REMOVALS"] = "1"
        self.s3 = FakeS3(["proj.first.visit", "proj.second.visit"])
        self.run_batch()
        self.assertEqual(len(self.s3.objects), 2)
        self.assertEqual(self.events[-1]["removed"], 1)

    def test_empty_prefixes_are_not_discovered(self):
        self.s3.objects.clear()
        self.run_batch()
        self.assertEqual(self.xnat.calls, [])
        self.assertEqual(self.events[-1]["empty"], 0)
        self.assertEqual(len(self.s3.calls), 1)

    def test_incomplete_discovery_never_deletes(self):
        def pages(**kwargs):
            yield {"IsTruncated": True, "NextContinuationToken": "next",
                   "Contents": [{"Key": "staged/proj.first.visit/file"}]}
        self.s3.paginate = pages
        self.assertEqual(self.run_batch(), self.mod.BATCH_UNAVAILABLE)
        self.assertFalse(any(c[0] == "delete" for c in self.s3.calls))
        self.assertNotIn("reclaim_finished", [e["event"] for e in self.events])

    def test_many_empty_folders_do_not_increase_examined_work(self):
        # A delimiter listing would enumerate these historical folders. A recursive
        # listing has identical objects regardless of how many folders remain.
        listing_counts = []
        for count in (0, 20_000):
            with self.subTest(empty_folders=count):
                self.s3 = FakeS3(["proj.first.visit", "proj.second.visit"])
                self.s3.names.extend(f"proj.empty{i}.visit" for i in range(count))
                self.run_batch()
                self.assertEqual(self.events[-1]["examined"], 2)
                self.assertEqual(self.events[-1]["empty"], 0)
                listing_counts.append(sum(c[0] == "list" for c in self.s3.calls))
        self.assertEqual(listing_counts[0], listing_counts[1])

    def test_folder_markers_do_not_create_empty_session_work(self):
        self.s3.objects["staged/old.empty.visit/"] = b""
        self.run_batch()
        self.assertEqual(self.events[-1]["examined"], 2)
        self.assertIn("staged/old.empty.visit/", self.s3.objects)

    def test_nonadjacent_repeated_session_keys_are_examined_once(self):
        def pages(**kwargs):
            if kwargs["Prefix"] == "staged/":
                self.assertNotIn("Delimiter", kwargs)
                yield {"IsTruncated": True, "NextContinuationToken": "next",
                       "Contents": [{"Key": "staged/proj.first.visit/a"},
                                    {"Key": "staged/proj.second.visit/a"}]}
                yield {"IsTruncated": False,
                       "Contents": [{"Key": "staged/proj.first.visit/b"}]}
            else:
                yield from FakeS3.paginate(self.s3, **kwargs)
        self.s3.paginate = pages
        self.run_batch()
        self.assertEqual(self.events[-1]["examined"], 2)

    def test_malformed_recursive_pages_examine_nothing(self):
        pages = [
            {"IsTruncated": False, "Contents": [{"Key": "staged/foo"}]},
            {"IsTruncated": False, "Contents": [{"Key": "elsewhere/a/b"}]},
            {"IsTruncated": False, "Contents": {"Key": "staged/a/b"}},
            {"IsTruncated": False, "Contents": [{"Key": "staged//file"}]},
            {"IsTruncated": False, "CommonPrefixes": [{"Prefix":"staged/foo/"}]},
            {"IsTruncated": True, "NextContinuationToken": "same", "Contents": []},
        ]
        for page in pages:
            with self.subTest(page=page):
                self.s3 = FakeS3(["proj.first.visit"])
                def listing(**kwargs):
                    yield {"IsTruncated": True, "NextContinuationToken": "same",
                           "Contents": [{"Key":"staged/proj.first.visit/file"}]}
                    yield page
                self.s3.paginate = listing
                self.assertEqual(self.run_batch(), self.mod.BATCH_UNAVAILABLE)
                self.assertFalse(any(c[0] == "delete" for c in self.s3.calls))
                self.assertNotIn("reclaim_finished", [e["event"] for e in self.events])



if __name__ == "__main__":
    unittest.main()
