#!/usr/bin/env bash
#
# Compare the curated array element delimiters against a real PostgreSQL server.
#
# PostgreSQL puts `pg_type.typdelim` between an array's elements, and it belongs to the element
# type rather than to the array. Almost every type uses a comma; `box` uses a semicolon, so a
# `box[]` arrives as `{(3,4),(1,2);(7,8),(5,6)}` and reading it with a comma splits one box into
# four fragments, which the element editor then writes back as an invalid literal.
#
# The driver does not report typdelim, so PostgresArrayDelimiter.swift carries the exception as a
# hand-written table. That is a fact about the server that nothing at runtime re-checks, and an
# extension is free to declare another delimiter, so this diffs the table against a live catalog.
#
# Usage:
#   scripts/check-postgres-array-delimiters.sh [psql connection arguments…]
#   scripts/check-postgres-array-delimiters.sh -h 127.0.0.1 -p 54329 -U postgres -d postgres
#
# Needs psql and a reachable server. Exits non-zero on a disagreement.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/TablePro/Core/Services/PostgresArrayDelimiter.swift"

command -v psql > /dev/null || {
    echo "psql not found" >&2
    exit 3
}
[ -f "$SOURCE" ] || {
    echo "not found: $SOURCE" >&2
    exit 3
}

# Every non-array type whose delimiter is not a comma. The array types themselves (`_box`) are
# excluded by category rather than by `typelem`: a `box` is made of points, so its own `typelem` is
# non-zero and filtering on that hid the one row this script exists to find.
server="$(psql "$@" -X -Atq -c "
    SELECT t.typname || ' ' || t.typdelim::text
    FROM pg_type t
    WHERE t.typdelim <> ',' AND t.typcategory <> 'A'
    ORDER BY t.typname;
")" || {
    echo "could not query the server" >&2
    exit 3
}

# The curated table, read back out of the Swift source rather than repeated here.
curated="$(sed -n 's/.*private static let byElementType: \[String: Character\] = \[\(.*\)\].*/\1/p' "$SOURCE" \
    | tr ',' '\n' \
    | sed -n 's/.*"\([a-z_]*\)"[[:space:]]*:[[:space:]]*"\(.\)".*/\1 \2/p' \
    | sort)"

server_sorted="$(printf '%s\n' "$server" | sed '/^$/d' | sort)"

if [ "$curated" = "$server_sorted" ]; then
    printf 'delimiters agree (%s entr%s)\n' \
        "$(printf '%s\n' "$curated" | sed '/^$/d' | wc -l | tr -d ' ')" \
        "$([ "$(printf '%s\n' "$curated" | sed '/^$/d' | wc -l | tr -d ' ')" = "1" ] && echo y || echo ies)"
    exit 0
fi

echo "PostgresArrayDelimiter.byElementType disagrees with the server." >&2
echo >&2
echo "curated:" >&2
printf '%s\n' "$curated" | sed 's/^/  /' >&2
echo "server:" >&2
printf '%s\n' "$server_sorted" | sed 's/^/  /' >&2
exit 1
