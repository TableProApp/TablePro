#!/usr/bin/env python3
"""Keep a release's complete Markdown, with new features before fixes.

With --highlights-only, emit just the lead block: the lines a version section carries before its
first `### ` heading. That is what the update window and the What's New surface read, because the
full section is not something anyone reads in a dialog. 0.73.0's appcast item ran 22,443 bytes and
231 list items, and the feed grows by about that much per release for every install that polls it.

The lead block is optional. When a version has none, this falls back to the full notes rather than
failing: the release job runs under `set -euo pipefail` about forty minutes in, after both
notarized builds, and a forgotten heading is not worth losing that to.
"""

import argparse
import re
import sys
from pathlib import Path

SECTION_ORDER = {
    "added": 1,
    "features": 1,
    "new features": 1,
    "changed": 2,
    "performance": 2,
    "fixed": 3,
}

MAX_HIGHLIGHT_LINES = 6


def extract_sections(changelog, version):
    """Every section of one version, as (priority, lines). Index 0 is the lead block."""
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
    return sections


def extract_notes(changelog, version):
    # Keep each section intact, including nested lists, code, and unknown headings.
    # The sort is stable, so sections at the same priority keep their original order.
    sections = extract_sections(changelog, version)
    blocks = ["".join(lines).strip("\n") for _, lines in sorted(sections, key=lambda section: section[0])]
    notes = "\n\n".join(block for block in blocks if block.strip())
    if not notes.strip():
        raise ValueError(f"No release notes found for version {version} in CHANGELOG.md")
    return notes + "\n"


def extract_highlights(changelog, version, require_lead=False):
    """The lead block, capped at MAX_HIGHLIGHT_LINES.

    Falls back to the full notes when a version has none, unless `require_lead`. The feed wants
    the fallback, because failing a release forty minutes in over a missing heading is worse than
    a long dialog. A file shipped inside the app bundle wants the opposite: 270 entries is not
    something to compile into the product.
    """
    sections = extract_sections(changelog, version)
    lead = [line for line in sections[0][1] if line.strip()]
    if not lead:
        if require_lead:
            raise ValueError(f"Version {version} has no lead block in CHANGELOG.md")
        return extract_notes(changelog, version)
    return "".join(lead[:MAX_HIGHLIGHT_LINES])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("version")
    parser.add_argument(
        "--highlights-only",
        action="store_true",
        help="emit the lead block instead of every section, falling back to the full notes",
    )
    parser.add_argument(
        "--require-lead-block",
        action="store_true",
        help="with --highlights-only, fail instead of falling back to the full notes",
    )
    parser.add_argument("--out", default="release_notes.md", help="where to write (default: release_notes.md)")
    args = parser.parse_args(argv)

    try:
        changelog = Path("CHANGELOG.md").read_text(encoding="utf-8")
        notes = extract_highlights(changelog, args.version, require_lead=args.require_lead_block) \
            if args.highlights_only else extract_notes(changelog, args.version)
        Path(args.out).write_text(notes, encoding="utf-8")
    except (OSError, ValueError) as error:
        sys.exit(f"ERROR: {error}")

    label = "Release highlights" if args.highlights_only else "Release notes"
    print(f"{label} extracted for {args.version} into {args.out}:")
    print(notes, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
