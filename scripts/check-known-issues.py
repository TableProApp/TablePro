#!/usr/bin/env python3
import re
import sys
from pathlib import Path

PROJECT_URL = "https://github.com/users/cozyGarage/projects/3"
LANES = {"B3", "B4", "UX", "Maintainer"}
ID = re.compile(r"^[A-Z0-9]+-\d+[a-z]?$")
ISSUE = re.compile(
    r"^\[#(\d+)\]\(https://github\.com/cozyGarage/BookiE/issues/\1\)$"
)
ROW = re.compile(r"^\|\s*([^|]+)\s*\|\s*([^|]+)\s*\|\s*([^|]+)\s*\|\s*$")
INDEX_HEADING = "## Open work index"


def problems(text):
    found = []
    if PROJECT_URL not in text:
        found.append(f"missing project URL {PROJECT_URL}")
    if INDEX_HEADING not in text:
        found.append("missing open work index heading")
        return found
    section = text.split(INDEX_HEADING, 1)[1].split("\n## ", 1)[0]
    seen = set()
    rows = 0
    for number, line in enumerate(section.splitlines(), 1):
        if not line.startswith("|"):
            continue
        match = ROW.match(line)
        if not match:
            continue
        ident, issue, lane = (cell.strip() for cell in match.groups())
        if ident in {"ID", "---"} or ident.startswith("---"):
            continue
        rows += 1
        if not ID.match(ident):
            found.append(f"index line {number}: bad id {ident!r}")
            continue
        if ident in seen:
            found.append(f"index line {number}: duplicate id {ident}")
        seen.add(ident)
        if not ISSUE.match(issue):
            found.append(f"index line {number}: {ident} issue link must be [#N](https://github.com/cozyGarage/BookiE/issues/N)")
        if lane not in LANES:
            found.append(f"index line {number}: {ident} has unknown lane {lane!r}")
    if rows == 0:
        found.append("open work index has no rows")
    return found


def main():
    path = Path(__file__).resolve().parents[1] / "docs/known-issues.md"
    text = path.read_text()
    found = problems(text)
    for problem in found:
        print(f"known-issues.md: {problem}", file=sys.stderr)
    if not found:
        print("known issues: ok")
    return 1 if found else 0


if __name__ == "__main__":
    raise SystemExit(main())
