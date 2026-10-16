---
paths:
  - "TablePro/Views/Results/**/*"
  - "TablePro/Core/DataGrid/**/*"
  - "TableProTests/Views/Results/**/*"
---

# Data grid

- **Selection indices are display positions**, not `TableRows.rows` indices. Resolve them through `DisplayRowMapping` (or `TableViewCoordinator.displayRow(at:)` and `tableRowsIndex(forDisplayRow:)`) before reading or changing a row; they match only while no sort or value filter applies.
- **Cells are drawn, not mounted.** `tableView(_:viewFor:row:)` returns nil for data columns and `DataGridRowView` draws the visible cells, and every column stays attached. Never hide off-screen columns with `NSTableColumn.isHidden`: each write costs O(attached columns).
- **Find data columns through `DataGridColumnPool.presentsColumn` and `firstPresentedColumnIndex`**, never a fixed index into `tableColumns` (the row-number column and pool slots sit there too).
- **The header draws all of its own chrome** through `SortableHeaderChrome`: the cell never calls `super.draw`, and `highlightedTableColumn` stays unset, because AppKit paints a fixed-height band that does not fit the taller header. Sort state goes through `SortableHeaderView.applySortState(_:schema:)`, which also sets each header cell's accessibility sort direction.
- **A themed header draws its own cells.** `NSTableHeaderView.draw` paints AppKit's band over the header fill before the cells, so while `dataGrid.headerBackground` is themed `SortableHeaderView` draws each column's header cell itself, the dragged one included; an unthemed header keeps `super.draw`.
- **Row selection is `NSTableRowView`'s own** unless the theme overrides `gridSelection` or `gridInactiveSelection`, so the default theme follows Accent and focus. The gutter and a selected column heading read `DataGridBodyChrome.selectionColor(emphasized:scope:)` so they match the row. A theme change repaints visible rows; it never reloads data.
- **A translucent theme selection is flattened once.** The row, the gutter and a heading sit on three different bases, so `DataGridBodyChrome.themedSelectionColor(emphasized:scope:)` lays the selection over the grid background and all three paint that opaque color with any alpha.
- **A range outline stays apart from its fill.** Natively a multi-cell range is outlined in the selection color at 70%. Under a themed `dataGrid.selection` that outline would vanish into the opaque fill, so `GridSelectionOverlay.rangeBorderColor(_:)` takes the active cell's border color instead (`dataGrid.focusBorder`, else Accent) at 70%.
- **The grid reads its colors through its `ThemeScope`.** `DataGridView(themeScope:)` hands it to `TableViewCoordinator`, and every grid color read goes through `coordinator.themeScope`, `KeyHandlingTableView.themeScope` and `SortableHeaderView.themeScope` included. `ThemeEngine.shared` supplies only the fonts and the cache counters that follow a system color change. A new scope repaints in place with no reload. Read `scope.resolved` once per draw, not once per cell. Scopes: `.claude/rules/theme.md`.
- **`gridStyleMask` stays empty; `DataGridBodyChrome` draws column separators and the stripes.** AppKit's vertical grid lines add one subview per column and make every layout pass quadratic. Take separator positions from `presentsColumn` and `rect(ofColumn:)`.
- **Scroll the grid with `NSView.scroll(_:)`**, never `clipView.scroll(to:)` plus `reflectScrolledClipView`, which leaves the header behind.
- **Accessibility goes through `DataGridCellAccessibilityView`**, mounted for on-screen rows once `DataGridAccessibility.isActive`; `NSTableView` builds its cell tree from views only. Keep that path working whenever row drawing changes.
