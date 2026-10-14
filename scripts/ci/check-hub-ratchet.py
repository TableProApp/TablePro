#!/usr/bin/env python3
"""Fail when a hub of the app grows past the size recorded in .github/hub-ratchet-baseline.json.

A count may go down, never up. After a change lowers one, run with --update to record the new
floor. --update never raises a value: growing a hub means editing the baseline by hand, in a diff
a reviewer sees.

Usage:
    check-hub-ratchet.py [--root <repo>]            # compare with the baseline
    check-hub-ratchet.py [--root <repo>] --update   # lower the baseline to what the tree holds
    check-hub-ratchet.py [--root <repo>] --print    # print the counts as JSON
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

BASELINE = ".github/hub-ratchet-baseline.json"
APP = "TablePro"

SHELL_EXTENSION = re.compile(r"^(MainContentCoordinator|MainSplitViewController|MainContentCommandActions)\+(\w+)\.swift$")

# Words that name a module of the modularization plan. A word matches at a camel-case boundary,
# with an optional plural "s", so MAINMenu does not match AI and Charter does not match Chart.
MODULE_WORDS = (
    "AI", "Agent", "AppleScript", "Backup", "Chart", "CodeFolding", "CompareSync", "Copilot",
    "CopyObjects", "CredentialProfile", "DataFile", "DuplicateDatabase", "ERDiagram",
    "HighlightRule", "InlineSuggestion", "LinkedFolder", "MCP", "NativeDump", "ObjectCopy",
    "PasswordSource", "PlanBaseline", "PreConnect", "Proxy", "QueryInsight", "ResultMap", "Rewind",
    "ServerDashboard", "SharedConnection", "SOCKS", "SQLFolder", "TableMaintenance", "Tunnel",
    "UsersRoles",
)

ENGINES = {
    "BigQuery": r"BigQuery",
    "Beancount": r"Beancount",
    "Cassandra": r"Cassandra",
    "ClickHouse": r"ClickHouse",
    "Cloudflare": r"Cloudflare",
    "CockroachDB": r"Cockroach",
    "Dameng": r"Dameng",
    "Databend": r"Databend",
    "DuckDB": r"DuckDB",
    "DynamoDB": r"DynamoDB",
    "Elasticsearch": r"Elasticsearch",
    "etcd": r"Etcd|etcd",
    "HANA": r"HANA|Hana",
    "Kafka": r"Kafka",
    "libSQL": r"LibSQL|libSQL",
    "MariaDB": r"MariaDB",
    "MongoDB": r"Mongo",
    "MySQL": r"MySQL",
    "OceanBase": r"OceanBase",
    "Oracle": r"Oracle",
    "PostgreSQL": r"Postgre",
    "Redis": r"Redis",
    "Redshift": r"Redshift",
    "ScyllaDB": r"Scylla",
    "Snowflake": r"Snowflake",
    "Spanner": r"Spanner",
    "SQL Server": r"MSSQL|(?<!Postgre)SQLServer",
    "SQLite": r"SQLite",
    "SurrealDB": r"Surreal",
    "Teradata": r"Teradata",
    "TiDB": r"TiDB",
    "Trino": r"Trino",
    "Turso": r"Turso",
    "Typesense": r"Typesense",
    "Weaviate": r"Weaviate",
}

ENUMS = {
    "ShortcutAction cases": "ShortcutAction",
    "TabType cases": "TabType",
    "SettingsPane cases": "SettingsPane",
    "ActiveSheet cases": "ActiveSheet",
    "LaunchIntent cases": "LaunchIntent",
}

LITERAL_START = re.compile(r'//|/\*|#*"')
STRING_STOP = re.compile(r'[\\"\n]')
PAREN_OR_LITERAL = re.compile(r'[()]|//|/\*|#*"')
TYPE_DECLARATION = re.compile(r"\b(?:class|struct|enum|actor|protocol|typealias)\s+([A-Z]\w*)")
IDENTIFIER = re.compile(r"\b[A-Z]\w*")
PROPERTY = re.compile(
    r"^[ \t]*(?:@[\w.]+(?:\([^)\n]*\))?\s+)*((?:\w+(?:\(\w+\))?[ \t]+)*?)(var|let)[ \t]+(?=\w)",
    re.MULTILINE,
)
SELECTOR_ARM = re.compile(r"\bcase\s+#selector\b")
CONTINUATION = frozenset(",=:.&|+-*/")


class RatchetError(Exception):
    pass


def literal_end(text: str, index: int) -> int:
    if text.startswith("//", index):
        newline = text.find("\n", index)
        return len(text) if newline < 0 else newline
    if text.startswith("/*", index):
        depth = 0
        position = index
        while position < len(text):
            if text.startswith("/*", position):
                depth += 1
                position += 2
            elif text.startswith("*/", position):
                depth -= 1
                position += 2
                if depth == 0:
                    return position
            else:
                position += 1
        return len(text)
    hashes = 0
    while text[index + hashes] == "#":
        hashes += 1
    opening = index + hashes
    multiline = text.startswith('"""', opening)
    delimiter = ('"""' if multiline else '"') + "#" * hashes
    escape = "\\" + "#" * hashes
    position = opening + (3 if multiline else 1)
    while True:
        stop = STRING_STOP.search(text, position)
        if stop is None:
            return len(text)
        position = stop.start()
        if text.startswith(escape, position):
            after = position + len(escape)
            position = interpolation_end(text, after) if text.startswith("(", after) else after + 1
        elif text.startswith(delimiter, position):
            return position + len(delimiter)
        elif text[position] == "\n" and not multiline:
            return position
        else:
            position += 1


def interpolation_end(text: str, index: int) -> int:
    depth = 0
    position = index
    while True:
        match = PAREN_OR_LITERAL.search(text, position)
        if match is None:
            return len(text)
        token = match.group()
        if token == "(":
            depth += 1
            position = match.end()
        elif token == ")":
            depth -= 1
            position = match.end()
            if depth == 0:
                return position
        else:
            position = literal_end(text, match.start())


def blank_literals(text: str) -> str:
    """The source with every comment and string literal replaced by spaces, newlines kept."""
    parts: list[str] = []
    position = 0
    while True:
        match = LITERAL_START.search(text, position)
        if match is None:
            parts.append(text[position:])
            return "".join(parts)
        end = literal_end(text, match.start())
        parts.append(text[position:match.start()])
        parts.append(re.sub(r"[^\n]", " ", text[match.start():end]))
        position = end


def depth_at(code: str, index: int) -> int:
    return code.count("{", 0, index) - code.count("}", 0, index)


def closing_brace(code: str, opening: int) -> int:
    depth = 0
    for position in range(opening, len(code)):
        if code[position] == "{":
            depth += 1
        elif code[position] == "}":
            depth -= 1
            if depth == 0:
                return position
    raise RatchetError("unbalanced braces")


class Tree:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.sources = sorted((root / APP).rglob("*.swift"))
        self._code: dict[Path, str] = {}

    def code(self, path: Path) -> str:
        if path not in self._code:
            self._code[path] = blank_literals(path.read_text(encoding="utf-8", errors="replace"))
        return self._code[path]

    def relative(self, path: Path) -> str:
        return path.relative_to(self.root).as_posix()

    def top_level_body(self, kind: str, name: str) -> str:
        """The body of the one top-level `kind name` declared under TablePro/."""
        pattern = re.compile(rf"\b{kind}\s+{name}\b")
        found: list[tuple[Path, str]] = []
        for path in self.sources:
            if name not in path.read_text(encoding="utf-8", errors="replace"):
                continue
            code = self.code(path)
            for match in pattern.finditer(code):
                if depth_at(code, match.start()) != 0:
                    continue
                opening = code.index("{", match.end())
                found.append((path, code[opening + 1:closing_brace(code, opening)]))
        if len(found) != 1:
            where = ", ".join(self.relative(path) for path, _ in found) or "nowhere"
            raise RatchetError(
                f"expected one top-level `{kind} {name}` under {APP}/, found {len(found)} ({where}). "
                "If it moved or was removed on purpose, update scripts/ci/check-hub-ratchet.py and the baseline."
            )
        return found[0][1]


def body_level(body: str) -> list[int]:
    """The brace depth of every position in a declaration body, 0 for its own members."""
    depths = []
    depth = 0
    for character in body:
        if character == "}":
            depth -= 1
        depths.append(depth)
        if character == "{":
            depth += 1
    return depths


def enum_case_count(body: str) -> int:
    depths = body_level(body)
    count = 0
    for match in re.finditer(r"\bcase\b", body):
        if depths[match.start()] != 0:
            continue
        nesting = 0
        names = 1
        last = ""
        position = match.end()
        while position < len(body):
            character = body[position]
            if character in "([":
                nesting += 1
            elif character in ")]":
                nesting -= 1
            elif nesting == 0 and character == ",":
                names += 1
            elif nesting == 0 and character in ";{}":
                break
            elif nesting == 0 and character == "\n" and last != ",":
                break
            if not character.isspace():
                last = character
            position += 1
        count += names
    return count


def stored_property_count(body: str) -> int:
    depths = body_level(body)
    count = 0
    for match in PROPERTY.finditer(body):
        modifiers = match.group(1).split()
        if depths[match.start()] != 0 or "static" in modifiers or "class" in modifiers:
            continue
        count += stored_bindings(body, match.end(), is_constant=match.group(2) == "let")
    return count


def is_observer_block(body: str, opening: int) -> bool:
    return body[opening + 1:].lstrip().startswith(("willSet", "didSet"))


def continues_on_next_line(body: str, newline: int, state: str) -> bool:
    following = body[newline:].lstrip()
    if following.startswith("{"):
        return state != "initializer" or is_observer_block(body, len(body) - len(following))
    return following.startswith(".") or (state != "initializer" and following.startswith("="))


def stored_bindings(body: str, start: int, is_constant: bool) -> int:
    """How many stored bindings the declaration starting at `start` declares, as in `var a = 1, b: Int`.
    A binding is computed when it has no initializer and an accessor block other than willSet or didSet."""
    stored = 0
    state = "name"
    computed = False
    nesting: list[str] = []
    last = ""
    position = start
    while position < len(body):
        character = body[position]
        if body.startswith("->", position):
            last = "-"
            position += 2
            continue
        if nesting and character == nesting[-1]:
            nesting.pop()
        elif character in "([":
            nesting.append(")" if character == "(" else "]")
        elif character == "<" and state == "type":
            nesting.append(">")
        elif nesting:
            if character == "{":
                nesting.append("}")
        elif character == ":" and state == "name":
            state = "type"
        elif character == "=" and state != "initializer":
            state = "initializer"
        elif character == ",":
            stored += 1 if is_constant or not computed else 0
            state, computed = "name", False
        elif character == "{":
            if not is_observer_block(body, position) and state == "initializer":
                nesting.append("}")
            else:
                computed = computed or not is_observer_block(body, position)
                position = closing_brace(body, position) + 1
                last = "}"
                continue
        elif character in ";}":
            break
        elif character == "\n" and last not in CONTINUATION and not continues_on_next_line(body, position, state):
            break
        if not character.isspace():
            last = character
        position += 1
    return stored + (1 if is_constant or not computed else 0)


def names_module(suffix: str) -> bool:
    for word in MODULE_WORDS:
        if re.search(rf"(?<![A-Z]){word}s?(?![a-z])", suffix):
            return True
    return any(re.search(pattern, suffix) for pattern in ENGINES.values())


def measure(root: Path) -> dict[str, int]:
    tree = Tree(root)
    counts: dict[str, int] = {}

    counts["MenuValidationContext stored properties"] = stored_property_count(
        tree.top_level_body("struct", "MenuValidationContext")
    )
    counts["menu validation `case #selector` arms"] = sum(
        len(SELECTOR_ARM.findall(tree.code(path)))
        for path in tree.sources
        if path.name.startswith("MainSplitViewController")
    )
    for label, name in ENUMS.items():
        counts[label] = enum_case_count(tree.top_level_body("enum", name))

    shell_extensions = [match for match in (SHELL_EXTENSION.match(path.name) for path in tree.sources) if match]
    counts["shell extensions named for a module or engine"] = sum(
        1 for match in shell_extensions if names_module(match.group(2))
    )
    counts["MainContentCoordinator+ files"] = sum(
        1 for match in shell_extensions if match.group(1) == "MainContentCoordinator"
    )

    app_delegate = [path for path in tree.sources if path.name.startswith("AppDelegate")]
    declared_elsewhere: set[str] = set()
    declared_in_app_delegate: set[str] = set()
    for path in tree.sources:
        names = set(TYPE_DECLARATION.findall(tree.code(path)))
        (declared_in_app_delegate if path in app_delegate else declared_elsewhere).update(names)
    named = set()
    for path in app_delegate:
        named.update(IDENTIFIER.findall(tree.code(path)))
    counts["app types AppDelegate names"] = len((named & declared_elsewhere) - declared_in_app_delegate)

    for engine, pattern in ENGINES.items():
        regex = re.compile(pattern)
        counts[f"files under {APP}/ named for {engine}"] = sum(1 for path in tree.sources if regex.search(path.stem))
    return counts


def compare(baseline: dict[str, int], current: dict[str, int]) -> tuple[list[str], list[str]]:
    """Failures, then notes about counts that went down."""
    failures: list[str] = []
    lowered: list[str] = []
    for key, value in current.items():
        if key not in baseline:
            failures.append(f"{key}: {value}, and the baseline has no entry for it")
        elif value > baseline[key]:
            failures.append(f"{key}: {value}, up from {baseline[key]}")
        elif value < baseline[key]:
            lowered.append(f"{key}: {value}, down from {baseline[key]}")
    for key in baseline:
        if key not in current:
            failures.append(f"{key}: in the baseline, but this script no longer counts it")
    return failures, lowered


def lowered_baseline(baseline: dict[str, int], current: dict[str, int]) -> dict[str, int]:
    return {key: min(value, baseline.get(key, value)) for key, value in current.items()}


def write_baseline(path: Path, counts: dict[str, int]) -> None:
    path.write_text(json.dumps(counts, indent=2) + "\n", encoding="utf-8")


def run(root: Path, update: bool = False, show: bool = False) -> int:
    try:
        current = measure(root)
    except RatchetError as error:
        print(f"check-hub-ratchet: {error}")
        return 1

    if show:
        print(json.dumps(current, indent=2))
        return 0

    baseline_path = root / BASELINE
    baseline = json.loads(baseline_path.read_text(encoding="utf-8")) if baseline_path.exists() else {}

    if update:
        write_baseline(baseline_path, lowered_baseline(baseline, current))
        print(f"wrote {BASELINE}")
        return 0

    failures, lowered = compare(baseline, current)
    for line in lowered:
        print(f"lower: {line}")
    if lowered:
        print("Record the lower counts with: python3 scripts/ci/check-hub-ratchet.py --update")
    if not failures:
        return 0
    for line in failures:
        print(f"FAIL: {line}")
    print()
    print(
        "These counts may only go down. Put the new code behind the feature's own type instead of "
        "the hub. If the growth is intended, raise the number in "
        f"{BASELINE} by hand and say why in the pull request."
    )
    return 1


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Fail when a hub count grows past its baseline.")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--update", action="store_true", help="lower the baseline to the current counts")
    action.add_argument("--print", dest="show", action="store_true", help="print the current counts as JSON")
    arguments = parser.parse_args(argv)
    return run(arguments.root.resolve(), update=arguments.update, show=arguments.show)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
