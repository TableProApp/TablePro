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
CHANGELOG = "CHANGELOG.md"
CONFIG = "towncrier.toml"
FRAGMENTS = "changelog.d"
IGNORED = {".gitkeep"}
MAX_LINE = 120
MAX_LEAD_LINES = 6
VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
DATE = r"(?P<date>[0-9]{4}-[0-9]{2}-[0-9]{2})"
OLD_HEADING = re.compile(rf"## \[(?P<version>{VERSION})\] - {DATE}")
GIT_STATUSES = {"A": "added", "D": "removed"}


class Project(NamedTuple):
    directory: str
    tag: str
    release_files: Tuple[str, ...] = ()

    def path(self, name: str) -> str:
        return f"{self.directory}/{name}" if self.directory else name

    @property
    def changelog(self) -> str:
        return self.path(CHANGELOG)

    @property
    def fragments(self) -> str:
        return self.path(FRAGMENTS)

    @property
    def new_heading(self) -> "re.Pattern[str]":
        return re.compile(
            rf"## \[(?P<version>{VERSION})\]\(https://github\.com/{re.escape(REPOSITORY)}/releases/tag/"
            rf"{re.escape(self.tag)}(?P=version)\) - {DATE}(?: \[CRITICAL\])?"
        )

    @property
    def release_title(self) -> "re.Pattern[str]":
        # The forward-port keeps the release commit's subject, which ends in its (#N).
        return re.compile(rf"chore\(release\): {re.escape(self.tag)}{VERSION}(?: \(#[0-9]+\))?")


# Each directory with a towncrier.toml, and the tag its title_format links. The Linux release
# commit also sets the version and date that linux/build-aux/packaging/check_packaging.py compares.
PROJECTS = (
    Project("", "v"),
    Project("linux", "linux-v", ("meson.build", "data/app.tablepro.TablePro.metainfo.xml.in.in",
                                 "build-aux/rpm/tablepro.spec", "data/tablepro.1")),
)


class ChangedFile(NamedTuple):
    filename: str
    status: str


class CheckError(Exception):
    pass


def fragment_problems(directory: Path, fragments: str = FRAGMENTS) -> List[str]:
    if not directory.is_dir():
        return []
    problems = []
    for path in sorted(directory.iterdir()):
        name = f"{fragments}/{path.name}"
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


def changelog_problems(changelog: str, project: Project = PROJECTS[0]) -> List[str]:
    name = project.changelog
    lines = changelog.split("\n")
    markers = [index for index, line in enumerate(lines) if line == MARKER]
    if len(markers) != 1:
        return [f"{name} has {len(markers)} `{MARKER}` lines, expected 1"]
    marker = markers[0]
    problems = []

    first = next((index for index in range(marker + 1, len(lines)) if lines[index].startswith("## [")), None)
    if first is not None and lines[marker + 1:first] != [""]:
        problems.append(f"{name}:{marker + 1}: only one blank line goes between the marker and the first ## [")

    new_heading = project.new_heading
    versions: List[Tuple[int, ...]] = []
    seen: Dict[str, int] = {}
    for index, line in enumerate(lines):
        if not line.startswith("## "):
            continue
        number = index + 1
        if index < marker:
            problems.append(f"{name}:{number}: `{line}` is above the marker")
            continue
        old, new = OLD_HEADING.fullmatch(line), new_heading.fullmatch(line)
        heading = old or new
        if heading is None:
            problems.append(f"{name}:{number}: `{line}` is not `## [X.Y.Z](<release link>) - YYYY-MM-DD`")
            continue
        if not _is_date(heading.group("date")):
            problems.append(f"{name}:{number}: {heading.group('date')} is not a date")
        version = heading.group("version")
        if version in seen:
            problems.append(f"{name}:{number}: ## [{version}] repeats line {seen[version]}")
            continue
        seen[version] = number
        parsed = tuple(int(part) for part in version.split("."))
        if versions and parsed >= versions[-1]:
            problems.append(f"{name}:{number}: ## [{version}] is not below the version above it")
        versions.append(parsed)
        if new is not None:
            problems += _new_section_problems(changelog, version, f"{name}:{number}")
    return problems


def _new_section_problems(changelog: str, version: str, where: str) -> List[str]:
    section = notes.find_section(changelog, version)
    if section is None:
        return [f"{where}: notes.py cannot find ## [{version}]"]
    if not section.lead:
        return []
    problems = []
    if not version.endswith(".0"):
        problems.append(f"{where}: {version} has a lead block; only an X.Y.0 takes one")
    if len(section.lead) > MAX_LEAD_LINES:
        problems.append(f"{where}: the {version} lead block has {len(section.lead)} lines, over {MAX_LEAD_LINES}")
    for line in section.lead:
        if line.startswith(("#", "- ")):
            problems.append(f"{where}: the {version} lead line `{line}` is not plain text")
    return problems


def repository_problems(root: Path, projects: Tuple[Project, ...] = PROJECTS) -> List[str]:
    problems = []
    for project in projects:
        problems += changelog_problems((root / project.changelog).read_text(encoding="utf-8"), project)
        problems += fragment_problems(root / project.fragments, project.fragments)
    return problems


def _fragment_name(project: Project, path: str) -> Optional[str]:
    prefix = f"{project.fragments}/"
    return path[len(prefix):] if path.startswith(prefix) else None


def _owner(project: Project, path: str) -> Optional[str]:
    name = _fragment_name(project, path)
    return None if name is None else name.partition(".")[0]


def _listing(items: List[str]) -> str:
    return items[0] if len(items) == 1 else f"{', '.join(items[:-1])} and {items[-1]}"


def pull_request_problems(number: int, title: str, base: str, files: List[ChangedFile],
                          projects: Tuple[Project, ...] = PROJECTS) -> List[str]:
    problems = []
    for project in projects:
        problems += _project_pull_request_problems(project, number, title, base, files)
    return problems


def _project_pull_request_problems(project: Project, number: int, title: str, base: str,
                                   files: List[ChangedFile]) -> List[str]:
    # The pull request that adds a project's towncrier.toml brings its changelog and fragments as they are.
    if ChangedFile(project.path(CONFIG), "added") in files:
        return []
    problems = []
    if project.release_title.fullmatch(title):
        release_files = [project.changelog, *(project.path(name) for name in project.release_files)]
        others = [changed.filename for changed in files
                  if changed.filename not in release_files and _fragment_name(project, changed.filename) is None]
        if others:
            more = f" and {len(others) - 1} more" if len(others) > 1 else ""
            allowed = _listing([release_files[0], f"{project.fragments}/", *release_files[1:]])
            problems.append(f"a release pull request changes only {allowed}; "
                            f"this one also changes {others[0]}{more}")
    elif any(changed.filename == project.changelog for changed in files):
        problems.append(f"only a `chore(release): {project.tag}X.Y.Z` pull request edits {project.changelog}. "
                        f"Put the entry in {project.fragments}/{number}.<type>.md (.claude/rules/changelog.md)")
    if base != "main":
        return problems

    # A fragment deleted and added again under a new type keeps the pull request it is named for.
    removed = {_owner(project, changed.filename) for changed in files if changed.status == "removed"}
    for changed in files:
        name = _fragment_name(project, changed.filename)
        if changed.status != "added" or name is None or name in IGNORED:
            continue
        owner = name.partition(".")[0]
        if owner != str(number) and owner not in removed:
            rest = name.partition(".")[2]
            # A rest with no dot holds no type, so towncrier would refuse it as a suffix.
            if "." not in rest:
                rest = "<type>.md"
            problems.append(f"{changed.filename} is not named for this pull request. "
                            f"Name it {project.fragments}/{number}.{rest}")
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
    parser = argparse.ArgumentParser(description="Check each towncrier project's changelog.d/ and CHANGELOG.md.")
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
    if args.pr is None:
        print("OK: " + ", ".join(f"{project.fragments}/ and {project.changelog}" for project in PROJECTS))
    else:
        print(f"OK: the changelog files of #{args.pr}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
