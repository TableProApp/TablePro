#!/usr/bin/env python3
"""Check every plugin source the iOS app compiles is explicitly nonisolated.

The iOS app target sets SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor, and it also compiles source
files that live under Plugins/ and belong to a macOS plugin target, which sets no such thing. So
one file has two default isolations: nonisolated in the plugin, MainActor in the app. Every
declaration in it that is not marked nonisolated is therefore @MainActor on iOS alone, and the
first nonisolated caller that touches it fails to compile with

    main actor-isolated property 'hasRangeTypes' can not be referenced from a nonisolated context

Nothing in the macOS build can see this: the plugin compiles the same file correctly. The iOS job
is the only thing that catches it, it runs only when a change touches an iOS path, and the error
arrives one symbol at a time, so fixing the reported symbol just uncovers the next one. That is
how main went red three times in a row over one missing keyword.

This check reads the shared file list out of TableProMobile/project.yml rather than repeating it,
so a file added to the iOS target is covered the moment it is added. It runs on Ubuntu in under a
second and needs no Xcode.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "TableProMobile" / "project.yml"

# A declaration that introduces a type, or a top-level function, constant or variable. Anything
# nested inside a type inherits that type's isolation, so only column-zero declarations matter.
DECLARATION = re.compile(
    r"^(?P<modifiers>(?:public |internal |private |fileprivate |final |open |indirect )*)"
    r"(?P<keyword>enum|struct|class|actor|extension|func|let|var)\s"
)

# Attributes that carry their own isolation, so the file is saying what it means.
ISOLATION_ATTRIBUTES = ("@MainActor", "@globalActor", "nonisolated")


def shared_sources() -> list[Path]:
    """Every ../Plugins/*.swift file listed in the iOS project."""
    text = PROJECT.read_text(encoding="utf-8")
    paths = re.findall(r"^\s*-\s*(\.\./Plugins/\S+\.swift)\s*$", text, re.MULTILINE)
    return [(PROJECT.parent / path).resolve() for path in sorted(set(paths))]


def offending_declarations(path: Path) -> list[tuple[int, str]]:
    """Top-level declarations in one file that state no isolation of their own."""
    found: list[tuple[int, str]] = []
    previous = ""
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = line.rstrip()
        if not stripped or stripped.startswith(("//", "/*", "*", "@", "import", "#")):
            previous = stripped
            continue
        if line[:1].isspace():
            previous = stripped
            continue
        if not DECLARATION.match(stripped):
            previous = stripped
            continue
        if stripped.startswith(ISOLATION_ATTRIBUTES) or previous.startswith(ISOLATION_ATTRIBUTES):
            previous = stripped
            continue
        found.append((number, stripped))
        previous = stripped
    return found


def main() -> int:
    if not PROJECT.is_file():
        print(f"not found: {PROJECT}", file=sys.stderr)
        return 3

    sources = shared_sources()
    if not sources:
        print("no shared plugin sources found in TableProMobile/project.yml", file=sys.stderr)
        return 3

    failures: list[str] = []
    for path in sources:
        if not path.is_file():
            failures.append(f"{path.relative_to(ROOT)}: listed in TableProMobile/project.yml but missing")
            continue
        for number, declaration in offending_declarations(path):
            failures.append(f"{path.relative_to(ROOT)}:{number}: {declaration}")

    if failures:
        print("These declarations are compiled into the iOS app, which defaults to MainActor,")
        print("and state no isolation of their own. Mark each one nonisolated:")
        print()
        for failure in failures:
            print(f"  {failure}")
        print()
        print(f"{len(failures)} declaration(s) across {len(sources)} shared file(s).")
        return 1

    print(f"{len(sources)} shared plugin sources, every top-level declaration isolated explicitly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
