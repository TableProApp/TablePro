# 0007: Filtering, structure, definitions, export and query history

- **Status**: Accepted
- **Date**: 2026-11-12

## Context

A workspace opened tables and views and nothing else (audit item WN-09). Functions, procedures, triggers and sequences did nothing when clicked; a table tab had no WHERE filter and no view of its columns, indexes and keys; there was no export and no query history. The macOS app has all of them, and the core has every read the Linux app uses for them, which the FFI now carries ([core 0022](../../../core/docs/decisions/0022-browsing-through-the-ffi.md)).

## Decision

Each one works as the macOS app's does, with its words in Windows sentence case, over the core's reads; the logic sits in `src/TablePro.App.Model` with fakes in `tests/TablePro.App.Model.Tests`, and the views lay out.

### Table tab

- A `SelectorBar` at the top of a table tab switches between Data and Structure.
- Data reads its page through `ReadTablePageAsync` on the session's pooled connections; the tab opens no editor connection of its own (amends 0004).
- The filter bar (Filter in the tab's command bar, Query > Filter rows, Ctrl+Shift+F) holds one row per rule: a column, an operator the engine offers for it, and its value, two for between, a comma-separated list for in list. A Raw SQL row takes a WHERE condition where the engine reads SQL. Match all or Match any shows once there are two conditions, Any only where the engine has OR. Apply reads the first page and counts the rows the filter picks; Clear reads the whole table. A rule missing its value is refused before anything is sent. A filter the core refuses, or the server refuses, keeps the one the rows were read with, and the bar says why from the core's code (`filter.*`, down to a value's own `edit.*`), without naming the rule. Changing the filter asks before it discards pending edits, as a sort does. The filter is kept with the tab in the session.
- Structure shows Columns, Indexes, Foreign keys and DDL (`GetStructureAsync`). The lists are the read-only data grid over `TextGridData`, with the macOS headers and YES or NO; DDL is the engine's CREATE script in a read-only text box with Copy, and none for a view, whose CREATE TABLE some engines would build from its columns. Structure is read once and again on Refresh.

### Objects without rows

- A function, procedure, trigger or sequence opens a definition tab: its source read only (`GetObjectDefinitionAsync`), Reload, Copy, and Open in editor, which opens a query tab with the text and is hidden where the core says running it would not make the object as it is. A definition whose text names no database, as MySQL's, opens a query tab that moves its connection to that database before its first run (`QueryEditor.UseDatabaseAsync`), and refuses to run where the move fails. "Source unavailable" says why, or that the object is gone or the login cannot read it, with Try again.
- The tree's context menu offers Open, Show structure and Copy name for objects with rows, and Show DDL and Copy name for the others.
- Definition tabs are not kept in session.json: an older build reads an unknown tab kind as a damaged file and starts empty, and the tree brings one back in a click.

### Export

- File > Export results (Ctrl+Shift+E) asks for a format, CSV, JSON, Excel, Markdown, HTML, XML, or SQL INSERT from a table, and on a table tab for Current page or Entire table, then for a file with the system save picker. The core writes the file (`ExportRowsAsync`, `ExportTableAsync`): the rows held, or every row the tab's filter and sort select, streamed. A file appears only once complete.

### Query history

- Every typed run of a query tab is recorded once it ends, with its time, duration, rows affected and outcome. The core withholds a statement that holds a secret. A sort's rerun, Commit, Roll back and a run Safe Mode kept back are not recorded.
- View > Show query history opens a pane beside the tabs with the connection's runs, newest first, searched as typed. A file opened without saving gets a new connection id each time, so its pane lists every connection's runs. An entry opens in a new query tab; Copy and Delete are on its menu, and Clear history asks first.

## Rationale

- The core builds every WHERE and binds its values, writes every file and keeps every history row, so Windows writes no SQL and keeps no store the Linux app does not.
- Stock WinUI controls: SelectorBar, ComboBox, TextBox, InfoBar, ListView, ContentDialog and the Windows App SDK's FileSavePicker.

## Consequences

- No completion in the SQL editor yet: the caret analysis lives in the Linux app and moves to the core first, then the editor needs its popup.
- MongoDB's typed filter document is not offered; its rules are.
- No CSV options and no history retention setting yet: the core's CSV defaults and the store's cap apply.
- The history keeps no database, so a run reopened from it runs where the connection is.
- A table tab's page no longer shares a connection with anything, so a session setting from a query tab does not reach it.
- A page is read whole before it shows, under the core's page deadline of 60 seconds, as the Linux app reads one; the editor path streamed it with no deadline. Show all rows on a large table shows nothing until the last row is in.
- A restored filter runs on the first read, Raw SQL included, as the rules do: one expression, read on a pooled connection. Text an engine that is not SQL would read as its own query language is refused by the core.
- An export the app is killed in leaves its `.part` file beside the target.
