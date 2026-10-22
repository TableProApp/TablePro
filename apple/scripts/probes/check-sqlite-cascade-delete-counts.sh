#!/bin/bash
#
# Re-checks the SQLite behaviour the cascade delete preview (CascadeDeleteSQL) is built on: the
# count queries it writes must match the rows a DELETE actually removes or rewrites. The SQLite
# plugin links Libs/libsqlite3_vendored.a (SQLITE_VERSION in scripts/build-sqlite.sh), so point
# this at a shell of that version.
#
# Usage: scripts/probes/check-sqlite-cascade-delete-counts.sh [path-to-sqlite3]

set -euo pipefail

SQLITE="${1:-sqlite3}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0

check() {
    if [ "$2" = "$3" ]; then
        printf '  ok    %s (%s)\n' "$1" "$2"
    else
        printf '  FAIL  %s: expected %s, got %s\n' "$1" "$3" "$2"
        failures=$((failures + 1))
    fi
}

printf 'sqlite3: %s\n\n' "$("$SQLITE" --version)"

# A connection enforces foreign keys only after PRAGMA foreign_keys = ON, which is why the preview
# reads the pragma on the save's own connection before counting anything.
printf 'Foreign key enforcement\n'
check "a new connection starts with foreign keys off" "$("$SQLITE" "$WORK/fresh.db" "PRAGMA foreign_keys;")" "0"

# The counts written for a two-level cascade and a SET NULL equal what the DELETE does.
printf '\nCounts against the DELETE\n'
db="$WORK/shop.db"
"$SQLITE" "$db" <<'SQL'
CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id) ON DELETE CASCADE);
CREATE TABLE order_items (id INTEGER PRIMARY KEY, order_id INTEGER REFERENCES orders(id) ON DELETE CASCADE);
CREATE TABLE invoices (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id) ON DELETE SET NULL);
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 10) INSERT INTO customers SELECT i, 'c' || i FROM n;
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 50) INSERT INTO orders SELECT i, (i % 10) + 1 FROM n;
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200) INSERT INTO order_items SELECT i, (i % 50) + 1 FROM n;
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 30) INSERT INTO invoices SELECT i, (i % 10) + 1 FROM n;
SQL
orders=$("$SQLITE" "$db" "SELECT COUNT(*) FROM \"orders\" WHERE EXISTS (SELECT 1 FROM \"customers\" cascade_1 WHERE cascade_1.\"id\" = \"orders\".\"customer_id\" AND (cascade_1.\"id\" IN ('1', '2', '3')));")
items=$("$SQLITE" "$db" "SELECT COUNT(*) FROM \"order_items\" WHERE EXISTS (SELECT 1 FROM \"orders\" cascade_1 WHERE cascade_1.\"id\" = \"order_items\".\"order_id\" AND (EXISTS (SELECT 1 FROM \"customers\" cascade_2 WHERE cascade_2.\"id\" = cascade_1.\"customer_id\" AND (cascade_2.\"id\" IN ('1', '2', '3')))));")
invoices=$("$SQLITE" "$db" "SELECT COUNT(*) FROM \"invoices\" WHERE EXISTS (SELECT 1 FROM \"customers\" cascade_1 WHERE cascade_1.\"id\" = \"invoices\".\"customer_id\" AND (cascade_1.\"id\" IN ('1', '2', '3')));")
after=$("$SQLITE" "$db" "PRAGMA foreign_keys = ON; SELECT (SELECT COUNT(*) FROM orders) || ' ' || (SELECT COUNT(*) FROM order_items); DELETE FROM customers WHERE id IN (1, 2, 3); SELECT (SELECT COUNT(*) FROM orders) || ' ' || (SELECT COUNT(*) FROM order_items) || ' ' || (SELECT COUNT(*) FROM invoices WHERE customer_id IS NULL);")
before_orders=$(echo "$after" | sed -n 1p | cut -d' ' -f1)
before_items=$(echo "$after" | sed -n 1p | cut -d' ' -f2)
check "orders a cascade deletes" "$orders" "$((before_orders - $(echo "$after" | sed -n 2p | cut -d' ' -f1)))"
check "order_items two keys away" "$items" "$((before_items - $(echo "$after" | sed -n 2p | cut -d' ' -f2)))"
check "invoices SET NULL rewrites" "$invoices" "$(echo "$after" | sed -n 2p | cut -d' ' -f3)"

# A key compares with the parent's collation and affinity. The parent column sits on the left of the
# `=`, which is where SQLite takes them from; the child side would find nothing in both cases below.
printf '\nParent collation and affinity\n'
db="$WORK/compare.db"
"$SQLITE" "$db" <<'SQL'
CREATE TABLE p (id TEXT COLLATE NOCASE PRIMARY KEY);
CREATE TABLE c (pid TEXT REFERENCES p(id) ON DELETE CASCADE);
INSERT INTO p VALUES ('ABC');
INSERT INTO c VALUES ('abc');
CREATE TABLE n (id INTEGER PRIMARY KEY);
CREATE TABLE m (nid REFERENCES n(id) ON DELETE CASCADE);
INSERT INTO n VALUES (9);
INSERT INTO m VALUES (9);
SQL
check "NOCASE parent finds a child in another case" \
    "$("$SQLITE" "$db" "SELECT COUNT(*) FROM \"c\" WHERE EXISTS (SELECT 1 FROM \"p\" cascade_1 WHERE cascade_1.\"id\" = \"c\".\"pid\" AND (cascade_1.\"id\" IN ('ABC')));")" "1"
check "a text literal matches an integer key through the parent" \
    "$("$SQLITE" "$db" "SELECT COUNT(*) FROM \"m\" WHERE EXISTS (SELECT 1 FROM \"n\" cascade_1 WHERE cascade_1.\"id\" = \"m\".\"nid\" AND (cascade_1.\"id\" IN ('9')));")" "1"
check "the same literal on the untyped child finds nothing" \
    "$("$SQLITE" "$db" "SELECT COUNT(*) FROM m WHERE nid IN ('9');")" "0"

printf '\n'
if [ "$failures" -gt 0 ]; then
    printf '%d check(s) failed: CascadeDeleteSQL has to change with SQLite.\n' "$failures"
    exit 1
fi
printf 'All checks passed.\n'
