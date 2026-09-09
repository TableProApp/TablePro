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

# 5. legacy_alter_table decides whether the rebuild's own rename works and whether a later
#    DROP COLUMN refuses a broken dependent. The plan sets it both ways for that reason, and puts
#    the connection back afterwards because the setting survives the commit.
printf '\nlegacy_alter_table\n'
rebuild_with_view() {
    local db="$WORK/lat-$1.db"
    "$SQLITE" "$db" "CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT); CREATE VIEW v AS SELECT b FROM t;"
    "$SQLITE" "$db" "PRAGMA foreign_keys=off; PRAGMA legacy_alter_table=$1;
        BEGIN;
        CREATE TABLE t_rb(a INTEGER PRIMARY KEY, b TEXT, c INT);
        INSERT INTO t_rb(rowid,a,b) SELECT rowid,a,b FROM t;
        DROP TABLE t;
        ALTER TABLE t_rb RENAME TO t;
        COMMIT;" >/dev/null 2>&1
}

if rebuild_with_view 1; then
    pass "the table rename succeeds at legacy_alter_table=1, which the rebuild sets"
else
    fail "the table rename failed even at legacy_alter_table=1"
fi

if rebuild_with_view 0; then
    pass "the table rename no longer needs legacy_alter_table=1; the plan may stop setting it"
else
    pass "the table rename still fails at 0 over a dependent view, so the plan must set it to 1"
fi

db="$WORK/dropdep.db"
"$SQLITE" "$db" "CREATE TABLE t(a INT, b TEXT);
    CREATE TRIGGER tr AFTER UPDATE OF b ON t BEGIN SELECT new.b; END;"
if "$SQLITE" "$db" "PRAGMA legacy_alter_table=0; ALTER TABLE t DROP COLUMN b;" >/dev/null 2>&1; then
    fail "DROP COLUMN no longer refuses a column a trigger needs; the plan's legacy=0 buys nothing"
else
    pass "DROP COLUMN refuses a column a trigger needs at legacy_alter_table=0"
fi

db="$WORK/latpersist.db"
"$SQLITE" "$db" "CREATE TABLE t(a);"
if [ "$("$SQLITE" "$db" "PRAGMA legacy_alter_table=1; BEGIN; COMMIT; SELECT * FROM pragma_legacy_alter_table();")" = "1" ]; then
    pass "legacy_alter_table survives the commit, so the epilogue must restore it"
else
    pass "legacy_alter_table no longer survives the commit; restoring it is now belt and braces"
fi

# 6. EXPLAIN compiles a dependent object's body without running it, which is how the plan catches
#    what ALTER TABLE and foreign_key_check both miss.
printf '\nDependent revalidation\n'
db="$WORK/explain.db"
"$SQLITE" "$db" "CREATE TABLE t(id INTEGER PRIMARY KEY, keep TEXT, doomed TEXT);
    CREATE VIEW v(a,b,c) AS SELECT * FROM t;
    CREATE TABLE inbox(n INT);
    CREATE TRIGGER tr AFTER INSERT ON inbox BEGIN INSERT INTO t VALUES(NEW.n,'a','d'); END;
    PRAGMA legacy_alter_table=off;
    ALTER TABLE t DROP COLUMN doomed;"

if "$SQLITE" "$db" "EXPLAIN SELECT * FROM v;" >/dev/null 2>&1; then
    fail "EXPLAIN no longer reports a view broken by a dropped column"
else
    pass "EXPLAIN reports a view whose declared column list no longer matches"
fi

if "$SQLITE" "$db" "EXPLAIN INSERT INTO inbox DEFAULT VALUES;" >/dev/null 2>&1; then
    fail "EXPLAIN no longer reports a trigger on another table broken by a dropped column"
else
    pass "EXPLAIN reports a trigger on another table left broken by the drop"
fi

if [ "$("$SQLITE" "$db" "SELECT count(*) FROM inbox;")" = "0" ]; then
    pass "EXPLAIN prepares without executing, so the checks write nothing"
else
    fail "EXPLAIN executed the statement; the dependent checks are not safe to run"
fi

# 7. The column-declaration grammar the rewriter walks. Each of these refutes the published
#    railroad diagrams, and the rewriter slices a declaration wrongly if any of them changes.
printf '\nColumn declaration grammar\n'
db="$WORK/grammar.db"
"$SQLITE" "$db" "CREATE TABLE g(a UNSIGNED BIG INT, b, c NULL, d BIG GENERATED ALWAYS AS (1), e \"DEFAULT\")" 2>/dev/null
types="$("$SQLITE" "$db" "SELECT group_concat(type, '|') FROM pragma_table_xinfo('g');" 2>/dev/null)"
if [ "$types" = "UNSIGNED BIG INT|||BIG|DEFAULT" ]; then
    pass "type names are multi-word, optional, and a bare NULL is a constraint rather than a type"
else
    fail "the column grammar moved: types read [$types]"
fi

db="$WORK/pkretype.db"
"$SQLITE" "$db" "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT); INSERT INTO t(v) VALUES('a');"
"$SQLITE" "$db" "BEGIN; CREATE TABLE t2(id TEXT PRIMARY KEY, v TEXT);
    INSERT INTO t2(rowid,id,v) SELECT rowid,id,v FROM t; DROP TABLE t;
    ALTER TABLE t2 RENAME TO t; COMMIT; INSERT INTO t(v) VALUES('b');" >/dev/null 2>&1
if [ "$("$SQLITE" "$db" "SELECT count(*) FROM t WHERE id IS NULL;")" = "0" ]; then
    pass "retyping an INTEGER PRIMARY KEY no longer strands NULLs; the refusal may be liftable"
else
    pass "retyping an INTEGER PRIMARY KEY still strands NULLs in the key, so it stays refused"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf 'All rebuild assumptions hold.\n'
else
    printf '%d assumption(s) no longer hold. SQLiteTableRebuildPlanner needs revisiting.\n' "$failures"
    exit 1
fi
