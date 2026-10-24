import argparse
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CHANGELOG = ROOT / "CHANGELOG.md"
REPO = "https://github.com/cozyGarage/BookiE"
UNRELEASED = "## [Unreleased]"


CATEGORIES = ("Added", "Changed", "Deprecated", "Removed", "Fixed", "Security")
TRAILER = re.compile(r"(?m)^Release-Note:[ \t]*(.*?)[ \t]*$")
PULL_NUMBER = re.compile(r"\(#(\d+)\)\s*$")
MAX_NOTE = 300


def parse_notes(message):
    """Return (entries, errors) for the Release-Note trailers of a commit or PR body."""
    values = TRAILER.findall(message)
    if not values:
        return [], ["no Release-Note line: add `Release-Note: <Category>: <text>` or `Release-Note: none`"]
    entries, errors = [], []
    has_none = any(value.lower() == "none" for value in values)
    for value in values:
        if value.lower() == "none":
            continue
        category, _, text = value.partition(":")
        text = text.strip()
        if category not in CATEGORIES:
            errors.append(f"unknown category {category!r}; use one of {', '.join(CATEGORIES)}")
        elif not text:
            errors.append(f"empty {category} note")
        elif len(text) > MAX_NOTE:
            errors.append(f"{category} note is longer than {MAX_NOTE} characters")
        else:
            entries.append((category, text))
    if has_none and (entries or len(values) > 1):
        errors.append("`Release-Note: none` cannot be combined with other notes")
    return entries, errors


def assemble(commits, allow_missing=False):
    """Group the notes of (subject, message) pairs under Keep a Changelog headings."""
    grouped = {category: [] for category in CATEGORIES}
    problems = []
    for subject, message in commits:
        entries, errors = parse_notes(message)
        if errors:
            problems.append(f"{subject}: {errors[0]}")
            continue
        pull = PULL_NUMBER.search(subject)
        suffix = f" (#{pull.group(1)})" if pull else ""
        for category, text in entries:
            grouped[category].append(text + suffix)
    if problems and not allow_missing:
        raise SystemExit("release notes incomplete:\n" + "\n".join(problems))
    parts = []
    for category in CATEGORIES:
        if grouped[category]:
            parts.append(f"### {category}\n\n" + "\n".join(f"- {line}" for line in grouped[category]))
    if not parts:
        raise SystemExit("no release notes in the selected range")
    return "\n\n".join(parts) + "\n"


def commits_between(since, until):
    log = subprocess.run(
        ["git", "log", "--reverse", "--format=%s%x1f%B%x1e", f"{since}..{until}"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout
    pairs = []
    for record in log.split("\x1e"):
        if record.strip():
            subject, _, message = record.strip("\n").partition("\x1f")
            pairs.append((subject, message))
    return pairs


def section(text, version):
    heading = re.search(rf"(?m)^## \[{re.escape(version)}\][^\n]*\n", text)
    if heading is None:
        raise SystemExit(f"CHANGELOG.md has no section for {version}")
    following = re.search(r"(?m)^## ", text[heading.end():])
    end = heading.end() + following.start() if following else len(text)
    body = text[heading.end():end].strip()
    if not body:
        raise SystemExit(f"the {version} section of CHANGELOG.md is empty")
    return body + "\n"


def cut(text, version, date):
    if re.search(rf"(?m)^## \[{re.escape(version)}\]", text):
        raise SystemExit(f"CHANGELOG.md already has a section for {version}")
    if UNRELEASED not in text:
        raise SystemExit("CHANGELOG.md has no Unreleased section")
    text = text.replace(UNRELEASED, f"{UNRELEASED}\n\n## [{version}] - {date}", 1)
    text = re.sub(r"(?m)^\[Unreleased\]: .*$", f"[Unreleased]: {REPO}/compare/linux-v{version}...linux", text)
    version_link = f"[{version}]: {REPO}/releases/tag/linux-v{version}"
    version_link_pattern = rf"(?m)^\[{re.escape(version)}\]: .*$"
    if re.search(version_link_pattern, text):
        return re.sub(version_link_pattern, version_link, text)
    return text.rstrip() + f"\n{version_link}\n"


def main():
    parser = argparse.ArgumentParser(description="Release notes from CHANGELOG.md or Release-Note trailers.")
    commands = parser.add_subparsers(dest="command", required=True)
    notes = commands.add_parser("notes", help="print the body of one version's section")
    notes.add_argument("version")
    cutting = commands.add_parser("cut", help="move Unreleased entries under a new version heading")
    cutting.add_argument("version")
    cutting.add_argument("date")
    checking = commands.add_parser("check", help="validate the Release-Note lines of a PR body or commit message")
    checking.add_argument("file", nargs="?", default="-", help="path, or - for standard input")
    trailers = commands.add_parser("trailers", help="print only the validated Release-Note lines of a PR body, for `gh pr merge --body-file`")
    trailers.add_argument("file", nargs="?", default="-", help="path, or - for standard input")
    assembling = commands.add_parser("assemble", help="build release notes from Release-Note trailers in a commit range")
    assembling.add_argument("--since", required=True, help="exclusive start revision, normally the previous tag")
    assembling.add_argument("--until", default="HEAD")
    assembling.add_argument("--allow-missing", action="store_true", help="skip commits without a Release-Note line")
    args = parser.parse_args()
    if args.command == "check":
        body = sys.stdin.read() if args.file == "-" else Path(args.file).read_text()
        _, errors = parse_notes(body)
        if errors:
            raise SystemExit("Release-Note check failed: " + "; ".join(errors))
        return
    if args.command == "trailers":
        body = sys.stdin.read() if args.file == "-" else Path(args.file).read_text()
        _, errors = parse_notes(body)
        if errors:
            raise SystemExit("Release-Note check failed: " + "; ".join(errors))
        sys.stdout.write("\n".join(f"Release-Note: {value}" for value in TRAILER.findall(body)) + "\n")
        return
    if args.command == "assemble":
        sys.stdout.write(assemble(commits_between(args.since, args.until), args.allow_missing))
        return
    text = CHANGELOG.read_text()
    if args.command == "notes":
        sys.stdout.write(section(text, args.version))
        return
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.date):
        raise SystemExit("date must be YYYY-MM-DD")
    CHANGELOG.write_text(cut(text, args.version, args.date))


if __name__ == "__main__":
    main()
