# SQLite

Driver id `sqlite`, crate `crates/drivers/sqlite`. It runs on sqlx 0.9 with `sqlite-unbundled`, so it links the system's libsqlite3 rather than a second copy, and calls `libsqlite3-sys` directly once, for `sqlite3_get_autocommit`, until sqlx exposes a connection's transaction state. The library must be SQLite 3.37.0 or newer (`SQLITE_MIN_VERSION`), which the driver checks when it opens the file. The contract it implements is in [adding-drivers.md](../adding-drivers.md).

There is no network, login or TLS: the target is a `FileEndpoint`, an absolute path with a `FileOpenMode`.

## Opening a file

Every connection to the file opens with the same options:

- The path is a file name, never a URI, so `?` and `%41` in it are part of the name.
- A missing file is `FileNotFound`; the driver never creates one by accident (`create_if_missing` is off).
- A read-only connection opens the file with `SQLITE_OPEN_READONLY`.
- `busy_timeout` is the workspace's lock timeout, 10 s: how long SQLite waits for another connection's lock before it reports `Busy`.
- `foreign_keys = ON`, and `trusted_schema = OFF`, so a view or trigger in a file from elsewhere cannot run SQL functions with side effects.
- The statement cache is off, because sqlx keeps a statement's columns from its first prepare and SQLite prepares it again with more columns after an `ALTER TABLE`.
- sqlx's statement logging is off.

The connect reads `sqlite_version()` from the file once, so a file that is not a database fails the connect (`NotADatabase`) rather than the first page. SQLite only says it could not open a file; the driver tells a moved file (`FileNotFound`) from one the user may not read (`FileAccessDenied`) by looking at the path.

### New databases

`FileOpenMode::CreateNew` is what the New Database flow sends after the save dialog has asked about replacing a file. The driver writes an empty file next to the target with mode 0600, syncs it, renames it over the path, removes any `-wal`, `-shm` or `-journal` file left beside the old database (it would be replayed into the new one), and syncs the folder so the rename is durable. A reader sees the old file or the new one, never half of one. An existing file is replaced, not refused.

A reconnect uses `FileEndpoint::for_reopen`, which is always `OpenExisting`, so reconnecting never empties a database the user just created.

### Where the file lives

SQLite relies on POSIX file locks and, for a database in WAL mode, on shared memory in the `-shm` file beside it. Both work on a local file system. On NFS or SMB, locks can fail without an error, and two writers can then corrupt the file. A FUSE mount may not implement the locks at all. A file chosen through the Flatpak document portal sits on the portal's own FUSE file system, which exposes the chosen file rather than its folder, so the journal and WAL files SQLite keeps beside it may not work there.

The driver does not detect any of these. Open such a file read-only, or copy it to a local folder first. Under the development Flatpak, which grants `--filesystem=home`, a file under the home folder is opened at its real path, not through the portal.

## Connections

| Connection | Used for |
|---|---|
| One workspace connection (`WORKSPACE_POOL_MAX_SIZE` is 1) | The sidebar, the grid, counts, saves |
| One read-only connection per call | `stream_read` (exports) |
| One connection per editor tab | `EditorSession` |

One workspace connection is enough because SQLite takes one writer at a time anyway, and it keeps a temporary table or an attached database where the next call can see it. Calls wait for it for up to the pool wait (5 s).

## Stops and timeouts

SQLite has no statement timeout and no out-of-band cancel. Each call installs a fresh flag, and a progress handler checks it every 1,000 virtual-machine instructions; when the flag is up the statement ends with `SQLITE_INTERRUPT`. The flag names the call, not the connection, so a stop that arrives late cannot reach the next call: `StopDelivery::OutOfBand(StopScope::Statement)`. `sqlite3_interrupt` is not used, because sqlx's handle to the connection waits for the worker thread to finish its current command, which is the statement the stop was meant for.

The workspace statement timeout (60 s) becomes a deadline the flag enforces. The flag is lowered before a rollback runs, so the rollback is never interrupted by the stop that caused it.

## Read-only

`ReadOnlyEnforcement::EngineEnforced`: the file is opened read-only, so SQLite refuses every write, whatever the SQL (`SQLITE_READONLY`, reported as `ReadOnly(ServerRejected)`). Saves on a read-only connection are refused before anything is sent. Exports always open their connection read-only.

## Writes

`WriteAtomicity::Transactional` for row and schema changes. A save is one transaction that starts with `BEGIN IMMEDIATE`, which takes the write lock before the first probe reads anything: contention shows up once, as `Busy` after the lock timeout, before anything has run.

SQLite is the one engine that can suspend foreign keys for a batch (`ForeignKeyMode::SuspendedThenVerified`), which a table rebuild needs for its copy:

1. `PRAGMA foreign_keys = OFF` before `BEGIN`, since the pragma does nothing inside a transaction.
2. `PRAGMA foreign_key_check` on the named tables before the batch and after it.
3. Only violations the batch introduced fail it, and the batch rolls back. A file can hold violations from long before, written while foreign keys were off, and those do not count.
4. `PRAGMA foreign_keys = ON` after the `COMMIT` or `ROLLBACK`.

A `COMMIT` never crosses a network, so nothing is left to resolve afterwards (`CommitResolutionSupport::Unavailable`).

### Row identity

The grid names a row by its primary key, then by a unique index whose columns are all `NOT NULL`, then by `rowid`. A `WITHOUT ROWID` table with neither key, or a table with a column named `rowid` that hides the real one, is read-only in the grid.

## Structure changes

`ALTER TABLE` renames a table or a column, adds a column, and drops one. The DDL dialect uses it where SQLite allows the change: an added column with no key, a constant default, and NOT NULL only with a default; a dropped column that has no key or UNIQUE of its own. Every other change rebuilds the table, following the procedure in [lang_altertable.html](https://www.sqlite.org/lang_altertable.html#otheralter), in one batch under `ForeignKeyMode::SuspendedThenVerified`:

1. Drop the views, and the triggers on other tables, that name the table, since the rename in step 5 checks every one of them.
2. Create `_tablepro_rebuild_<table>` from the stored CREATE TABLE with only the edited parts replaced: a column's type, NULL, DEFAULT and key, the key itself, and the foreign keys added or dropped. A COLLATE, CHECK, generated expression, conflict clause, comment or `WITHOUT ROWID` the edit did not touch stays as it was written.
3. Copy the rows, with their rowids unless the table has none or an `INTEGER PRIMARY KEY` column carries them. A generated column is computed again.
4. With AUTOINCREMENT on both sides, carry the `sqlite_sequence` mark, so a deleted number is not handed out again.
5. Drop the old table and rename the new one into its place.
6. Make the indexes, triggers and views again from their stored SQL, in the order the schema first made them.
7. Rename columns, then the table, natively, so SQLite carries the new names into every index, trigger, view and foreign key.

The foreign key check covers the rebuilt table and every table whose keys point at it, and fails the save only for a violation the save introduced. A rebuild refuses to drop a column that a kept index, CHECK, generated column, foreign key, trigger or view still names. A table whose CREATE TABLE the reader cannot follow, such as a virtual table, keeps the native changes and refuses the rest as `UnreadableDefinition`.

SQLite's pragmas do not report a foreign key's constraint name, so the definition reads it from the CREATE TABLE text, and a key declared without one is named `fk_<table>_<n>` after its position.

## Editor sessions

- A script is split where SQLite itself would end a statement, so the semicolons inside a trigger body do not end it. Text the splitter cannot finish, such as an unterminated string, goes to SQLite whole, so the error is SQLite's own. The splitter is tested against `sqlite3_complete` (`tests/script_plan_matches_sqlite3_complete.rs`).
- Each statement is prepared first, so a `SELECT` that finds nothing still has its columns. A column with no declared type gets its type from the first row, sent as `ResultEvent::ColumnsResolved`.
- The row limit stops the read one row past the limit, and the set ends with `Truncation::ReadPastLimit`. SQLite computes a row only when it is stepped, so the rest of the result is never produced.
- A stop raises the run's flag and gives the statement the cancel grace to notice it; past that its read is dropped.
- The transaction state after a run comes from `sqlite3_get_autocommit`.
