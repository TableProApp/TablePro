import contextlib
import io
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "check_github_issue_status", ROOT / "scripts/check-github-issue-status.py"
)
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)

PROJECT_URL = "https://github.com/users/cozyGarage/projects/3"


def write_ledger(script_dir, rows):
    docs = script_dir.parent / "docs"
    docs.mkdir()
    (docs / "known-issues.md").write_text(
        f"{PROJECT_URL}\n\n## Open work index\n\n| ID | Issue | Lane |\n| --- | --- | --- |\n{rows}",
        encoding="utf-8",
    )


class GitHubIssueStatusTests(unittest.TestCase):
    def test_fetch_uses_the_gh_cli_when_no_runner_is_injected(self):
        result = subprocess.CompletedProcess(args=[], returncode=0, stdout='[[{"number": 1, "state": "open"}]]', stderr="")
        with patch.object(checker.subprocess, "run", return_value=result) as runner:
            states, error = checker.fetch_issue_states("cozyGarage/BookiE")
        self.assertIsNone(error)
        self.assertEqual(states, {1: "OPEN"})
        self.assertEqual(runner.call_count, 1)

    def test_fetch_reads_all_issue_pages_and_ignores_pull_requests(self):
        result = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(
                [[
                    {"number": 1, "state": "open"},
                    {"number": 2, "state": "closed"},
                    {"number": 3, "state": "closed", "pull_request": {"url": "example"}},
                ]]
            ),
            stderr="",
        )
        runner = Mock(return_value=result)

        states, error = checker.fetch_issue_states("cozyGarage/BookiE", runner)

        self.assertIsNone(error)
        self.assertEqual(states, {1: "OPEN", 2: "CLOSED"})
        command = runner.call_args.args[0]
        self.assertIn("--paginate", command)
        self.assertIn("--slurp", command)
        self.assertIn("repos/cozyGarage/BookiE/issues?state=all&per_page=100", command)
        self.assertEqual(runner.call_args.kwargs["timeout"], checker.REQUEST_TIMEOUT_SECONDS)

    def test_closed_and_missing_issues_are_distinguished_from_open(self):
        entries = [("UI-1", 1), ("PEER-18", 2), ("PEER-19", 3)]

        found = checker.stale_entries(entries, {1: "OPEN", 2: "CLOSED"})

        self.assertEqual(
            found,
            [
                "PEER-18 (#2) is closed",
                "PEER-19 (#3) was not returned by GitHub; state is unverified",
            ],
        )

    def test_authentication_failure_is_unavailable_not_closed(self):
        result = subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr="authentication required")

        states, error = checker.fetch_issue_states("cozyGarage/BookiE", Mock(return_value=result))

        self.assertIsNone(states)
        self.assertEqual(error, "gh api failed: authentication required")

        empty_error = subprocess.CompletedProcess(args=[], returncode=9, stdout="", stderr="")
        states, error = checker.fetch_issue_states("cozyGarage/BookiE", Mock(return_value=empty_error))
        self.assertIsNone(states)
        self.assertEqual(error, "gh api failed: exit status 9")

    def test_missing_cli_and_timeout_are_unavailable(self):
        missing = Mock(side_effect=FileNotFoundError)
        states, error = checker.fetch_issue_states("cozyGarage/BookiE", missing)
        self.assertIsNone(states)
        self.assertEqual(error, "gh CLI is not installed")

        timeout = Mock(side_effect=subprocess.TimeoutExpired(cmd="gh api", timeout=30))
        states, error = checker.fetch_issue_states("cozyGarage/BookiE", timeout)
        self.assertIsNone(states)
        self.assertEqual(error, "gh api timed out after 30 seconds")

    def test_invalid_api_json_is_unavailable(self):
        result = subprocess.CompletedProcess(args=[], returncode=0, stdout="not-json", stderr="")

        states, error = checker.fetch_issue_states("cozyGarage/BookiE", Mock(return_value=result))

        self.assertIsNone(states)
        self.assertEqual(error, "gh api returned invalid JSON")

    def test_unexpected_api_shapes_are_unavailable(self):
        for output, expected in (
            (json.dumps({"number": 1, "state": "open"}), "unexpected response shape"),
            (json.dumps([[{"number": 1}]]), "without a valid number and state"),
            (json.dumps([[None]]), "unexpected issue record"),
        ):
            result = subprocess.CompletedProcess(args=[], returncode=0, stdout=output, stderr="")
            states, error = checker.fetch_issue_states("cozyGarage/BookiE", Mock(return_value=result))
            self.assertIsNone(states)
            self.assertIn(expected, error)

    def test_main_reports_open_ledger_entries(self):
        with tempfile.TemporaryDirectory() as temporary:
            script_dir = Path(temporary) / "scripts"
            script_dir.mkdir()
            write_ledger(
                script_dir,
                "| UI-1 | [#1](https://github.com/cozyGarage/BookiE/issues/1) | UX |\n",
            )
            stdout = io.StringIO()
            with (
                patch.object(checker, "SCRIPT_DIR", script_dir),
                patch.object(checker, "fetch_issue_states", return_value=({1: "OPEN"}, None)),
                contextlib.redirect_stdout(stdout),
            ):
                result = checker.main([])
            self.assertEqual(result, 0)
            self.assertIn("1 open ledger entries verified", stdout.getvalue())

    def test_main_reports_stale_entries_and_unavailable_api_separately(self):
        for states, error, expected_result, expected_output in (
            ({1: "CLOSED"}, None, 1, "UI-1 (#1) is closed"),
            (None, "gh api timed out", 2, "GitHub issue status unavailable"),
        ):
            with self.subTest(error=error), tempfile.TemporaryDirectory() as temporary:
                script_dir = Path(temporary) / "scripts"
                script_dir.mkdir()
                write_ledger(
                    script_dir,
                    "| UI-1 | [#1](https://github.com/cozyGarage/BookiE/issues/1) | UX |\n",
                )
                stderr = io.StringIO()
                with (
                    patch.object(checker, "SCRIPT_DIR", script_dir),
                    patch.object(checker, "fetch_issue_states", return_value=(states, error)),
                    contextlib.redirect_stderr(stderr),
                ):
                    result = checker.main([])
                self.assertEqual(result, expected_result)
                self.assertIn(expected_output, stderr.getvalue())

    def test_main_rejects_invalid_ledger_before_requesting_github(self):
        with tempfile.TemporaryDirectory() as temporary:
            script_dir = Path(temporary) / "scripts"
            script_dir.mkdir()
            (script_dir.parent / "docs").mkdir()
            (script_dir.parent / "docs/known-issues.md").write_text("invalid", encoding="utf-8")
            stderr = io.StringIO()
            with (
                patch.object(checker, "SCRIPT_DIR", script_dir),
                patch.object(checker, "fetch_issue_states") as fetch,
                contextlib.redirect_stderr(stderr),
            ):
                result = checker.main([])
            self.assertEqual(result, 1)
            self.assertIn("missing project URL", stderr.getvalue())
            fetch.assert_not_called()

    def test_main_rejects_an_invalid_repository_argument(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            checker.main(["--repo", "owner/name?state=all"])
        self.assertEqual(raised.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
