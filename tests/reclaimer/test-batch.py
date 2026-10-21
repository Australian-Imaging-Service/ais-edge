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
from unittest.mock import patch

HELPER = Path(__file__).resolve().parents[2] / "charts/edge/files/reclaim-files.py"


def load_helper():
    spec = importlib.util.spec_from_file_location("batch_helper", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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
        import time
        self.temp = tempfile.TemporaryDirectory()
        self.xnat = FakeXnat()
        self.env = patch.dict(os.environ, STORAGE="filesystem", STAGED_ROOT=self.temp.name,
                              MIN_AGE_S="1", RECLAIM_NOW=str(int(time.time())+60), DRY_RUN="true",
                              VERIFY_XNAT="true", MAX_REMOVALS="50",
                              XNAT_SERVER=f"http://127.0.0.1:{self.xnat.server.server_port}",
                              XNAT_USER="u", XNAT_PASS="p", XNAT_JSESSION="initial")
        self.env.start()
        for subject in ("first", "second"):
            folder = Path(self.temp.name) / ("proj."+subject+".visit") / "1.scan/TEXT"
            folder.mkdir(parents=True)
            (folder/"f.txt").write_bytes(b"source bytes")
            (folder/"__MANIFEST__.json").write_text(json.dumps({"datatype":"text/plain", "checksums":{"f.txt":hashlib.md5(b"source bytes").hexdigest()}}))
        self.mod = load_helper()

    def tearDown(self):
        self.env.stop(); self.xnat.close(); self.temp.cleanup()

    def run_batch(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = self.mod.batch()
        self.events = [json.loads(line) for line in out.getvalue().splitlines()]
        return code

    def test_fresh_xnat_reads_and_one_connection_dry_run(self):
        self.assertEqual(self.run_batch(),0)
        self.assertEqual(self.events[-1]["skipped"],2)
        self.assertEqual(sum(c[0]=="HEAD" for c in self.xnat.calls),2)
        self.assertTrue(all(c[2]=="no-cache" for c in self.xnat.calls))
        self.assertEqual(self.xnat.logins,0) # one borrowed shell session
        self.assertEqual(len(list(Path(self.temp.name).rglob('f.txt'))),2)

    def test_lost_file_at_later_session_decision_is_kept(self):
        real = self.mod.reclaim
        def reclaim(session, **kwargs):
            if session=="proj.second.visit":self.xnat.missing_files.add("second")
            return real(session, **kwargs)
        with patch.object(self.mod,'reclaim',side_effect=reclaim):self.run_batch()
        self.assertTrue(any(e['event']=='reclaim_kept' and e['session']=='proj.second.visit' for e in self.events))
        self.assertFalse(any(e['event']=='reclaim_confirmed' and e['session']=='proj.second.visit' for e in self.events))

    def test_expired_auth_is_refreshed_and_closed(self):
        for code in (401,403,302):
            with self.subTest(code=code):
                self.xnat.calls.clear();self.xnat.tokens={"initial"};self.xnat.expired=False
                self.xnat.expire_after=5;self.xnat.auth_code=code;self.xnat.logins=self.xnat.logouts=0
                self.run_batch()
                self.assertEqual(self.events[-1]['skipped'],2)
                self.assertEqual((self.xnat.logins,self.xnat.logouts),(1,1))

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

    def test_failed_login_keeps_sessions_without_unbounded_retries(self):
        self.xnat.tokens.clear()
        self.xnat.login_failure = True
        self.run_batch()
        self.assertEqual(self.xnat.logins, 2)
        self.assertEqual(self.events[-1]['kept'], 2)
        self.assertFalse(any(e['event']=='reclaim_confirmed' for e in self.events))

    def test_transport_loss_at_later_decision_keeps_that_session(self):
        real = self.mod.reclaim
        def reclaim(session, **kwargs):
            if session == 'proj.second.visit':
                self.xnat.disconnect = True
            return real(session, **kwargs)
        with patch.object(self.mod, 'reclaim', side_effect=reclaim):
            self.run_batch()
        self.assertTrue(any(e.get('reason')=='xnat_check_failed' for e in self.events))
        self.assertFalse(any(e['event']=='reclaim_confirmed' and e['session']=='proj.second.visit' for e in self.events))

    def test_experiment_absence_and_bad_responses_are_not_proof(self):
        for defect in ('absent','5xx','json'):
            with self.subTest(defect=defect):
                self.xnat.missing_experiments={'first','second'} if defect=='absent' else set()
                self.xnat.bad_status=503 if defect=='5xx' else None;self.xnat.non_json=defect=='json'
                self.run_batch()
                self.assertEqual(self.events[-1]['kept'],2)
                self.assertFalse(any(e['event']=='reclaim_confirmed' for e in self.events))


if __name__ == '__main__':unittest.main()
