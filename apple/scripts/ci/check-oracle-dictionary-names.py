#!/usr/bin/env python3
"""Fail when Oracle or Dameng SQL names a data dictionary object without its SYS owner.

Oracle resolves a bare `ALL_TABLES`, `DUAL`, `V$SESSION` or `PLAN_TABLE` in the session's current schema
before the public synonym, so a schema the reader switched into can plant a view that runs with the reader's
privileges. `OracleDictionary` is the one place that spells these names; every other string literal
reaches them through it. Skipped: localized messages, the name handed to an `OracleDictionary` call,
and a lone word in an array literal (a keyword list), none of which is SQL.

Usage:
    check-oracle-dictionary-names.py [path...]    # default: the Oracle and Dameng sources
"""

import re
import sys
from pathlib import Path

from swift_string_literals import string_literals

APPLE = Path(__file__).resolve().parents[2]

DEFAULT_PATHS = [
    APPLE / "Packages/TableProOracle/Sources",
    APPLE / "Plugins/OracleDriverPlugin",
    APPLE / "Plugins/DamengDriverPlugin",
    APPLE / "TablePro/Core/ServerDashboard/Providers/OracleDashboardProvider.swift",
    APPLE / "TableProMobile/TableProMobile/Drivers/OracleDriver.swift",
]

OWNER_FILE = "OracleDictionary.swift"

QUALIFIED = re.compile(r"\bSYS\.[A-Z_$0-9]+")
# A lowercase alias in front marks a column (`c.USER_GENERATED`), not an object.
BARE = re.compile(r"(?<![a-z]\.)\b(?:ALL|DBA|USER)_[A-Z_]+\b|\bDUAL\b|\bG?V\$[A-Z_]+|\bPLAN_TABLE\b")
# Without INTO, EXPLAIN PLAN writes to whatever PLAN_TABLE resolves to.
EXPLAIN_PLAN = re.compile(r"\bEXPLAIN\s+PLAN\b")
INTO = re.compile(r"\bINTO\b")
LOCALIZED_CALL = re.compile(r"String\(\s*localized:\s*$")
OWNER_CALL = re.compile(r"OracleDictionary\.(?:view|performanceView|package)\(\s*$")
LONE_WORD = re.compile(r"^[A-Z_$#0-9]+$")
ARRAY_ELEMENT = re.compile(r"[\[,]\s*$")


def violations(path):
    found = []
    source = path.read_text(encoding="utf-8")
    for line, text, before in string_literals(source):
        if (
            LOCALIZED_CALL.search(before)
            or OWNER_CALL.search(before)
            or (LONE_WORD.match(text) and ARRAY_ELEMENT.search(before))
        ):
            continue
        stripped = QUALIFIED.sub(" ", text)
        for match in BARE.finditer(stripped):
            offset = line + stripped.count("\n", 0, match.start())
            found.append((offset, match.group(0)))
        explain = EXPLAIN_PLAN.search(text)
        if explain and not INTO.search(text, explain.end()):
            found.append((line + text.count("\n", 0, explain.start()), "PLAN_TABLE"))
    return found


def swift_files(paths):
    for path in paths:
        if path.is_file():
            yield path
        elif path.is_dir():
            yield from sorted(path.rglob("*.swift"))


def main(argv):
    paths = [Path(arg) for arg in argv] or DEFAULT_PATHS
    missing = [path for path in paths if not path.exists()]
    if missing:
        for path in missing:
            print(f"error: {path} does not exist", file=sys.stderr)
        return 2
    failures = 0
    for path in swift_files(paths):
        if path.name == OWNER_FILE:
            continue
        for line, name in violations(path):
            failures += 1
            print(f"{path}:{line}: {name} has no SYS owner; name it through OracleDictionary")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
