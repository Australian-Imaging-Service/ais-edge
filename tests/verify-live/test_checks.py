"""Exercise the Python probes embedded in verify-live without a live cluster."""

import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import urllib.request
import urllib.response
import yaml
from email.message import Message

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (ROOT / "scripts/verify-live.sh").read_text()
TIER1 = 'section "cluster"' in SCRIPT


class Checks(unittest.TestCase):
    def test_alert_settings(self):
        code = SCRIPT.split("<<'PYEMAIL'\n", 1)[1].split("\nPYEMAIL", 1)[0]
        path = "observability.stack.alerting" if TIER1 else "observability.alerting"
        defaults = ROOT / (
            "charts/edge/values.yaml" if TIER1 else "charts/mgmt/values.yaml"
        )
        valid = dict(
            smtpHost="mail.hospital.internal",
            emailTo="Ops <ops@hospital.test>",
            emailFrom="ingest@hospital.test",
        )
        for changes, expected in [
            ({}, "OK"),
            ({"emailTo": "alerts@example.org"}, "FAIL emailTo"),
            ({"emailTo": "ops@hospital.test, alerts@example.net"}, "FAIL emailTo"),
            ({"smtpHost": "smtp.example.com"}, "FAIL smtpHost"),
            ({"smtpHost": "smtp.example.org:587"}, "FAIL smtpHost"),
            ({"emailFrom": ""}, "FAIL emailFrom"),
            ({"emailTo": "changeme"}, "FAIL emailTo"),
        ]:
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as tmp:
                data = dict(valid, **changes)
                for key in reversed(path.split(".")):
                    data = {key: data}
                source = Path(tmp) / "values.yaml"
                source.write_text(yaml.safe_dump(data))
                run = subprocess.run(
                    ["python3", "-c", code, str(source), str(defaults), path],
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertEqual(run.stdout.strip(), expected)

    def test_xnat_transport(self):
        if TIER1:
            code = SCRIPT[SCRIPT.index("import os, ssl, urllib.request") :].split(
                "\nPY'", 1
            )[0]
        else:
            code = SCRIPT[
                SCRIPT.index("import os, json, base64, ssl, urllib.request") :
            ].split("\ntry:\n    projects=", 1)[0]
        for host, status in [
            ("http://xnat.test", 301),
            ("https://xnat.test", 200),
            ("https://xnat.test", 301),
            ("https://xnat.test", 302),
            ("https://xnat.test", 401),
        ]:
            with self.subTest(host=host, status=status):
                requests = []

                class FakeHTTPS(urllib.request.HTTPSHandler):
                    def https_open(self, req):
                        requests.append(req)
                        headers = Message()
                        headers["Location"] = "https://other.test/data/JSESSION"
                        reply = urllib.response.addinfourl(
                            io.BytesIO(b"body"), headers, req.full_url, status
                        )
                        reply.msg = "fixture"
                        return reply

                class FakeHTTP(urllib.request.HTTPHandler):
                    http_open = FakeHTTPS.https_open

                output = io.StringIO()
                with (
                    patch.dict(
                        os.environ,
                        {
                            "XINGEST_HOST": host,
                            "XINGEST_USER": "fake-user",
                            "XINGEST_PASS": "fake-password",
                        },
                    ),
                    patch.object(urllib.request, "HTTPSHandler", FakeHTTPS),
                    patch.object(urllib.request, "HTTPHandler", FakeHTTP),
                    contextlib.redirect_stdout(output),
                ):
                    try:
                        exec(compile(code, "<xnat-probe>", "exec"), {})
                    except SystemExit:
                        pass
                result = output.getvalue().strip()
                if host.startswith("http:"):
                    self.assertEqual(result, "INSECURE_URL")
                    self.assertEqual(requests, [])
                elif status == 200:
                    self.assertEqual(result, "200" if TIER1 else "AUTH_OK")
                    self.assertEqual(len(requests), 1)
                else:
                    self.assertNotIn("AUTH_OK", result)
                    self.assertNotEqual(result, "200")
                    self.assertIn(str(status), result)
                    self.assertEqual(
                        len(requests),
                        1,
                        "redirect must not send credentials to another URL",
                    )

    @unittest.skipUnless(TIER1, "main already excludes Job-owned pods")
    def test_failed_job_pod_is_not_a_failed_workload(self):
        code = (
            SCRIPT[SCRIPT.index("unhealthy=") :]
            .split("python3 -c '\n", 1)[1]
            .split("\n' 2>/dev/null)", 1)[0]
        )
        data = {
            "items": [
                {
                    "metadata": {
                        "name": "old-job",
                        "ownerReferences": [{"kind": "Job"}],
                    },
                    "status": {"phase": "Failed"},
                },
                {"metadata": {"name": "broken-worker"}, "status": {"phase": "Failed"}},
            ]
        }
        run = subprocess.run(
            ["python3", "-c", code],
            input=json.dumps(data),
            capture_output=True,
            text=True,
        )
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertNotIn("old-job", run.stdout)
        self.assertIn("broken-worker", run.stdout)


if __name__ == "__main__":
    unittest.main()
