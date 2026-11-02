#!/usr/bin/env python3
"""Fail when a statement classifier matches SQL text with a regex or a substring search.

The classifier reads words as TableProSQLGrammar's tokens read them. A regex or `range(of:)` reads them another way:
`\\s` misses a control character the server treats as a blank, and a literal `" DROP "` misses a line break. Comments
are skipped, string literals are not.

Usage:
    check-classifier-text-matching.py [path...]    # default: the classifier sources
"""

import re
import sys
from pathlib import Path

APPLE = Path(__file__).resolve().parents[2]

DEFAULT_PATTERNS = [
    "TablePro/Core/Utilities/SQL/QueryClassifier*.swift",
    "Packages/TableProCore/Sources/TableProSQLGrammar/SQLStatementClassifier*.swift",
    "Packages/TableProCore/Sources/TableProSQLGrammar/SQLStateChangingFunctions.swift",
    "Packages/TableProCore/Sources/TableProQuery/SQLWriteClassifier.swift",
]

BANNED = re.compile(
    r"\bNSRegularExpression\b|\bRegex\b|\branges?\(of:|\.(?:firstMatch|wholeMatch|prefixMatch)\(|\.matches\((?:of|in):"
)


def code_lines(source):
    """Yield (line, text) for each line with its comments blanked. String literals stay."""
    out = []
    i = 0
    length = len(source)
    while i < length:
        if source.startswith("//", i):
            end = source.find("\n", i)
            i = length if end == -1 else end
        elif source.startswith("/*", i):
            end = source.find("*/", i + 2)
            end = length if end == -1 else end + 2
            out.append("\n" * source.count("\n", i, end))
            i = end
        elif source[i] == '"':
            closer = '"""' if source.startswith('"""', i) else '"'
            j = i + len(closer)
            while j < length and not source.startswith(closer, j):
                j += 2 if source[j] == "\\" else 1
            end = min(length, j + len(closer))
            out.append(source[i:end])
            i = end
        else:
            out.append(source[i])
            i += 1
    for number, text in enumerate("".join(out).split("\n"), start=1):
        yield number, text


def violations(path):
    return [
        (line, match.group(0))
        for line, text in code_lines(path.read_text(encoding="utf-8"))
        for match in BANNED.finditer(text)
    ]


def default_paths():
    return sorted(path for pattern in DEFAULT_PATTERNS for path in APPLE.glob(pattern))


def main(argv):
    paths = [Path(arg) for arg in argv] or default_paths()
    missing = [path for path in paths if not path.is_file()]
    if missing or not paths:
        for path in missing:
            print(f"error: {path} does not exist", file=sys.stderr)
        if not paths:
            print("error: no classifier sources found", file=sys.stderr)
        return 2
    failures = 0
    for path in paths:
        for line, found in violations(path):
            failures += 1
            print(f"{path}:{line}: {found} in a classifier; read words through TableProSQLGrammar's tokens")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
