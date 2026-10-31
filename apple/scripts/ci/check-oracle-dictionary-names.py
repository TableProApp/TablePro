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


def string_literals(source):
    """Yield (line, text, is_skipped) for each string literal outside comments."""
    i = 0
    line = 1
    length = len(source)
    while i < length:
        char = source[i]
        if char == "\n":
            line += 1
            i += 1
        elif source.startswith("//", i):
            end = source.find("\n", i)
            i = length if end == -1 else end
        elif source.startswith("/*", i):
            end = source.find("*/", i + 2)
            end = length if end == -1 else end + 2
            line += source.count("\n", i, end)
            i = end
        elif char == '"' or (char == "#" and source.startswith('#"', i)):
            hashes = 0
            while source.startswith("#", i + hashes):
                hashes += 1
            start = i + hashes
            multiline = source.startswith('"""', start)
            opener = '"""' if multiline else '"'
            closer = opener + "#" * hashes
            body_start = start + len(opener)
            before = source[max(0, i - 60):i]
            interpolation = "\\" + "#" * hashes + "("
            pieces = []
            j = body_start
            while j < length and not source.startswith(closer, j):
                if source.startswith(interpolation, j):
                    end = matching_paren(source, j + len(interpolation))
                    # An interpolation is Swift code: its own literals are checked on their own.
                    for inner_line, inner_text, inner_skipped in string_literals(source[j:end]):
                        yield line + source.count("\n", i, j) + inner_line - 1, inner_text, inner_skipped
                    pieces.append(" ")
                    j = end
                    continue
                if source[j] == "\\":
                    pieces.append(source[j:j + 2])
                    j += 2
                    continue
                if not multiline and source[j] == "\n":
                    break
                pieces.append(source[j])
                j += 1
            text = "".join(pieces)
            skipped = bool(
                LOCALIZED_CALL.search(before)
                or OWNER_CALL.search(before)
                or (LONE_WORD.match(text) and ARRAY_ELEMENT.search(before))
            )
            yield line, text, skipped
            line += source.count("\n", i, j)
            i = j + len(closer)
        else:
            i += 1


def matching_paren(source, start):
    """The index just past the parenthesis that closes the one opened before `start`."""
    depth = 1
    j = start
    while j < len(source) and depth:
        char = source[j]
        if char == '"':
            j += 1
            while j < len(source) and source[j] != '"':
                j += 2 if source[j] == "\\" else 1
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        j += 1
    return j


def violations(path):
    found = []
    source = path.read_text(encoding="utf-8")
    for line, text, skipped in string_literals(source):
        if skipped:
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
