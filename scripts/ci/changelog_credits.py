#!/usr/bin/env python3
"""Credit every CHANGELOG entry of one version to the pull request that added it.

An outside contributor's entry ends `(#123 by @author)`, a maintainer's ends `(#123)`. An issue
reference stays first: `(#1748, #2741 by @author)`. A maintainer is a pull request author whose role
on the repository is admin or maintain.

The credit comes from the history: `git blame` names the commit that wrote each entry line, a squash
merge ends its subject with `(#123)`, and `gh pr view` names that pull request's author. Blame
reports the last commit to touch a line, so reword a contributor's entry in their own pull request.
An entry whose commit has no pull request number, or that is not committed yet, is left alone and
listed. When an author's role cannot be read, the entry keeps the handle and the login is listed.

Usage:
    python3 scripts/ci/changelog_credits.py [--section Unreleased] [--dry-run]

Run it from the repository root. It rewrites CHANGELOG.md in place and is idempotent.
"""

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REFERENCES = re.compile(r"\s*\((#\d+(?:,\s*#\d+)*)\)\s*$")
CREDITED = re.compile(r"\(#\d+(?:,\s*#\d+)* by @[A-Za-z0-9][A-Za-z0-9-]*\)\s*$")
PULL_REQUEST_SUBJECT = re.compile(r"\(#(\d+)\)\s*$")
UNCOMMITTED = "0" * 40
MAINTAINER_ROLES = {"admin", "maintain"}


def is_entry(line):
    return line.startswith("- ")


def is_credited(line):
    return CREDITED.search(line) is not None


def normalized_login(login):
    """`gh` reports a GitHub App as `app/name`, which GitHub itself renders as `@name`."""
    return login.split("/", 1)[1] if login.startswith("app/") else login


def credit_entry(line, pull_request, author=None):
    """`line` with the pull request folded into its reference parens, and `by @author` unless None."""
    if is_credited(line):
        return line
    body = line.rstrip()
    references = []
    existing = REFERENCES.search(body)
    if existing:
        references = [reference.strip() for reference in existing.group(1).split(",")]
        body = body[:existing.start()]
    if f"#{pull_request}" not in references:
        references.append(f"#{pull_request}")
    credit = "" if author is None else f" by @{normalized_login(author)}"
    return f"{body} ({', '.join(references)}{credit})"


def section_bounds(lines, section):
    """Zero-based `[start, end)` of the entries under `## [section]`, heading excluded."""
    heading = f"## [{section}]"
    start = next((index for index, line in enumerate(lines) if line.startswith(heading)), None)
    if start is None:
        raise ValueError(f"CHANGELOG.md has no {heading} section")
    end = next(
        (index for index in range(start + 1, len(lines)) if lines[index].startswith("## [")),
        len(lines),
    )
    return start + 1, end


@dataclass
class BlamedLine:
    sha: str
    summary: str


def parse_blame(porcelain):
    """One `BlamedLine` per line of `git blame --line-porcelain` output, in order."""
    blamed = []
    sha = None
    summary = ""
    for line in porcelain.split("\n"):
        header = re.match(r"^([0-9a-f]{40}) \d+ \d+", line)
        if header:
            sha = header.group(1)
            summary = ""
        elif line.startswith("summary "):
            summary = line[len("summary "):]
        elif line.startswith("\t") and sha is not None:
            blamed.append(BlamedLine(sha=sha, summary=summary))
    return blamed


def pull_request_of(blamed):
    if blamed.sha == UNCOMMITTED:
        return None
    match = PULL_REQUEST_SUBJECT.search(blamed.summary)
    return match.group(1) if match else None


def blame_section(start, end):
    result = subprocess.run(
        ["git", "blame", "--line-porcelain", "-L", f"{start + 1},{end}", "--", "CHANGELOG.md"],
        capture_output=True,
        text=True,
        check=True,
    )
    return parse_blame(result.stdout)


def author_of(pull_request, cache):
    if pull_request not in cache:
        result = subprocess.run(
            ["gh", "pr", "view", pull_request, "--json", "author"],
            capture_output=True,
            text=True,
            check=True,
        )
        cache[pull_request] = json.loads(result.stdout)["author"]["login"]
    return cache[pull_request]


class Maintainers:
    """Whether a login holds the admin or maintain role on the repository, asked once per login."""

    def __init__(self, run=subprocess.run):
        self._run = run
        self._roles = {}
        self.unknown = set()

    def includes(self, login):
        if login.startswith("app/"):
            return False
        if login not in self._roles:
            self._roles[login] = self._role_of(login)
        return self._roles[login] in MAINTAINER_ROLES

    def _role_of(self, login):
        result = self._run(
            ["gh", "api", f"repos/{{owner}}/{{repo}}/collaborators/{login}/permission", "--jq", ".role_name"],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            self.unknown.add(login)
            return None
        return result.stdout.strip()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--section", default="Unreleased", help="the version heading to credit")
    parser.add_argument("--dry-run", action="store_true", help="print the result instead of writing it")
    args = parser.parse_args(argv)

    path = Path("CHANGELOG.md")
    lines = path.read_text(encoding="utf-8").split("\n")
    try:
        start, end = section_bounds(lines, args.section)
    except ValueError as error:
        sys.exit(f"ERROR: {error}")
    if start == end:
        print(f"[{args.section}] has no entries")
        return 0

    blamed = blame_section(start, end)
    if len(blamed) != end - start:
        sys.exit("ERROR: git blame did not return one record per line")

    authors = {}
    maintainers = Maintainers()
    credited = 0
    skipped = []
    for offset, record in enumerate(blamed):
        index = start + offset
        line = lines[index]
        if not is_entry(line) or is_credited(line):
            continue
        pull_request = pull_request_of(record)
        if pull_request is None:
            reason = "not committed yet" if record.sha == UNCOMMITTED else f"{record.sha[:9]} has no pull request number"
            skipped.append(f"line {index + 1}: {reason}: {line[:90]}")
            continue
        author = author_of(pull_request, authors)
        handle = None if maintainers.includes(author) else author
        lines[index] = credit_entry(line, pull_request, handle)
        credited += 1

    if args.dry_run:
        print("\n".join(lines[start:end]))
    else:
        path.write_text("\n".join(lines), encoding="utf-8")

    logins = set(authors.values())
    inside = sorted(normalized_login(login) for login in logins if maintainers.includes(login))
    outside = sorted(normalized_login(login) for login in logins if not maintainers.includes(login))
    print(f"Credited {credited} entries in [{args.section}] across {len(authors)} pull requests.")
    print(f"Maintainers, credited by pull request only: {', '.join('@' + login for login in inside) or 'none'}")
    print(f"Contributors: {', '.join('@' + login for login in outside) or 'none'}")
    for login in sorted(maintainers.unknown):
        print(f"Role unknown, credited by handle: @{login}")
    for line in skipped:
        print(f"Left uncredited, {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
