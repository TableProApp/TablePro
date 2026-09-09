#!/bin/bash
#
# Re-checks the SQLite behaviour the table-rebuild planner is built on.
#
# SQLiteTableRebuildPlanner emits a fixed script shape, and every part of that shape exists because
# of something SQLite does that no header or doc page states plainly. This asserts each of those
# against the SQLite actually on this machine, which is the one the plugin links: project.yml passes
# -lsqlite3 with no LIBRARY_SEARCH_PATHS, and there is no vendored libsqlite3 in the repo, so the
# driver runs against the system library and its behaviour moves with macOS.
#
# Run it after a macOS upgrade, or whenever the rebuild starts behaving oddly. A failure here is not
# a broken test: it means SQLite changed and the planner's shape has to change with it.
#
# Usage: scripts/check-sqlite-rebuild-assumptions.sh [path-to-sqlite3]

set -euo pipefail

SQLITE="${1:-sqlite3}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

printf 'sqlite3: %s\n\n' "$("$SQLITE" --version)"

# 1. ALTER TABLE cannot add a FOREIGN KEY, at any version.
#
# This is the whole reason the rebuild exists. SQLite 3.53 added ADD/DROP CONSTRAINT, and its
# changelog covers NOT NULL and CHECK only. If a future version accepts a FOREIGN KEY here, the
# rebuild is no longer the only way and ForeignKeyEditSupport should offer .alter for SQLite.
printf 'ALTER TABLE constraint support\n'
db="$WORK/alter.db"
"$SQLITE" "$db" "CREATE TABLE p(id INTEGER PRIMARY KEY, code TEXT); CREATE TABLE c(id INTEGER, pid INTEGER, note TEXT);"

if "$SQLITE" "$db" "ALTER TABLE c ADD CONSTRAINT fk FOREIGN KEY (pid) REFERENCES p(id);" 2>/dev/null; then
    fail "ADD CONSTRAINT … FOREIGN KEY is now accepted; the rebuild may no longer be required"
else
    pass "ADD CONSTRAINT … FOREIGN KEY is still rejected"
fi

if "$SQLITE" "$db" "ALTER TABLE c ADD CONSTRAINT ck CHECK (id > 0);" 2>/dev/null; then
    pass "ADD CONSTRAINT … CHECK is accepted, which SQLitePlugin's version gate relies on"
else
    fail "ADD CONSTRAINT … CHECK was rejected; the check-constraint editor's version gate is wrong"
fi

db="$WORK/dropfk.db"
"$SQLITE" "$db" "CREATE TABLE p(id INTEGER PRIMARY KEY); CREATE TABLE c(pid INTEGER, CONSTRAINT fk FOREIGN KEY(pid) REFERENCES p(id));"
if "$SQLITE" "$db" "ALTER TABLE c DROP CONSTRAINT fk;" 2>/dev/null; then
    fail "DROP CONSTRAINT on a foreign key is now accepted; dropping one no longer needs a rebuild"
else
    pass "DROP CONSTRAINT on a foreign key is still rejected"
fi

# 2. The foreign_keys pragma has to precede BEGIN.
#
# DROP TABLE performs an implicit DELETE FROM, which fires ON DELETE CASCADE on every table
# referencing the one being rebuilt, and the pragma is silently ignored inside a transaction.
# PluginColumnReorderPlan.prologue exists to run it outside, and StructureRebuildPlanRunner runs the
# prologue before beginTransaction for this reason alone.
printf '\nRebuild and ON DELETE CASCADE\n'
rebuild() {
    local db="$1" prologue="$2" inside="$3"
    "$SQLITE" "$db" "CREATE TABLE p(id INTEGER PRIMARY KEY, v TEXT);
        CREATE TABLE kid(id INTEGER PRIMARY KEY, pid INTEGER REFERENCES p(id) ON DELETE CASCADE);
        INSERT INTO p VALUES(1,'a'),(2,'b'); INSERT INTO kid VALUES(10,1),(20,2);"
    "$SQLITE" "$db" "$prologue
        BEGIN;
        $inside
        CREATE TABLE p_new(id INTEGER PRIMARY KEY, v TEXT);
        INSERT INTO p_new(rowid,id,v) SELECT rowid,id,v FROM p;
        DROP TABLE p;
        ALTER TABLE p_new RENAME TO p;
        COMMIT;" >/dev/null 2>&1 || true
    "$SQLITE" "$db" "SELECT count(*) FROM kid;"
}

if [ "$(rebuild "$WORK/a.db" "PRAGMA foreign_keys=OFF;" "")" = "2" ]; then
    pass "pragma before BEGIN keeps the child rows"
else
    fail "pragma before BEGIN lost child rows; the rebuild is unsafe on this SQLite"
fi

if [ "$(rebuild "$WORK/b.db" "PRAGMA foreign_keys=ON;" "PRAGMA foreign_keys=OFF;")" = "0" ]; then
    pass "pragma inside the transaction still loses the child rows, so it must stay in the prologue"
else
    pass "pragma inside the transaction no longer loses rows; the prologue is now belt and braces"
fi

if [ "$(rebuild "$WORK/c.db" "PRAGMA foreign_keys=ON; PRAGMA defer_foreign_keys=1;" "")" = "0" ]; then
    pass "defer_foreign_keys still loses the child rows, so it is still the wrong knob"
else
    pass "defer_foreign_keys no longer loses rows; foreign_keys=off remains the documented route"
fi

# 3. foreign_key_check has to be scoped to one table.
#
# The plan's verification reads its rows and rolls back on any. Measured: the whole-database form
# aborts with "foreign key mismatch" and returns NO rows when any key anywhere in the database is
# structurally invalid, so one unrelated bad key would hide every real violation.
printf '\nforeign_key_check scoping\n'
db="$WORK/fkc.db"
"$SQLITE" "$db" "PRAGMA foreign_keys=off;
    CREATE TABLE p(id INTEGER PRIMARY KEY, code TEXT);
    CREATE TABLE bad(a INTEGER REFERENCES p(code));
    CREATE TABLE good(b INTEGER REFERENCES p(id));
    INSERT INTO p VALUES(1,'x'); INSERT INTO good VALUES(99);"

if "$SQLITE" "$db" "PRAGMA foreign_key_check;" >/dev/null 2>&1; then
    fail "the whole-database check no longer aborts on a structurally invalid key; scoping may be unneeded"
else
    pass "the whole-database check still aborts, so the plan must scope to one table"
fi

if [ -n "$("$SQLITE" "$db" "PRAGMA foreign_key_check(good);" 2>/dev/null)" ]; then
    pass "a table-scoped check reports a row with no matching parent"
else
    fail "a table-scoped check missed an orphan row; the rebuild would commit bad data"
fi

if "$SQLITE" "$db" "PRAGMA foreign_key_check(bad);" >/dev/null 2>&1; then
    fail "a key whose parent columns are not unique no longer raises; the plan needs its own pre-flight"
else
    pass "a key whose parent columns are not unique raises, so no separate pre-flight is needed"
fi

# 4. A copy that does not name rowid renumbers every row.
#
# For a table with no INTEGER PRIMARY KEY the rowid is the only row identity the app has, so a
# renumber silently repoints an open grid's selection and its pending edits.
printf '\nRow identity\n'
db="$WORK/rowid.db"
"$SQLITE" "$db" "CREATE TABLE t(a TEXT); INSERT INTO t VALUES('x'),('y'),('z'); DELETE FROM t WHERE a='y';"
"$SQLITE" "$db" "BEGIN; CREATE TABLE t2(a TEXT); INSERT INTO t2(a) SELECT a FROM t; DROP TABLE t; ALTER TABLE t2 RENAME TO t; COMMIT;"
if [ "$("$SQLITE" "$db" "SELECT rowid FROM t WHERE a='z';")" = "3" ]; then
    pass "a copy without rowid preserved it; naming rowid is now redundant"
else
    pass "a copy without rowid renumbers rows, so the plan names rowid explicitly"
fi

db="$WORK/rowid2.db"
"$SQLITE" "$db" "CREATE TABLE t(a TEXT); INSERT INTO t VALUES('x'),('y'),('z'); DELETE FROM t WHERE a='y';"
"$SQLITE" "$db" "BEGIN; CREATE TABLE t2(a TEXT); INSERT INTO t2(rowid,a) SELECT rowid,a FROM t; DROP TABLE t; ALTER TABLE t2 RENAME TO t; COMMIT;"
if [ "$("$SQLITE" "$db" "SELECT rowid FROM t WHERE a='z';")" = "3" ]; then
    pass "naming rowid preserves it exactly"
else
    fail "naming rowid did not preserve it; row identity is lost across a rebuild"
fi

# INTEGER PRIMARY KEY DESC is not a rowid alias, and PRAGMA table_xinfo cannot tell it from one
# that is. That is why the copy names rowid on every rowid table rather than skipping it when the
# table appears to have an alias: skipping it there renumbers every row.
db="$WORK/desc.db"
"$SQLITE" "$db" "CREATE TABLE asc1(a INTEGER PRIMARY KEY, v TEXT); CREATE TABLE desc1(a INTEGER PRIMARY KEY DESC, v TEXT);
    INSERT INTO asc1 VALUES(5,'x'); INSERT INTO desc1 VALUES(5,'x');"
asc_rowid="$("$SQLITE" "$db" "SELECT rowid FROM asc1;")"
desc_rowid="$("$SQLITE" "$db" "SELECT rowid FROM desc1;")"
asc_xinfo="$("$SQLITE" "$db" "PRAGMA table_xinfo(asc1);" | head -1)"
desc_xinfo="$("$SQLITE" "$db" "PRAGMA table_xinfo(desc1);" | head -1)"

if [ "$asc_rowid" = "5" ] && [ "$desc_rowid" != "5" ] && [ "$asc_xinfo" = "$desc_xinfo" ]; then
    pass "INTEGER PRIMARY KEY DESC is still not an alias and still looks identical in table_xinfo"
elif [ "$asc_xinfo" != "$desc_xinfo" ]; then
    pass "table_xinfo now distinguishes the DESC form; the copy could skip rowid when an alias exists"
else
    fail "the rowid alias forms behave unexpectedly; re-check why the copy always names rowid"
fi

db="$WORK/wr.db"
"$SQLITE" "$db" "CREATE TABLE w(k TEXT PRIMARY KEY, v INT) WITHOUT ROWID; INSERT INTO w VALUES('a',1);"
if "$SQLITE" "$db" "CREATE TABLE w2(k TEXT PRIMARY KEY, v INT) WITHOUT ROWID; INSERT INTO w2(rowid,k,v) SELECT rowid,k,v FROM w;" >/dev/null 2>&1; then
    fail "a WITHOUT ROWID table now accepts a rowid column; the planner's branch is dead code"
else
    pass "a WITHOUT ROWID table still rejects a rowid column, so the planner must branch on it"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf 'All rebuild assumptions hold.\n'
else
    printf '%d assumption(s) no longer hold. SQLiteTableRebuildPlanner needs revisiting.\n' "$failures"
    exit 1
fi
