#!/usr/bin/env python3
"""Keep a release's complete Markdown, with new features before fixes."""

from pathlib import Path
import re
import sys


SECTION_ORDER = {
    "added": 1,
    "features": 1,
    "new features": 1,
    "changed": 2,
    "performance": 2,
    "fixed": 3,
}


def extract_notes(changelog, version):
    # Keep each section intact, including nested lists, code, and unknown headings.
    # The sort is stable, so sections at the same priority keep their original order.
    sections = [(0, [])]
    found = False
    fence = None
    for line in changelog.splitlines(keepends=True):
        if fence is not None:
            if re.fullmatch(r" {0,3}" + re.escape(fence[0]) + "{" + str(len(fence)) + r",}\s*", line):
                fence = None
            if found:
                sections[-1][1].append(line)
            continue

        opening_fence = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if opening_fence:
            fence = opening_fence[1]
            if found:
                sections[-1][1].append(line)
            continue

        release = re.match(r"^## \[([^]]+)\]", line)
        if release:
            if found:
                break
            found = release[1] == version
            continue

        if found:
            heading = re.match(r"^### (.+?)\s*$", line)
            if heading:
                sections.append((SECTION_ORDER.get(heading[1].casefold(), 4), []))
            sections[-1][1].append(line)

    blocks = ["".join(lines).strip("\n") for _, lines in sorted(sections, key=lambda section: section[0])]
    notes = "\n\n".join(block for block in blocks if block.strip())
    if not notes.strip():
        raise ValueError(f"No release notes found for version {version} in CHANGELOG.md")
    return notes + "\n"


def main():
    if len(sys.argv) != 2:
        sys.exit("Usage: extract-release-notes.py <version>")
    try:
        notes = extract_notes(Path("CHANGELOG.md").read_text(encoding="utf-8"), sys.argv[1])
        Path("release_notes.md").write_text(notes, encoding="utf-8")
    except (OSError, ValueError) as error:
        sys.exit(f"ERROR: {error}")
    print(f"Release notes extracted for {sys.argv[1]}:")
    print(notes, end="")


if __name__ == "__main__":
    main()
