# 0027: One data grid on GtkColumnView, with rows and a focused cell

- **Status**: Accepted
- **Date**: 2026-10-25

## Context

The table tab, the SQL editor's results and the key tab showed rows through one builder, but what a grid did lived in four places: the grid's own actions, the table tab's actions and handlers, and each host's handling of the grid's messages. Copy, insert, delete and the edit lifecycle meant different things on each surface, each column was described twice, and a reload replaced every row object, which made GTK build every row and cell widget again.

GTK 4.22 gives one data table, `GtkColumnView` with the `.data-table` style. It selects rows, not cells or ranges; it builds a widget for every visible column of about 205 rows, so wide results cost in proportion to their columns; it keeps its row widgets only for row objects that stay in the model; it has no pinned column; and its header takes no keyboard focus.

## Decision

Every surface shows rows in one `DataGrid` widget on `GtkColumnView`, with row selection plus a focused cell, rows held in stable slots whose data is replaced in place, a row number column, values as text, and a row detail pane for long values.

## Rationale

- One widget owns selection, keys, menus, editing, copy, find and the column layout, so an action means the same on every surface and has one enabled state that its key, its menu item and the host's button all read.
- Rows and a focused cell are what the toolkit selects. A cell range would mean turning row selection off and drawing and keeping a selection of the grid's own.
- Slots keep GTK's widgets across a reload: measured at 300 columns, a reload took 2,321 ms with new row objects and 328 ms with the same ones. Anything that acts later (a menu, an editor, a copy) holds the row pinned to the slot's generation, so it acts on the row the user chose or on nothing.
- The detail pane is the HIG's utility pane: every field of the focused row, and an editor for long text, JSON and dates, toggled by Alt+Return, the HIG's Properties key, since F9 shows the sidebar.
- Values as text, booleans as `true` and `false`, keep every row one line tall in every grid; a check button made rows taller, and GtkInscription draws ellipsized text from its top edge.
- The row number column is the toolkit's only way to show row numbers; it scrolls and can be dragged like any column.

## Consequences

- No cell range selection, unlike the macOS app; Copy copies the focused cell's value when one row is selected and the rows otherwise.
- Every column is shown; a result with hundreds of columns scrolls slower, since GTK builds them all.
- The header's actions are also in the cell menu, since the header takes no keyboard focus; sort changes are announced, since AT-SPI reads no sort state.
- Pending changes show as the row number column's icon and as text marks (bold in the warning colour for a changed value, struck through for a deleted row), not as row tints.
- Column order, visibility and widths are kept per table in the column layout file.

## Alternatives considered

- **A grid drawn on a `GtkDrawingArea`.** It scales in both directions, but rebuilds focus, selection, editing and accessibility by hand.
- **`GtkEditableLabel` in every cell.** GTK's own in-place editor starts editing on the first click, cannot ellipsize, takes the context menu, and at 50 columns used over 1 GB and took 8 s to reload.
- **A separate list beside the grid for row numbers.** It would pin them, but only by reading the column view's private layout to keep the two in step.
