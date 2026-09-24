#!/usr/bin/env python3
"""Check every plugin source that logs through OSLog imports the module that defines it.

The 40 plugin targets build with SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY, so a member is
only visible when the file importing it names a module that declares it. A file that writes

    logger.warning("read failed: \\(error.publicLogShape, privacy: .public)")

with only `import Foundation` fails with

    instance method 'warning' is not available due to missing import of defining module 'os'

and it fails once per interpolation segment, so one line produces eight errors.

Either `import os` or `import OSLog` satisfies it, measured on this toolchain at
-target arm64-apple-macos13.0 with the feature enabled: both compile a `Logger` built at file
scope, a `.debug` call and a `.warning` carrying a `privacy: .public` interpolation, and dropping
both fails at `Logger` itself. So this check accepts either and does not prefer one, or it would
report PostgreSQLPluginDriver+EnumTypes.swift, which imports OSLog alone and compiles.

This is a merge-order trap rather than an ordinary compile error. The feature flag arrived in one
pull request and the files that needed the import were fixed in that same one; a file added in any
other pull request open at the time compiles fine on its own branch, where the flag is not set yet,
and only breaks once both land. That is how main broke with MySQLPluginDriver+CatalogFallback.swift
and MySQLPluginDriver+Schema.swift, each green on its own branch.

Compiling every plugin catches it, but only after both sides are merged. This runs on Ubuntu in
under a second with no Xcode, so it catches it on whichever pull request adds the file.
"""

from __future__ import annotations

import pathlib
import re
import sys

PLUGINS = pathlib.Path(__file__).resolve().parents[2] / "Plugins"

LOGGING_USE = re.compile(
    r"""\b(?:
        Logger\s*\(
      | logger\s*\.\s*(?:debug|info|notice|warning|error|fault|critical|log)\b
      | os_log\b
      | OSLogType\b
    )""",
    re.VERBOSE,
)
IMPORTS_OS = re.compile(r"^\s*import\s+(?:os|OSLog)\s*$", re.MULTILINE)


def offenders() -> list[pathlib.Path]:
    found = []
    for path in sorted(PLUGINS.rglob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="replace")
        if LOGGING_USE.search(text) and not IMPORTS_OS.search(text):
            found.append(path)
    return found


def main() -> int:
    if not PLUGINS.is_dir():
        print(f"error: {PLUGINS} is not a directory", file=sys.stderr)
        return 1

    found = offenders()
    if not found:
        return 0

    root = PLUGINS.parent
    print("These plugin sources log through OSLog without importing a module that defines it.")
    print("Add `import os` beside `import Foundation`:")
    for path in found:
        print(f"  {path.relative_to(root)}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
