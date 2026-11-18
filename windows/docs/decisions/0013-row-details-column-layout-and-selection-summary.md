# 0013: Row details, table info, column layout, selection summary and connection URLs

- **Status**: Accepted
- **Date**: 2026-11-18

## Context

A table tab showed its rows and nothing about the row or the table beside them, its columns stayed in the table's order, and no selection said what it held. The Connections page could not start a connection from a URL, the SSH section could not show the jump hosts the core already stores, and a group could not take the colour the library keeps for it. The macOS app does all of it.

## Decision

### Table tab

- Details on the table bar opens a pane beside the rows, as macOS's inspector. Row lists each column of the focused row in the table's own order with its type, in a text box that edits the cell as the grid's editor does (`TableTab.StartEdit`, `CommitEdit`): kept when the box loses the focus or on Ctrl+Enter, put back with Escape, and with the line break style the value had. Its menu sets Empty, NULL or DEFAULT where the column takes it, and copies the value. Read only, or too long to show whole, a field cannot be edited there.
- Table shows the row estimate, the data, index and total size, and the comment, from the core's `table_info` (core `Connection::table_info`): each figure the engine keeps, and Not reported for the rest. It is read once and again after Refresh.
- Each table keeps its column layout per saved connection (or opened file), database, schema and table in `table-columns.json` (`ColumnLayoutMemory`), as filters are kept ([0012](0012-catalog-operations-table-filters-and-export-progress.md)): the order, the hidden columns and how many are frozen, by column name, so a column added since goes last and a dropped one is passed over. A dropped table, schema or database forgets it.
- A header's menu has Hide column, Show all columns, Move column left and right (Alt+Left, Alt+Right), Freeze up to this column (refused when the frozen columns would leave less than a third of the grid, as macOS refuses it; a smaller window or wider columns freeze only those that fit, as macOS shows them), Unfreeze columns and Columns; a header drag moves a column. Columns on the bar lists every column with a check, Show all columns and Reset columns. The last shown column cannot be hidden.
- The table tab's grid data (`EditedGridData`) carries the order, so the grid works in display positions and the tab maps them to the set's columns where it calls the model: edits, the cell menu, the value viewer, Filter, a followed foreign key and the sort.

### Selection summary

- Two or more selected cells show Sum, Average and Count under the grid, as a spreadsheet's status bar, with every figure and a Copy for each in its flyout: the count, how many hold numbers, the empty ones (NULL or DEFAULT), the ones a numeric column cannot read, sum, average, minimum and maximum. Integer, decimal and float columns are summed; a column the engine could not type is summed where its text reads as a number; the rest are counted. The sum is exact (`ExactDecimal`), the average to 10 more decimals. Deleted rows are left out and pending edits counted. It is worked out off the UI thread after the selection rests, and a new selection stops the last.

### Connections

- New from URL on the Connections page opens a box filled from a connection URL on the clipboard, as macOS's Import from URL; Continue opens the connection form on what the URL names. Ctrl+V on the page, outside a text box, does the same with the clipboard's URL. Both read it as the engine chooser's From connection URL does (`ConnectionDraft.FromUrl`).
- The SSH section has Jump hosts, one list as OpenSSH's `-J` takes it and the Linux app shows it: `user@host:port` separated by commas, saved as one entry. The core checks it as a connect would (`check_jump_hosts`) before a save or a test.
- A group's menu has Color, None and the nine connection colours; the group's folder takes its colour (`set_group_color`).

## Rationale

- The core reads the figures, checks the jump hosts and stores the colour, so the app only words and lays out.
- Stock WinUI controls: SelectorBar, TextBox, DropDownButton, Flyout, MenuFlyout with toggle and radio items, and KeyboardAccelerator.
- One order in the grid data keeps the grid control's API in display space, where its selection rectangle lives.

## Consequences

- A query result keeps its own order: a layout belongs to a table.
- The connect timeout field (roadmap W-05) waits: it needs a field on `SavedConnection` and on the connect request, both of which `linux/crates/app` builds with full struct literals, after Linux 0.1.0.
- Engines that keep no size or comment for a table (Redis, and sizes on Cassandra and DuckDB) show Not reported.
