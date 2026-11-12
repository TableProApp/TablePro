# 0006: Editing a table's rows

- **Status**: Accepted
- **Date**: 2026-11-11

## Context

A table tab only read its rows (audit item WN-08). The macOS app edits cells, adds, duplicates and deletes rows, keeps every change pending until Save, previews the SQL and asks Safe Mode first. The core already plans row saves for the Linux app (`save::plan_save`), and the FFI now carries the edits ([core 0019](../../../core/docs/decisions/0019-row-edits-through-the-ffi.md)). The grid had no editor ([0003](0003-data-grid-control.md)).

## Decision

A table tab edits its page as the macOS app does, with the commands and words of the macOS app in Windows sentence case, through the core's `TableEditor`. The pending changes are typed text per row of the page, in `TableEdits` (`src/TablePro.App.Model`), which the grid shows through `EditedGridData`. `TableTab` holds the edit commands, the questions and the save over `ITableEditor` and `IRowSave`, so `tests/TablePro.App.Model.Tests` runs every path with fakes; `TableTabView` draws and asks.

## Design

### Editing

- F2, Enter or a double-click edits the focused cell in a `TextBox` over it; typing does not start an edit, as on macOS. Enter keeps the edit, Tab and Shift+Tab keep it and move, Escape cancels. A value with a line break edits on several lines, and Ctrl+Enter keeps it.
- The editor starts from the pending edit or the whole stored value (`TableEditor.GetEditStart`), never the grid's cut text. A cell the column cannot take back (bytes, a value the driver could not read, a key or a column the server fills) does not open, and the status says so.
- A kept edit is read as the save will read it (`TableEditor.Check`). A refusal keeps the editor open with the reason in its tooltip and its accessible description, and the status says it too, since a focus loss closes the editor. An edit back to the stored value is no change.
- A right-click outside the selection selects the cell under it; inside it, the selection stays. The grid's menu acts on the focused cell and the selected rows, and a right-click while a cell is edited keeps the edit first. It has Set value (Empty where the column takes it, NULL where it is nullable, Default in a new row where the server fills the column and in a saved row where the engine sets a declared default), Add row, Duplicate, Delete, and Copy. On a row marked for delete it offers Undo delete and Copy, as macOS does.
- Add row (Ctrl+Shift+N) adds a row after the page's rows, holding the server's value where it has one and NULL elsewhere, and opens the editor on the first column the server does not fill. Duplicate row (Ctrl+Shift+D) copies the selected rows, with the key and the columns the server fills as a new row starts them. Delete marks the selected rows; a new row goes at once.
- A lock keeps every edit back and the status names it when the grid is asked to edit: a read-only connection, a table with no primary key, a page whose keys cannot be read back exactly, or columns that changed since the page was read. Refresh reads the table's columns from the server again.

### Pending changes

- An edited cell is underlined on the caution fill, a new row on the success fill, and a row marked for delete is struck through on the critical fill, from WinUI's theme resources; high contrast keeps the underline and the strike-through. A cell's UIA ItemStatus says "edited", "new row" or "marked for deletion".
- A value still in the open editor counts as a pending change: Save takes it, and every close asks about it.
- A sort, a page, a page size or Refresh asks "Discard unsaved changes?" while changes are pending, as macOS asks, since the edits name rows of the page shown. An open edit is kept first; one the grid cannot keep holds the reload back.
- Closing the tab, Disconnect, Reconnect, connecting an edited connection, closing the window and Exit show the tab and ask "Do you want to save changes to name?" with Save, Don't save and Cancel, beside the questions about held transactions. The workspace asks, since a tab that is not shown is out of the tree. A save that fails keeps the tab open and the window with it. A close while a save runs waits for it and asks only about what it left pending. Making the connection read only asks with Don't save and Cancel alone, since the changes would not be written there.

### Saving

- Save (Ctrl+S) keeps an open edit, plans the save, and asks before deleting rows at every Safe Mode level ("Delete 3 rows from Track?"). At Confirm writes it then shows every statement with the values it binds and Execute or Cancel, Cancel the default, and only an Execute lets the save run. Read only locks editing, and the commands are off.
- The save runs as one batch through the core, with each row at its latest change, as the Linux app orders a save, so a parent row added before a child is pointed at it saves first; a parent edited again after that saves after the child, and its foreign key refuses the save. A close waits for a save in flight and never stops it halfway.
- A save that writes reloads the page and counts the table again. One the server rolled back says "Save failed", keeps every change pending and selects the row it stopped at. One whose outcome is unknown says "Save incomplete", keeps the changes, selects the row and refuses another save until the page is read again or the changes are discarded. One the core refuses before it sends anything, as when Safe Mode changed, says why and keeps the changes; any other failure counts as an unknown outcome. Discarding the changes, or a reload that discards them, lifts the block.
- Preview SQL (Ctrl+Shift+P) shows the same statements, with Copy all and Done, or why the edits cannot be planned. Discard changes asks first.
- Save, Discard changes and Preview SQL are in the tab's command bar and the File and Query menus; Add row, Duplicate row and Delete in the command bar and the Edit menu. The keys belong to the menu items alone, so a press never runs twice. The command bar holds them after Refresh and Stop, so a narrow bar moves them to its overflow first and keeps the pager. A query tab has none of them.

## Rationale

- The core plans and runs the save, so Windows writes nothing Linux would not, and the SQL generation has one home.
- Typed text against the page's rows is all the app holds, so a page reload has to be asked about; macOS asks the same question for the same actions.
- A table with no primary key stays read-only, as on Linux. macOS matches every column; that choice is the maintainer's, and read-only is the state the app was in.

## Consequences

- No undo of a pending edit yet; Discard changes drops them all.
- A query result does not edit yet (core 0015).
- The core's three Safe Mode levels stand for macOS's six: Off saves, Confirm writes shows the statements, Read only locks.
