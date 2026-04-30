# DataGrid Audit

Tracks issues found during the DataGrid refactor (54 total) and their resolution status across phases.

## Phase 3 Status (2026-04-30)

Refactor complete. Phase 3 audit re-evaluated, most issues found to be already correct in current code (Phase 1/2 era fixes). Real changes in Phase 3:

- Removed Ctrl+HJKL Vim navigation (#12)
- Removed custom Shift+Arrow / Home / End / PageUp / PageDown, replaced with NSTableView native via `interpretKeyEvents` (#34, #49)
- NSUndoManager dual-invocation cleanup (#24)

Issues marked "Already correct" had explorer findings that disagreed with audit. See per-issue annotations.

## Issue Index

### #6 Single-click to edit
Not applicable. Single-click edit conflicts with cell selection in data grid context. Double-click is correct native pattern (matches Numbers, TablePlus, DBeaver, DataGrip).

### #10 Escape key behavior
Already correct. Escape only cancels active edit, does not deselect rows.

### #11 Right-click responder chain
Already correct. `CellTextField.rightMouseDown` walks responder chain to `TableRowViewWithMenu`.

### #12 Ctrl+HJKL Vim navigation
Fixed in Phase 3. Ctrl+HJKL block removed from `KeyHandlingTableView.keyDown`. NSTableView native handles arrow keys via `interpretKeyEvents` and the standard `moveLeft:`/`moveRight:`/`moveUp:`/`moveDown:` selectors.

### #13 Context menu key equivalents
Already correct. Context menu items use `keyEquivalent: ""` so they do not shadow system shortcuts.

### #14 Overlay editor dismiss
Already correct. `CellOverlayEditor` uses NSPanel + `resignKey`, not a global event monitor.

### #16 Action dispatch
Already correct. No dual-path action dispatch found.

### #23 Paste flow
Already correct. Paste flows through responder chain via `paste(_:)` selector.

### #24 NSUndoManager dual invocation
Cleaned in Phase 3. `DataChangeManager.undoLastChange()` and `redoLastChange()` removed. `RowOperationsManager.undoLastChange(tableRows:)` and `redoLastChange(tableRows:)` were dead wrappers, also removed. Production undo flows through Cmd+Z, the responder chain, NSUndoManager, registered undo blocks, and the `onUndoApplied` callback.

### #32 Pasteboard format
Already correct. Pasteboard writes `.string`, custom TSV, `.html` types.

### #33 Multi-cell paste
Already correct. Multi-cell paste implemented. Line 20 heuristic in `KeyHandlingTableView.paste` routes full-row pastes to `dataGridPasteRows` intentionally when no cell focus is active.

### #34 Custom Home/End/PageUp/PageDown
Fixed in Phase 3. Custom helpers removed. NSTableView native via `interpretKeyEvents` routes to `scrollToBeginningOfDocument:`, `scrollToEndOfDocument:`, `scrollPageUp:`, `scrollPageDown:` with native `andModifySelection:` Shift variants.

### #35 Shift+Tab in edit mode
Already correct. Shift+Tab works in browse and edit modes via `handleShiftTabKey`.

### #49 Custom Shift+Arrow range selection
Fixed in Phase 3. Custom Shift+Up/Down handlers removed. NSTableView native via `interpretKeyEvents` handles `moveUpAndModifySelection:` and `moveDownAndModifySelection:` and maintains its own selection anchor internally.
