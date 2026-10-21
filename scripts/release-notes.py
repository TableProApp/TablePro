import argparse
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
CHANGELOG = ROOT / "CHANGELOG.md"
REPO = "https://github.com/cozyGarage/BookiE"
UNRELEASED = "## [Unreleased]"


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
    parser = argparse.ArgumentParser(description="Release notes from CHANGELOG.md.")
    commands = parser.add_subparsers(dest="command", required=True)
    notes = commands.add_parser("notes", help="print the body of one version's section")
    notes.add_argument("version")
    cutting = commands.add_parser("cut", help="move Unreleased entries under a new version heading")
    cutting.add_argument("version")
    cutting.add_argument("date")
    args = parser.parse_args()
    text = CHANGELOG.read_text()
    if args.command == "notes":
        sys.stdout.write(section(text, args.version))
        return
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.date):
        raise SystemExit("date must be YYYY-MM-DD")
    CHANGELOG.write_text(cut(text, args.version, args.date))


if __name__ == "__main__":
    main()
