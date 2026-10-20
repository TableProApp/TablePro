#!/usr/bin/env python3
"""Fail when a driver lists a column type its corpus has no column for.

Each Plugins/ColumnTypeCorpus/Corpus/<engine>.json names, under "typeList", the Swift file that holds its driver's
`columnTypesByCategory`, a dictionary literal or one built from a `categories` literal. A list this cannot read
fails, so a reshaped list never reads as empty. The probe, scripts/probes/check-column-type-corpus.sh, checks the
compiled list too.

Usage:
    check-column-type-corpus.py [--corpus <dir>] [--root <apple dir>]
"""

import argparse
import json
import re
import sys
from pathlib import Path

APPLE_DIR = Path(__file__).resolve().parents[2]
CORPUS_DIR = APPLE_DIR / "Plugins" / "ColumnTypeCorpus" / "Corpus"
STEPS = {"create", "insert", "columns", "browse", "stream", "edit", "csv", "json", "sql"}
DECLARATION = re.compile(r"\bstatic\s+let\s+(columnTypesByCategory|categories)\b[^=]*=\s*\[")


class Unreadable(Exception):
    pass


def literal_after(text, start):
    depth = 0
    index = start
    while index < len(text):
        character = text[index]
        if character == '"':
            index = text.index('"', index + 1)
            while text[index - 1] == "\\":
                index = text.index('"', index + 1)
        elif character == "[":
            depth += 1
        elif character == "]":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
        index += 1
    raise Unreadable("an unterminated list")


# The strings inside an inner list are the types; the ones outside are category names.
def listed_types(source):
    declarations = {match.group(1): match for match in DECLARATION.finditer(source)}
    match = declarations.get("columnTypesByCategory") or declarations.get("categories")
    if match is None:
        raise Unreadable("no columnTypesByCategory or categories list literal")
    literal = literal_after(source, match.end() - 1)
    types = []
    depth = 0
    index = 0
    while index < len(literal):
        character = literal[index]
        if character == "[":
            depth += 1
        elif character == "]":
            depth -= 1
        elif character == '"':
            end = literal.index('"', index + 1)
            if depth >= 2:
                types.append(literal[index + 1:end])
            index = end
        index += 1
    if not types:
        raise Unreadable("a type list with no types")
    return types


def base_name(declaration):
    return declaration.split("(", 1)[0].strip()


def problems_in(corpus_path, apple_dir):
    try:
        corpus = json.loads(corpus_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise Unreadable(f"does not parse: {error}") from error
    type_list = apple_dir / corpus.get("typeList", "")
    if not corpus.get("typeList") or not type_list.is_file():
        raise Unreadable(f"typeList {corpus.get('typeList')!r} is not a file")

    problems = []
    covered = set(corpus.get("notColumnTypes", {}))
    for column in corpus.get("columns", []):
        declaration = column.get("type", "")
        covered.update(column["covers"] if "covers" in column else [base_name(declaration)])
        for key in ("skip", "known"):
            for step in column.get(key, {}):
                if step not in STEPS:
                    problems.append(f"{declaration}: {key} names {step!r}, not a step")
        for step, issue in column.get("known", {}).items():
            if not (isinstance(issue, dict) and isinstance(issue.get("defect"), str)
                    and isinstance(issue.get("matches"), str)):
                problems.append(f"{declaration}: known {step!r} needs a defect and the failure it matches")
        if "edit" not in column and "edit" not in column.get("skip", {}):
            problems.append(f"{declaration}: no edit and no skip reason for it")

    try:
        listed = listed_types(type_list.read_text(encoding="utf-8"))
    except Unreadable as error:
        raise Unreadable(f"{corpus['typeList']}: {error}") from error
    missing = sorted(set(listed) - covered)
    if missing:
        problems.append(f"{corpus['typeList']} lists {', '.join(missing)} with no corpus column")
    return problems


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--corpus", type=Path, default=CORPUS_DIR)
    parser.add_argument("--root", type=Path, default=APPLE_DIR)
    args = parser.parse_args(argv)

    corpora = sorted(args.corpus.glob("*.json"))
    if not corpora:
        sys.exit(f"no corpus under {args.corpus}")

    failures = []
    for corpus in corpora:
        try:
            failures += [f"{corpus.name}: {problem}" for problem in problems_in(corpus, args.root)]
        except Unreadable as error:
            failures.append(f"{corpus.name}: {error}")
    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        sys.exit(1)
    print(f"{len(corpora)} corpora cover every listed type")


if __name__ == "__main__":
    main()
