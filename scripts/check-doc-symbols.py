#!/usr/bin/env python3
import re
import sys
from pathlib import Path

REFERENCES = (
    ("ARCHITECTURE.md", "crates/policy/src/guard.rs", "PolicyGuard", "struct"),
    ("ARCHITECTURE.md", "crates/core/src/connection.rs", "Connection", "trait"),
    ("ARCHITECTURE.md", "crates/core/src/operation.rs", "OperationControl", "struct"),
    ("ARCHITECTURE.md", "crates/core/src/driver.rs", "DatabaseDriver", "trait"),
    ("ARCHITECTURE.md", "crates/core/src/query.rs", "Value", "enum"),
    ("AGENTS.md", "scripts/preflight.sh", "preflight.sh", "file"),
    ("AGENTS.md", "scripts/check-doc-links.py", "check-doc-links.py", "file"),
    ("AGENTS.md", "scripts/check-known-issues.py", "check-known-issues.py", "file"),
    ("AGENTS.md", "scripts/forgejo-gate.sh", "forgejo-gate.sh", "file"),
)


def declaration_exists(source, symbol, kind):
    if kind == "file":
        return source.is_file()
    text = source.read_text(encoding="utf-8")
    return re.search(
        rf"^\s*(?:pub(?:\([^)]*\))?\s+)?{kind}\s+{re.escape(symbol)}\b",
        text,
        re.MULTILINE,
    ) is not None


def check_references(root, references=REFERENCES):
    problems = []
    for doc_name, source_name, symbol, kind in references:
        doc = root / doc_name
        source = root / source_name
        if not doc.is_file():
            problems.append(f"{doc_name}: documentation page is missing")
            continue
        if not source.is_file():
            problems.append(f"{doc_name}: referenced source path is missing: {source_name}")
            continue
        documentation = doc.read_text(encoding="utf-8")
        if re.search(rf"(?<![A-Za-z0-9_]){re.escape(symbol)}(?![A-Za-z0-9_])", documentation) is None:
            problems.append(f"{doc_name}: named symbol is missing: {symbol}")
            continue
        if not declaration_exists(source, symbol, kind):
            problems.append(f"{doc_name}: {kind} {symbol} is missing from {source_name}")
    return problems


def main():
    root = Path(__file__).resolve().parents[1]
    problems = check_references(root)
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        return 1
    print("doc symbols: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
