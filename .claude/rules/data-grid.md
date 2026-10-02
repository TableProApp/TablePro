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
- **`gridStyleMask` stays empty; `DataGridBodyChrome` draws column separators and the stripes.** AppKit's vertical grid lines add one subview per column and make every layout pass quadratic. Take separator positions from `presentsColumn` and `rect(ofColumn:)`.
- **Scroll the grid with `NSView.scroll(_:)`**, never `clipView.scroll(to:)` plus `reflectScrolledClipView`, which leaves the header behind.
- **Accessibility goes through `DataGridCellAccessibilityView`**, mounted for on-screen rows once `DataGridAccessibility.isActive`; `NSTableView` builds its cell tree from views only. Keep that path working whenever row drawing changes.
- **UI tests click at an offset from the `data-grid` element**, never on a row or cell element, which XCUITest reports as obscured.
