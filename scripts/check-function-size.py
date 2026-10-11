#!/usr/bin/env python3
"""Enforce Rust function length limits under crates.

A function body longer than the limit needs an entry in
baselines/function-size-baselines.txt, which records how many over-limit functions a file
may still contain. That count may shrink but never grow. Test code is excluded:
`#[cfg(test)]` modules, `*_tests.rs` modules, and every file under a crate's tests/.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

LIMIT = 60

ROOT = Path(__file__).resolve().parent.parent
CRATES = [ROOT / "crates", ROOT / "apps", ROOT / "tests"]
BASELINES = ROOT / "baselines" / "function-size-baselines.txt"

RAW_STRING = re.compile(r'b?r(?P<hashes>#*)"')
CHAR_LITERAL = re.compile(r"b?'(?:\\.|[^\\'])'")

SIGNATURE = re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:default\s+)?(?:const\s+)?(?:async\s+)?(?:unsafe\s+)?(?:extern\s+\"[^\"]*\"\s+)?fn\s+(\w+)")
CFG_TEST = re.compile(r"^\s*#\[cfg\(test\)\]")


def strip_literals(text: str) -> str:
    """Blank out comments and literals so brace counting sees only code.

    Rust allows a brace inside a string, byte string or char literal, and a
    lexer that counts braces textually measures such a function to the end of
    the file, hiding every function after it from the check. Newlines are kept
    so line numbers still line up.
    """
    out = []
    index = 0
    length = len(text)
    while index < length:
        char = text[index]
        if char == "/" and index + 1 < length and text[index + 1] == "/":
            while index < length and text[index] != "\n":
                out.append(" ")
                index += 1
            continue
        if char == "/" and index + 1 < length and text[index + 1] == "*":
            depth = 0
            while index < length:
                if text.startswith("/*", index):
                    depth += 1
                    out.append("  ")
                    index += 2
                    continue
                if text.startswith("*/", index):
                    depth -= 1
                    out.append("  ")
                    index += 2
                    if depth == 0:
                        break
                    continue
                out.append("\n" if text[index] == "\n" else " ")
                index += 1
            continue
        if char in "rb" and (match := RAW_STRING.match(text, index)):
            hashes = match.group("hashes")
            terminator = '"' + hashes
            end = text.find(terminator, match.end())
            end = length if end < 0 else end + len(terminator)
            out.append(blank(text[index:end]))
            index = end
            continue
        if char == '"' or (char == "b" and text.startswith('b"', index)):
            start = index
            index += 2 if char == "b" else 1
            while index < length:
                if text[index] == "\\":
                    index += 2
                    continue
                if text[index] == '"':
                    index += 1
                    break
                index += 1
            out.append(blank(text[start:index]))
            continue
        if (match := CHAR_LITERAL.match(text, index)) is not None:
            out.append(blank(match.group(0)))
            index = match.end()
            continue
        out.append(char)
        index += 1
    return "".join(out)


def blank(fragment: str) -> str:
    return "".join("\n" if c == "\n" else " " for c in fragment)


def test_module_ranges(lines: list[str]) -> list[tuple[int, int]]:
    ranges = []
    for index, line in enumerate(lines):
        if not CFG_TEST.match(line):
            continue
        start = index
        while start < len(lines) and "{" not in lines[start]:
            start += 1
        if start >= len(lines):
            continue
        depth = 0
        end = start
        while end < len(lines):
            depth += lines[end].count("{") - lines[end].count("}")
            if depth <= 0:
                break
            end += 1
        ranges.append((index, end))
    return ranges


def measure(path: Path) -> list[tuple[str, int, int]]:
    source = path.read_text(encoding="utf8", errors="replace")
    lines = strip_literals(source).split("\n")
    skip = test_module_ranges(lines)
    found = []
    index = 0
    while index < len(lines):
        match = SIGNATURE.match(lines[index])
        if not match:
            index += 1
            continue
        if any(start <= index <= end for start, end in skip):
            index += 1
            continue
        opening = index
        while opening < len(lines) and "{" not in lines[opening]:
            if ";" in lines[opening]:
                break
            opening += 1
        if opening >= len(lines) or "{" not in lines[opening]:
            index += 1
            continue
        depth = 0
        closing = opening
        while closing < len(lines):
            depth += lines[closing].count("{") - lines[closing].count("}")
            if depth <= 0:
                break
            closing += 1
        found.append((match.group(1), index + 1, max(closing - opening - 1, 0)))
        index = closing + 1
    return found


def read_baselines() -> dict[str, int]:
    allowed: dict[str, int] = {}
    if not BASELINES.exists():
        return allowed
    for raw in BASELINES.read_text(encoding="utf8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.rsplit(" ", 1)
        if len(parts) != 2 or not parts[1].isdigit():
            print(f"error: malformed baseline line: {raw}", file=sys.stderr)
            sys.exit(1)
        allowed[parts[0]] = int(parts[1])
    return allowed


def main() -> int:
    allowed = read_baselines()
    errors = 0
    seen: set[str] = set()

    for path in sorted(p for d in CRATES for p in d.rglob("*.rs")):
        relative = path.relative_to(ROOT).as_posix()
        if "/tests/" in relative or path.name.endswith("_tests.rs"):
            continue
        over_limit = []
        for name, line, body in measure(path):
            if body > LIMIT:
                over_limit.append((name, line, body))

        ceiling = allowed.get(relative)
        if ceiling is None:
            for name, line, body in over_limit:
                print(
                    f"error: {relative}:{line} {name} has a {body}-line body (limit {LIMIT}). "
                    f"Extract a named step, or add '{relative} {len(over_limit)}' to baselines/function-size-baselines.txt.",
                    file=sys.stderr,
                )
                errors += 1
            continue

        seen.add(relative)
        if len(over_limit) > ceiling:
            print(
                f"error: {relative} now has {len(over_limit)} functions over {LIMIT} lines (baseline {ceiling}).",
                file=sys.stderr,
            )
            for name, line, body in over_limit:
                print(f"       {relative}:{line} {name} ({body} lines)", file=sys.stderr)
            errors += 1
        elif len(over_limit) < ceiling:
            print(f"note: {relative} is down to {len(over_limit)} over-limit functions (baseline {ceiling}). Lower the baseline.")

    for relative in sorted(set(allowed) - seen):
        print(f"error: baselines/function-size-baselines.txt lists {relative}, which no longer exists or is now clean.", file=sys.stderr)
        errors += 1

    if errors:
        print(f"\n{errors} function-size violation(s).", file=sys.stderr)
        return 1
    print("function sizes within limits")
    return 0


if __name__ == "__main__":
    sys.exit(main())
