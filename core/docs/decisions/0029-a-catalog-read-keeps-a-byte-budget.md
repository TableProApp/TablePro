# 0029: A catalog read keeps a byte budget

- **Status**: Accepted
- **Date**: 2026-11-15

## Context

A file engine reads its catalog from the file the user opened, and the file chooses every name in it. SQLite's pragmas repeat a name on every key that uses it: a column that carries REFERENCES thousands of times comes back with its name on every key, a child's name on every key into its parent, and a key that names no parent columns took a copy of the parent's whole primary key. The keys into a table also carried the child's whole CREATE TABLE on each key column, and that text grows with the keys the child declares. DuckDB's keys into a table did the same with the child's CREATE TABLE. A file of a few hundred kilobytes made one read of a table's keys hold gigabytes, and each read held all its rows before it looked at the first.

## Decision

`CatalogBudget` in `tablepro-core` bounds what one catalog read holds at `ByteLimit::CATALOG_DEFAULT`, 64,000,000 bytes, counted as `Value::retained_bytes` counts text: a string's slot and its length. Past it the read fails with `DriverError::CatalogTooLarge { limit_bytes }`, code `driver.catalog_too_large`, category `Internal`.

- SQLite and DuckDB charge each text a read keeps as it arrives, and each copy made per key before it is made. A text read and dropped before the next one, as each child's CREATE TABLE, is released.
- Each text of the file is read once per call. SQLite streams catalog rows, unsorted where a sort would hold every row before the first, reads each child's CREATE TABLE once in a second query, and parses each CREATE TABLE once. DuckDB reads each child's and each parent's CREATE TABLE once.
- A save's foreign key check reads a rowid and a key id for each row that breaks a key, not the table's and parent's names.

## Rationale

- **An error, not a cut list.** A table definition plans structure changes, and a rebuild planned from a list cut short would drop what was left out.
- **64 MB.** A schema of 5,000 tables keyed to one table reads its keys in a few megabytes, and a million table names fit under it.
- **In the driver.** The driver knows which texts it copies per key, and no app has to pass a limit.

## Consequences

- Large real schemas read as before; the keys into a table read faster, without a child's CREATE TABLE on each row.
- One value is read before it is charged. SQLite bounds a value at `SQLITE_MAX_LENGTH` and parsed the text when it opened the file.
- DuckDB holds a catalog query's whole result before the first row, and names each constraint after its table. The budget bounds what the driver keeps, not that.
- Not budgeted: the schema list, reads of one value, and the SQL dumps, which read each object once.
- The apps word the code: Linux in `linux/crates/app/src/ui/error_text/driver.rs`, Windows in `Resources.resw`.
