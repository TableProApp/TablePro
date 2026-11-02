#!/usr/bin/env python3
"""Fail when SQL the apps write for the PostgreSQL family calls a function, or an array or json operator, without
naming pg_catalog.

PostgreSQL looks an unqualified function or operator up over every schema on search_path, and a candidate that takes
the operands' types exactly beats a pg_catalog one reached through a cast, so one another role plants in a schema on
the path runs with the reader's privileges. pg_catalog's array and json operators take polymorphic or json operands,
so a lookalike over concrete types always wins there. The drivers' catalog reads run under
PostgreSQLCatalogSearchPath; naming pg_catalog is the second layer, the one pg_dump keeps, and the only one on Redshift,
on CockroachDB and on a session whose path nothing pins. Plain comparisons (=, <>, LIKE, IN) are left to that pin and
to the live probe (scripts/probes/check-postgresql-catalog-shadowing.sh). Skipped: SQL comments and string literals
inside the SQL, a column list after an alias, and logged or localized text.

Usage:
    check-postgresql-qualified-calls.py [path...]    # default: every source that writes PostgreSQL-family SQL
"""

import re
import sys
from pathlib import Path

from swift_string_literals import string_literals

APPLE = Path(__file__).resolve().parents[2]

DEFAULT_PATHS = [
    APPLE / "Packages/TableProCore/Sources/TableProPostgreSQLCore",
    APPLE / "Plugins/PostgreSQLDriverPlugin",
    APPLE / "Plugins/KingbaseESDriverPlugin",
    APPLE / "TablePro/Core/ServerDashboard/Providers/PostgreSQLActivityCatalog.swift",
    APPLE / "TablePro/Core/ServerDashboard/Providers/PostgreSQLDashboardProvider.swift",
    APPLE / "TablePro/Core/TableHealth/PostgreSQLTableHealthProvider.swift",
    APPLE / "TableProMobile/TableProMobile/Drivers/PostgreSQLDriver.swift",
    APPLE / "TableProMobile/TableProMobile/Drivers/PostgreSQLDriver+Catalog.swift",
]

# Unquoted words a parenthesis follows that are not function calls: grammar, statement options and type modifiers.
# Some still compare through an operator (IN, ANY, NULLIF, LIKE), which the operator rule and the pin cover. EXTRACT,
# POSITION, TRIM and NORMALIZE parse to pg_catalog functions by name, as SUBSTRING and OVERLAY do in their keyword forms.
NOT_FUNCTIONS = {
    "all", "analyse", "analyze", "and", "any", "array", "as", "between", "bit", "by", "call", "case", "cast", "char",
    "character", "check", "cluster", "coalesce", "conflict", "copy", "cube", "current_time", "current_timestamp",
    "decimal", "default", "distinct", "distkey", "do", "else", "enum", "escape", "except", "exists", "explain",
    "extract", "filter", "float", "for", "from", "function", "greatest", "group", "grouping", "hash", "having",
    "ilike", "in", "include", "index", "intersect", "interval", "into", "is", "join", "key", "lateral", "least",
    "like", "list", "localtime", "localtimestamp", "normalize", "not", "nullif", "numeric", "of", "on", "only",
    "operator", "options", "or", "ordinality", "over", "partition", "position", "primary", "procedure",
    "range", "recursive", "references", "reindex", "reset", "returning", "rollup", "row", "select", "set", "sets",
    "some", "sortkey", "table", "then", "time", "timestamp", "to", "transaction", "trim", "union", "unique", "using",
    "vacuum", "values", "varchar", "varying", "when", "where", "window", "with", "within",
}
KEYWORD_FORMS = {"substring": re.compile(r"\b(?:from|for|similar)\b", re.I), "overlay": re.compile(r"\bplacing\b", re.I)}

# A quoted name resolves over the path as a bare one does; the interpolation placeholder "?" is no name. A name after
# `::` is a type.
CALL = re.compile(r'(?<![\w.$"])(?<!::)([A-Za-z_][A-Za-z0-9_$]*|"(?:[^"?]|"")+")\s*\(')
OPERATOR_CHARACTERS = "-#@<>=!~*/&|^%?+"
POLYMORPHIC_OPERATOR = re.compile(
    r"(?<!OPERATOR\(pg_catalog\.)(?<![" + re.escape(OPERATOR_CHARACTERS) + r"])"
    r"(@>|<@|&&|->>|->|#>>|#>|#-|\?\||\?&|@\?|@@)"
    r"(?![" + re.escape(OPERATOR_CHARACTERS) + r"])"
)
ALIAS_COLUMNS = re.compile(r"(?:^|\W)(?:as|with|recursive)\s*$", re.I)
# One pass, so a quote inside a comment, a name or a dollar body, or a comment marker inside a string, is read as the
# server reads it. Quoted names are matched to be skipped, not blanked, and a dollar body (a DO block or a function) is
# code, so only its tags are. A line comment also ends at Swift's `\n`.
STRINGS_AND_COMMENTS = re.compile(
    r'"(?:[^"]|"")*"|[Ee]\'(?:[^\'\\]|\\.|\'\')*\'|\'(?:[^\']|\'\')*\'|\$(\w*)\$.*?\$\1\$|--(?:(?!\\n)[^\n])*|/\*.*?\*/',
    re.S,
)
NOT_SQL = re.compile(
    r"String\(\s*localized:\s*$|\.(?:debug|info|notice|warning|error|fault|critical|log|trace)\(\s*$"
)
SWIFT_ESCAPE = re.compile(r'\\(["\\])')
# An interpolated name reads as a quoted identifier, so `\(qualified)(...)` is not taken for a bare call.
INTERPOLATION = '"?"'


def blanked(match):
    token = match.group(0)
    if token.startswith('"'):
        return token
    if token.startswith("$"):
        tag = len(match.group(1)) + 2
        return " " * tag + STRINGS_AND_COMMENTS.sub(blanked, token[tag:-tag]) + " " * tag
    return re.sub(r"[^\n]", " ", token)


def argument_text(text, open_paren):
    """The text inside the parentheses that open at `open_paren`, nested groups blanked."""
    depth = 0
    out = []
    for index in range(open_paren, len(text)):
        char = text[index]
        if char == "(":
            depth += 1
            if depth == 1:
                continue
        elif char == ")":
            depth -= 1
            if depth == 0:
                break
        out.append(char if depth == 1 else " ")
    return "".join(out)


def bare_calls(sql):
    """Yield (offset, name) for each function call or polymorphic operator in `sql` that names no schema."""
    text = STRINGS_AND_COMMENTS.sub(blanked, sql)
    for match in CALL.finditer(text):
        name = match.group(1)
        if ALIAS_COLUMNS.search(text, 0, match.start()):
            continue
        if name.startswith('"'):
            # A quoted table before a column list, `INSERT INTO "t" (a)`, is spaced; a quoted call is not.
            if match.group(0).endswith(name + "("):
                yield match.start(), name
            continue
        lowered = name.lower()
        if lowered in NOT_FUNCTIONS:
            continue
        keyword_form = KEYWORD_FORMS.get(lowered)
        if keyword_form and keyword_form.search(argument_text(text, match.end() - 1)):
            continue
        yield match.start(), name
    for match in POLYMORPHIC_OPERATOR.finditer(text):
        yield match.start(), match.group(1)


def violations(path):
    found = []
    source = path.read_text(encoding="utf-8")
    for line, text, before in string_literals(source, INTERPOLATION):
        if NOT_SQL.search(before):
            continue
        # The literal's text keeps Swift's escapes: an escaped quote or backslash is one in the SQL.
        sql = SWIFT_ESCAPE.sub(r"\1", text)
        for offset, name in bare_calls(sql):
            found.append((line + sql.count("\n", 0, offset), name))
    return sorted(found)


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
        for line, name in violations(path):
            failures += 1
            if name[0].isalpha() or name[0] in '_"':
                print(f"{path}:{line}: {name}(...) names no schema; call it as pg_catalog.{name}")
            else:
                print(f"{path}:{line}: {name} names no schema; write OPERATOR(pg_catalog.{name})")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
