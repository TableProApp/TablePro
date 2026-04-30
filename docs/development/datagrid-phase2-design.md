# DataGrid Phase 2: Persistent Column Pool + Typed Cell Hierarchy

## Problem

Switching tables blocked the main thread for ~135 ms on a 14-column, 1000-row dataset. The CPU spike came from the cell rendering hot path.

Two underlying causes:

1. `rebuildColumns` removed every `NSTableColumn` and recreated them on each table switch. Removing a column also evicts its associated cell views from the AppKit reuse pool. The next `reloadData` had no warm cells to dequeue and allocated a fresh `NSTableCellView` per visible cell. OSLog signposts showed Section A (`makeView`/reuse) consuming about 87% of `viewFor` time on a cold pool.

2. The data cell was a single `DataGridCellView` reused across every kind of column (text, foreign key, dropdown, boolean, date, JSON, blob). One `NSUserInterfaceItemIdentifier`, one constructor with 15 parameters, kind-specific state read back through `viewWithTag` integer constants. The reuse pool keyed on a single identifier could not reuse cells per-kind, and the constructor itself ran kind-checks on every call.

The combination produced a per-cell render cost around 0.26 ms. Multiplied across ~500 visible cells on first paint, that is the visible jank on table click.

## Approach

### Persistent column pool

`DataGridColumnPool` (`TablePro/Views/Results/DataGridColumnPool.swift`) holds the `NSTableColumn` instances. Identifiers are slot-based: `dataColumn-0`, `dataColumn-1`, etc. The pool grows when a wider table arrives and never removes columns. Surplus columns past the current schema are hidden, not evicted.

`reconcile(...)` is called whenever the column schema changes:

1. Grow the backing pool to cover the visible column count.
2. Rename headers and reset width / type / editable state on each visible slot.
3. Hide surplus slots.
4. Compute the target visual order from the saved layout, falling back to slot order.
5. Attach any not-yet-attached columns, then `moveColumn` each slot into its target position.

Because columns are not removed, the AppKit cell reuse pool remains warm across table switches.

### Typed cell hierarchy

`DataGridBaseCellView` (`TablePro/Views/Results/Cells/DataGridBaseCellView.swift`) is the shared `NSTableCellView` base. It owns:

- `cellTextField: CellTextField` plus its layout constraints
- `backgroundView` for delete / insert / modify highlight
- focus ring drawing via `drawFocusRingMask`
- value formatting branches (null, empty, default marker, regular)
- accessibility row / column index ranges

Seven leaf subclasses, one per `DataGridCellKind`:

- `DataGridTextCellView`
- `DataGridForeignKeyCellView` (FK arrow accessory)
- `DataGridDropdownCellView` (chevron accessory)
- `DataGridBooleanCellView`
- `DataGridDateCellView`
- `DataGridJsonCellView`
- `DataGridBlobCellView`

Each subclass overrides `class var reuseIdentifier` so AppKit's reuse pool keys per-kind. A reused dropdown cell is always a dropdown cell. Boolean, date, JSON, and blob currently render as text and are placeholders for native widgets in a later phase.

Accessory buttons (FK arrow, chevron) live in `AccessoryButtons.swift` as standalone `NSButton` subclasses. Subclasses that need an accessory install it once in `installAccessory()` and toggle visibility in `updateAccessoryVisibility(content:state:)`.

### Cell registry

`DataGridCellRegistry` (`TablePro/Views/Results/Cells/DataGridCellRegistry.swift`) replaces the 15-parameter `DataGridCellFactory.makeDataCell`. Two methods:

- `resolveKind(columnIndex:columnType:isFKColumn:isDropdownColumn:)` returns the matching `DataGridCellKind`.
- `dequeueCell(of:in:)` calls `tableView.makeView(withIdentifier:)` against the kind's identifier and falls back to a fresh allocation only on first use.

Construction wires the cell's `accessoryDelegate` and `cellTextField.delegate` once. Per-render mutations on those properties are gone.

### Schema change detection

The naive trigger for a column rebuild was "did the column identifiers change". Slot identifiers are identical across tables of the same width (`dataColumn-0` matches `dataColumn-0`), so that check missed real schema changes between tables with the same column count.

`TableViewCoordinator.lastReconciledColumnNames` records the names that were last reconciled into the pool. `DataGridView.updateNSView` compares the current `latestRows.columns` against that list. A mismatch means the schema changed and `reconcile(...)` runs. Identical names skip the rebuild.

### Animation suppression

`reconcile(...)` runs `moveColumn` calls in sequence to install the saved order. Without animation suppression, the user briefly saw the natural slot order before each move animated into place, producing a visible swap on every table click.

The reconcile body wraps the whole sequence in:

```
NSAnimationContext.beginGrouping()
NSAnimationContext.current.duration = 0
NSAnimationContext.current.allowsImplicitAnimation = false
CATransaction.begin()
CATransaction.setDisableActions(true)
```

with matching `defer` to commit and end grouping. `moveColumn` and the header rename commit in a single visual frame.

## Results

Measured on a 14-column, 1000-row table click, MacBook Air M2:

| Metric | Before | After |
| --- | --- | --- |
| Per-cell `viewFor` cost | 0.26 ms | 0.10 ms |
| Section A (`makeView` / reuse) share of `viewFor` | 87% | ~0% on warm reuse pool |
| `viewFor` total for first paint (~500 cells) | ~135 ms | ~41 ms |

The user-visible CPU spike on table click is gone. Subsequent switches between tables of similar shape stay under 5 ms total in `reconcile` because the pool already has enough slots and only headers and order need updating.

## Files

### New

`TablePro/Views/Results/Cells/`:

- `AccessoryButtons.swift`
- `DataGridBaseCellView.swift`
- `DataGridBlobCellView.swift`
- `DataGridBooleanCellView.swift`
- `DataGridCellAccessoryDelegate.swift`
- `DataGridCellContent.swift`
- `DataGridCellKind.swift`
- `DataGridCellRegistry.swift`
- `DataGridChevronCellView.swift`
- `DataGridDateCellView.swift`
- `DataGridDropdownCellView.swift`
- `DataGridForeignKeyCellView.swift`
- `DataGridJsonCellView.swift`
- `DataGridTextCellView.swift`

`TablePro/Views/Results/`:

- `DataGridColumnPool.swift`

`TableProTests/`:

- `Views/Results/Cells/DataGridCellRegistryTests.swift`
- `Views/Results/DataGridColumnPoolTests.swift`

### Modified

- `TablePro/Models/UI/ColumnIdentitySchema.swift`: added slot identifier helper and column name to slot lookup.
- `TablePro/Views/Results/DataGridView.swift`: switched from `rebuildColumns` to `reconcileColumnPool`, added schema change detection by name.
- `TablePro/Views/Results/DataGridCoordinator.swift`: owns `columnPool` and `cellRegistry`, tracks `lastReconciledColumnNames`.
- `TablePro/Views/Results/Extensions/DataGridView+Columns.swift`: `viewFor` now goes through the registry, no factory call.
- `TablePro/Views/Results/Extensions/DataGridView+Click.swift`: click resolution uses slot identifiers via the schema.
- `TablePro/Views/Main/Extensions/MainContentCoordinator+QueryHelpers.swift`: instrumentation added during measurement, removed at end of phase.
- `TableProTests/Models/UI/ColumnIdentitySchemaTests.swift`: covers the new lookups.

### Deleted

- `TablePro/Views/Results/DataGridCellView.swift`: the mega-cell.
- Most of `TablePro/Views/Results/DataGridCellFactory.swift`: kept only the column width calculator. Cell construction is gone.

### Out of scope

- Phase 2c: native widgets per kind. `NSButton` checkbox for boolean, `NSDatePicker` popover for date, JSON syntax view for JSON, hex viewer for blob. The kind hierarchy is in place to receive them without further architectural change.
- Phase 2d: window-level field editor that replaces the per-cell `NSTextView` overlay. Removes the per-cell editor allocation and lets editing share one editor across the grid.
- Phase 3+: interaction polish (keyboard nav, paste UX, undo grouping refinements).

## Audit issues addressed

From `docs/development/datagrid-audit.md`:

- #5 partial: cell construction is decomposed but native widgets are deferred.
- #7 prepared: typed kinds make per-kind editors trivial to add.
- #19: `NSTableColumn` lifetime decoupled from schema changes.
- #20: reuse pool stays warm on table switch.
- #21: accessory buttons no longer carry stale handler state across reuse (fixed earlier in the branch and now backed by the kind hierarchy).
- #28: slot-based identifiers are stable across schema permutations.
- #40: cell construction no longer reads tag-based state.
- #50: column reorder during reconcile no longer flickers.
