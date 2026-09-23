#!/usr/bin/env python3
"""Check no source publishes an error's text to the system log.

`.swiftlint.yml` forbids it through the `public_error_text_in_log` custom rule, because a driver
error's text carries row values, paths and server messages: PostgreSQL puts the offending value in
a unique-violation message, and `.public` hands it to any process that reads the log and to every
sysdiagnose. Two things kept the rule from holding. SwiftLint's `included:` names `TablePro` and
`Packages` only, so it never read `Plugins/`, where fifteen log lines broke it. And SwiftLint runs
in CI only on a release tag, so nothing checked the rule on a pull request anywhere.

Bringing all of `Plugins/` under SwiftLint is the fuller answer and a larger one: measured on
2026-09-23 with SwiftLint 0.65.1, `swiftlint lint --strict` over the 536 plugin sources outside
TableProPluginKit, passed as file paths, reports 175 violations across 23 plugins, and only 15 of
them were this rule.

So this applies the one rule to every Swift file under `TablePro/`, `Packages/` and `Plugins/`,
across line breaks the way SwiftLint matches it. It reads the regex out of `.swiftlint.yml` rather
than repeating it, so the lint rule and this check cannot drift apart. It runs on Ubuntu in about a
second with no Xcode, and `test_check_log_privacy.py` pins what the regex must and must not match.

A regex sees one interpolation, not where its text came from: an error's description bound to a
variable first and published under another name passes. Those sites are found by reading.

`TableProMobile/` is not scanned yet: it still holds log lines this rule rejects.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

RULE = "public_error_text_in_log"
SCANNED = ("TablePro", "Packages", "Plugins")
SKIPPED_DIRECTORIES = {".build", "checkouts", "DerivedData"}


def rule_pattern(config: Path) -> re.Pattern[str]:
    lines = config.read_text(encoding="utf-8").splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.strip() == f"{RULE}:")
    except StopIteration:
        raise SystemExit(f"error: {config.name} has no `{RULE}` custom rule") from None

    indent = len(lines[start]) - len(lines[start].lstrip())
    for line in lines[start + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            break
        match = re.match(r"\s*regex:\s*'(?P<body>(?:[^']|'')*)'\s*$", line)
        if match:
            return re.compile(match.group("body").replace("''", "'"))
    raise SystemExit(f"error: the `{RULE}` rule in {config.name} has no single-quoted regex")


def sources(root: Path) -> list[Path]:
    seen: set[Path] = set()
    found = []
    for directory in SCANNED:
        for path in sorted((root / directory).rglob("*.swift")):
            if SKIPPED_DIRECTORIES.intersection(path.relative_to(root).parts):
                continue
            resolved = path.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            found.append(path)
    return found


def offenders(root: Path, pattern: re.Pattern[str]) -> list[str]:
    found = []
    for path in sources(root):
        text = path.read_text(encoding="utf-8", errors="replace")
        for match in pattern.finditer(text):
            number = text.count("\n", 0, match.start()) + 1
            found.append(f"{path.relative_to(root)}:{number}")
    return found


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
    pattern = rule_pattern(root / ".swiftlint.yml")
    found = offenders(root, pattern)
    if not found:
        return 0

    print("These log lines publish an error's text, which can carry row values, paths and server")
    print("messages. Publish `error.publicLogShape` in the app, or")
    print("`LogRedaction.publicDescription(of: error)` elsewhere, and log the description at .private:")
    for site in found:
        print(f"  {site}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
