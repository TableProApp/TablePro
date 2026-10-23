from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HEAD = "a" * 40
GIT = """#!/usr/bin/env bash
case "$1" in
  remote) echo https://example.invalid/fixture/repo.git ;;
  rev-parse|ls-remote) printf '%s\\n' "$GATE_TEST_HEAD" ;;
  diff) echo Cargo.toml ;;
  fetch) exit 0 ;;
  *) exit 91 ;;
esac
"""
CURL = """import json, os, pathlib, sys
fixture = pathlib.Path(os.environ['GATE_TEST_FIXTURE'])
data = json.loads(fixture.read_text())
if '/actions/tasks?' in sys.argv[-1]:
    print(json.dumps({'workflow_runs': data['tasks']}))
else:
    state = fixture.with_suffix('.polls')
    polls = int(state.read_text()) if state.exists() else 0
    state.write_text(str(polls + 1))
    run = dict(data['run'], status='failure' if polls == 0 else 'success')
    print(json.dumps({'workflow_runs': [run]}))
"""


def gate(tasks):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        tools = root / 'bin'
        tools.mkdir()
        for name, source in [('git', GIT), ('curl', f'#!{sys.executable}\n' + CURL), ('sleep', '#!/bin/sh\nexit 0\n')]:
            path = tools / name
            path.write_text(source)
            path.chmod(0o755)
        fixture = root / 'fixture.json'
        fixture.write_text(json.dumps({'run': {'id': 928, 'index_in_repo': 927, 'commit_sha': HEAD, 'workflow_id': 'ci.yml'}, 'tasks': tasks}))
        token = root / 'token'
        token.write_text('fixture-token')
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                   GATE_TEST_HEAD=HEAD, GATE_TEST_FIXTURE=str(fixture), FORGEJO_TOKEN_FILE=str(token),
                   FORGEJO_GATE_LOCK=str(root / 'gate.lock'), FORGEJO_GATE_TIMEOUT_MINUTES='1')
        return subprocess.run(['bash', str(ROOT / 'scripts/forgejo-gate.sh'), 'subject'],
                              cwd=root, env=env, capture_output=True, text=True, timeout=10)


class ForgejoGateTests(unittest.TestCase):
    def test_a_matching_retry_waits_when_api_id_differs_from_run_number(self):
        result = gate([{'run_number': 927, 'head_sha': HEAD, 'status': 'running', 'name': 'widgets'}])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('927', result.stdout)
        self.assertIn('928', result.stdout)

    def test_failure_reporting_excludes_another_run_and_another_revision(self):
        result = gate([
            {'run_number': 927, 'head_sha': HEAD, 'status': 'failure', 'name': 'expected-job'},
            {'run_number': 928, 'head_sha': HEAD, 'status': 'running', 'name': 'another-run'},
            {'run_number': 927, 'head_sha': 'b' * 40, 'status': 'running', 'name': 'another-revision'},
        ])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('expected-job', result.stdout)
        self.assertNotIn('another-run', result.stdout)
        self.assertNotIn('another-revision', result.stdout)


if __name__ == '__main__':
    unittest.main()
