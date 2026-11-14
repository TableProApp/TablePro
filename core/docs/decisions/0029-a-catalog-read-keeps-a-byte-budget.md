# 0029: A catalog read keeps a byte budget

- **Status**: Accepted
- **Date**: 2026-11-15

## Context

A file engine reads its catalog from the file the user opened, and the file chooses every name in it. SQLite's pragmas repeat a name on every key that uses it: a column that carries REFERENCES thousands of times comes back with its name on every key, a child's name on every key into its parent, and a key that names no parent columns took a copy of the parent's whole primary key. SQLite also compiles `PRAGMA foreign_key_list` with a copy of those names for each key column, so a 300 KB table cost it over 300 MB before the first row, and the keys into any table ran that pragma on every table of the schema. The keys into a table carried the child's whole CREATE TABLE on each key column, in SQLite and in DuckDB, and that text grows with the keys the child declares. A file of a few hundred kilobytes made one read of a table's keys hold gigabytes.

## Decision

`CatalogBudget` in `tablepro-core` bounds what one catalog read holds at `ByteLimit::CATALOG_DEFAULT`, 64,000,000 bytes, counted as `Value::retained_bytes` counts text: a string's slot and its length. Past it the read fails with `DriverError::CatalogTooLarge { limit_bytes }`, code `driver.catalog_too_large`, category `Internal`.

- SQLite and DuckDB charge each text a read keeps as it arrives, and each copy made per key before it is made. A text read and dropped before the next one, as each child's CREATE TABLE, is released.
- Each text of the file is read once per call, and SQLite's catalog rows stream, unsorted where a sort would hold every row first.
- SQLite runs `pragma_foreign_key_list` on a table only once the key list's cost, worked out from its CREATE TABLE (`foreign_key_list_bytes`), fits the budget. The keys into a table ask every table of at most 64 KiB whose key list cannot cost more than the budget in one read; each other table is read alone, searched in linear time for the parent's name, and costed first.
- A save's foreign key check holds each checked table's name and each broken key once, and each broken row as a key index and a rowid, all charged to one budget for the checks before and after the save. Past it the save rolls back with `CatalogTooLarge`: a check by count alone could let the save move a broken key to other rows.
- DuckDB builds every table's constraint rows, a chunk at a time, before a query filters them, and holds the whole result before the first row. A constraint read runs only once both fit, bounded from `duckdb_tables()` and `duckdb_dependencies()`. It reads each child's and each parent's CREATE TABLE once, and charges the column names it keeps from them.

## Rationale

- **An error, not a cut list.** A table definition plans structure changes, and a rebuild planned from a list cut short would drop what was left out.
- **64 MB.** A schema of 5,000 tables keyed to one table reads its keys in a few megabytes, and a million table names fit under it.
- **In the driver.** The driver knows which texts it copies per key and what SQLite compiles for them, and no app has to pass a limit.

## Consequences

- Large real schemas read as before, and the keys into a table read faster: 5,000 children in 0.2 s, against 1.4 s.
- One value is read before it is charged, and sqlx queues up to 50 rows ahead of the reader. SQLite bounds a value at `SQLITE_MAX_LENGTH`, and a CREATE TABLE over 64 KiB is read alone.
- In a DuckDB file with a crafted table, every read that touches constraints fails, the columns of any table among them, since DuckDB builds the crafted table's rows for each. The table list still reads.
- A save on a table with millions of rows that already break its keys rolls back rather than compare them.
- Not budgeted: the schema list, reads of one value, and the SQL dumps, which read each object once.
- The apps word the code: Linux in `linux/crates/app/src/ui/error_text/driver.rs`, Windows in `Resources.resw`.
