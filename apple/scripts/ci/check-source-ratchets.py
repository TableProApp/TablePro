#!/usr/bin/env python3
"""Fail when engine-name comparisons in the app, or singleton reads in its views, rise above their baseline.

Comments are skipped, block comments nested, and a string literal is opaque apart from its interpolations, which are
code.

engine-name-comparisons, over apple/TablePro/. The names are the `static let <name> = DatabaseType(rawValue: "<raw>")`
lines of apple/TablePro/Models/Connection/DatabaseType.swift. Each of these counts once:
  - `==` or `!=`, optional whitespace, an optional `DatabaseType`, then `.<name>` ending at a word boundary;
  - `.<name>` or `DatabaseType.<name>` as a whole item of a `case` pattern list, which ends at `:`, `where`, `in`,
    or the `=` of `if case .a = x`;
  - a string literal whose whole text is a raw value, right after or right before `==` or `!=`, or as a whole item
    of a `case` list.
  A name counts on any type: `case .mysql:` over SqlDialect counts too. `[.mysql].contains(t)` does not.

view-singleton-reads, over apple/TablePro/Views/ and apple/TablePro/ViewModels/: each `DatabaseManager.shared`,
`PluginManager.shared` and `AppSettingsManager.shared`.

A count above its baseline in source-ratchets.json fails. A count below it passes with a notice to lower it.

Usage:
    check-source-ratchets.py [--apple <dir>] [--list | --write]
"""

import argparse
import functools
import json
import re
import sys
from pathlib import Path

APPLE = Path(__file__).resolve().parents[2]
SCRIPT = "apple/scripts/ci/check-source-ratchets.py"
BASELINE = "scripts/ci/source-ratchets.json"
DATABASE_TYPE = "TablePro/Models/Connection/DatabaseType.swift"

ENGINES = "engine-name-comparisons"
SINGLETONS = "view-singleton-reads"
RATCHETS = (ENGINES, SINGLETONS)

ADVICE = {
    ENGINES: "move the new ones into plugin metadata or a PluginKit capability (apple/AGENTS.md, Scope)",
    SINGLETONS: "pass the new ones in as injected services",
}

ENGINE_NAME = re.compile(r'^\s*static let (\w+) = DatabaseType\(rawValue: "([^"\\]*)"\)', re.MULTILINE)
SINGLETON = re.compile(r"\b(?:DatabaseManager|PluginManager|AppSettingsManager)\.shared(?!\w)")

OPAQUE = re.compile(r'//|/\*|#*"')
STRING_OPENER = re.compile(r'(#*)("""|")')
BLOCK_COMMENT = re.compile(r"/\*|\*/")
INTERPOLATION = re.compile(r'[()]|//|/\*|#*"')
NOT_NEWLINE = re.compile(r"[^\n]")

CASE = re.compile(r"(?<![.\w`])case\b")
LIST_END_WORD = re.compile(r"(?:case|where|in)\b")
OPERATOR = set("=!<>+-*/%&|^~")
COMPARED_BEFORE = re.compile(r"(?<![=!])(==|!=)\s*\Z")
COMPARED_AFTER = re.compile(r"\s*(==|!=)(?!=)")


def comment_end(source, i):
    if source.startswith("//", i):
        end = source.find("\n", i)
        return len(source) if end == -1 else end
    depth = 0
    for match in BLOCK_COMMENT.finditer(source, i):
        depth += 1 if match.group() == "/*" else -1
        if depth == 0:
            return match.end()
    return len(source)


@functools.lru_cache(maxsize=None)
def string_stops(hashes, multiline):
    closer = ('"""' if multiline else '"') + "#" * hashes
    escape = "\\" + "#" * hashes
    stops = [re.escape(closer), re.escape(escape)] + ([] if multiline else ["\n"])
    return closer, re.compile("|".join(stops))


def string_end(source, i):
    """(end, text, interpolations) of the literal opening at `i`; text is None when it interpolates or never closes."""
    opener = STRING_OPENER.match(source, i)
    hashes = len(opener.group(1))
    multiline = opener.group(2) == '"""'
    if multiline and hashes:
        # Swift reads #""""# as a one-line literal when its closing delimiter is on the same line.
        line_end = source.find("\n", opener.end())
        multiline = '"' + "#" * hashes not in source[opener.start(2) + 1:None if line_end == -1 else line_end]
    j = opener.start(2) + (3 if multiline else 1)
    closer, stops = string_stops(hashes, multiline)
    pieces = []
    interpolations = []
    while True:
        match = stops.search(source, j)
        if match is None:
            return len(source), None, interpolations
        pieces.append(source[j:match.start()])
        if match.group() == closer:
            return match.end(), None if interpolations else "".join(pieces), interpolations
        if match.group() == "\n":
            return match.start(), None, interpolations
        if source.startswith("(", match.end()):
            j = interpolation_end(source, match.end() + 1)
            interpolations.append((match.end() + 1, j - 1))
        else:
            pieces.append(source[match.start():match.end() + 1])
            j = match.end() + 1


def interpolation_end(source, i):
    depth = 1
    while True:
        match = INTERPOLATION.search(source, i)
        if match is None:
            return len(source)
        stop = match.group()
        if stop.endswith('"'):
            i = string_end(source, match.start())[0]
        elif stop in ("//", "/*"):
            i = comment_end(source, match.start())
        else:
            depth += 1 if stop == "(" else -1
            i = match.end()
            if depth == 0:
                return i


def lex(source, offset=0, end=None):
    """The source with comments and string contents blanked at the same offsets, and {start: (end, text)} per literal.

    An interpolation stays code.
    """
    end = len(source) if end is None else end
    code = []
    literals = {}
    i = offset
    while True:
        match = OPAQUE.search(source, i, end)
        if match is None:
            code.append(source[i:end])
            return "".join(code), literals
        start = match.start()
        code.append(source[i:start])
        if match.group().endswith('"'):
            i, text, interpolations = string_end(source, start)
            literals[start] = (i, text)
            blanked = start + 1
            code.append('"')
            for inner_start, inner_end in interpolations:
                code.append(NOT_NEWLINE.sub(" ", source[blanked:inner_start]))
                inner_code, inner_literals = lex(source, inner_start, inner_end)
                code.append(inner_code)
                literals.update(inner_literals)
                blanked = inner_end
            code.append(NOT_NEWLINE.sub(" ", source[blanked:max(blanked, i - 1)]) + '"' if i - start > 1 else "")
        else:
            i = comment_end(source, start)
            code.append(NOT_NEWLINE.sub(" ", source[start:i]))


def stripped(code, start, end):
    while start < end and code[start].isspace():
        start += 1
    while end > start and code[end - 1].isspace():
        end -= 1
    return start, end


def case_items(code, i):
    """Yield (start, end) of each item in the pattern list that starts at `i`."""
    depth = 0
    item = i
    while i < len(code):
        char = code[i]
        if char in "([":
            depth += 1
        elif char in ")]":
            if depth == 0:
                break
            depth -= 1
        elif char in "{};":
            break
        elif depth == 0:
            if char == ",":
                yield stripped(code, item, i)
                item = i + 1
            elif char == ":" or (char == "=" and code[i - 1] not in OPERATOR and code[i + 1:i + 2] != "="):
                break
            elif LIST_END_WORD.match(code, i) and not (code[i - 1].isalnum() or code[i - 1] == "_"):
                break
        i += 1
    yield stripped(code, item, i)


@functools.lru_cache(maxsize=None)
def engine_patterns(names):
    member = r"(?:DatabaseType)?\.(?:" + "|".join(names) + r")\b"
    return re.compile(r"(?<![=!])(?:==|!=)(?!=)\s*" + member), re.compile(member)


def engine_matches(source, code, literals, engines):
    comparison, member = engine_patterns(tuple(engines))
    raw_values = set(engines.values())
    found = [(match.start(), code[match.start():match.end()]) for match in comparison.finditer(code)]
    in_case = set()
    for case in CASE.finditer(code):
        for start, end in case_items(code, case.end()):
            literal = literals.get(start)
            if member.fullmatch(code, start, end):
                found.append((start, "case " + code[start:end]))
            elif literal and literal[1] in raw_values and not code[literal[0]:end].strip():
                found.append((start, "case " + source[start:literal[0]]))
                in_case.add(start)
    for start, (end, text) in literals.items():
        if start in in_case or text not in raw_values:
            continue
        before = COMPARED_BEFORE.search(code, max(0, start - 200), start)
        after = None if before else COMPARED_AFTER.match(code, end)
        if before:
            found.append((start, before.group(1) + " " + source[start:end]))
        elif after:
            found.append((start, source[start:end] + " " + after.group(1)))
    return found


def singleton_matches(code):
    return [(match.start(), match.group()) for match in SINGLETON.finditer(code)]


def engine_names(apple):
    path = apple / DATABASE_TYPE
    if not path.is_file():
        return {}
    return dict(ENGINE_NAME.findall(path.read_text(encoding="utf-8")))


def scan(apple, engines):
    """{ratchet: [(path, line, text)]} over the app's sources."""
    found = {ratchet: [] for ratchet in RATCHETS}
    app = apple / "TablePro"
    for path in sorted(app.rglob("*.swift")):
        source = path.read_text(encoding="utf-8")
        code, literals = lex(source)
        matches = {ENGINES: engine_matches(source, code, literals, engines)}
        if path.relative_to(app).parts[0] in ("Views", "ViewModels"):
            matches[SINGLETONS] = singleton_matches(code)
        relative = path.relative_to(apple.parent).as_posix()
        for ratchet, hits in matches.items():
            for offset, text in sorted(hits):
                found[ratchet].append((relative, source.count("\n", 0, offset) + 1, " ".join(text.split())))
    return found


def main(argv):
    parser = argparse.ArgumentParser(description="Keep engine-name comparisons and view singleton reads from growing.")
    parser.add_argument("--apple", type=Path, default=APPLE, help="the apple/ folder to scan")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--list", action="store_true", help="print every match")
    mode.add_argument("--write", action="store_true", help="write the current counts as the baseline")
    args = parser.parse_args(argv)
    apple = args.apple.resolve()

    engines = engine_names(apple)
    if not engines:
        print(f"::error::No `static let <name> = DatabaseType(rawValue: ...)` lines in apple/{DATABASE_TYPE}.")
        return 1
    found = scan(apple, engines)

    if args.list:
        for ratchet, matches in found.items():
            for path, line, text in matches:
                print(f"{path}:{line}: {ratchet}: {text}")
        return 0

    counts = {ratchet: len(matches) for ratchet, matches in found.items()}
    baseline_path = apple / BASELINE
    if args.write:
        baseline_path.write_text(json.dumps(counts, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        for ratchet in RATCHETS:
            print(f"{ratchet}: {counts[ratchet]}")
        return 0

    if not baseline_path.is_file():
        print(f"::error::apple/{BASELINE} is missing. Run {SCRIPT} --write.")
        return 1
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    status = 0
    for ratchet in RATCHETS:
        count = counts[ratchet]
        if ratchet not in baseline:
            print(f"::error::apple/{BASELINE} has no baseline for {ratchet}. Run {SCRIPT} --write.")
            status = 1
            continue
        limit = baseline[ratchet]
        print(f"{ratchet}: {count} (baseline {limit})")
        if count > limit:
            print(
                f"::error::{ratchet} rose from {limit} to {count}. Run {SCRIPT} --list and {ADVICE[ratchet]}; "
                f"raise the baseline in apple/{BASELINE} only when that is not possible."
            )
            status = 1
        elif count < limit:
            print(f"::notice::{ratchet} fell from {limit} to {count}. Lower the baseline with {SCRIPT} --write.")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
