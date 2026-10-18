#!/usr/bin/env python3

import argparse
import datetime
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable, Dict, List, NamedTuple, Optional, Tuple

ROOT = Path(__file__).resolve().parent.parent.parent
NOTES_SPEC = importlib.util.spec_from_file_location("notes", ROOT / "scripts" / "release" / "notes.py")
notes = importlib.util.module_from_spec(NOTES_SPEC)
NOTES_SPEC.loader.exec_module(notes)

REPOSITORY = "TableProApp/TablePro"
MARKER = "<!-- towncrier release notes start -->"
FRAGMENTS = "changelog.d"
IGNORED = {".gitkeep"}
MAX_LINE = 120
TYPE_DIRECTORY = re.compile(r'^\[\[tool\.towncrier\.type\]\]\ndirectory = "([a-z]+)"$', re.MULTILINE)
VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
DATE = r"(?P<date>[0-9]{4}-[0-9]{2}-[0-9]{2})"
OLD_HEADING = re.compile(rf"## \[(?P<version>{VERSION})\] - {DATE}")
NEW_HEADING = re.compile(
    rf"## \[(?P<version>{VERSION})\]\(https://github\.com/{re.escape(REPOSITORY)}/releases/tag/v(?P=version)\)"
    rf" - {DATE}(?: \[CRITICAL\])?"
)
# The forward-port to main keeps the release commit's subject, which ends in its (#N).
RELEASE_TITLE = re.compile(rf"chore\(release\): v{VERSION}(?: \(#[0-9]+\))?")
NEW_STATUSES = {"added", "copied"}


class Fragment(NamedTuple):
    owner: str
    kind: str
    counter: Optional[str]


class ChangedFile(NamedTuple):
    filename: str
    status: str
    previous_filename: Optional[str] = None


class CheckError(Exception):
    pass


def fragment_types(towncrier_toml: str) -> List[str]:
    return TYPE_DIRECTORY.findall(towncrier_toml)


def parse_fragment_name(name: str, types: List[str]) -> Optional[Fragment]:
    match = re.fullmatch(
        rf"(?P<owner>[0-9]+|\+[a-z0-9][a-z0-9-]*)\.(?P<kind>{'|'.join(types)})(?:\.(?P<counter>[1-9][0-9]*))?\.md",
        name,
    )
    if not match:
        return None
    return Fragment(match.group("owner"), match.group("kind"), match.group("counter"))


def fragment_problems(directory: Path, types: List[str]) -> List[str]:
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
        if parse_fragment_name(path.name, types) is None:
            problems.append(f"{name} is not named <PR>.<type>.md or <PR>.<type>.<n>.md, with type one of "
                            + ", ".join(types))
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
    problems = []
    if len(section.lead) > notes.MAX_LEAD_LINES:
        problems.append(f"CHANGELOG.md:{number}: the {version} lead block has {len(section.lead)} lines, "
                        f"over {notes.MAX_LEAD_LINES}")
    with tempfile.TemporaryDirectory() as scratch:
        source = Path(scratch, "CHANGELOG.md")
        source.write_text(changelog, encoding="utf-8")
        if not notes.whats_new(version, source, Path(scratch, "WhatsNew.md")):
            problems.append(f"CHANGELOG.md:{number}: notes.py whats-new renders nothing for {version}")
    return problems


def repository_problems(root: Path) -> List[str]:
    types = fragment_types((root / "towncrier.toml").read_text(encoding="utf-8"))
    if not types:
        return ["towncrier.toml defines no [[tool.towncrier.type]]"]
    return (changelog_problems((root / "CHANGELOG.md").read_text(encoding="utf-8"))
            + fragment_problems(root / FRAGMENTS, types))


def _fragment_in(path: Optional[str], types: List[str]) -> Optional[Fragment]:
    if path is None or not path.startswith(f"{FRAGMENTS}/"):
        return None
    return parse_fragment_name(path[len(FRAGMENTS) + 1:], types)


def pull_request_problems(number: int, title: str, base: str, files: List[ChangedFile],
                          types: List[str]) -> List[str]:
    problems = []
    expected = f"{FRAGMENTS}/{number}.<type>.md"
    if any("CHANGELOG.md" in (changed.filename, changed.previous_filename) for changed in files) \
            and not RELEASE_TITLE.fullmatch(title):
        problems.append(f"only a `chore(release): vX.Y.Z` pull request edits CHANGELOG.md. Put the entry in "
                        f"{expected}, with type one of {', '.join(types)} (.claude/rules/changelog.md)")
    if base != "main":
        return problems

    # A fragment deleted and added again under a new type keeps the pull request it is named for.
    removed = {fragment.owner for fragment in
               (_fragment_in(changed.filename, types) for changed in files if changed.status == "removed")
               if fragment is not None}
    for changed in files:
        if changed.status not in NEW_STATUSES or not changed.filename.startswith(f"{FRAGMENTS}/"):
            continue
        if changed.filename[len(FRAGMENTS) + 1:] in IGNORED:
            continue
        fragment = _fragment_in(changed.filename, types)
        if fragment is None:
            problems.append(f"{changed.filename} is not a fragment name. Name it {expected}")
        elif fragment.owner != str(number) and fragment.owner not in removed:
            counter = f".{fragment.counter}" if fragment.counter else ""
            problems.append(f"{changed.filename} is named for another pull request. "
                            f"Name it {FRAGMENTS}/{number}.{fragment.kind}{counter}.md")
    return problems


def _gh(run: Callable, endpoint: str, jq: str, paginate: bool = False) -> List[str]:
    command = ["gh", "api", *(["--paginate"] if paginate else []), endpoint, "--jq", jq]
    result = run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise CheckError(f"gh api {endpoint}: {result.stderr.strip()}")
    return [line for line in result.stdout.splitlines() if line.strip()]


def fetch_pull_request(number: int, repository: str,
                       run: Callable = subprocess.run) -> Tuple[str, str, List[ChangedFile]]:
    endpoint = f"repos/{repository}/pulls/{number}"
    details = json.loads(_gh(run, endpoint, "{title: .title, base: .base.ref} | @json")[0])
    entries = _gh(run, f"{endpoint}/files", ".[] | {filename, status, previous_filename} | @json", paginate=True)
    files = [ChangedFile(entry["filename"], entry["status"], entry.get("previous_filename"))
             for entry in map(json.loads, entries)]
    return details["title"], details["base"], files


def workflow_command_data(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def main(argv: Optional[List[str]] = None, run: Callable = subprocess.run) -> int:
    parser = argparse.ArgumentParser(description="Check changelog.d/ and CHANGELOG.md.")
    parser.add_argument("--pr", type=int, help="check the files this pull request changes instead")
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(argv)

    try:
        if args.pr is None:
            problems = repository_problems(args.root)
        else:
            types = fragment_types((args.root / "towncrier.toml").read_text(encoding="utf-8"))
            repository = os.environ.get("GITHUB_REPOSITORY", REPOSITORY)
            title, base, files = fetch_pull_request(args.pr, repository, run)
            problems = pull_request_problems(args.pr, title, base, files, types)
    except (CheckError, OSError, ValueError, KeyError, IndexError) as error:
        problems = [str(error)]

    for problem in problems:
        print(f"::error title=Changelog::{workflow_command_data(problem)}")
    if problems:
        return 1
    print("OK: changelog.d/ and CHANGELOG.md" if args.pr is None else f"OK: the changelog files of #{args.pr}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
