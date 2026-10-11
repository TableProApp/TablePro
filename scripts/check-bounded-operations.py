#!/usr/bin/env python3
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UNCONTROLLED = re.compile(
    r"\b(?:conn|connection)\s*\.\s*"
    r"(?:query|query_params|execute|execute_params|execute_in_transaction|"
    r"fetch_rows|fetch_columns|fetch_indexes|fetch_foreign_keys|list_tables|list_views)\s*\("
)


def unbounded_calls(paths):
    for path in paths:
        source = path.read_text()
        for match in UNCONTROLLED.finditer(source):
            line = source.count("\n", 0, match.start()) + 1
            call = " ".join(match.group().split())
            yield path, line, call


def main():
    paths = [
        path
        for folder in [ROOT / "crates/app/src", ROOT / "crates/mcp/src"]
        for path in folder.rglob("*.rs")
        if not path.name.endswith("_tests.rs")
    ]
    violations = list(unbounded_calls(paths))
    if violations:
        print("error: unbounded database calls in the GUI or MCP (use the *_controlled form):")
        for path, line, call in violations:
            print(f"{path.relative_to(ROOT)}:{line}: {call}")
        return 1
    print("bounded-operations: ok (every GUI and MCP database call carries an OperationControl)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
