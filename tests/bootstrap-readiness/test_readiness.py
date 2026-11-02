#!/usr/bin/env python3
"""Run the real installer with fake k0s; stop before it writes kubeconfig."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

INSTALLER = Path(os.environ.get("INSTALLER_UNDER_TEST",
    Path(__file__).resolve().parents[2] / "scripts/01-install-k0s.sh"))
FAKE = r'''
import json, os, sys
from pathlib import Path

root = Path(os.environ['READINESS_TEST_ROOT'])
command, args = Path(sys.argv[0]).name, sys.argv[1:]
if command == 'sudo':
    assert args[0] == 'k0s', args
    os.execv(str(Path(sys.argv[0]).parent / 'k0s'), args)
if command == 'sleep':
    sys.exit(0)
if command == 'mkdir':
    (root / 'boundary').touch()
    sys.exit(97)
assert command == 'k0s', command
if args == ['version']:
    print('offline-test-k0s')
    sys.exit(0)
if args == ['status']:
    sys.exit(0)
assert args[:3] == ['kubectl', 'get', 'nodes'], args
counter = root / 'attempts'
attempt = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(attempt))
nodes, error_first = json.loads((root / 'reply.json').read_text())
if '-o' in args:
    for status in nodes:
        print('' if status is None else status)
else:
    print('NAME STATUS')
    for index, status in enumerate(nodes):
        print(index, 'Ready' if status == 'True' else 'NotReady')
sys.exit(1 if error_first and attempt == 1 else 0)
'''

CASES = [
    ("ready", ["True"], False, 1, True),
    ("not_ready", ["False"], False, 30, False),
    ("one_of_two_not_ready", ["True", "False"], False, 30, False),
    ("last_node_missing_ready", ["True", None], False, 30, False),
    ("api_error_then_ready", ["True"], True, 2, True),
]


class ReadinessTests(unittest.TestCase):
    def test_readiness(self):
        for name, nodes, error_first, attempts, ready in CASES:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                for command in ("sudo", "k0s", "sleep", "mkdir"):
                    executable = root / command
                    executable.write_text(f"#!{sys.executable}\n" + FAKE)
                    executable.chmod(0o755)
                (root / "reply.json").write_text(json.dumps([nodes, error_first]))
                env = dict(os.environ, PATH=str(root) + os.pathsep + os.defpath,
                           READINESS_TEST_ROOT=str(root), AIS_CONFIG_FROM_SITE="1",
                           MGMT_NODE_IP="127.0.0.1", INSTALL_MODE="new",
                           DATA_ROOT="", K0S_VERSION="")
                env.pop("BASH_ENV", None)
                result = subprocess.run(["bash", str(INSTALLER)], env=env, cwd=root,
                                        text=True, capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 97 if ready else 1,
                                 result.stdout + result.stderr)
                self.assertEqual((root / "boundary").exists(), ready)
                self.assertEqual(int((root / "attempts").read_text()), attempts)
                self.assertEqual("Node Ready!" in result.stdout, ready)


if __name__ == "__main__":
    unittest.main(verbosity=2)
