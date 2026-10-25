import importlib.util
import json
import os
import subprocess
import sys
import unittest
from io import BytesIO
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError, URLError

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("pr_readiness", ROOT / "scripts/check-pr-readiness.py")
readiness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(readiness)


class PullRequestReadinessTests(unittest.TestCase):
    def test_required_contexts_still_match_the_workflow_job_names(self):
        sources = {
            "pr-title": ("pr-title.yml", "  pr-title:"),
            "release-note": ("release-note-check.yml", "  release-note:"),
            "Pin tested revision": ("build-linux.yml", "name: Pin tested revision"),
            "Ensure CI debian-testing GTK image": ("build-linux.yml", "name: Ensure CI debian-testing GTK image"),
            "Preflight and sandbox tier (no GTK app)": ("build-linux.yml", "name: Preflight and sandbox tier (no GTK app)"),
            "Fast checks (GTK)": ("build-linux.yml", "name: Fast checks (GTK)"),
            "flatpak-builder (default)": ("flatpak-linux.yml", "name: flatpak-builder (${{ matrix.profile }})"),
            "resolve-ref": ("linux-security.yml", "  resolve-ref:"),
            "Security (security-policy)": ("linux-security.yml", "name: Security (${{ matrix.layer }})"),
            "Security (supply-chain)": ("linux-security.yml", "layer: [security-policy, supply-chain]"),
            "workflow-lint": ("linux-ci-contracts.yml", "  workflow-lint:"),
            "workflow-security": ("linux-ci-contracts.yml", "  workflow-security:"),
            "harness": ("linux-ci-contracts.yml", "  harness:"),
        }

        for context, (filename, marker) in sources.items():
            with self.subTest(context=context):
                workflow = (ROOT / ".github/workflows" / filename).read_text()
                self.assertIn(marker, workflow)

    def test_code_changes_require_build_security_and_flatpak_contexts(self):
        required = readiness.required_contexts(["crates/core/src/query.rs"])

        self.assertTrue(
            {
                "pr-title",
                "release-note",
                "Pin tested revision",
                "Ensure CI debian-testing GTK image",
                "Preflight and sandbox tier (no GTK app)",
                "Fast checks (GTK)",
                "flatpak-builder (default)",
                "resolve-ref",
                "Security (security-policy)",
                "Security (supply-chain)",
            }.issubset(required)
        )
        self.assertNotIn("harness", required)

    def test_docs_only_changes_require_contract_checks_without_build_checks(self):
        required = readiness.required_contexts(["docs/testing.md", "README.md"])

        self.assertEqual(
            set(required),
            {"pr-title", "release-note", "harness", "workflow-lint", "workflow-security"},
        )

    def test_mixed_changes_require_code_and_contract_checks(self):
        required = readiness.required_contexts(["docs/testing.md", "scripts/check-pr-title.py"])

        self.assertIn("Fast checks (GTK)", required)
        self.assertIn("harness", required)
        self.assertIn("workflow-lint", required)

    def test_a_check_suite_must_match_the_pull_request_and_exact_head(self):
        suite = {
            "head_sha": "a" * 40,
            "app": {"slug": "github-actions"},
            "pull_requests": [{"number": 7}],
        }

        self.assertTrue(readiness.check_suite_matches(suite, 7, "a" * 40))
        self.assertFalse(readiness.check_suite_matches(suite, 8, "a" * 40))
        self.assertFalse(readiness.check_suite_matches(suite, 7, "b" * 40))

    def test_checks_from_other_apps_do_not_satisfy_the_gate(self):
        suite = {
            "head_sha": "a" * 40,
            "app": {"slug": "sonarqubecloud"},
            "pull_requests": [{"number": 7}],
        }

        self.assertFalse(readiness.check_suite_matches(suite, 7, "a" * 40))

    def test_renamed_files_classify_both_paths_when_selecting_checks(self):
        class Api(readiness.GitHubApi):
            def __init__(self):
                super().__init__("cozyGarage/BookiE", "token", "https://api.github.com")

            def get(self, _path):
                return {"changed_files": 1}

            def pages(self, _path, _key=None):
                return [{"filename": "docs/query.md", "previous_filename": "crates/core/src/query.rs"}]

        paths = Api().pull_request_paths(7)
        required = readiness.required_contexts(paths)

        self.assertIn("crates/core/src/query.rs", paths)
        self.assertIn("docs/query.md", paths)
        self.assertIn("Fast checks (GTK)", required)
        self.assertIn("harness", required)

    def test_missing_checks_remain_pending(self):
        result = readiness.evaluate_checks(["pr-title"], [])

        self.assertEqual(result["state"], "waiting")
        self.assertEqual(result["waiting"], ["pr-title: missing"])

    def test_a_failure_takes_precedence_over_checks_that_are_still_waiting(self):
        result = readiness.evaluate_checks(
            ["pr-title", "release-note"],
            [{"name": "pr-title", "status": "completed", "conclusion": "failure", "id": 1}],
        )

        self.assertEqual(result["state"], "failed")
        self.assertEqual(result["waiting"], ["release-note: missing"])
        self.assertEqual(result["failed"], ["pr-title: failure"])

    def test_a_pending_latest_attempt_does_not_inherit_an_older_success(self):
        runs = [
            {"name": "pr-title", "status": "completed", "conclusion": "success", "started_at": "2026-01-01T00:00:00Z", "id": 1},
            {"name": "pr-title", "status": "in_progress", "conclusion": None, "started_at": "2026-01-01T00:01:00Z", "id": 2},
        ]

        result = readiness.evaluate_checks(["pr-title"], runs)

        self.assertEqual(result["state"], "waiting")
        self.assertEqual(result["waiting"], ["pr-title: in_progress"])

    def test_a_newer_successful_attempt_replaces_an_older_failure(self):
        runs = [
            {"name": "pr-title", "status": "completed", "conclusion": "failure", "started_at": "2026-01-01T00:00:00Z", "id": 1},
            {"name": "pr-title", "status": "completed", "conclusion": "success", "started_at": "2026-01-01T00:01:00Z", "id": 2},
        ]

        result = readiness.evaluate_checks(["pr-title"], runs)

        self.assertEqual(result["state"], "passed")

    def test_a_failed_or_skipped_applicable_check_fails_closed(self):
        for conclusion in ("failure", "cancelled", "skipped", "timed_out", "neutral"):
            with self.subTest(conclusion=conclusion):
                result = readiness.evaluate_checks(
                    ["pr-title"],
                    [{"name": "pr-title", "status": "completed", "conclusion": conclusion, "started_at": "2026-01-01T00:00:00Z", "id": 1}],
                )

                self.assertEqual(result["state"], "failed")

    def test_all_required_checks_must_succeed(self):
        runs = [
            {"name": name, "status": "completed", "conclusion": "success", "started_at": "2026-01-01T00:00:00Z", "id": index}
            for index, name in enumerate(("pr-title", "release-note"), start=1)
        ]

        result = readiness.evaluate_checks(["pr-title", "release-note"], runs)

        self.assertEqual(result["state"], "passed")
        self.assertEqual(result["passed"], ["pr-title", "release-note"])

    def test_a_transient_github_api_error_retries_before_reporting_readiness(self):
        class Client:
            attempts = 0

            def pull_request_paths(self, _pull_number):
                return ["README.md"]

            def check_runs_for_pull_request(self, _pull_number, _head_sha):
                self.attempts += 1
                if self.attempts == 1:
                    raise readiness.TransientGitHubError("temporary")
                names = readiness.required_contexts(["README.md"])
                return [
                    {"name": name, "status": "completed", "conclusion": "success", "started_at": "2026-01-01T00:00:00Z", "id": index}
                    for index, name in enumerate(names, start=1)
                ]

        sleeps = []
        result = readiness.wait_for_checks(
            Client(),
            7,
            "a" * 40,
            timeout_seconds=10,
            poll_seconds=1,
            sleep=sleeps.append,
            monotonic=lambda: 0,
        )

        self.assertEqual(result, 0)
        self.assertEqual(sleeps, [1])

    def test_latest_checks_ignore_unnamed_runs_and_use_run_id_for_timestamp_ties(self):
        result = readiness.latest_checks(
            [
                {"created_at": "2026-01-01T00:00:00Z", "id": 9},
                {
                    "name": "pr-title",
                    "created_at": "2026-01-01T00:00:00Z",
                    "id": 3,
                    "conclusion": "failure",
                },
                {
                    "name": "pr-title",
                    "created_at": "2026-01-01T00:00:00Z",
                    "id": 4,
                    "conclusion": "success",
                },
                {
                    "name": "pr-title",
                    "created_at": "2025-01-01T00:00:00Z",
                    "id": 10,
                    "conclusion": "failure",
                },
            ]
        )

        self.assertEqual(result["pr-title"]["id"], 4)
        self.assertEqual(result["pr-title"]["conclusion"], "success")

    def test_transient_retries_stop_at_the_deadline(self):
        times = iter((0, 2))
        sleeps = []

        def unavailable():
            raise readiness.TransientGitHubError("temporary")

        with self.assertRaisesRegex(readiness.ReadinessError, "Timed out"):
            readiness.retry_transient(unavailable, 1, 0.5, sleeps.append, lambda: next(times))

        self.assertEqual(sleeps, [0.5])

    def test_github_api_rejects_invalid_repository_identity(self):
        invalid_repositories = ("owner", "owner/repo/extra", "../repo", "./repo", "owner/..", "owner/.")
        for repository in invalid_repositories:
            with self.subTest(repository=repository), self.assertRaises(readiness.ReadinessError):
                readiness.GitHubApi(repository, "token", "https://api.github.com")

    def test_github_api_get_decodes_json_and_classifies_transport_errors(self):
        api = readiness.GitHubApi("cozyGarage/BookiE", "token", "https://api.github.com/")
        response = BytesIO(json.dumps({"ok": True}).encode())

        with patch.object(readiness, "urlopen", return_value=response) as urlopen:
            self.assertEqual(api.get("/repos/cozyGarage/BookiE"), {"ok": True})
        self.assertEqual(urlopen.call_args.args[0].full_url, "https://api.github.com/repos/cozyGarage/BookiE")

        for code in (429, 500):
            error = HTTPError("https://api.github.com", code, "temporary", None, None)
            with self.subTest(code=code), patch.object(readiness, "urlopen", side_effect=error):
                with self.assertRaises(readiness.TransientGitHubError):
                    api.get("/repos/cozyGarage/BookiE")
            error.close()

        error = HTTPError("https://api.github.com", 404, "missing", None, None)
        with patch.object(readiness, "urlopen", side_effect=error):
            with self.assertRaises(readiness.ReadinessError):
                api.get("/repos/cozyGarage/BookiE")
        error.close()

        with patch.object(readiness, "urlopen", side_effect=URLError("offline")):
            with self.assertRaises(readiness.TransientGitHubError):
                api.get("/repos/cozyGarage/BookiE")

    def test_github_api_pages_follow_full_pages_and_reject_invalid_lists(self):
        class Api(readiness.GitHubApi):
            def __init__(self):
                super().__init__("cozyGarage/BookiE", "token", "https://api.github.com")
                self.requests = []

            def get(self, path):
                self.requests.append(path)
                if path.endswith("page=1"):
                    return {"rows": list(range(readiness.PAGE_SIZE))}
                return {"rows": [readiness.PAGE_SIZE]}

        api = Api()
        self.assertEqual(api.pages("/items", "rows"), list(range(readiness.PAGE_SIZE + 1)))
        self.assertEqual(len(api.requests), 2)

        with patch.object(api, "get", return_value={"rows": "invalid"}):
            with self.assertRaises(readiness.ReadinessError):
                api.pages("/items", "rows")

        with patch.object(api, "get", return_value=["row"]):
            self.assertEqual(api.pages("/items"), ["row"])

    def test_pull_request_paths_reject_incomplete_file_lists_and_invalid_names(self):
        class Api(readiness.GitHubApi):
            def __init__(self, changed_files, rows):
                super().__init__("cozyGarage/BookiE", "token", "https://api.github.com")
                self.changed_files = changed_files
                self.rows = rows

            def get(self, _path):
                return {"changed_files": self.changed_files}

            def pages(self, _path, _key=None):
                return self.rows

        with self.assertRaisesRegex(readiness.ReadinessError, "file list is incomplete"):
            Api(2, [{"filename": "README.md"}]).pull_request_paths(7)
        with self.assertRaisesRegex(readiness.ReadinessError, "invalid pull request path"):
            Api(1, [{"filename": ""}]).pull_request_paths(7)
        self.assertEqual(Api(1, [{"filename": "README.md"}]).pull_request_paths(7), ["README.md"])

    def test_check_runs_are_limited_to_matching_github_suites_and_cached(self):
        head = "a" * 40

        class Api(readiness.GitHubApi):
            def __init__(self):
                super().__init__("cozyGarage/BookiE", "token", "https://api.github.com")
                self.suite_requests = []

            def pages(self, _path, _key=None):
                return [
                    {"name": "good", "head_sha": head, "app": {"slug": "github-actions"}, "check_suite": {"id": 1}},
                    {"name": "other-pr", "head_sha": head, "app": {"slug": "github-actions"}, "check_suite": {"id": 2}},
                    {
                        "name": "old-head",
                        "head_sha": "b" * 40,
                        "app": {"slug": "github-actions"},
                        "check_suite": {"id": 1},
                    },
                    {
                        "name": "other-app",
                        "head_sha": head,
                        "app": {"slug": "sonarqubecloud"},
                        "check_suite": {"id": 1},
                    },
                    {"name": "no-suite", "head_sha": head, "app": {"slug": "github-actions"}},
                ]

            def get(self, path):
                self.suite_requests.append(path)
                suite_id = int(path.rsplit("/", 1)[1])
                return {
                    "head_sha": head,
                    "app": {"slug": "github-actions"},
                    "pull_requests": [{"number": 7 if suite_id == 1 else 8}],
                }

        api = Api()
        for _ in range(2):
            result = api.check_runs_for_pull_request(7, head)

        self.assertEqual([run["name"] for run in result], ["good"])
        self.assertEqual(
            api.suite_requests,
            ["/repos/cozyGarage/BookiE/check-suites/1", "/repos/cozyGarage/BookiE/check-suites/2"],
        )

    def test_wait_for_checks_reports_failed_checks_and_times_out_pending_checks(self):
        required = readiness.required_contexts(["README.md"])

        class FailedClient:
            def pull_request_paths(self, _pull_number):
                return ["README.md"]

            def check_runs_for_pull_request(self, _pull_number, _head_sha):
                return [
                    {
                        "name": name,
                        "status": "completed",
                        "conclusion": "failure" if name == "release-note" else "success",
                        "id": index,
                    }
                    for index, name in enumerate(required, start=1)
                ]

        with self.assertRaisesRegex(readiness.ReadinessError, "checks failed"):
            readiness.wait_for_checks(FailedClient(), 7, "a" * 40, monotonic=lambda: 0)

        class PendingClient:
            def pull_request_paths(self, _pull_number):
                return ["README.md"]

            def check_runs_for_pull_request(self, _pull_number, _head_sha):
                return []

        times = iter((0, 0, 1))
        sleeps = []
        with self.assertRaisesRegex(readiness.ReadinessError, "Timed out waiting"):
            readiness.wait_for_checks(
                PendingClient(),
                7,
                "a" * 40,
                timeout_seconds=1,
                poll_seconds=0.5,
                sleep=sleeps.append,
                monotonic=lambda: next(times),
            )
        self.assertEqual(sleeps, [0.5])

    def test_main_uses_the_exact_pull_request_head_and_validates_inputs(self):
        values = {
            "GITHUB_REPOSITORY": "cozyGarage/BookiE",
            "GITHUB_TOKEN": "token",
            "PR_NUMBER": "17",
            "PR_HEAD_SHA": "a" * 40,
        }
        with (
            patch.dict(os.environ, values, clear=True),
            patch.object(readiness, "GitHubApi") as client,
            patch.object(readiness, "wait_for_checks", return_value=0) as wait,
        ):
            self.assertEqual(readiness.main(), 0)
        wait.assert_called_once_with(client.return_value, 17, "a" * 40)

        with patch.dict(os.environ, {"GITHUB_TOKEN": "", "PR_NUMBER": "7", "PR_HEAD_SHA": "bad"}, clear=True):
            with self.assertRaisesRegex(readiness.ReadinessError, "inputs are incomplete"):
                readiness.main()

    def test_cli_formats_readiness_errors_for_github_actions(self):
        env = dict(os.environ)
        env.update(
            {"GITHUB_REPOSITORY": "cozyGarage/BookiE", "GITHUB_TOKEN": "", "PR_NUMBER": "7", "PR_HEAD_SHA": "bad"}
        )
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/check-pr-readiness.py")],
            capture_output=True,
            check=False,
            env=env,
            text=True,
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("::error::Pull request readiness inputs are incomplete", result.stdout)

    def test_readiness_workflow_checks_exact_head_with_read_only_permissions(self):
        workflow = (ROOT / ".github/workflows/linux-pr-readiness.yml").read_text()
        checkout = workflow.split("- uses: actions/checkout", 1)[1].split("\n      - name", 1)[0]

        self.assertIn("pull_request:", workflow)
        self.assertNotIn("pull_request_target:", workflow)
        self.assertIn("ref: ${{ github.event.pull_request.head.sha }}", checkout)
        self.assertIn("  checks: read", workflow)
        self.assertIn("  contents: read", workflow)
        self.assertIn("  pull-requests: read", workflow)
        self.assertNotIn("contents: write", workflow)


if __name__ == "__main__":
    unittest.main()
