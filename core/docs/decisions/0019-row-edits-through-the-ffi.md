# 0019: A table tab's row edits cross the FFI as typed text, and the core plans and runs the save

- **Status**: Accepted
- **Date**: 2026-11-11

## Context

The Windows app shows a table page from a `ResultSet` the core holds, read as windows of text ([0003](0003-result-windows-for-native-grids.md)). Editing it writes rows back. The Linux app keeps its pending edits as `Value`s in its own tracker and saves through `save::plan_save` with the primary key as the row identity. An app on the FFI holds no `Value`: only display text and cell kinds cross.

The result store keeps each value formatted once, on arrival. Integers, booleans, wide integers, decimals, text, bytes, UUIDs and dates keep what names the value exactly. A float keeps its double's bits, which for a `real` column binds digits the column never held. A time, timestamp or interval keeps the text `value_text` wrote for it, which `parse_literal_text` reads back as the same value for the column it was read as. PostgreSQL's editor reads every column as server text, which `edit::value_for_column` turns into the catalog's type where that text is exact (0015).

## Decision

The app sends what the user typed; the core reads every key and stored value from the result set and plans, previews and runs the save.

- `DatabaseSession::table_editor` gives a `TableEditor` over the catalog's columns, read again when the host asks (a tab's Refresh), locked for a read-only connection or a table with no primary key, as the Linux tracker keys rows by `pk_identity`. `lock_for` adds a page's own locks: columns that are not the catalog's, in order, and a key the page holds that cannot be named exactly.
- A column follows the Linux grid's rules (`cell_editability`, `cell_presets`): a saved row's key, a generated or auto-increment column and a kind with no text are locked to typing; a new row may set its key, the server fills a generated or auto-increment column whatever the row holds, and a kind with no text takes NULL or the server's value in a new row. DEFAULT goes into a saved row only for a declared default on an engine whose UPDATE takes one.
- An edit is `CellEdit::Text`, `Null` or `Default`, per row of the page by its place in the set (`RowEdit::Update`, `Delete`) or as a new row (`Insert`, one cell per column). Text is read with `parse_edit_text`, so an empty cell means what it means on Linux; `check` reads one cell the same way, with the `EditParseError` code.
- `TableEditor::plan` reads each key column back (`stored_value`, then `value_for_column`) and refuses a key it cannot name exactly (`edit.key_unreadable`). The edits keep the host's order, which places each row at its latest change, as the Linux tracker orders its rows, so a parent row added before a child is pointed at it saves first, unless the parent changed again after. A row is written once: a deleted row's updates go, one row's updates merge with later cells winning, and a cell edited back to its value is dropped (`is_unchanged`).
- A `RowSave` holds the plan. `statements` gives each statement with its bound values as the user would write them, as the Linux confirmation lists them. `gate` is `SafeModeLevel::gate(Write)`: Off saves, Confirm writes shows the statements first, Read only refuses.
- `RowSave::run(confirmed)` refuses a Confirm writes save the user did not answer (`edit.not_confirmed`), a level other than the one planned at, checked again on the writing lease (`edit.safe_mode_changed`), and a plan the lease makes differently from the one shown (`edit.not_as_planned`). It runs once, as one `WriteBatch`, asks the server about a lost commit acknowledgement, and reports `Saved`, `RolledBack` or `Unknown` with the edit it stopped at, as the Linux app's `SaveOutcome::classify` reads a write.
- `EditParseError` and `BuildSqlError` gain stable `code()`s, `edit.*` and `build.*`.

## Rationale

- Values never cross the boundary, so nothing is lost to a round trip through display text, and the SQL is the core's, as on Linux.
- The pending edits are what the user typed against rows of one page, which the app already holds, so the app needs no copy of the core's value types.
- Planning again on the writing lease is the guard the Linux structure save keeps: the statements shown are the statements sent.

## Consequences

- An edit names a row by its place in the set the page was read into, so an app asks before anything replaces that set (a sort, a page, a refresh) while edits are pending, as macOS does, and opens the editor again on a refresh with `refresh`, which reads the catalog again before the page.
- A table whose primary key is a float, or a type the store keeps only as other text, is read-only.
- A table with no primary key is read-only, where macOS matches every column.
- A query result edits through 0015 later; this API covers a table tab.

## Alternatives considered

- **The tracker in the core.** The Linux tracker is the Linux app's, with its undo and its relayout; an app on the FFI needs only typed text per row, which it already holds.
- **Keys as display text.** A cut or locale-free text that is not the stored value could name another row.
- **Keeping the page's `Value`s in the store.** Twice the memory for every page, for the few columns a key needs.
