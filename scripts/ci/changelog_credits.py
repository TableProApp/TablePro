#!/usr/bin/env python3
"""Credit every CHANGELOG entry of one version to the pull request and the person that added it.

GitHub's generated release notes end each line with `by @author in #123`. The CHANGELOG is what
the release body is built from, so it carries the same credit, in the parens every entry already
ends with: `(#123 by @author)`, or `(#1748, #2741 by @author)` when the entry names an issue.

An entry cannot carry this when it is written: the pull request has no number until it is opened,
and a contributor should not have to push a second commit to add one. So the release stamps it.
The credit comes from the history, not from anyone's memory:

1. `git blame` names the commit that wrote each entry line.
2. A squash merge ends its subject with the pull request number, `(#123)`.
3. `gh pr view` names that pull request's author, which is the person credited, never whoever
   merged it.

Blame reports the last commit to touch a line, so a maintainer who rewords a contributor's entry
takes the credit for it. Reword in the contributor's own pull request, or restore the credit by
hand. An entry whose commit carries no pull request number (a direct push) is left alone and
listed, and so is a working-tree line that is not committed yet.

Usage:
    python3 scripts/ci/changelog_credits.py [--section Unreleased] [--dry-run]

Run it from the repository root. It rewrites CHANGELOG.md in place and is idempotent: an entry
that already ends in a credit is never touched again.
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


def is_entry(line):
    return line.startswith("- ")


def is_credited(line):
    return CREDITED.search(line) is not None


def normalized_login(login):
    """`gh` reports a GitHub App as `app/name`, which GitHub itself renders as `@name`."""
    return login.split("/", 1)[1] if login.startswith("app/") else login


def credit_entry(line, pull_request, author):
    """`line` with `(#pull_request by @author)` folded into the reference parens it ends with."""
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
    return f"{body} ({', '.join(references)} by @{normalized_login(author)})"


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
        lines[index] = credit_entry(line, pull_request, author_of(pull_request, authors))
        credited += 1

    if args.dry_run:
        print("\n".join(lines[start:end]))
    else:
        path.write_text("\n".join(lines), encoding="utf-8")

    contributors = sorted({normalized_login(login) for login in authors.values()})
    print(f"Credited {credited} entries in [{args.section}] across {len(authors)} pull requests.")
    print(f"Contributors: {', '.join('@' + login for login in contributors) or 'none'}")
    for line in skipped:
        print(f"Left uncredited, {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
