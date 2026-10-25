---
paths:
  - "apple/TablePro/Views/DataGrid/**/*"
  - "apple/TablePro/Core/DataGrid/**/*"
  - "apple/TablePro/Views/Results/**/*"
  - "apple/TableProTests/Views/DataGrid/**/*"
  - "apple/TableProTests/Core/DataGrid/**/*"
  - "apple/TableProTests/Views/Results/**/*"
---

# Data grid

Three layers, knowledge pointing one way: an owner's adapter, then `DataGridModel` (`Core/DataGrid`), then the AppKit view (`Views/DataGrid`). The value editors and viewers stay in `Views/Results`.

## Model

- **`DataGridModel` holds the grid's state** and outlives every mount: column set, row order, selection, sort, value filter, column layout, display formats, find and the edit session. Its owner holds it strongly; the data tab keeps one per tab on `MainContentCoordinator`.
- **An owner talks to the model, never to the view.** It implements `DataGridDataSource` and `DataGridActions` in an adapter class and calls `reloadRows()` when its rows were replaced or `apply(_ delta:)` when they changed. The model keeps the selection by identity and sends the mounted view one `DataGridChange`.
- **Rows are `RowID`, columns are `DataGridColumnID`.** `DataGridRowOrder` maps display rows, and `DataGridColumnSet` is the only converter between data index, display position and pane. A bare `Int` is a display position, valid only inside one call: capture the IDs before a popover, a sheet or an `await`.
- **Every edit is one `model.commit(_:actionName:)`** of `DataGridCellEdit`s, taken by IDs when the gesture began. A command over many cells is one call, so one undo step.
- **The selection is `model.selection`, changed through `GridSelectionReducer`**, a pure engine in `Core/DataGrid/Engine` with its own tests. The tables' `selectedRowIndexes` mirror the rows it spans; a change AppKit makes itself (Up, Down, type-select) goes through `rowsSelectedNatively` first.
- **A selection says what it is in `GridSelection.Mode`**: a click selects the row with the cell cursor on the clicked cell (`.cursor`), a drag, Shift or Command gesture makes a cell range (`.cells`), and row numbers or Select All pick rows (`.rows`). Copy, Delete and the row commands read the mode, never the rectangle's shape.
- **What a grid offers is `configuration.commands`.** Menus and validation read it, because a defaulted protocol method cannot be detected at runtime.
- **State persists through `model.store`.** Only the data tab of a real, non-temporary table has `layoutScope` `.table`; every other grid is `.ephemeral` and never writes a table's saved layout or display formats.

## Panes

- **Two tables, one grid.** The main pane's `DataGridTableView` holds every column, the row numbers first. The frozen pane is a second table laid over the main pane's leading edge, showing the row numbers and the frozen columns. Keys, find, copy and VoiceOver work on the main table.
- **The main table is the only first responder.** The frozen table refuses it and hands its presses to the controller. `DataGridContainerView.gridHasFocus` is the one focus flag: both panes' row views take `isEmphasized` from it, and so does the active-cell border.
- **Row height, row count, reloads, inserts and removes reach both panes in one call**, so their document heights never differ.
- **Vertical scroll stays in step through bounds-change notifications**: each pane's clip moves the other with `clipView.scroll(to:)` and `reflectScrolledClipView`, only when its y differs. Anywhere else scroll with `NSView.scroll(_:)`: moving a clip's x that way leaves the header behind.
- **The frozen pane forwards every wheel event to the main scroll view**, so one momentum engine moves both.
- **Frozen columns take at most two thirds of the grid** (`DataGridMetrics.maximumFrozenShare`). Columns past that scroll, and Freeze Up to This Column is refused in the menu.
- **`DataGridTableView.scrollToVisible(_:)` widens the rect leftward by the frozen width**, so a revealed column never parks under the frozen pane.
- **A column moves only within its side of the freeze line.** A freeze or unfreeze rebuilds both panes' column lists from the set, writing width and position explicitly: remove-then-add alone strands a column at the end and resets its width.

## Cells

- **Cells are drawn, not mounted.** `DataGridRowView` draws its pane's cells through `DataGridCellRenderer`. `tableView(_:viewFor:row:)` returns nil except for the cell being edited and the accessibility stand-ins: a view per cell costs 45 ms a frame at 1,000 rows by 200 columns against 1.5 ms drawn.
- **A change repaints, it never reloads.** It reaches pixels as `needsDisplay` on the row views it names. `reloadData(forRowIndexes:columnIndexes:)` only mounts or unmounts a cell view, since reloading an edited row ends the edit. A full `reloadData()` drops the table selection without telling anyone, so the controller writes it back.
- **Every column stays attached.** Never hide an off-screen column with `NSTableColumn.isHidden`: each write costs O(attached columns). Columns come from each pane's pool, keyed by `DataGridColumnID`, so a re-run of the same result does not flicker (#951).
- **Resolve a table column through `DataGridPane.slot(atTableIndex:columns:)` and `tableIndex(forDisplayPosition:columns:)`**, never a fixed index into `tableColumns`: the row-number column sits first and the frozen pane holds a subset.
- **`gridStyleMask` stays empty.** AppKit's vertical grid lines keep a subview per column (518 ms a layout at 500 columns). `DataGridBodyChrome` draws the separators in each row, and the stripes and separators past the last row.
- **Selection takes the theme.** `drawSelection(in:)` fills the whole row in a row selection and the selected columns' span in a cell range: `dataGrid.selection` when emphasized, else `dataGrid.inactiveSelection`. The active cell is an inner stroke in `dataGrid.focusBorder`, 2 pt with focus and 1 pt without, in the selected text color over an emphasized fill. No outline goes round a range.
- **Never draw the active cell with the focus ring API.** From a row view the ring loses its top and bottom; on an `NSTableView` it draws nothing.
- **Colors come from `model.themeScope`**, read once per draw. A theme, Accent or Increase Contrast change repaints the visible rows and never reloads data. `ThemeEngine.shared` supplies only the fonts.
- **The row view draws the column a header drag is moving**, at the header's `draggedDistance`: drawn cells have no views for AppKit to float.

## Header

- **AppKit's header behavior in the theme's colors.** `DataGridHeaderView` is a `ThemeTableHeaderView` and every column a `ThemeTableHeaderCell` (`.claude/rules/theme.md`); it adds `menu(for:)` and a `viewWillDraw` that repaints the body on each step of a column drag. AppKit draws the title and the primary sort arrow; the controller sets each header cell's `accessibilitySortDirection`, which AppKit leaves unknown.
- **The model's sort is the source.** `tableView.sortDescriptors` is written from `store.sortState` under `isApplyingSortDescriptors`, because an assignment inside the callback fires it again. A plain click keeps only the clicked key and flips it on a repeat; an Option-click keeps the key AppKit appended (`HeaderSortCycle`). Shift-click reaches no sort callback, and Command-click selects the column.
- **Header text is the column name.** The type, the comment and, while several keys sort, the sort order go in `headerToolTip`; an active value filter adds a funnel symbol attachment to the title, in the header text color.

## Keyboard, mouse and menus

- **Behavior comes from responder actions, never key codes.** `keyDown` sends Return, Enter, Tab, Backtab, Delete, Forward Delete, Left, Right, and Shift-Up or Shift-Down over a cell range through `interpretKeyEvents`. Everything else goes to `super`, which keeps AppKit's row movement and type-select.
- **A modifier test masks `.capsLock` and `.function`**: compare within `[.command, .shift, .option, .control]` only. Forward Delete carries `.function`.
- **Copy, Paste, Delete, Select All, Find, Copy Special, Set Value and zoom are actions the grid answers itself**, with `NSMenuItemValidation`, so they work in every window. The context menu's Paste takes the keyboard's path. A window's own handler runs only while the grid is not focused.
- **The context menu is built from `clickedRow` and `clickedColumn`** in `menuNeedsUpdate(_:)`. It acts on the selection when the clicked cell is inside it, else on the clicked cell or row; the selection never moves.
- **A press in either pane resolves to one `GridCoord`** through the container and the column set. A drag autoscrolls the main pane and crosses panes.

## Accessibility

- **AppKit builds the AXCell tree from cell views only**, so while `DataGridAccessibility.isActive` the main table mounts a `DataGridAccessibilityCellView` (identifier `data-grid-cell`) for each on-screen cell. It draws nothing and takes no clicks. Keep that path working whenever row drawing changes.
- **A label reads "Row N, column M: value"**: N is the row number on screen, page offset included, and M the display position. UI tests find cells by it (`.claude/rules/ui-tests.md`, The grid).
- **The frozen pane is hidden from accessibility.** A frozen column's stand-in in the main table reports the frame the frozen pane shows it at.
- **Only the viewport mounts.** Mounting for every row starved the main thread behind a 1,000-row page (#2392); rows scrolled into view remount.
