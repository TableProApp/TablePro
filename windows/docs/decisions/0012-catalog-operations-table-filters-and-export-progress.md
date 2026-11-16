# 0012: Catalog operations, filters kept per table, filter by a cell and export progress

- **Status**: Accepted
- **Date**: 2026-11-16

## Context

A table's filter lived only with its tab ([0007](0007-browsing-a-connection.md)), so a table opened again started unfiltered, and no cell offered to filter by its value. Export results wrote SQL INSERT only from a table and said nothing while it ran. The object tree could not empty or drop a table, and nothing made or dropped a schema or database. The macOS app does all of it, and the core plans the catalog operations ([core 0013](../../../core/docs/decisions/0013-catalog-operations.md)), which the FFI now carries.

## Decision

### Filters

- The filter a table's rows were last read with is kept per saved connection (or opened file), database, schema and table in `table-filters.json` beside the session file (`TableFilterMemory`), as macOS keys it. A table opened again reads with it and shows it in the bar. Clear forgets it; a filter the core or the server refused is not kept. A restored tab and a followed foreign key keep their own filter.
- A dropped table forgets its filter, and a dropped schema or database every filter under it.
- A table tab's cell menu has Filter, with `col = “value”` and `col != “value”`, `>` and `<` where the column orders, and `is NULL` and `is not NULL` for a NULL cell, each only where the engine offers the operator (`CellFilters`). The value is the core's filter text for the cell (`ResultSet.GetFilterText`), the text that binds back to the value stored, as a followed foreign key's filter is built; a value no text binds back to, such as 'true' in a SQLite BOOLEAN column, offers none. None either for a binary value, a value over 10,000 characters, one with a blank at either end or one that reads as NULL, a new row or an edited cell. The rule joins the rules under Match all and applies at once; under Match any of two clauses it runs alone; a rule already running does nothing. A query result has no Filter, as on macOS.

### Export

- SQL INSERT is offered for a query result too, into `query_results` under the result's own column names, as macOS writes it. A result whose names the engine reads as one column twice is refused before any file.
- The export bar counts the rows written, read from the core's counter (`ExportProgress`) four times a second, out of the rows held or the counted total where known. Stop ends it with no file left, so it asks nothing first.

### Catalog operations

- The tree's table menu adds Open in new tab, Show DDL, Truncate... and Drop..., the last two where the engine has them and the connection is not read-only. A schema row has New schema... and Drop schema, or New database... and Drop database where the server's databases are its schemas; with one schema, whose folders show with no row of their own, the folders carry them. The database switcher ends with New database... and a Drop database list, and Database > New database... and New schema... reach the same dialogs. The engine's own databases and schemas, and the one the window is in, are never offered for a drop.
- Each dialog shows the statements the core planned for its options (`PlanCatalogChange`), planned again as an option changes: Cascade and Restart identity for a truncate, Cascade for a drop, Close other connections first for a database, Run on for a cluster, and for a new database the options the engine names (`CatalogAbilities.DatabaseFields`) with the server's choices.
- A truncate where the server refuses a table other tables' keys point at is refused first, naming them; so is a drop where the engine has no Cascade.
- Safe Mode gates them as the core says (`CatalogChange.Gate`): emptying or dropping is asked at every level, in the dialog that shows the statements; creating is asked again where Confirm writes asks; Read only refuses. Each runs at once, as the Linux app's do, in the bar exports use, whose Cancel stops one waiting on a lock; leaving the window stops it too. A stopped change reads the tree again and closes nothing. The commands are hidden while the bar is busy.
- After a drop, the table's tabs close without asking, since their changes have nowhere to go, and are not kept to reopen; so do the tabs of every object the catalog no longer lists, as a partitioned table's partitions and the views Cascade drops. A truncate reads every table tab again, since Cascade and a partitioned table empty others; a tab holding edits asks first. A change whose outcome is unknown reads the tree again and closes nothing. The tree reads the schemas again on every refresh.

## Rationale

- The core plans, gates and runs each statement, so Windows writes no DDL.
- Stock WinUI controls: MenuFlyout, ContentDialog, CheckBox, ComboBox, NumberBox and InfoBar.

## Consequences

- macOS stages a truncate or drop until Save; here it runs once answered, as on Linux. Staging waits on the pending structure model (roadmap C-05).
- Views, materialized views, foreign tables and sequences have no Drop: the core plans DROP TABLE only (roadmap C-05).
- No filter settings yet: a table always restores and applies its filter, macOS's default.
