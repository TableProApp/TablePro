# 0022: A table page is read on the session with its filter bound, and structure, definitions, export and history cross the FFI

- **Status**: Accepted
- **Date**: 2026-11-12

## Context

The Windows app reaches the core only through `crates/ffi`. A table tab read its page as editor text: `table_query` built the page with an empty filter, refused any statement that bound a value, and the tab ran the SQL on an editor connection of its own. A filter cannot work that way, since `build_filter` parses each value as the column's type and binds it. The FFI also had no read for a table's indexes, foreign keys and CREATE script, a routine's or trigger's source, an export, or the query history the Linux app reads through `tablepro-storage`.

## Decision

The FFI exposes what the Linux app calls, and does the work the Linux app does, so an app on it builds no SQL and keeps no store of its own.

- `DatabaseSession::read_table_page` reads the catalog's columns and the row identity, builds the page once with the filter so a value the column cannot take or a column the table lacks fails the call before anything is sent, then reads it with `browse::read_page` on a pooled connection (`OperationKind::Page`). The rows arrive as the run events an editor run gives (`ResultSetStarted`, `RowsAppended`, `ResultSetFinished`, `Finished` with an idle transaction), so a host shows a page and a query result the same way. `table_query` is gone, and a table tab no longer holds an editor connection.
- `table_row_count` takes the same filter. `filter_choices` gives each column's operators from `SqlDialect::filter_operators`, the engine's combinators, and whether it takes a raw SQL predicate, which `validate_raw_predicate` reads as exactly one expression. MongoDB's raw filter is a query document, not SQL, so it is not offered there yet, and raw text for an engine that is not SQL is refused (`filter.raw_unsupported`).
- A refused filter carries the codes of each layer: `operation.browse`, `browse.filter`, the rule's `filter.*`, and for a value the column cannot take, the parse's `edit.*` (`BrowseSqlError::codes`, `BuildFilterError::codes`).
- `table_structure` reads `fetch_table_definition` and gives its columns, indexes and foreign keys as display text, and the CREATE script from `DdlDialect::create_table_script` only for a table or a partitioned table, by the kind the catalog lists it under where it has one: on some engines the script for a view would be a CREATE TABLE made from its columns.
- `QueryEditor::use_database` moves an editor's connection to a database, for a definition whose text names none (MySQL's), as the Linux app opens such a definition.
- `object_definition` reads `fetch_object_definition` for a function, procedure, trigger or sequence, with whether running the text in an editor would make the object as it is.
- `export_rows` writes the rows a finished `ResultSet` holds, its visible columns only; `export_table` streams every row the filter and sort select through `build_export` and `stream_read`, as the Linux app exports a table. Both use the core's encoders (CSV with its default options, JSON, Excel, Markdown, HTML, XML, and SQL INSERT from a table), write beside the target and rename once complete, so a failed or cancelled export leaves no file.
- `Core::history` opens the query history at `<storage>/state/history.db` once. `record` takes the session, so the engine's `history_recording` withholds a statement that holds a secret, as on Linux; `search` pages by the store's keyset; `delete` and `clear` change it.

## Rationale

- One place builds the WHERE, binds its values and pages the table, for every app.
- Delivering a page as run events keeps the host's results code single, and a pooled connection is what the Linux app reads a page on.
- An editor connection per table tab held a connection the tab only read through.

## Consequences

- A table tab's page is no longer on a connection of its own, so a session setting made in a query tab does not reach it, as on Linux.
- A page is read whole, under `OperationKind::Page`'s deadline, before its rows reach the app.
- History is pruned to the store's cap when it opens; a retention setting, as Linux has, is the host's to add.
- An array value in `export_rows` is written as its text, since the result store keeps arrays only as text; `export_table` writes it as an array.

## Alternatives considered

- **Inline the filter's values as literals in editor text.** The values would be spliced into SQL, which the filter's design refuses.
- **A bound-statement run on the editor connection.** `EditorSession` runs only user text, and a page needs no transaction of the user's.
