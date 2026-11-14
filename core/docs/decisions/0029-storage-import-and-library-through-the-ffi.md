# 0029: Saved queries, favourites, history pins, CSV import and connection copies cross the FFI

- **Status**: Accepted
- **Date**: 2026-11-15

## Context

The Windows app reaches the core only through `crates/ffi`. Saved queries with folders and keywords, favourite tables and databases ([0017](0017-favourites.md)), history pins and export, the CSV import (`tablepro_core::import`) and the connection library's export are core code the Linux app calls directly and the FFI did not expose. Duplicating a connection with its secrets lived only in the Linux app, over storage calls the FFI already has.

## Decision

- `QueryHistoryStore` gains `set_pinned`, `export(ids, format, path)` and two stores over the same database: `saved_queries()` and `favourites()`.
- `SavedQueryStore` reads a connection's queries and folders in one transaction (`snapshot`) and writes through `SavedQueries` and `SavedQueryFolders` as they are. `save(draft, replace)` gives the id, or nothing when the name is taken and `replace` is false, so the app asks before replacing. `delete_for_connection` takes a deleted connection's queries, folders and favourites.
- `FavouriteStore` lists, marks and unmarks tables and databases per connection, a database with one of the four environments.
- `DatabaseSession::open_csv_import(table)` reads the table's definition into `ImportColumn`s. `CsvImport` previews the first `MAX_PREVIEW_ROWS`, suggests a mapping by header, and `plan(path, options, mapping)` reads the whole file, at most `MAX_CSV_FILE_BYTES` read through a bounded reader, turns each row into cells with `row_to_cells` and plans with `plan_import`. A field the column cannot read comes back as `RowRefused` with its line, column, text and the `EditParseError` code, and an empty file as `Empty`; neither is an error. `Ready` carries the row count, the statements' SQL and the Safe Mode gate.
- `CsvImport::run(confirmed)` writes the import planned last, once, as one `WriteBatch` under `OperationKind::Save(WriteKind::RowChanges)`, gated as a row save ([0019](0019-row-edits-through-the-ffi.md)): Confirm writes needs `confirmed`, Read only refuses, and a level changed since the plan refuses on the writing lease. Each statement adds 5 seconds to the call's deadline, as the Linux import allows. A failure reports the file lines of the statement that failed: `RolledBack`, `PartlyWritten` with the rows before it on an engine without a transaction, or `Unknown`.
- `ConnectionLibrary::duplicate(id, name)` copies the connection under a new id right after the original (`insert_after_blocking`), never opened and no favourite, after copying every secret kind the original keeps; a refused secret or write takes the copy's secrets back. The app names the copy, since the name is in the user's language. `export_file(path)` writes `export_blocking`'s document, which carries no secret.
- History exports and connection exports are written beside the target and renamed over it once synced, as result exports are.

## Rationale

- The storage and import code stays where Linux runs it; the FFI only maps records and codes, so both apps keep one behavior.
- A row the file cannot fill and an empty file are things the user fixes in the dialog, so they come back as values the app words with the cell edit's own codes.
- The plan is kept in the `CsvImport` object, so the statements shown before a confirmed run are the ones sent, without the rows crossing the boundary twice.
- The copy's secrets go in before its entry, so no listed connection points at secrets that are not there.

## Consequences

- The app words the copy's name and every error code (`import.*`, `storage.*`, `secret.*`).
- `DraftStore` stays off the FFI: the Windows app keeps a query tab's text in its own session file and calls nothing that needs it.
- `PastedTable` and `PastedRows` stay off the FFI until a paste into the grid has its key-based edits (roadmap C-10).
- An import of a file past 64 MiB is refused; one larger import needs the streaming the SQL file import has ([0011](0011-sql-dump-and-import-in-process.md)).

## Alternatives considered

- **The app reads the file and sends rows.** Every value would cross as text twice and the app would hold a copy of the file the core already reads.
- **A row fault as an error with fields.** `ErrorInfo` would grow fields only one call fills, in every binding.
