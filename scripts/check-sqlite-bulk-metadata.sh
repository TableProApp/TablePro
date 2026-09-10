#!/usr/bin/env bash
#
# Checks that the SQLite driver's whole-schema metadata reads agree with its
# per-table ones.
#
# The bulk read stands in for the per-table read, so the two have to answer the
# same question. They did not: `fetchAllColumns` used `pragma_table_info`, which
# omits generated columns entirely, while `fetchColumns` uses `table_xinfo` for
# exactly that reason. A comparison built on the bulk read saw neither side's
# generated columns and reported them as matching.
#
# The queries here are the ones the driver runs, so a SQLite upgrade that changes
# what a pragma reports fails this instead of shipping a silent disagreement.
#
# Usage: scripts/check-sqlite-bulk-metadata.sh
set -euo pipefail

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "sqlite3 is not on PATH" >&2
    exit 2
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
db="$workdir/probe.db"

sqlite3 "$db" <<'SQL'
CREATE TABLE orders(
    id INTEGER PRIMARY KEY,
    a TEXT,
    b TEXT,
    virtual_len INT GENERATED ALWAYS AS (length(a)) VIRTUAL,
    stored_len INT GENERATED ALWAYS AS (length(b)) STORED
);
CREATE UNIQUE INDEX ux_orders_ab ON orders(a, b);
CREATE INDEX ix_orders_b ON orders(b);
CREATE TABLE composite(a TEXT, b TEXT, v TEXT, PRIMARY KEY(a, b));
CREATE TABLE plain(id INTEGER PRIMARY KEY, x TEXT);
SQL

status=0

# fetchAllColumns, from SQLitePlugin.swift. table_xinfo, not table_info: the
# `hidden` column is what marks a generated column 2 (VIRTUAL) or 3 (STORED).
bulk_columns() {
    sqlite3 "$db" 'SELECT m.name, p.cid, p.name, p.type, p."notnull", p.dflt_value, p.pk, p.hidden
        FROM sqlite_master m, pragma_table_xinfo(m.name) p
        WHERE m.type = '"'"'table'"'"' AND m.name NOT LIKE '"'"'sqlite_%'"'"'
        ORDER BY m.name, p.cid;'
}

# fetchColumns, from SQLitePlugin.swift, run for one table.
per_table_columns() {
    sqlite3 "$db" "SELECT '$1', p.cid, p.name, p.type, p.\"notnull\", p.dflt_value, p.pk, p.hidden
        FROM pragma_table_xinfo('$1') p ORDER BY p.cid;"
}

# fetchAllIndexes, from SQLitePluginDriver+BulkMetadata.swift.
bulk_indexes() {
    sqlite3 "$db" 'SELECT m.name, il.name, il."unique", il.origin, ii.name
        FROM sqlite_master m
        JOIN pragma_index_list(m.name) il
        LEFT JOIN pragma_index_info(il.name) ii ON 1=1
        WHERE m.type = '"'"'table'"'"' AND m.name NOT LIKE '"'"'sqlite_%'"'"'
        ORDER BY m.name, il.seq, ii.seqno;'
}

# fetchIndexes, from SQLitePlugin.swift, run for one table.
per_table_indexes() {
    sqlite3 "$db" "SELECT '$1', il.name, il.\"unique\", il.origin, ii.name
        FROM pragma_index_list('$1') il
        LEFT JOIN pragma_index_info(il.name) ii ON 1=1
        ORDER BY il.seq, ii.seqno;"
}

tables="orders composite plain"

for table in $tables; do
    if ! diff -u \
        <(per_table_columns "$table") \
        <(bulk_columns | grep "^$table|" || true) >"$workdir/columns-$table.diff"; then
        echo "columns disagree for $table:" >&2
        cat "$workdir/columns-$table.diff" >&2
        status=1
    fi

    if ! diff -u \
        <(per_table_indexes "$table") \
        <(bulk_indexes | grep "^$table|" || true) >"$workdir/indexes-$table.diff"; then
        echo "indexes disagree for $table:" >&2
        cat "$workdir/indexes-$table.diff" >&2
        status=1
    fi
done

# The reason the columns read moved to table_xinfo. A generated column must be
# in the list, and must carry the hidden flag that says which kind it is.
generated="$(bulk_columns | grep -c '|virtual_len|\||stored_len|' || true)"
if [ "$generated" -ne 2 ]; then
    echo "the whole-schema column read lost a generated column (found $generated of 2)" >&2
    status=1
fi

if [ "$status" -eq 0 ]; then
    echo "SQLite whole-schema reads agree with the per-table reads ($(sqlite3 "$db" 'SELECT sqlite_version();'))"
fi

exit "$status"
