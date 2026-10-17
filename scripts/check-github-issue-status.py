#!/usr/bin/env python3
import argparse
import json
import re
import runpy
import subprocess
import sys
from pathlib import Path

REPOSITORY = "cozyGarage/BookiE"
REQUEST_TIMEOUT_SECONDS = 30
SCRIPT_DIR = Path(__file__).resolve().parent
CHECKER = runpy.run_path(str(SCRIPT_DIR / "check-known-issues.py"))


def fetch_issue_states(repository, runner=None):
    run = subprocess.run if runner is None else runner
    endpoint = f"repos/{repository}/issues?state=all&per_page=100"
    try:
        result = run(
            ["gh", "api", "--paginate", "--slurp", endpoint],
            capture_output=True,
            text=True,
            timeout=REQUEST_TIMEOUT_SECONDS,
            check=False,
        )
    except FileNotFoundError:
        return None, "gh CLI is not installed"
    except subprocess.TimeoutExpired:
        return None, f"gh api timed out after {REQUEST_TIMEOUT_SECONDS} seconds"

    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit status {result.returncode}"
        return None, f"gh api failed: {detail}"

    try:
        pages = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None, "gh api returned invalid JSON"

    if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
        return None, "gh api returned an unexpected response shape"

    states = {}
    for page in pages:
        for issue in page:
            if not isinstance(issue, dict):
                return None, "gh api returned an unexpected issue record"
            if "pull_request" in issue:
                continue
            number = issue.get("number")
            state = issue.get("state")
            if not isinstance(number, int) or not isinstance(state, str) or state.lower() not in {"open", "closed"}:
                return None, "gh api returned an issue without a valid number and state"
            states[number] = state.upper()
    return states, None


def stale_entries(entries, states):
    found = []
    for ident, number in entries:
        state = states.get(number)
        if state is None:
            found.append(f"{ident} (#{number}) was not returned by GitHub; state is unverified")
        elif state != "OPEN":
            found.append(f"{ident} (#{number}) is {state.lower()}")
    return found


def main(argv=None):
    parser = argparse.ArgumentParser(description="Check live GitHub states for the open-work issue index")
    parser.add_argument("--repo", default=REPOSITORY, help="GitHub repository in OWNER/NAME form")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo):
        parser.error("--repo must be OWNER/NAME")

    ledger = SCRIPT_DIR.parent / "docs/known-issues.md"
    text = ledger.read_text(encoding="utf-8")
    invalid = CHECKER["problems"](text)
    if invalid:
        for problem in invalid:
            print(f"known-issues.md: {problem}", file=sys.stderr)
        return 1

    entries = CHECKER["indexed_issues"](text)
    states, error = fetch_issue_states(args.repo)
    if error is not None:
        print(f"GitHub issue status unavailable: {error}", file=sys.stderr)
        return 2

    stale = stale_entries(entries, states)
    if stale:
        for problem in stale:
            print(f"known-issues.md: {problem}", file=sys.stderr)
        return 1

    print(f"GitHub issue status: {len(entries)} open ledger entries verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
