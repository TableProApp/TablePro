# 09 - Dead code, single-call-site abstractions, redundant logic

Scope: `Views/Results/`, `Views/Results/Cells/`, `Views/Results/Extensions/`,
`Views/Editor/`, `Models/Query/`, `Core/Database/`, `Core/Plugins/`,
`Core/ChangeTracking/`. Reference counts collected with `grep -rn` across
`/Users/ngoquocdat/Projects/TablePro/TablePro` (worktree shadows excluded).
Symbols are flagged when their only caller is the declaration file or the
caller is itself dead.

Legend in tables: refs = call sites outside the declaration file. Verdict:
**DELETE** = zero callers; **INLINE** = one caller, abstraction adds no
value; **KEEP** = real reuse; **REVIEW** = duplicated or cohabiting with
similar code.

---

## A. Strong delete candidates (zero external callers)

### A.1. `Views/Editor/QuerySuccessView.swift` - entire file

`struct QuerySuccessView: View` exists only as a declaration plus its own
`#Preview`. Replaced by `Views/Results/ResultSuccessView`. The single
project-wide reference to "QuerySuccessView" is a comment in
`ResultSuccessView.swift:6` ("Replaces the full-screen QuerySuccessView for
multi-result contexts"). 0 callers.

Action: delete `Views/Editor/QuerySuccessView.swift`.

### A.2. `TableSelection.swift` - three methods + static

| Symbol | refs | Verdict |
| --- | --- | --- |
| `TableSelection.empty` | 0 | DELETE |
| `TableSelection.hasFocus` | 0 | DELETE |
| `TableSelection.clearFocus()` | 0 | DELETE |
| `TableSelection.setFocus(row:column:)` | 0 | DELETE |
| `TableSelection.reloadIndexes(from:)` | 1 (`KeyHandlingTableView.swift:12`) | KEEP |

`TableSelection` is only used by `KeyHandlingTableView.selection`. The four
items above were never wired up. After removing them the struct shrinks to
two stored properties and `reloadIndexes`. Once that is true, consider
folding the remaining bag into `KeyHandlingTableView` directly.

### A.3. `DataGridView+RowActions.swift` - `setCellValue(_:at:)`

```
TablePro/Views/Results/DataGridView+RowActions.swift:79
    func setCellValue(_ value: String?, at rowIndex: Int) { … }
```

The only call to `setCellValue(_:at:)` is its own body, which forwards to
`setCellValueAtColumn`. No external caller. DELETE.

`setCellValueAtColumn(_:at:columnIndex:)` is used by `TableRowViewWithMenu`
3 times - KEEP.

### A.4. `TableRowViewWithMenu.undoInsertRow()`

```
TablePro/Views/Results/TableRowViewWithMenu.swift:218
    @objc private func undoInsertRow() {
        coordinator?.undoInsertRow(at: rowIndex)
    }
```

No `NSMenuItem` in the same file is ever wired with `#selector(undoInsertRow)`
(the menu only adds `undoDeleteRow`). The `@objc` is unreachable from the
context menu and unreachable through validation routing. DELETE.

(Note: the *coordinator's* `undoInsertRow(at:)` is real and called from
`MainContentView.swift:384` and `MainContentCoordinator+RowOperations.swift`.)

### A.5. `JSONEditorContentView` - thin wrapper

```
TablePro/Views/Results/JSONEditorContentView.swift  // 50 lines, single caller
TablePro/Views/Results/Extensions/DataGridView+Popovers.swift:118
    JSONEditorContentView(initialValue: …, onCommit: …, onDismiss: …)
```

The view is a pass-through that constructs a binding around `text` and
delegates to `JSONViewerView`. It has one caller. INLINE its body into
`showJSONEditorPopover` (or move its 8 lines of compact-comparison logic into
`JSONViewerView` itself, see C.1). Delete the file afterward.

---

## B. Single-call-site abstractions (INLINE candidates)

These are not "dead" - they execute when called - but each has exactly one
caller, the abstraction is local to one feature, and the indirection adds
nothing. They were extracted because the host file is over the SwiftLint
warn threshold; the cure should be re-grouping by responsibility, not
shaving off one-liners.

### B.1. `DataGridView+TypePicker.swift` - entire file (39 lines)

| Symbol | refs | Verdict |
| --- | --- | --- |
| `showTypePickerPopover(...)` | 1 (`DataGridView+Click.swift:86`) | INLINE |

One method, one caller. File should be deleted; the body either inlined
into `+Click` or moved into `+Popovers` next to its sibling popover
helpers.

### B.2. `DataGridView+Popovers.swift` - most public methods are 1-call

| Symbol | call site | Verdict |
| --- | --- | --- |
| `showDatePickerPopover` | `+Click.swift:104` | INLINE |
| `showForeignKeyPopover` | `+Click.swift:43` | INLINE |
| `showJSONEditorPopover` | `+Click.swift` (single) | INLINE |
| `showBlobEditorPopover` | `+Click.swift:108` | INLINE |
| `showEnumPopover` | `+Click.swift:100` | INLINE |
| `showSetPopover` | `+Click.swift:102` | INLINE |
| `showDropdownMenu` | `+Click.swift` and `+TypePicker` | KEEP (2 sites) |
| `toggleForeignKeyPreview` | `KeyHandlingTableView.swift:185` and `MainContentCoordinator+FKNavigation.swift` | KEEP |
| `showForeignKeyPreview` | `TableRowViewWithMenu.swift:298` and `+Click.swift` | KEEP |
| `commitPopoverEdit` | 5+ sites within the popover handlers | KEEP |
| `cellValue(at:column:)` | 3 sites | KEEP |
| `dropdownMenuItemSelected/Null` | NSMenu @objc selectors | KEEP |

The whole file is essentially a single switch over click intent (already
expressed as a chain in `+Click.handleDoubleClick`). The split between
`+Click` (which decides what to show) and `+Popovers` (which shows it) is
near-tautological - `+Click` already knows the cell type. Six of the eight
public `show*Popover` methods exist purely to host "build NSPopover, set
content, present, register cleanup" boilerplate that is structurally
identical across all of them.

Recommendation: collapse the popover construction into a single
`presentPopover(content:anchor:onCommit:)` helper plus inline call sites.
Keep `commitPopoverEdit` - it is the actual shared logic.

### B.3. `DataGridView+CellPaste.swift` and `DataGridView+CellCommit.swift`

Each file declares one method.

| Symbol | refs | Verdict |
| --- | --- | --- |
| `pasteCellsFromClipboard(anchorRow:anchorColumn:)` | 1 (`KeyHandlingTableView.swift:114`) | INLINE/KEEP |
| `commitCellEdit(row:columnIndex:newValue:)` | 4 (used by `setCellValueAtColumn`, `commitOverlayEdit`, etc.) | KEEP |

`commitCellEdit` is real shared infrastructure. `pasteCellsFromClipboard` has
one caller and 49 lines of local logic - could move into `KeyHandlingTableView`
where it is used.

### B.4. `DataGridView+Selection.swift`

All four NSTableViewDelegate callbacks (`tableViewColumnDidResize`,
`tableViewColumnDidMove`, `tableViewSelectionDidChange`) are AppKit-invoked
through the delegate protocol - they look 1-ref but the runtime is the
caller. KEEP.

`scheduleLayoutPersist()` has 2 internal call sites (`tableViewColumnDidResize`
and selection change paths). KEEP.

`resolvedFocus(...)` is private and used once inside the same extension.
Could be inlined; keeping it factored aids readability. KEEP.

### B.5. `DataGridView+RowActions.swift` - what is used by what

| Method | Callers | Verdict |
| --- | --- | --- |
| `addNewRow()` | `TableProApp.swift:446`, `MainContentCommandActions.swift:150` | KEEP |
| `undoDeleteRow(at:)` | `TableRowViewWithMenu.swift:215`, `MainContentView.swift` | KEEP |
| `undoInsertRow(at:)` | `MainContentView.swift:384`, `TableRowViewWithMenu.swift:219` (dead - see A.4) | KEEP |
| `copyRows(at:)` | `MainContentCommandActions.swift:215`, AppKit `copy:` selector | KEEP |
| `copyRowsWithHeaders` | `TableRowViewWithMenu.swift:227` | KEEP |
| `copyRowsAsInsert` | `TableRowViewWithMenu.swift:267` | KEEP |
| `copyRowsAsUpdate` | `TableRowViewWithMenu.swift:275` | KEEP |
| `copyRowsAsJson` | `TableRowViewWithMenu.swift:287` | KEEP |
| `setCellValue(_:at:)` | none | DELETE (A.3) |
| `setCellValueAtColumn` | `TableRowViewWithMenu.swift` (3) | KEEP |
| `copyCellValue(at:columnIndex:)` | `TableRowViewWithMenu.swift:244` | KEEP |
| `formatRowValues` | private, used twice | KEEP |
| `resolveDriver()` | private, 2 sites | KEEP |
| `tableView(_:pasteboardWriterForRow:)` etc. | NSTableViewDataSource conformance | KEEP |

After deleting A.3, this file is justified by NSTableView drag-and-drop
plus copy variants.

### B.6. `DataGridView+Sort.swift` - all `@objc` actions are NSMenuItem targets

`sortAscending`, `sortDescending`, `clearSortAction`, `copyColumnName`,
`filterWithColumn`, `hideColumn`, `sizeColumnToFit`, `sizeAllColumnsToFit`,
`setDisplayFormat`, `showAllColumns` - each appears 2 times in code (declaration
+ `#selector(...)`), but all are reachable through NSMenu targets installed
in `menuNeedsUpdate(_:)`. KEEP.

`tableView(_:sizeToFitWidthOfColumn:)` is an NSTableViewDelegate callback -
KEEP.

### B.7. `DataGridView+Editing.swift`

| Symbol | refs | Verdict |
| --- | --- | --- |
| `inlineEditEligibility` | 2 internal | KEEP |
| `canStartInlineEdit(row:columnIndex:)` | 1 (`KeyHandlingTableView.swift:92`) | KEEP (cross-file) |
| `tableView(_:shouldEdit:row:)` | NSTableViewDelegate | KEEP |
| `showOverlayEditor` | 3 sites (`KeyHandlingTableView`, `+Click`, recursion) | KEEP |
| `commitOverlayEdit` | 1 (closure capture) | KEEP |
| `handleOverlayTabNavigation` | 1 (closure capture) | KEEP |
| `control(_:textShouldEndEditing:)` | NSControlTextEditingDelegate | KEEP |
| `control(_:textView:doCommandBy:)` | NSControlTextEditingDelegate | KEEP |

KEEP - file does cohesive work.

### B.8. `DataGridView+Click.swift` - `handleChevronAction` / `handleFKArrowAction`

Both have 1 caller each (`DataGridCoordinator.swift:597`, `:601`, in the
`DataGridCellAccessoryDelegate` conformance block). The delegate conformance
is one place but the file split has hidden the call. INLINE candidates if
the popover refactor in B.2 happens; otherwise KEEP - single cohesive flow.

---

## C. Redundant / duplicated logic

### C.1. JSON viewer triplet - `JSONViewerView` / `ResultsJsonView` / `JSONEditorContentView` / `JSONViewerWindowController`

Four SwiftUI views/controllers with overlapping responsibilities.

| File | Purpose | Distinctive |
| --- | --- | --- |
| `JSONViewerView.swift` (203 lines) | Reusable Text/Tree viewer with toolbar, edit footer, save-with-confirm dialog | The base view |
| `ResultsJsonView.swift` (171 lines) | Reusable Text/Tree viewer for query results, with row-count toolbar and Copy JSON button | Reads from `TableRows` instead of `Binding<String>`; Copy button instead of edit footer |
| `JSONEditorContentView.swift` (50 lines) | Wraps `JSONViewerView` in a fixed-frame editor sheet for the cell-popover use case | Frames + compact-compare on commit |
| `JSONViewerWindowController.swift` (118 lines) | Detached window hosting `JSONViewerView` | Window lifecycle + same compact-compare on commit |

Duplicated bodies across these files:

1. **State trio + parse trigger.** `viewMode`, `treeSearchText`, `parsedTree`,
   `parseError`, `prettyText` and `parseTree()` / `JSONTreeParser.parse(...)`
   exist verbatim in both `JSONViewerView` and `ResultsJsonView`.
2. **`treeErrorView(_:)`.** Identical-shaped `ContentUnavailableView` block
   in `JSONViewerView` (lines 116-131) and `ResultsJsonView` (lines 135-150),
   differing only in the closing message string.
3. **Text/Tree segmented picker.** Same Picker code in both viewers.
4. **`onChange(of: viewMode)` writing back to `AppSettingsManager.shared.editor.jsonViewerPreferredMode`.**
   Duplicated.
5. **Compact-compare on commit.** Identical 4-line block in
   `JSONEditorContentView:39-43` and `JSONViewerWindowController:109-113`:
   ```
   let normalizedNew = JSONViewerView.compact(newValue)
   let normalizedOld = JSONViewerView.compact(initialValue)
   if normalizedNew != normalizedOld { onCommit?(newValue) }
   ```

Recommendation:
- Make `JSONViewerView` the canonical viewer with two modes: edit-binding
  vs read-only string-view.
- Convert `ResultsJsonView` into a thin host that builds the JSON string
  from `TableRows` and hands a read-only binding to `JSONViewerView` (or
  inline the row-count toolbar around `JSONViewerView`).
- Delete `JSONEditorContentView.swift` (A.5).
- Move the compact-compare into `JSONViewerView.commitAndClose` so callers
  don't reimplement it.

Net: -200 to -250 lines, single source of truth for the JSON viewing
toolbar / picker / parse / error states.

### C.2. `DataGridCellFactory` is misnamed

`DataGridCellFactory` does not produce cells. It owns three column-width
calculators (`calculateColumnWidth`, `calculateOptimalColumnWidth`,
`calculateFitToContentWidth`) and nothing else. Cell production lives in
`DataGridCellRegistry.dequeueCell(of:in:)`.

The `Cells/DataGridCellFactory.swift` filename + class name suggest overlap
with `DataGridCellRegistry`. There is none. KEEP the logic - REVIEW the
name. Suggested rename: `ColumnWidthCalculator` (or fold the three methods
into `DataGridColumnPool` since pooling and width sizing are co-managed -
the column pool already takes a `widthCalculator` closure parameter).

The two non-trivial methods, `calculateOptimalColumnWidth` and
`calculateFitToContentWidth`, share ~14 lines of identical loop structure
differing only in (a) how `charCount` is bounded and (b) the early-return
behaviour when `maxColumnWidth` is hit. They could collapse to one
parameterised method with two thin entry points.

### C.3. Cell registries are NOT redundant

| Type | Responsibility |
| --- | --- |
| `DataGridCellFactory` | column **width** measurement (misnamed - see C.2) |
| `DataGridCellRegistry` | resolves `DataGridCellKind` and dequeues `DataGridBaseCellView` subclasses |
| `DataGridColumnPool` | pools `NSTableColumn` slots, applies layout, attaches headers |

These three are orthogonal - KEEP. The original suspicion that they overlap
turns out to be naming-driven.

### C.4. `TableViewCoordinating` protocol - single conformer, single user

```
Views/Results/TableViewCoordinating.swift:4
    protocol TableViewCoordinating: AnyObject { 9 methods }
Views/Results/TableViewCoordinating.swift:16
    extension TableViewCoordinator: TableViewCoordinating {}
```

One conformer (`TableViewCoordinator`). One declared user
(`DataTabGridDelegate.tableViewCoordinator: (any TableViewCoordinating)?`).

Reading `DataTabGridDelegate.swift:114`, the `dataGridAttach` call
unconditionally assigns the concrete `TableViewCoordinator`. The protocol
exists only to weaken the property type on the delegate side; there is no
test double, no second implementation, no DI seam in use.

Verdict: REVIEW. If no test/mock motivation appears, delete the protocol
and type the property as `weak var tableViewCoordinator: TableViewCoordinator?`.
That deletes a file (`TableViewCoordinating.swift`) and a layer of
indirection.

### C.5. `AnyChangeManager` wrapping `ChangeManaging`

```
Core/ChangeTracking/AnyChangeManager.swift  (69 lines)
  protocol ChangeManaging
  @Observable final class AnyChangeManager
```

Conformers of `ChangeManaging`: `DataChangeManager`, `StructureChangeManager`.

Callers of `AnyChangeManager`:
- `DataGridView.swift:28` (the `var changeManager: AnyChangeManager`)
- `DataGridCoordinator.swift:13`
- `TableStructureView.swift:48`, `:64` (wraps `StructureChangeManager`)
- `CreateTableView.swift:37`, `:58`
- `MainEditorContentView.swift:71-77`, `:150` (wraps `DataChangeManager`)

KEEP. Two distinct conformers and four distinct construction sites means
the wrapper is paying for itself.

Minor: `MainEditorContentView` rebuilds the wrapper each time it falls
through the `cachedChangeManager` `nil` branch (line 77). Not dead code,
but a subtle correctness smell - the docstring says "Safe: onAppear fires
before any user interaction needs it" but a fresh instance per access
would defeat `@Observable` identity. Out of scope for this report; flag
to performance/threading owners.

### C.6. `SortableHeaderCell` vs `SortableHeaderView` - NOT duplicated

Investigated the suspicion that header drawing is split across both. They
divide cleanly:

- `SortableHeaderCell` (`NSTableHeaderCell`) - drawing only: title,
  ascending/descending indicator, multi-sort priority badge.
- `SortableHeaderView` (`NSTableHeaderView`) - input only: cursor rects,
  click vs drag detection, multi-sort modifier, sort-cycle dispatch.

`HeaderSortCycle.nextTransition` is the pure state-transition function
used once by `SortableHeaderView.mouseDown`. KEEP.

### C.7. `HistoryDataProvider`

```
Views/Results/HistoryDataProvider.swift:40   final class HistoryDataProvider
Views/Editor/HistoryPanelView.swift:30       private let dataProvider = HistoryDataProvider()
```

One construction, one user. KEEP - it is a real `@Observable` data source
hosted in the editor's history panel. The location under
`Views/Results/` is misleading; the panel is rendered in the editor surface
and reads the `QueryHistory` persistence layer. REVIEW: move under
`Views/Editor/`.

### C.8. `CellOverlayEditor`

```
Views/Results/CellOverlayEditor.swift             // NSTextViewDelegate-driven editor
DataGridCoordinator.swift:93                       var overlayEditor: CellOverlayEditor?
DataGridView+Editing.swift:80                      overlayEditor = CellOverlayEditor()
```

Constructed once, retained on the coordinator, used by the multi-line
inline edit path. KEEP.

### C.9. `TableRowViewWithMenu.menu(for:)` - used

`TableRowViewWithMenu` is the row view returned from
`+Columns.tableView(_:rowViewForRow:)`. `KeyHandlingTableView.menu(for:)`
delegates to it (`KeyHandlingTableView.swift:342: return rowView.menu(for: event)`).
The menu hook is the entire reason for the subclass - KEEP.

After deleting `undoInsertRow()` (A.4) the file shrinks but stays load-bearing.

### C.10. `ResultSuccessView`, `InlineErrorBanner`, `HexEditorContentView`,
`DatePickerCellEditor`, `ForeignKeyPreviewView`, `KeyHandlingTableView`

All wired up:

| File | Caller |
| --- | --- |
| `ResultSuccessView` | `MainEditorContentView.swift:479` and `:490` |
| `InlineErrorBanner` | `MainEditorContentView.swift:468` |
| `HexEditorContentView` | `+Popovers.swift:151` |
| `DatePickerCellEditor` | `+Popovers.swift:177` |
| `ForeignKeyPreviewView` | `+Popovers.swift:88` |
| `KeyHandlingTableView` | `DataGridView.swift:51`; subclassed and used heavily |

KEEP all.

### C.11. `JSONBraceMatchingHelper` and `JSONHighlightPatterns`

| Type | Used by |
| --- | --- |
| `JSONBraceMatchingHelper` | `JSONSyntaxTextView.swift:54`, `:154` |
| `JSONHighlightPatterns` | `JSONSyntaxTextView.swift:110, 112, 119, 120` |
| `JSONSyntaxTextView` | `JsonEditorView.swift:14`, `ResultsJsonView.swift:118`, `JSONViewerView.swift:100` |
| `JSONTreeView` | `JSONViewerView.swift:107`, `ResultsJsonView.swift:125` |

All real users. KEEP. The duplication problem here is at the *viewer* layer
(C.1), not the helper layer.

### C.12. `DataGridCellKind` - all branches reachable

All seven cases (`text`, `foreignKey`, `dropdown`, `boolean`, `date`,
`json`, `blob`) appear in `DataGridCellRegistry.dequeueCell`'s switch. The
sole producer is `DataGridCellRegistry.resolveKind(...)` whose conditions
dispatch to all seven outcomes (FK / dropdown / boolean / date / json /
blob / text fallthrough). No unreachable branches.

---

## D. DatabaseType switch reachability

Searched `Core/Database/` for switches over `DatabaseType`.

```
DatabaseDriver.swift:465  switch connection.type {
                            case .mongodb: …
                            case .redis: …
                            case .mssql: …
                            case .oracle: …
                            default: break
                          }
```

Only switch in `Core/Database`. All four cases correspond to types with
plugin-bundled drivers in current code; the `default:` branch handles the
open-ended `DatabaseType` struct. No unreachable case.

(Wider audit of switches across the app would require its own pass - out
of scope for this report.)

---

## E. Empty / one-liner file candidates

None of the swept files are empty. The smallest are:

| File | Lines | Verdict |
| --- | --- | --- |
| `DataGridCellKind.swift` | 17 | KEEP - focused enum |
| `DataGridCellAccessoryDelegate.swift` | ~12 | KEEP - protocol contract |
| `TableViewCoordinating.swift` | 17 | DELETE if no test seam (C.4) |
| `DataGridView+TypePicker.swift` | 39 | DELETE (B.1) |
| `JSONEditorContentView.swift` | 50 | DELETE (A.5) |
| `DataGridView+CellPaste.swift` | 49 | INLINE candidate (B.3) |
| `DataGridView+CellCommit.swift` | 58 | KEEP |

---

## F. Headline numbers

- 1 entire file dead (`QuerySuccessView.swift`).
- 1 file dead pending the C.4 decision (`TableViewCoordinating.swift`).
- 2 files inline-or-delete candidates with one caller
  (`DataGridView+TypePicker.swift`, `JSONEditorContentView.swift`).
- 6 zero-call-site members (`TableSelection.empty`, `hasFocus`, `clearFocus`,
  `setFocus`, `DataGridView+RowActions.setCellValue(_:at:)`,
  `TableRowViewWithMenu.undoInsertRow`).
- ~250 lines of duplicated JSON-viewer scaffolding across `JSONViewerView`,
  `ResultsJsonView`, `JSONEditorContentView`, `JSONViewerWindowController`
  (C.1).
- 1 misnamed type (`DataGridCellFactory` → ColumnWidthCalculator) with two
  near-duplicate width methods that can collapse to one parameterised
  method (C.2).
- 6 of 8 `show*Popover` methods in `DataGridView+Popovers.swift` have a
  single caller in `DataGridView+Click.swift`; the file is mostly
  boilerplate around `NSPopover` setup (B.2).

## G. Out-of-scope notes

- `Core/Plugins/` and most of `Models/Query/` were swept; one external
  reference outlier (`LinkedFavoriteTransfer`, 1 caller) is a real
  `Transferable` drag payload - KEEP.
- `QueryTabState` shows 0 external refs because every type in that file is
  imported under its own name (`SortState`, `PaginationState`, etc.); not
  dead.
- `LineCutCalculator` (single caller) is small, pure, and tested in
  isolation. KEEP.

---

End of inventory.
