#!/usr/bin/env python3

import argparse
import datetime
import importlib.util
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable, Dict, List, NamedTuple, Optional, Tuple

ROOT = Path(__file__).resolve().parent.parent.parent
FRAGMENTS = "changelog.d"
MAX_LEAD_LINES = 6
CRITICAL = " [CRITICAL]"
NO_LEAD = "This release is fixes and refinements. Every entry is in the changelog."
DOCS_CHANGELOG = "https://docs.tablepro.app/changelog"
VENV_COMMAND = "python3 -m venv .venv && .venv/bin/pip install --require-hashes -r scripts/release/requirements.txt"

FRAGMENT_NAME = re.compile(r"([0-9]+)\.[a-z]+(?:\.[0-9]+)?\.md")
SECTION_START = re.compile(r"## \[([^\]]+)\]")
HEADING = re.compile(
    r"## \[(?P<version>[^\]]+)\](?:\([^)]*\))?"
    r"(?: - (?P<date>[0-9]{4}-[0-9]{2}-[0-9]{2}))?(?P<critical> \[CRITICAL\])?\s*"
)
FENCE = re.compile(r" {0,3}(`{3,}|~{3,})")
DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
MAINTAINER_ASSOCIATIONS = {"OWNER", "MEMBER"}
DOCS_SECTIONS = {"Added": "New Features", "Changed": "Improvements", "Fixed": "Bug Fixes"}
MONTHS = ("January", "February", "March", "April", "May", "June", "July", "August", "September",
          "October", "November", "December")
UPDATE_BLOCK = re.compile(r'^<Update label="v([^"]+)"[^\n]*>\n.*?^</Update>$', re.MULTILINE | re.DOTALL)

Author = Tuple[str, str]


class NotesError(Exception):
    pass


class Section(NamedTuple):
    version: str
    date: Optional[str]
    is_critical: bool
    lead: List[str]
    entries: List[str]

    @property
    def body(self) -> str:
        parts = []
        if self.lead:
            parts.append("\n".join(self.lead))
        if self.entries:
            parts.append("\n".join(self.entries).strip("\n"))
        return "\n\n".join(parts)


def _closes(fence: str, line: str) -> bool:
    return re.fullmatch(r" {0,3}" + re.escape(fence[0]) + "{" + str(len(fence)) + r",}\s*", line) is not None


def find_section(changelog: str, version: str) -> Optional[Section]:
    heading = None
    lines: List[str] = []
    first_subsection = None
    fence = None
    for line in changelog.splitlines():
        if fence is not None:
            if _closes(fence, line):
                fence = None
        elif FENCE.match(line):
            fence = FENCE.match(line).group(1)
        elif SECTION_START.match(line):
            if heading is not None:
                break
            if SECTION_START.match(line).group(1) == version:
                heading = line
            continue
        elif heading is not None and first_subsection is None and line.startswith("### "):
            first_subsection = len(lines)
        if heading is not None:
            lines.append(line.rstrip())
    if heading is None:
        return None
    if first_subsection is None:
        first_subsection = len(lines)
    details = HEADING.fullmatch(heading)
    return Section(
        version=version,
        date=details.group("date") if details else None,
        is_critical=bool(details and details.group("critical")),
        lead=[line for line in lines[:first_subsection] if line.strip()],
        entries=lines[first_subsection:],
    )


def whats_new(version: str, changelog: Path, out: Path) -> bool:
    section = find_section(changelog.read_text(encoding="utf-8"), version)
    if section is None:
        if out.exists():
            out.unlink()
        return False
    lead = section.lead[:MAX_LEAD_LINES]
    body = "\n\n".join(lead) if lead else NO_LEAD
    out.write_text(f"# TablePro {version}\n\n{body}\n", encoding="utf-8")
    return True


def credit(text: str, author: Author) -> str:
    login, association = author
    if association in MAINTAINER_ASSOCIATIONS or " by @" in text:
        return text
    body = text.rstrip()
    trailing = text[len(body):]
    if body.endswith("."):
        return f"{body[:-1]} by @{login}.{trailing}"
    return f"{body} by @{login}{trailing}"


def credit_fragments(directory: Path, author_of: Callable[[int], Author]) -> None:
    if not directory.is_dir():
        return
    for path in sorted(directory.iterdir()):
        match = FRAGMENT_NAME.fullmatch(path.name)
        if not match:
            continue
        text = path.read_text(encoding="utf-8")
        credited = credit(text, author_of(int(match.group(1))))
        if credited != text:
            path.write_text(credited, encoding="utf-8")


class PullRequestAuthors:
    def __init__(self, repository: str, run: Callable = subprocess.run):
        self.repository = repository
        self._run = run
        self._cache: Dict[int, Author] = {}

    def __call__(self, number: int) -> Author:
        if number not in self._cache:
            result = self._run(
                ["gh", "api", f"repos/{self.repository}/pulls/{number}",
                 "--jq", "{login: .user.login, association: .author_association}"],
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                raise NotesError(f"gh could not read pull request #{number}: {result.stderr.strip()}")
            fields = json.loads(result.stdout)
            self._cache[number] = (fields["login"], fields["association"])
        return self._cache[number]


def fragment_files(root: Path) -> List[Path]:
    directory = root / FRAGMENTS
    if not directory.is_dir():
        return []
    return sorted(path for path in directory.iterdir() if path.is_file() and path.name != ".gitkeep")


def towncrier_command() -> List[str]:
    if importlib.util.find_spec("towncrier") is not None:
        return [sys.executable, "-m", "towncrier"]
    local = ROOT / ".venv" / "bin" / "towncrier"
    if local.exists():
        return [str(local)]
    raise NotesError(f"towncrier is not installed. Run: {VENV_COMMAND}")


def towncrier(root: Path, *args: str, run: Callable = subprocess.run) -> str:
    result = run([*towncrier_command(), *args], cwd=root, capture_output=True, text=True)
    if result.returncode != 0:
        raise NotesError(f"towncrier {args[0]} failed:\n{result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def draft(root: Path, version: str, author_of: Callable[[int], Author]) -> str:
    with tempfile.TemporaryDirectory() as scratch:
        scratch_root = Path(scratch)
        shutil.copy2(root / "towncrier.toml", scratch_root / "towncrier.toml")
        if (root / FRAGMENTS).is_dir():
            shutil.copytree(root / FRAGMENTS, scratch_root / FRAGMENTS)
        credit_fragments(scratch_root / FRAGMENTS, author_of)
        rendered = towncrier(root, "build", "--draft", "--config", str(scratch_root / "towncrier.toml"),
                             "--dir", str(scratch_root), "--version", version)
    lines = rendered.strip("\n").splitlines()
    if lines and SECTION_START.match(lines[0]):
        lines = lines[1:]
    return "\n".join(lines).strip("\n")


def stable_section(root: Path, version: str) -> Section:
    section = find_section((root / "CHANGELOG.md").read_text(encoding="utf-8"), version)
    if section is None:
        raise NotesError(f"CHANGELOG.md has no ## [{version}]")
    return section


def release_body(root: Path, version: str, author_of: Callable[[int], Author]) -> str:
    if _parse(version).is_beta:
        return draft(root, version, author_of) + "\n"
    return stable_section(root, version).body + "\n"


def feed(root: Path, version: str, author_of: Callable[[int], Author]) -> str:
    parsed = _parse(version)
    title = f"# What's New in TablePro {version}"
    if parsed.is_beta:
        link = f"[View release notes](https://github.com/{_repository()}/releases/tag/{parsed.tag})"
        return f"{title}\n\n{draft(root, version, author_of)}\n\n{link}\n"
    section = stable_section(root, version)
    lead = section.lead[:MAX_LEAD_LINES]
    body = "\n\n".join(lead) if lead else section.body
    return f"{title}\n\n{body}\n\n[View full changelog]({DOCS_CHANGELOG})\n"


def lead(root: Path, version: str) -> str:
    if _parse(version).is_beta:
        return ""
    lines = stable_section(root, version).lead[:MAX_LEAD_LINES]
    return "\n".join(lines) + "\n" if lines else ""


def critical(root: Path, version: str) -> bool:
    if _parse(version).is_beta:
        return False
    return stable_section(root, version).is_critical


def read_lead(path: Optional[Path]) -> List[str]:
    if path is None:
        return []
    lines = [line.rstrip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    if len(lines) > MAX_LEAD_LINES:
        raise NotesError(f"{path} has {len(lines)} lines; a lead block has at most {MAX_LEAD_LINES}")
    for line in lines:
        if line.startswith("#") or line.startswith("- "):
            raise NotesError(f"a lead line is plain text, not a heading or a list item: {line}")
    return lines


def git(root: Path, *args: str, run: Callable = subprocess.run) -> subprocess.CompletedProcess:
    return run(["git", "-C", str(root), *args], capture_output=True, text=True)


def assemble(root: Path, version: str, author_of: Callable[[int], Author], lead_lines: List[str],
             is_critical: bool, date: str, run: Callable = subprocess.run) -> None:
    # towncrier compares the fragment paths it lists with the ones git reports, which are resolved.
    root = root.resolve()
    parsed = _parse(version)
    if parsed.is_beta:
        raise NotesError(f"{version} is a beta; a beta is a tag with nothing committed")
    if lead_lines and parsed.patch != 0:
        raise NotesError("a lead block is for X.Y.0 only")
    if not DATE.fullmatch(date):
        raise NotesError(f"--date takes YYYY-MM-DD, got {date}")

    branch = f"origin/release/{parsed.line}"
    if git(root, "rev-parse", "--quiet", "--verify", f"{branch}^{{commit}}", run=run).returncode != 0:
        raise NotesError(f"{branch} does not exist; fetch it first")
    if git(root, "merge-base", "--is-ancestor", branch, "HEAD", run=run).returncode != 0:
        raise NotesError(f"HEAD does not contain {branch}; branch prep/{parsed.tag} from it")
    subjects = git(root, "log", "--format=%s", f"{branch}..HEAD", run=run).stdout.splitlines()
    # Reverting a stable that never published is the one commit allowed before the notes.
    extra = [subject for subject in subjects if not subject.startswith('Revert "')]
    if extra:
        raise NotesError(f"HEAD has commits that are not on {branch}: {extra[0]}")
    if not fragment_files(root):
        raise NotesError(f"{FRAGMENTS}/ has no fragments")

    changelog_path = root / "CHANGELOG.md"
    if find_section(changelog_path.read_text(encoding="utf-8"), version) is not None:
        raise NotesError(f"CHANGELOG.md already has ## [{version}]")

    credit_fragments(root / FRAGMENTS, author_of)
    towncrier(root, "build", "--yes", "--config", str(root / "towncrier.toml"), "--dir", str(root),
              "--version", version, "--date", date, run=run)

    lines = changelog_path.read_text(encoding="utf-8").split("\n")
    index = next((i for i, line in enumerate(lines) if line.startswith(f"## [{version}]")), None)
    if index is None:
        raise NotesError(f"towncrier wrote no ## [{version}] heading; check start_string in towncrier.toml")
    if is_critical:
        lines[index] += CRITICAL
    if lead_lines:
        lines[index + 1:index + 1] = ["", *lead_lines]
    changelog_path.write_text("\n".join(lines), encoding="utf-8")
    added = git(root, "add", "CHANGELOG.md", run=run)
    if added.returncode != 0:
        raise NotesError(f"git add CHANGELOG.md: {added.stderr.strip()}")


def _link(text: str, repository: str) -> str:
    pieces = re.split(r"(`+[^`]*`+)", text)
    for index in range(0, len(pieces), 2):
        piece = re.sub(r"(?<![\w\[/&])#([0-9]+)\b(?!\])",
                       rf"[#\1](https://github.com/{repository}/issues/\1)", pieces[index])
        pieces[index] = re.sub(r"(?<![\w\[/`])@([A-Za-z0-9][A-Za-z0-9-]*)(?![\w\]])",
                               r"[@\1](https://github.com/\1)", piece)
    return "".join(pieces)


def docs_date(date: str) -> str:
    year, month, day = (int(part) for part in date.split("-"))
    return f"{MONTHS[month - 1]} {day}, {year}"


def render_update(section: Section, repository: str) -> str:
    if section.date is None:
        raise NotesError(f"## [{section.version}] has no date")
    lines = [f'<Update label="v{section.version}" description="{docs_date(section.date)}">']
    for line in section.lead:
        lines += [f"  {_link(line, repository)}", ""]
    for line in section.entries:
        subsection = re.fullmatch(r"### (.+?)\s*", line)
        if subsection:
            name = subsection.group(1)
            lines.append(f"  ### {DOCS_SECTIONS.get(name, name)}")
        elif line.strip():
            lines.append(f"  {_link(line, repository)}")
        else:
            lines.append("")
    while lines and not lines[-1]:
        lines.pop()
    lines.append("</Update>")
    return "\n".join(lines)


def merge_update(mdx: str, version: str, block: str) -> str:
    matches = list(UPDATE_BLOCK.finditer(mdx))
    if not matches:
        return mdx.rstrip("\n") + "\n\n" + block + "\n"
    for previous, following in zip(matches, matches[1:]):
        if mdx[previous.end():following.start()].strip():
            raise NotesError(f"text between the v{previous.group(1)} and v{following.group(1)} blocks")
    blocks: Dict[str, str] = {}
    for match in matches:
        if match.group(1) in blocks:
            raise NotesError(f"two v{match.group(1)} blocks")
        blocks[match.group(1)] = match.group(0)
    blocks[version] = block
    try:
        ordered = sorted(blocks, key=lambda label: _parse(label).build, reverse=True)
    except ValueError as error:
        raise NotesError(f"an Update label is not a version: {error}") from error
    return mdx[:matches[0].start()] + "\n\n".join(blocks[label] for label in ordered) + mdx[matches[-1].end():]


def docs(root: Path, version: str, ref: str, mdx: Path, run: Callable = subprocess.run) -> None:
    if _parse(version).is_beta:
        raise NotesError(f"{version} is a beta; the docs changelog lists stables only")
    shown = git(root, "show", f"{ref}:CHANGELOG.md", run=run)
    if shown.returncode != 0:
        raise NotesError(f"git show {ref}:CHANGELOG.md: {shown.stderr.strip()}")
    section = find_section(shown.stdout, version)
    if section is None:
        raise NotesError(f"CHANGELOG.md at {ref} has no ## [{version}]")
    block = render_update(section, _repository())
    mdx.write_text(merge_update(mdx.read_text(encoding="utf-8"), version, block), encoding="utf-8")


# Imported on use: the What's New build phase runs this file in Xcode's script sandbox, which
# lets it read only its declared inputs, and version.py is not one of them.
def _parse(version: str):
    from version import parse_version
    return parse_version(version)


def _repository() -> str:
    from version import REPOSITORY
    return REPOSITORY


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Release notes from CHANGELOG.md and changelog.d/.")
    commands = parser.add_subparsers(dest="command", required=True)

    command = commands.add_parser("assemble", help="consume the fragments into a CHANGELOG.md section")
    command.add_argument("version")
    command.add_argument("--critical", action="store_true")
    command.add_argument("--lead", type=Path, help="a file of at most 6 lines, X.Y.0 only")
    command.add_argument("--date", default=datetime.date.today().isoformat())
    for name, text in (("body", "the GitHub release body"), ("feed", "the Sparkle release notes"),
                       ("lead", "the lead lines"), ("critical", "true or false")):
        commands.add_parser(name, help=text).add_argument("version")
    command = commands.add_parser("whats-new", help="write the bundle's WhatsNew.md")
    command.add_argument("version")
    command.add_argument("--changelog", type=Path, required=True)
    command.add_argument("--out", type=Path, required=True)
    command = commands.add_parser("docs", help="insert the version's block into the docs changelog.mdx")
    command.add_argument("version")
    command.add_argument("--ref", required=True)
    command.add_argument("--mdx", type=Path, required=True)
    args = parser.parse_args(argv)

    try:
        if args.command == "whats-new":
            whats_new(args.version, args.changelog, args.out)
        elif args.command == "assemble":
            assemble(ROOT, args.version, PullRequestAuthors(_repository()), read_lead(args.lead),
                     args.critical, args.date)
            print(f"CHANGELOG.md has ## [{args.version}]; review it with git diff --cached")
        elif args.command == "body":
            sys.stdout.write(release_body(ROOT, args.version, PullRequestAuthors(_repository())))
        elif args.command == "feed":
            sys.stdout.write(feed(ROOT, args.version, PullRequestAuthors(_repository())))
        elif args.command == "lead":
            sys.stdout.write(lead(ROOT, args.version))
        elif args.command == "critical":
            print("true" if critical(ROOT, args.version) else "false")
        elif args.command == "docs":
            docs(ROOT, args.version, args.ref, args.mdx)
    except (NotesError, ValueError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
