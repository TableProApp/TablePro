#!/usr/bin/env python3

import argparse
import datetime
import importlib.util
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, NamedTuple, Optional, Tuple

ROOT = Path(__file__).resolve().parent.parent.parent
NOTES_SPEC = importlib.util.spec_from_file_location("notes", ROOT / "scripts" / "release" / "notes.py")
notes = importlib.util.module_from_spec(NOTES_SPEC)
NOTES_SPEC.loader.exec_module(notes)

REPOSITORY = "TableProApp/TablePro"
MARKER = "<!-- towncrier release notes start -->"
FRAGMENTS = "changelog.d"
IGNORED = {".gitkeep"}
MAX_LINE = 120
MAX_LEAD_LINES = 6
VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
DATE = r"(?P<date>[0-9]{4}-[0-9]{2}-[0-9]{2})"
OLD_HEADING = re.compile(rf"## \[(?P<version>{VERSION})\] - {DATE}")
NEW_HEADING = re.compile(
    rf"## \[(?P<version>{VERSION})\]\(https://github\.com/{re.escape(REPOSITORY)}/releases/tag/v(?P=version)\)"
    rf" - {DATE}(?: \[CRITICAL\])?"
)
# The forward-port to main keeps the release commit's subject, which ends in its (#N).
RELEASE_TITLE = re.compile(rf"chore\(release\): v{VERSION}(?: \(#[0-9]+\))?")
GIT_STATUSES = {"A": "added", "D": "removed"}


class ChangedFile(NamedTuple):
    filename: str
    status: str


class CheckError(Exception):
    pass


def fragment_problems(directory: Path) -> List[str]:
    if not directory.is_dir():
        return []
    problems = []
    for path in sorted(directory.iterdir()):
        name = f"{FRAGMENTS}/{path.name}"
        if path.name in IGNORED:
            continue
        if not path.is_file():
            problems.append(f"{name} is not a file")
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            problems.append(f"{name} is not UTF-8")
            continue
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        if len(lines) != 1:
            problems.append(f"{name} has {len(lines)} non-blank lines; a fragment is one line")
            continue
        line = lines[0]
        if len(line) > MAX_LINE:
            problems.append(f"{name} is {len(line)} characters, over the {MAX_LINE} limit")
        if line.startswith("- "):
            problems.append(f"{name} starts with `- `; towncrier adds the bullet")
        if "by @" in line:
            problems.append(f"{name} credits an author; notes.py adds the credit at release")
    return problems


def _is_date(text: str) -> bool:
    try:
        datetime.date.fromisoformat(text)
    except ValueError:
        return False
    return True


def changelog_problems(changelog: str) -> List[str]:
    lines = changelog.split("\n")
    markers = [index for index, line in enumerate(lines) if line == MARKER]
    if len(markers) != 1:
        return [f"CHANGELOG.md has {len(markers)} `{MARKER}` lines, expected 1"]
    marker = markers[0]
    problems = []

    first = next((index for index in range(marker + 1, len(lines)) if lines[index].startswith("## [")), None)
    if first is not None and lines[marker + 1:first] != [""]:
        problems.append(f"CHANGELOG.md:{marker + 1}: only one blank line goes between the marker and the first ## [")

    versions: List[Tuple[int, ...]] = []
    seen: Dict[str, int] = {}
    for index, line in enumerate(lines):
        if not line.startswith("## "):
            continue
        number = index + 1
        if index < marker:
            problems.append(f"CHANGELOG.md:{number}: `{line}` is above the marker")
            continue
        old, new = OLD_HEADING.fullmatch(line), NEW_HEADING.fullmatch(line)
        heading = old or new
        if heading is None:
            problems.append(f"CHANGELOG.md:{number}: `{line}` is not `## [X.Y.Z](<release link>) - YYYY-MM-DD`")
            continue
        if not _is_date(heading.group("date")):
            problems.append(f"CHANGELOG.md:{number}: {heading.group('date')} is not a date")
        version = heading.group("version")
        if version in seen:
            problems.append(f"CHANGELOG.md:{number}: ## [{version}] repeats line {seen[version]}")
            continue
        seen[version] = number
        parsed = tuple(int(part) for part in version.split("."))
        if versions and parsed >= versions[-1]:
            problems.append(f"CHANGELOG.md:{number}: ## [{version}] is not below the version above it")
        versions.append(parsed)
        if new is not None:
            problems += _new_section_problems(changelog, version, number)
    return problems


def _new_section_problems(changelog: str, version: str, number: int) -> List[str]:
    section = notes.find_section(changelog, version)
    if section is None:
        return [f"CHANGELOG.md:{number}: notes.py cannot find ## [{version}]"]
    if not section.lead:
        return []
    problems = []
    if not version.endswith(".0"):
        problems.append(f"CHANGELOG.md:{number}: {version} has a lead block; only an X.Y.0 takes one")
    if len(section.lead) > MAX_LEAD_LINES:
        problems.append(f"CHANGELOG.md:{number}: the {version} lead block has {len(section.lead)} lines, "
                        f"over {MAX_LEAD_LINES}")
    for line in section.lead:
        if line.startswith(("#", "- ")):
            problems.append(f"CHANGELOG.md:{number}: the {version} lead line `{line}` is not plain text")
    return problems


def repository_problems(root: Path) -> List[str]:
    return (changelog_problems((root / "CHANGELOG.md").read_text(encoding="utf-8"))
            + fragment_problems(root / FRAGMENTS))


def _owner(path: str) -> Optional[str]:
    if not path.startswith(f"{FRAGMENTS}/"):
        return None
    return path[len(FRAGMENTS) + 1:].partition(".")[0]


def pull_request_problems(number: int, title: str, base: str, files: List[ChangedFile]) -> List[str]:
    problems = []
    if RELEASE_TITLE.fullmatch(title):
        others = [changed.filename for changed in files
                  if changed.filename != "CHANGELOG.md" and _owner(changed.filename) is None]
        if others:
            more = f" and {len(others) - 1} more" if len(others) > 1 else ""
            problems.append(f"a release pull request changes only CHANGELOG.md and {FRAGMENTS}/; "
                            f"this one also changes {others[0]}{more}")
    elif any(changed.filename == "CHANGELOG.md" for changed in files):
        problems.append(f"only a `chore(release): vX.Y.Z` pull request edits CHANGELOG.md. Put the entry in "
                        f"{FRAGMENTS}/{number}.<type>.md (.claude/rules/changelog.md)")
    if base != "main":
        return problems

    # A fragment deleted and added again under a new type keeps the pull request it is named for.
    removed = {_owner(changed.filename) for changed in files if changed.status == "removed"}
    for changed in files:
        owner = _owner(changed.filename)
        if changed.status != "added" or owner is None or changed.filename[len(FRAGMENTS) + 1:] in IGNORED:
            continue
        if owner != str(number) and owner not in removed:
            rest = changed.filename[len(FRAGMENTS) + 1:].partition(".")[2] or "<type>.md"
            problems.append(f"{changed.filename} is not named for this pull request. "
                            f"Name it {FRAGMENTS}/{number}.{rest}")
    return problems


def changed_files(root: Path) -> List[ChangedFile]:
    result = subprocess.run(["git", "diff", "--name-status", "--no-renames", "-z", "HEAD^1", "HEAD"],
                            cwd=root, capture_output=True, text=True)
    if result.returncode != 0:
        raise CheckError(f"git diff HEAD^1 HEAD: {result.stderr.strip()}")
    fields = result.stdout.split("\0")[:-1]
    return [ChangedFile(path, GIT_STATUSES.get(status, "modified"))
            for status, path in zip(fields[0::2], fields[1::2])]


def workflow_command_data(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Check changelog.d/ and CHANGELOG.md.")
    parser.add_argument("--pr", type=int,
                        help="check the files this pull request changes instead, from its merge commit at HEAD")
    parser.add_argument("--title", help="the pull request's title, with --pr")
    parser.add_argument("--base", help="the branch the pull request merges into, with --pr")
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    if args.pr is not None and (args.title is None or args.base is None):
        parser.error("--pr needs --title and --base")

    try:
        if args.pr is None:
            problems = repository_problems(args.root)
        else:
            problems = pull_request_problems(args.pr, args.title, args.base, changed_files(args.root))
    except (CheckError, OSError, ValueError) as error:
        problems = [str(error)]

    for problem in problems:
        print(f"::error title=Changelog::{workflow_command_data(problem)}")
    if problems:
        return 1
    print("OK: changelog.d/ and CHANGELOG.md" if args.pr is None else f"OK: the changelog files of #{args.pr}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
