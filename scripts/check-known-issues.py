#!/usr/bin/env python3
import re
import sys
from pathlib import Path

STATUSES = {"OPEN", "DONE", "UNVERIFIED", "ACCEPTED"}
ROW = re.compile(r"^\|\s*([A-Z0-9]+-[0-9a-z]+)\s*\|(.*)\|\s*$")


def problems(text):
    found = []
    seen = set()
    for number, line in enumerate(text.splitlines(), 1):
        match = ROW.match(line)
        if not match:
            continue
        ident = match.group(1)
        cells = [cell.strip() for cell in match.group(2).split("|")]
        if len(cells) != 4:
            found.append(f"line {number}: {ident} has {len(cells) + 1} columns, expected 5")
            continue
        issue, status, evidence, _layer = cells
        if ident in seen:
            found.append(f"line {number}: duplicate id {ident}")
        seen.add(ident)
        if status not in STATUSES:
            found.append(f"line {number}: {ident} has unknown status {status!r}")
        crossed = issue.startswith("~~") and issue.endswith("~~")
        if status == "DONE" and not crossed:
            found.append(f"line {number}: {ident} is DONE but not crossed out")
        if status != "DONE" and crossed:
            found.append(f"line {number}: {ident} is crossed out but {status}")
        if status == "DONE" and not evidence:
            found.append(f"line {number}: {ident} is DONE without evidence")
    return found


OWNERS_HEADING = "## Owners and handoff"
ID = re.compile(r"\b[A-Z0-9]+-\d+[a-z]?\b")


def owner_problems(text):
    ledger = {}
    for line in text.splitlines():
        match = ROW.match(line)
        if match:
            cells = [cell.strip() for cell in match.group(2).split("|")]
            if len(cells) == 4:
                ledger[match.group(1)] = cells[1]
    if OWNERS_HEADING not in text:
        return ["the ledger has no owners section"]
    section = text.split(OWNERS_HEADING, 1)[1].split("\n## ", 1)[0]
    listed = []
    for line in section.splitlines():
        if line.startswith("|"):
            columns = line.split("|")
            if len(columns) > 3:
                listed.extend(ID.findall(columns[2]))
    found = []
    for ident in sorted({ident for ident in listed if listed.count(ident) > 1}):
        found.append(f"{ident} has more than one owner")
    for ident in sorted(set(listed) - ledger.keys()):
        found.append(f"{ident} is listed as owned but is not in the ledger")
    for ident, status in sorted(ledger.items()):
        if status in {"OPEN", "UNVERIFIED"} and ident not in listed:
            found.append(f"{ident} is {status} and has no owner")
    return found


def main():
    path = Path(__file__).resolve().parents[1] / "docs/known-issues.md"
    text = path.read_text()
    found = problems(text) + owner_problems(text)
    for problem in found:
        print(f"known-issues.md: {problem}", file=sys.stderr)
    if not found:
        print("known issues: ok")
    return 1 if found else 0


if __name__ == "__main__":
    raise SystemExit(main())
