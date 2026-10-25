#!/usr/bin/env python3
import json
import os
import re
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

PAGE_SIZE = 100
REQUIRED_CODE_CHECKS = (
    "Pin tested revision",
    "Ensure CI debian-testing GTK image",
    "Preflight and sandbox tier (no GTK app)",
    "Fast checks (GTK)",
    "flatpak-builder (default)",
    "resolve-ref",
    "Security (security-policy)",
    "Security (supply-chain)",
)
REQUIRED_CONTRACT_CHECKS = ("harness", "workflow-lint", "workflow-security")
REQUIRED_ALWAYS = ("pr-title", "release-note")
CONTRACT_PREFIXES = (".github/workflows/", ".github/actions/", "scripts/", "apps/linux/packaging/", "docs/")
HEAD_SHA = re.compile(r"^[0-9a-f]{40}$")


class ReadinessError(Exception):
    pass


class TransientGitHubError(ReadinessError):
    pass


def required_contexts(paths):
    required = set(REQUIRED_ALWAYS)
    code_change = any(not path.startswith("docs/") and not path.endswith(".md") for path in paths)
    contract_change = any(path.startswith(CONTRACT_PREFIXES) or path.endswith(".md") for path in paths)
    if code_change:
        required.update(REQUIRED_CODE_CHECKS)
    if contract_change:
        required.update(REQUIRED_CONTRACT_CHECKS)
    return sorted(required)


def check_suite_matches(suite, pull_number, head_sha):
    if suite.get("head_sha") != head_sha:
        return False
    if suite.get("app", {}).get("slug") != "github-actions":
        return False
    return any(pull.get("number") == pull_number for pull in suite.get("pull_requests", []))


def latest_checks(runs):
    latest = {}
    for run in runs:
        name = run.get("name")
        if not name:
            continue
        stamp = run.get("started_at") or run.get("created_at") or ""
        key = (stamp, int(run.get("id", 0)))
        current = latest.get(name)
        if current is None or key > current[0]:
            latest[name] = (key, run)
    return {name: row[1] for name, row in latest.items()}


def evaluate_checks(required, runs):
    latest = latest_checks(runs)
    passed = []
    waiting = []
    failed = []
    for name in required:
        run = latest.get(name)
        if run is None:
            waiting.append(f"{name}: missing")
            continue
        if run.get("status") != "completed":
            waiting.append(f"{name}: {run.get('status') or 'unknown'}")
            continue
        if run.get("conclusion") == "success":
            passed.append(name)
            continue
        failed.append(f"{name}: {run.get('conclusion') or 'no conclusion'}")
    if failed:
        state = "failed"
    elif waiting:
        state = "waiting"
    else:
        state = "passed"
    return {"state": state, "passed": passed, "waiting": waiting, "failed": failed}


def retry_transient(operation, deadline, poll_seconds, sleep, monotonic):
    while True:
        try:
            return operation()
        except TransientGitHubError:
            remaining = deadline - monotonic()
            if remaining <= 0:
                raise ReadinessError("Timed out while reading GitHub check status") from None
            print("GitHub API is temporarily unavailable; retrying", flush=True)
            sleep(min(poll_seconds, remaining))


class GitHubApi:
    def __init__(self, repository, token, api_url):
        valid_repository = re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) and all(
            part not in {".", ".."} for part in repository.split("/")
        )
        if not valid_repository:
            raise ReadinessError("GitHub repository identity is invalid")
        self.repository = repository
        self.token = token
        self.api_url = api_url.rstrip("/")
        self.suite_matches = {}

    def get(self, path):
        request = Request(
            f"{self.api_url}{path}",
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            with urlopen(request, timeout=20) as response:
                return json.load(response)
        except HTTPError as error:
            if error.code == 429 or error.code >= 500:
                raise TransientGitHubError(f"GitHub API temporarily returned HTTP {error.code}") from None
            raise ReadinessError(f"GitHub API read failed with HTTP {error.code}") from None
        except URLError:
            raise TransientGitHubError("GitHub API is temporarily unavailable") from None

    def pages(self, path, key=None):
        collected = []
        page = 1
        while True:
            result = self.get(f"{path}?per_page={PAGE_SIZE}&page={page}")
            rows = result if key is None else result.get(key, [])
            if not isinstance(rows, list):
                raise ReadinessError("GitHub API returned an invalid list response")
            collected.extend(rows)
            if len(rows) < PAGE_SIZE:
                return collected
            page += 1

    def pull_request_paths(self, pull_number):
        base = f"/repos/{self.repository}/pulls/{pull_number}"
        pull = self.get(base)
        files = self.pages(f"{base}/files")
        changed_files = pull.get("changed_files")
        if not isinstance(changed_files, int) or changed_files != len(files):
            raise ReadinessError("Pull request file list is incomplete; split the pull request before merging")
        paths = []
        for file in files:
            filename = file.get("filename")
            previous_filename = file.get("previous_filename")
            if not isinstance(filename, str) or not filename:
                raise ReadinessError("GitHub API returned an invalid pull request path")
            if isinstance(previous_filename, str) and previous_filename:
                paths.append(previous_filename)
            paths.append(filename)
        return paths

    def check_runs_for_pull_request(self, pull_number, head_sha):
        runs = self.pages(f"/repos/{self.repository}/commits/{head_sha}/check-runs", "check_runs")
        suite_ids = {run.get("check_suite", {}).get("id") for run in runs}
        suite_ids.discard(None)
        matching_suites = set()
        for suite_id in suite_ids:
            if suite_id not in self.suite_matches:
                suite = self.get(f"/repos/{self.repository}/check-suites/{suite_id}")
                self.suite_matches[suite_id] = check_suite_matches(suite, pull_number, head_sha)
            if self.suite_matches[suite_id]:
                matching_suites.add(suite_id)
        return [
            run
            for run in runs
            if run.get("head_sha") == head_sha
            and run.get("app", {}).get("slug") == "github-actions"
            and run.get("check_suite", {}).get("id") in matching_suites
        ]


def wait_for_checks(
    client,
    pull_number,
    head_sha,
    *,
    timeout_seconds=5400,
    poll_seconds=60,
    sleep=time.sleep,
    monotonic=time.monotonic,
):
    deadline = monotonic() + timeout_seconds
    paths = retry_transient(
        lambda: client.pull_request_paths(pull_number), deadline, poll_seconds, sleep, monotonic
    )
    required = required_contexts(paths)
    print(f"Checking PR #{pull_number} head {head_sha}")
    print(f"Applicable check contexts: {', '.join(required)}")
    while True:
        runs = retry_transient(
            lambda: client.check_runs_for_pull_request(pull_number, head_sha),
            deadline,
            poll_seconds,
            sleep,
            monotonic,
        )
        result = evaluate_checks(required, runs)
        if result["state"] == "passed":
            print(f"All {len(required)} applicable GitHub checks passed on {head_sha}")
            return 0
        if result["state"] == "failed":
            raise ReadinessError("Applicable GitHub checks failed: " + "; ".join(result["failed"]))
        remaining = deadline - monotonic()
        if remaining <= 0:
            raise ReadinessError("Timed out waiting for applicable GitHub checks: " + "; ".join(result["waiting"]))
        print("Waiting for applicable GitHub checks: " + "; ".join(result["waiting"]), flush=True)
        sleep(min(poll_seconds, remaining))


def main():
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    token = os.environ.get("GITHUB_TOKEN", "")
    pull_number = os.environ.get("PR_NUMBER", "")
    head_sha = os.environ.get("PR_HEAD_SHA", "")
    if not token or not pull_number.isdigit() or not HEAD_SHA.fullmatch(head_sha):
        raise ReadinessError("Pull request readiness inputs are incomplete")
    client = GitHubApi(repository, token, os.environ.get("GITHUB_API_URL", "https://api.github.com"))
    return wait_for_checks(client, int(pull_number), head_sha)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ReadinessError as error:
        print(f"::error::{error}")
        sys.exit(1)
