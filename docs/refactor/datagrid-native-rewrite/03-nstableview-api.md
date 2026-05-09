# 03 - NSTableView API Correctness Audit

Scope: every place TablePro reimplements behavior that AppKit's `NSTableView` already provides. For each finding: TablePro file/line, what is being reimplemented, the native API to use, and the canonical Apple reference (developer.apple.com URL or AppKit header). All recommendations are anchored against the Sequel-Ace and Gridex precedents in this repo.

View-based vs. cell-based decision: TablePro is view-based and that is correct for a fully editable grid with mixed accessory views (FK arrows, chevrons, NULL/DEFAULT placeholders). Apple's "Cell-Based and View-Based Table Views" guidance (Apple TableView Programming Guide, "View-Based vs. Cell-Based Table Views") explicitly recommends view-based when cells contain controls, custom drawing, or per-row accessibility. Sequel-Ace runs cell-based (`SPCopyTable` is an `NSTableView` subclass with `NSCell`-style drawing) but Sequel-Ace pre-dates view-based tables and pays for it with a custom field editor and custom drag/drop plumbing we should not adopt. Keep view-based.

References used throughout:
- `Frameworks/AppKit/NSTableView.h`
- developer.apple.com/documentation/appkit/nstableview
- developer.apple.com/documentation/appkit/nstablecolumn
- TablePlanning Programming Guide: "Sorting" and "View-Based Table Views" (TableView Programming Guide for Mac)
- AppKit Release Notes (10.7+ view-based; 10.5+ sort descriptor; 10.10+ row animations; 11+ `style`)

---

## T1 - Column persistence: replace custom layout file with `autosaveName` + `autosaveTableColumns`

**Reimplemented in TablePro**:
- `TablePro/Views/Results/DataGridCoordinator.swift:42` `savedColumnLayout(binding:)`
- `TablePro/Views/Results/DataGridCoordinator.swift:56` `captureColumnLayout()`
- `TablePro/Views/Results/DataGridCoordinator.swift:79` `persistColumnLayoutToStorage()`
- `TablePro/Views/Results/DataGridView.swift:365` `dismantleNSView` calls `persistColumnLayoutToStorage()`
- `TablePro/Views/Results/DataGridView.swift:218` `savedLayout` round-trip on every `updateNSView`
- `TablePro/Views/Results/DataGridColumnPool.swift:27` `reconcile(... savedLayout: ColumnLayoutState?, ...)` rebuilds `columnWidths`, `columnOrder`, `hiddenColumns` from a custom `ColumnLayoutState` written via `FileColumnLayoutPersister`

What it reimplements: width persistence, visible column order persistence, hidden-column persistence, and re-application of all three when the table re-attaches. AppKit already does this on the table view itself.

**Native API**:
```
tableView.autosaveName = "TableProDataGrid.<connectionId>.<tableName>"
tableView.autosaveTableColumns = true
```
- `NSTableView.autosaveName: NSTableView.AutosaveName?` persists per-column **width**, **visibility (`isHidden`)**, and **display order** under `NSTableView Columns <autosaveName>` in `NSUserDefaults`.
- `NSTableView.autosaveTableColumns: Bool` toggles the persistence.
- AppKit calls `restoreState` automatically when the table is loaded with an autosave name set; persistence happens automatically on column reorder/resize/hide.
- For per-table-name layouts, set `autosaveName` after `tableName` is known. For the initial `nil` state (no real table, e.g. ad-hoc query results), leave `autosaveName = nil` - autosave silently no-ops.

Apple references:
- developer.apple.com/documentation/appkit/nstableview/autosavename
- developer.apple.com/documentation/appkit/nstableview/autosavetablecolumns
- `Frameworks/AppKit/NSTableView.h` → `@property (copy, nullable) NSTableView.AutosaveName autosaveName;`

Sequel-Ace precedent: every `<tableView ...>` element in `Sequel-Ace/Source/Interfaces/DBView.xib`, `QueryFavoriteManager.xib`, `BundleEditor.xib`, etc. ships with `autosaveName="..."` - Sequel-Ace never hand-rolls a column layout file.

Migration path:
1. Set `tableView.autosaveName = makeAutosaveName(connectionId:tableName:tabType:)`. For `tabType == .query` use a stable per-query-tab key; for `tabType == .table` use `"TablePro.\(connectionId).\(tableName)"`.
2. Delete `FileColumnLayoutPersister`, `ColumnLayoutState.columnWidths`/`columnOrder`/`hiddenColumns`, `captureColumnLayout()`, `persistColumnLayoutToStorage()`, `savedColumnLayout(binding:)`, the `onColumnLayoutDidChange` callback, and the `@Binding var columnLayout` on `DataGridView`.
3. `DataGridColumnPool.reconcile` no longer takes `savedLayout`; it just creates/configures the columns and lets AppKit restore state.
4. One-time migration: read the legacy `ColumnLayoutState` file and write its widths/order into `UserDefaults` under the AppKit autosave key (`NSTableView Columns <name>`) on first launch, then delete the file. AppKit's stored format is a flat dictionary keyed by column identifier - straightforward to translate.

---

## T2 - Sort: replace `SortableHeaderView` mouseDown with `sortDescriptorPrototype` + `tableView(_:sortDescriptorsDidChange:)`

**Reimplemented in TablePro**:
- `TablePro/Views/Results/SortableHeaderView.swift:207` whole `mouseDown(with:)` override that hit-tests resize zone, suppresses drag, reads `event.modifierFlags.shift`, runs `HeaderSortCycle.nextTransition`, mutates `coordinator.currentSortState`, and calls `coordinator.delegate?.dataGridSort(...)`.
- `TablePro/Views/Results/SortableHeaderView.swift:158` `updateSortIndicators(state:schema:)` driving custom `SortableHeaderCell.sortDirection`/`sortPriority`.
- `TablePro/Views/Results/SortableHeaderCell.swift:32` whole `drawInterior` + `drawSortIndicator` no-op override.
- `TablePro/Views/Results/DataGridView.swift:264` `syncSortDescriptors(...)` writes a single-element `tableView.sortDescriptors` and toggles `highlightedTableColumn`.
- `TablePro/Views/Results/DataGridColumnPool.swift:211` already sets `sortDescriptorPrototype = NSSortDescriptor(key: name, ascending: true)`, but the prototype is never honored because the click is intercepted before AppKit's standard handler runs.

What it reimplements: the entire `NSTableView` sort-by-header-click flow. AppKit already does click detection, modifier handling for multi-sort, animated indicator drawing, and accessibility.

**Native API**:
```
column.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier.rawValue, ascending: true)
// in delegate:
func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
    let new = tableView.sortDescriptors
    delegate?.dataGridApplySortDescriptors(new)
}
```
- AppKit semantics (documented in TableView Programming Guide → "Sorting"):
  - Click on header column with prototype → AppKit appends or replaces the prototype in `tableView.sortDescriptors`, flipping `ascending` if the same column is clicked again.
  - **Shift-click** on a column with a prototype → AppKit appends instead of replacing, producing multi-key sort. This is the exact behavior `HeaderSortCycle.multiSortTransition` reimplements by hand.
  - The single sort-cycle "ascending → descending → cleared" is **not** native - AppKit cycles ascending ↔ descending only. The "third click clears" UX in `HeaderSortCycle.singleSortTransition` is a TablePro design choice; it can be re-added in the delegate by inspecting `oldDescriptors` vs the new array.
  - The header cell's sort triangle and priority number are drawn by `NSTableHeaderCell` automatically when `tableView.indicatorImage(in:)` is left at default. Override `tableView(_:didClick:)` only if you want **non-sort** column-click side effects.

Apple references:
- developer.apple.com/documentation/appkit/nstablecolumn/sortdescriptorprototype
- developer.apple.com/documentation/appkit/nstableviewdatasource/tableview(_:sortdescriptorsdidchange:)
- TableView Programming Guide → "Sorting Table Views"
- `Frameworks/AppKit/NSTableView.h` → `@property (copy) NSArray<NSSortDescriptor *> *sortDescriptors;`

Sequel-Ace precedent: `Sequel-Ace/Source/Controllers/SubviewControllers/SPProcessListController.m:762` `tableView:sortDescriptorsDidChange:` is the entire sort handler; the XIB defines `<sortDescriptor key="sortDescriptorPrototype" .../>` on each column. No mouse handling, no header subclass.

**Migration: descriptor flow and multi-column sort**:

1. In `DataGridColumnPool.configureColumn`, keep the existing `sortDescriptorPrototype = NSSortDescriptor(key: name, ascending: true)` line; remove the `SortableHeaderCell` swap (use stock `NSTableHeaderCell` so AppKit draws the indicator triangle).
2. Delete `SortableHeaderView` entirely; restore `tableView.headerView = NSTableHeaderView()`.
3. In `TableViewCoordinator`, implement:
   ```
   func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
       let descriptors = tableView.sortDescriptors
       let sortColumns = descriptors.compactMap { descriptor -> SortColumn? in
           guard let key = descriptor.key,
                 let columnIndex = identitySchema.dataIndex(forColumnName: key)
           else { return nil }
           return SortColumn(
               columnIndex: columnIndex,
               direction: descriptor.ascending ? .ascending : .descending
           )
       }
       var newState = SortState(); newState.columns = sortColumns
       delegate?.dataGridApplySortState(newState)
   }
   ```
4. `DataGridView.syncSortDescriptors` becomes a one-way push: convert the bound `SortState` to `[NSSortDescriptor]` and assign `tableView.sortDescriptors`. AppKit handles redraw.
5. Multi-column sort now requires no special code: shift-click is built into `NSTableView`. The "shift-click third time removes" behavior in `HeaderSortCycle.multiSortTransition` (lines 31–58) can be re-added by post-filtering `descriptors` in `sortDescriptorsDidChange` - strip duplicates whose direction was flipped by the user, etc. Since the descriptor diff (`oldDescriptors` → `tableView.sortDescriptors`) tells you exactly which column the click changed, the cycle logic is local to that delegate call, ~10 lines, and doesn't need its own type.
6. The "sort indicator priority number ≥ 2" UI in `SortableHeaderCell` (lines 49–60) is replaced by AppKit's stock numbered triangles - `NSTableHeaderCell.drawSortIndicator(withFrame:in:ascending:priority:)` already does this.
7. The `currentSortState` mirror on the coordinator becomes redundant - `tableView.sortDescriptors` is the single source of truth.

Net deletions if T2 + indicator simplification land: `SortableHeaderView.swift` (288 lines), `SortableHeaderCell.swift` (182 lines), `HeaderSortCycle` enum and `HeaderSortTransition`, `currentSortState` on `TableViewCoordinator`. The custom resize-cursor zone in `SortableHeaderView.resetCursorRects`/`mouseMoved` (lines 103–155) is also dead weight: `NSTableHeaderView` already manages resize cursors via `NSTableView.resizeColumn(...)` infrastructure when `column.resizingMask.contains(.userResizingMask)` (which `DataGridColumnPool` already sets).

---

## T3 - Field editor: replace `CellOverlayEditor` borderless `NSPanel` with the standard field editor flow + `NSTextView` field editor for multi-line cells

**Reimplemented in TablePro**:
- `TablePro/Views/Results/CellOverlayEditor.swift:31` `show(in:row:column:columnIndex:value:)` - builds a borderless `NSPanel` (lines 97–115) containing an `NSScrollView` + custom `OverlayTextView`, places it in **screen** coordinates (lines 60–66 use `convertToScreen`), wires `onCommit`/`onTabNavigation`, observes `NSView.boundsDidChangeNotification` and `NSTableView.columnDidResizeNotification` to dismiss.
- `TablePro/Views/Results/CellOverlayEditor.swift:148` `dismiss(commit:)` plus the `CellOverlayPanel.resignKey` hook to simulate commit-on-blur.
- `TablePro/Views/Results/CellOverlayEditor.swift:180` `textView(_:doCommandBy:)` reroutes Return/Esc/Tab/Backtab.
- `TablePro/Views/Results/Extensions/DataGridView+Editing.swift:78` `showOverlayEditor(...)` invoked from `tableView(_:shouldEdit:row:)` whenever the value contains a line break - diverting the standard `editColumn:row:with:select:` path entirely.
- `TablePro/Views/Results/KeyHandlingTableView.swift:209` `insertNewline(_:)` calls `showOverlayEditor` instead of `editColumn:row:with:select:` when the cell value contains a line break.

What it reimplements:
1. The window/positioning/dismiss machinery that AppKit's field-editor system already provides.
2. Multi-line text entry in a single cell - but using a side-channel panel rather than the cell's own field editor.
3. Tab/Backtab navigation across cells (already supported by `NSTextField` + `NSTableView`).
4. Commit-on-blur (already provided by `NSControlTextEditingDelegate`'s `controlTextDidEndEditing`).

**Native API** (single-line, the common case):
```
tableView.editColumn(columnIndex, row: rowIndex, with: nil, select: true)
// commit and tab navigation flow through the standard delegate:
//   func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool
//   func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool
```
- `NSTableView.editColumn(_:row:with:select:)` already hosts the cell's `NSTextField` field editor inline at the cell rect, scrolls the row to visible, focuses the editor, and routes commit through `controlTextDidEndEditing(_:)`. Apple: developer.apple.com/documentation/appkit/nstableview/editcolumn(_:row:with:select:).
- The cell text field is supplied by `NSTableCellView.textField`, which TablePro already uses (`DataGridBaseCellView.textField`).

**Native API** (multi-line cells, the case `CellOverlayEditor` exists for):

Use a custom **field editor** returned by `NSWindowDelegate.windowWillReturnFieldEditor(_:to:)`. This is the documented Apple pattern for replacing the default single-line `NSTextView` field editor with a multi-line one for specific controls, without needing a separate window.

```
// On the window delegate (or on EditorWindow itself):
func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
    guard let textField = client as? CellTextField,
          textField.usesMultilineFieldEditor else { return nil }
    return MultilineFieldEditor.shared  // a long-lived NSTextView with field-editor mode
}

final class MultilineFieldEditor: NSTextView {
    static let shared: MultilineFieldEditor = {
        let tv = MultilineFieldEditor(frame: .zero)
        tv.isFieldEditor = true
        tv.allowsUndo = true
        tv.isRichText = false
        tv.usesFontPanel = false
        tv.importsGraphics = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        return tv
    }()
}
```

Apple references:
- developer.apple.com/documentation/appkit/nswindowdelegate/windowwillreturnfieldeditor(_:to:)
- developer.apple.com/documentation/appkit/nstextview/isfieldeditor
- TextEditing Programming Guide → "Using a Field Editor", section "Replacing the default field editor"
- `Frameworks/AppKit/NSWindow.h` → `- (nullable id)windowWillReturnFieldEditor:(NSWindow *)sender toObject:(nullable id)client;`

Sequel-Ace precedent: `Sequel-Ace/Source/Views/TextViews/SPTextView.{h,m}` is exactly this pattern - a long-lived multi-line `NSTextView` returned as the field editor for SQL editing controls. The control delegate's `control(_:textView:doCommandBy:)` (TablePro already implements this in `DataGridView+Editing.swift:179`) handles Return/Esc/Tab; Option-Return for newline is one extra `commandSelector` check. Sequel-Ace references for cell editing are at `SPCopyTable.m:1192/1210/1260/1292/1306/1318` - note that every navigation call uses `[self editColumn:column row:row withEvent:nil select:YES]`, never a side-channel panel.

**Migration**:
1. Add `usesMultilineFieldEditor: Bool` to `CellTextField`. Set it in `tableView(_:viewFor:row:)` (or `prepareForReuse`) when the cell value `containsLineBreak`.
2. Make `EditorWindow` (or whichever `NSWindow` hosts the table) implement `windowWillReturnFieldEditor(_:to:)` and return the shared `MultilineFieldEditor` for those cells.
3. Delete `CellOverlayEditor.swift` (243 lines), `CellOverlayPanel`, `OverlayTextView`. Delete `showOverlayEditor`, `commitOverlayEdit`, `handleOverlayTabNavigation`, the `.needsOverlayEditor` case in `InlineEditEligibility`, and the `KeyHandlingTableView.insertNewline` branch that invokes the overlay.
4. In `control(_:textView:doCommandBy:)` (`DataGridView+Editing.swift:179`):
   - `insertNewline` → if Option held (`NSApp.currentEvent?.modifierFlags.contains(.option) == true`), `textView.insertNewlineIgnoringFieldEditor(nil)` and return `true`; otherwise commit and return `false` (let AppKit advance).
   - `cancelOperation` already routes correctly through `isEscapeCancelling`.
   - `insertTab` / `insertBacktab` already work - the existing implementation is correct.
5. The "dismiss on column resize" and "dismiss on scroll" observers in `CellOverlayEditor.show(...)` (lines 125–145) become unnecessary: AppKit's field editor lives inside the cell view, so it follows resize/scroll for free.

Caveat: the standard field editor commits on blur. Some users want "Return commits, Esc cancels, click-outside also commits" - that's already the default. The current overlay editor's "click outside cancels" semantics (`onResignKey { dismiss(commit: true) }` at line 116) match commit-on-blur, so no behavioral change.

---

## T4 - Split single class implementing 4 protocols into separate dataSource, delegate, and field-editor delegate

**Reimplemented in TablePro**:
`TablePro/Views/Results/DataGridCoordinator.swift:8` declares
```
final class TableViewCoordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource,
                                  NSControlTextEditingDelegate, NSTextFieldDelegate, NSMenuDelegate
```
and the class accumulates ~600 lines plus extension files for cells/sort/columns/editing/selection. There is also a `DataGridCellAccessoryDelegate` adoption at line 595.

What it reimplements: nothing technically - but it conflates four roles AppKit treats as separate. Apple's TableView Programming Guide says: "The data source and delegate are typically separate objects... Splitting them keeps each responsibility focused and makes it easier to swap implementations." (TableView Programming Guide → "Setting Up a Table View" → "Data Source and Delegate".)

**Native split**:
- `final class DataGridDataSource: NSObject, NSTableViewDataSource` - owns `numberOfRows(in:)`, `tableView(_:pasteboardWriterForRow:)`, drag/drop validate/accept, `tableView(_:sortDescriptorsDidChange:)` (technically a data-source method per the docs).
- `final class DataGridDelegate: NSObject, NSTableViewDelegate, NSMenuDelegate` - owns `tableView(_:viewFor:row:)`, `tableView(_:rowViewForRow:)`, `tableView(_:shouldEdit:row:)`, `tableView(_:sizeToFitWidthOfColumn:)`, header context menu (`menuNeedsUpdate`), selection callbacks.
- `final class DataGridFieldEditorController: NSObject, NSControlTextEditingDelegate, NSTextFieldDelegate` - owns `control(_:textShouldEndEditing:)`, `control(_:textView:doCommandBy:)`, plus the multi-line field editor vending if T3 lands.
- A small `DataGridContext` (or keep `TableViewCoordinator` as the composition root) holds shared state: `tableRowsProvider`, `changeManager`, `identitySchema`, `displayCache` reference, etc. The three role objects each take a context reference.

This makes the file-length warnings under control (1200 line warning, 1800 error in `.swiftlint.yml`) and lets the dataSource be reused for non-AppKit scenarios (e.g. unit tests that drive `numberOfRows(in:)`/`pasteboardWriterForRow:` directly).

Apple references:
- developer.apple.com/documentation/appkit/nstableviewdatasource
- developer.apple.com/documentation/appkit/nstableviewdelegate
- developer.apple.com/documentation/appkit/nscontroltexteditingdelegate
- TableView Programming Guide → "Data Source and Delegate"

Sequel-Ace precedent: `SPTableContent` is the data source; `SPCopyTable` (the table itself) plus `SPTableContent` share delegate methods, but cell editing/field-editor handling lives on a separate "table content" controller and the `SPFieldEditorController` class (`Sequel-Ace/Source/Controllers/SubviewControllers/SPFieldEditorController.{h,m}`).

Migration: this is the only finding in this section that does not change behavior. Defer until after T1–T3 land - those reduce the surface area of `TableViewCoordinator` first.

---

## T5 - Adopt `tableView(_:typeSelectStringFor:row:)` for free incremental search

**Reimplemented in TablePro**: nothing - TablePro currently has no incremental search. AppKit gives it for free if you implement one delegate method.

**Native API**:
```
func tableView(
    _ tableView: NSTableView,
    typeSelectStringFor tableColumn: NSTableColumn?,
    row: Int
) -> String? {
    guard let tableColumn,
          let columnIndex = identitySchema.dataIndex(from: tableColumn.identifier),
          let row = displayRow(at: row),
          columnIndex < row.values.count
    else { return nil }
    return row.values[columnIndex]
}
```
- AppKit picks up keystrokes on the table view, debounces them into a search prefix, and walks rows via this delegate to find the next match. Scrolls the matched row into view automatically.
- `NSTableView.typeSelectMatching(searchString:)`, `tableView(_:nextTypeSelectMatchFromRow:toRow:for:)`, and `tableView(_:shouldTypeSelectFor:withCurrentSearchString:)` give finer control if needed.

Apple references:
- developer.apple.com/documentation/appkit/nstableviewdelegate/tableview(_:typeselectstringfor:row:)
- developer.apple.com/documentation/appkit/nstableviewdelegate/tableview(_:nexttypeselectmatchfromrow:torow:for:)
- developer.apple.com/documentation/appkit/nstableview/typeselectmatching(searchstring:)

Recommended scope: first visible **non-row-number** column. Cap the result at ~120 characters to keep the search loop cheap. Skip when the user is editing (`tableView.editedRow >= 0`) so keystrokes don't both type-select and enter the field editor.

---

## T6 - Replace blanket `reloadData()` with `reloadData(forRowIndexes:columnIndexes:)`

Every call site below either targets a known subset of rows/columns or could.

| Site | Current call | What it actually changes | Targeted alternative |
|---|---|---|---|
| `DataGridCoordinator.swift:209` (`releaseData()`) | `tableView.reloadData()` | wipes all rows because columns were just removed | OK - column structure changed; full reload is correct here |
| `DataGridCoordinator.swift:243` (`applyFullReplace()`) | `tableView.reloadData()` | column or row count changed | OK - `Delta.fullReplace`/`columnsReplaced` truly invalidates structure |
| `DataGridView+RowActions.swift:36` (`undoInsertRow(at:)`) | `tableView.reloadData()` | one row removed | `tableView.removeRows(at: IndexSet(integer: index), withAnimation: .slideUp)` - already what `applyRemovedRows` does for the normal delete path (line 232) |
| `DataGridView.swift:305` (`reloadAndSyncSelection`) | `tableView.reloadData()` when `needsFullReload` | structure changed | OK when row/column count truly changed; but `needsFullReload` is set whenever `oldRowCount != rowDisplayCount`, including +1/−1 deltas. Use `insertRows(at:withAnimation:)` / `removeRows(at:withAnimation:)` for ±k cases (already done by `applyDelta`). The full reload should fire only on `Delta.fullReplace` / column replacement. |
| `DataGridCoordinator.swift:418` (`invalidateCachesForUndoRedo`) | already targets `forRowIndexes:columnIndexes:` over visible rect | OK |
| `DataGridCoordinator.swift:166` (settings change handler) | already targets visible range × all columns | OK |
| `DataGridView+Sort.swift:251` (`setDisplayFormat`) | already targets visible range × all columns | OK |
| `DataGridCoordinator.swift:21` (`undoDeleteRow(at:)`) | `reloadData(forRowIndexes:columnIndexes:)` over single row × all columns | OK |

Net change: only one site (`undoInsertRow`) is mis-using `reloadData()` for a single-row removal. Switch it to `removeRows(at:withAnimation:)` to match the rest of the delta path.

Apple references:
- developer.apple.com/documentation/appkit/nstableview/reloaddata(forrowindexes:columnindexes:)
- developer.apple.com/documentation/appkit/nstableview/insertrows(at:withanimation:)
- developer.apple.com/documentation/appkit/nstableview/removerows(at:withanimation:)
- TableView Programming Guide → "Modifying the Contents of a Table View" → "Updating Data".

---

## T7 - Confirm fixed-row-height path and skip `noteHeightOfRowsWithIndexesChanged:`

TablePro sets `tableView.rowHeight = CGFloat(settings.rowHeight.rawValue)` (`DataGridView.swift:66`) and never sets `usesAutomaticRowHeights` (Apple property; default `false`). The Audit doc §6 ("Invariants to preserve") notes "`usesAutomaticRowHeights` must stay off for large datasets." Confirmed: TablePro is on the fixed-height path, which means `tableView(_:heightOfRow:)` is never queried and `noteHeightOfRowsWithIndexesChanged(_:)` is never needed.

**Recommendation**: add a code-comment-free guarantee by setting `tableView.usesAutomaticRowHeights = false` explicitly at construction (`DataGridView.swift:51` in `makeNSView`). It's the AppKit default but Future-Us deserves the assertion. No call to `noteHeightOfRowsWithIndexesChanged(_:)` should ever be added.

Apple references:
- developer.apple.com/documentation/appkit/nstableview/usesautomaticrowheights
- `Frameworks/AppKit/NSTableView.h` → `@property BOOL usesAutomaticRowHeights;`

---

## T8 - Intercell spacing: align with Gridex

Current TablePro: `tableView.intercellSpacing = NSSize(width: 1, height: 0)` (`DataGridView.swift:65`) plus `gridStyleMask = [.solidVerticalGridLineMask]`.

Gridex: `intercellSpacing = NSSize(width: 0, height: 0)` plus `gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]` (`gridex/macos/Presentation/Views/DataGrid/AppKitDataGrid.swift:32, 35`).

The 1pt horizontal intercell space in TablePro is what currently draws the column separator (since horizontal grid is off); but with `.solidVerticalGridLineMask` enabled the grid line draws inside the cell rect anyway, so the 1pt extra space adds a faint background gap between the cell contents and the grid line. This isn't a bug, but for a denser, Excel-like grid match Gridex: zero intercell spacing, grid lines do the visual separation.

**Recommendation**: change to `NSSize(width: 0, height: 0)` and decide whether to also enable `.solidHorizontalGridLineMask` based on the design system from finding-set 06 (HIG audit). Pure cleanup, no behavior change beyond visual density.

Apple references:
- developer.apple.com/documentation/appkit/nstableview/intercellspacing
- developer.apple.com/documentation/appkit/nstableview/gridstylemask

---

## T9 - Pasteboard: keep `pasteboardWriterForRow:` correct path; add parallel system types via `pasteboardItem(propertyList:forType:)`-equivalents

Current TablePro: `DataGridView+RowActions.swift:178` `tableView(_:pasteboardWriterForRow:)` returns one `NSPasteboardItem` with three types:
- `com.TablePro.rowDrag` - the row index, internal use.
- `.string` - TSV row.
- `.html` - HTML table row.

This is the correct modern path (preferred over the deprecated `tableView(_:writeRowsWith:to:)`). Two improvements for system interop:

1. **Add `.tabularText`** alongside `.string`. Older Cocoa apps (Numbers, BBEdit) accept tab-separated data via `NSPasteboard.PasteboardType("NeXT tabular text pasteboard type")`. Cheap to add.
2. **Add a `public.json` (UTType.json) representation** for one-row drags. The DataGrid already has `JsonRowConverter` (used in `copyRowsAsJson` at line 152). Reusing it on the pasteboard item gives drag-out into JSON-aware tools for free.
3. **For multi-row drags**, return a `[NSPasteboardWriting]` (one item per row). `NSPasteboard` and `NSDraggingInfo` will iterate them; the receiver can read either as a list or as concatenated strings. AppKit's default behavior is correct here as long as each item carries the same type set.

`NSPasteboardItem.setPropertyList(_:forType:)` is the analog the audit prompt asks about - TablePro doesn't use it because its current types are all strings, which is fine. If we ever attach a `[String: Any]` row dictionary (column → value) for receivers like Numbers, that's the API to use.

Apple references:
- developer.apple.com/documentation/appkit/nstableviewdatasource/tableview(_:pasteboardwriterforrow:)
- developer.apple.com/documentation/appkit/nspasteboarditem/setpropertylist(_:fortype:)
- developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/string
- TableView Programming Guide → "Drag and Drop"

Sequel-Ace precedent: drag uses calloc-cached column index mapping (`SPCopyTable.m:171–173`) and TSV/CSV output (`rowsAsTabStringWithHeaders:onlySelectedRows:blobHandling:` and `rowsAsCsvStringWithHeaders:...`). The system-interop angle is solved by emitting plain `.string` TSV; we already do that.

---

## T10 - Drag/drop: validate signatures and `draggingDestinationFeedbackStyle`

Current TablePro:
- `tableView(_:validateDrop:proposedRow:proposedDropOperation:)` at `DataGridView+RowActions.swift:196` - correct modern signature.
- `tableView(_:acceptDrop:row:dropOperation:)` at `DataGridView+RowActions.swift:212` - correct.
- `tableView.draggingDestinationFeedbackStyle = .gap` at `DataGridView.swift:101, 154` - correct for between-row inserts.
- Drag source: `pasteboardWriterForRow:` registered with `registerForDraggedTypes([com.TablePro.rowDrag])`. Internal-only payload - drop is rejected when `draggingSource as? NSTableView !== tableView` (line 203).

Two minor issues:

1. **`draggingDestinationFeedbackStyle` set only on the active-delegate path**: it's set inside an `if hasMoveRow` guard (line 102 / 154). When the table goes from "drop disabled" to "drop enabled" the style is reapplied - but when going the other direction we drop the registered types but never reset the feedback style. Cosmetic; harmless because no drop will be accepted. Set the style once in `makeNSView` and leave it.
2. **`validateDrop` returns `.move` even when `dropOperation == .above` is forced via `setDropRow`**: the current code (lines 205–207) calls `setDropRow(row, dropOperation: .above)` to coerce a row drop into a between-row drop, which is the documented escape hatch. Keep.

Apple references:
- developer.apple.com/documentation/appkit/nstableview/draggingdestinationfeedbackstyle
- developer.apple.com/documentation/appkit/nstableviewdatasource/tableview(_:validatedrop:proposedrow:proposeddropoperation:)
- developer.apple.com/documentation/appkit/nstableviewdatasource/tableview(_:acceptdrop:row:dropoperation:)

---

## T11 - Selection: prefer `selectionIndexesForProposedSelection` over per-row `shouldSelectRow`

Current TablePro: I do not see `tableView(_:shouldSelectRow:)` implemented; selection is driven by binding push/pull (`DataGridView.reloadAndSyncSelection`) and `KeyHandlingTableView.mouseDown` setting `focusedRow`/`focusedColumn`. Good.

**Recommendation**: when a row gets a `RowVisualState.isDeleted` flag, you may want to skip selection or mark it visually but allow undo. If selection ever needs row-level filtering, prefer:

```
func tableView(
    _ tableView: NSTableView,
    selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet
) -> IndexSet {
    proposedSelectionIndexes  // optionally filter
}
```

Apple's docs explicitly recommend this over `shouldSelectRow:` for multi-range selections: "Implementing this delegate method instead of `tableView(_:shouldSelectRow:)` is preferred for performance, especially when selection involves a range or multiple ranges of rows."

Apple references:
- developer.apple.com/documentation/appkit/nstableviewdelegate/tableview(_:selectionindexesforproposedselection:)
- developer.apple.com/documentation/appkit/nstableviewdelegate/tableview(_:shouldselectrow:)

---

## T12 - Context menu: split header menu and body menu via `NSTableView.menu` + per-row-view menus

Current TablePro:
- Body context menu: `KeyHandlingTableView.menu(for:)` at `KeyHandlingTableView.swift:333` does the routing manually - falls through to `rowView.menu(for:)` for hit rows, otherwise `delegate?.dataGridEmptySpaceMenu()`, else `super`. This is a hand-rolled alternative to `NSTableView.menu`/`NSView.menu`.
- Header menu: `SortableHeaderView.menu` is set to an `NSMenu` whose `delegate = coordinator` (`DataGridView.swift:93–96`). The coordinator's `menuNeedsUpdate(_:)` (`DataGridView+Sort.swift:32`) populates per-column items dynamically. **This part is correct** - it uses `NSMenuDelegate.menuNeedsUpdate(_:)` exactly as Apple intends.

The body side can be simplified: set `NSTableRowView.menu` from `tableView(_:rowViewForRow:)` (TablePro already returns `TableRowViewWithMenu` at `DataGridView+Columns.swift:113`), and set `tableView.menu` to the empty-space menu. AppKit auto-routes right-clicks: row hit → row view's menu; otherwise → table view's menu. The override of `menu(for:)` becomes unnecessary.

```
// in DataGridView.makeNSView:
tableView.menu = makeEmptySpaceMenu()  // or wire via delegate
// in tableView(_:rowViewForRow:):
rowView.menu = makeRowMenu(for: row)   // existing TableRowViewWithMenu pathway
```

Apple references:
- developer.apple.com/documentation/appkit/nsview/menu
- developer.apple.com/documentation/appkit/nstableview/menu  (inherited)
- developer.apple.com/documentation/appkit/nsmenudelegate/menuneedsupdate(_:)

Sequel-Ace precedent: `SPCopyTable.m` uses standard `menu(for:)` chain - no manual routing.

---

## T13 - Column visibility: header NSMenu (already partly done) - but kill any custom popover

Current TablePro:
- Header menu does include a "Hide Column" item (`DataGridView+Sort.swift:143–146`) and a "Show All Columns" item (lines 148–157). This is the right native pattern.
- There is also `TablePro/Views/Results/ColumnVisibilityPopover.swift` - listed in the directory, separate from the header menu pathway.

**Recommendation**:
1. Keep the header `NSMenu` route. It is the standard macOS behavior (Finder list view, Mail, every other Apple table).
2. Audit `ColumnVisibilityPopover.swift` against §06 (HIG audit). If it is invoked from a toolbar button or a corner glyph, those entry points should funnel through the same header `NSMenu` items so behavior stays consistent. If the popover offers reordering or batch toggles that the menu lacks, retain only the unique features and bind them to `NSTableColumn.isHidden`.
3. The "Show All Columns" item should iterate `tableView.tableColumns` and set `column.isHidden = false`. AppKit's `autosaveTableColumns` (T1) persists the change.

Apple references:
- developer.apple.com/documentation/appkit/nstablecolumn/ishidden
- developer.apple.com/documentation/appkit/nstableview/menu
- developer.apple.com/documentation/appkit/nstableheaderview

(The "header has its own NSMenu attached at construction" idiom is exactly what `DataGridView.swift:93–96` already does - bind it to `NSTableView.headerView?.menu` instead of to the custom `SortableHeaderView` once T2 lands.)

---

## T14 - Floating editor placement: place on tableView, not as cell subview (Gridex pattern)

If for any reason a floating editor is retained after T3 (e.g. for a dedicated multi-line column type), match Gridex's placement:

```
// gridex/macos/Presentation/Views/DataGrid/AppKitDataGrid.swift:522–551
let cellRect = tableView.frameOfCell(atColumn: col, row: row)
let container = EditContainerView()
container.frame = cellRect
tableView.addSubview(container)  // direct child of tableView
tableView.window?.makeFirstResponder(editor)
```

Reasons:
- Tied to tableView's coordinate space → automatically clipped and translated when the table scrolls.
- First-responder changes do not destabilize the cell view hierarchy (Gridex audit comment at line 522 explicitly calls this out).
- No screen-coordinate math, no need to observe `boundsDidChangeNotification` to dismiss on scroll (Gridex's editor scrolls with the cell because it lives on the table).

TablePro's current `CellOverlayEditor` does the opposite - places a borderless `NSPanel` in screen coordinates (`CellOverlayEditor.swift:48, 60–66`) and has to observe scroll to dismiss (lines 125–134). This is precisely the failure mode T3 fixes.

Apple references:
- developer.apple.com/documentation/appkit/nstableview/frameofcell(atcolumn:row:)
- developer.apple.com/documentation/appkit/nsview/addsubview(_:)

---

## T15 - `KeyHandlingTableView.mouseDown` re-implements `editColumn:row:with:select:` start-edit on second click - keep it, but document the contract

`KeyHandlingTableView.swift:54–96`: the "click an already-focused cell once → start editing" UX. This is **not** an AppKit reimplementation - AppKit normally requires double-click. TablePro chose single-second-click for spreadsheet-style UX. Keep, but two adjustments:

1. The branch at line 89–95 currently calls `editColumn(clickedColumn, row: clickedRow, with: nil, select: true)`. It should also pass through `tableView(_:shouldEdit:row:)` for the eligibility check - which `editColumn(_:row:with:select:)` already does internally (AppKit calls the delegate before opening the field editor). Confirmed.
2. The `clickCount == 2 && clickedRow == -1` branch (line 61) calls `dataGridAddRow()` - double-click on empty space adds a row. This is a TablePro convention, not native, but is harmless; document it in the delegate protocol. Native macOS does nothing on table empty-space double-click.

Apple references:
- developer.apple.com/documentation/appkit/nstableview/editcolumn(_:row:with:select:)
- developer.apple.com/documentation/appkit/nstableviewdelegate/tableview(_:shouldedit:row:)

---

## T16 - Drop hand-rolled cursor handling in `SortableHeaderView`

`SortableHeaderView.resetCursorRects()` (lines 103–118), `viewDidMoveToWindow` (120), `layout` (125), `updateTrackingAreas` (130–143), `mouseMoved(with:)` (145–156), `isInResizeZone` (180–194). Once T2 deletes `SortableHeaderView`, these all go with it. AppKit's `NSTableHeaderView` already manages resize cursors on columns whose `resizingMask.contains(.userResizingMask)` is true - `DataGridColumnPool.configureColumn` already sets `resizingMask = .userResizingMask` (line 86), so the cursor is wired automatically when the stock header is restored.

Apple references:
- developer.apple.com/documentation/appkit/nstableheaderview
- developer.apple.com/documentation/appkit/nstablecolumn/resizingmask

---

## Net deletions and additions if T1–T7, T11, T12, T16 land

Files to delete:
- `TablePro/Views/Results/SortableHeaderView.swift` (288 lines)
- `TablePro/Views/Results/SortableHeaderCell.swift` (182 lines)
- `TablePro/Views/Results/CellOverlayEditor.swift` (243 lines)
- `Core/Storage/FileColumnLayoutPersister.swift` (size unknown - referenced by `DataGridView.swift:377`)
- `Models/.../ColumnLayoutState.swift` (struct - kept as a transient if needed for legacy migration only)

Code to delete inside surviving files:
- `TableViewCoordinator.savedColumnLayout`, `captureColumnLayout`, `persistColumnLayoutToStorage`, `currentSortState`, `onColumnLayoutDidChange`
- `DataGridView.syncSortDescriptors` (becomes a one-line `tableView.sortDescriptors = ...` push)
- `DataGridView.reloadAndSyncSelection` `needsFullReload` branch on row count delta - already redundant with `applyDelta`
- `KeyHandlingTableView.menu(for:)` (let AppKit route)
- `DataGridView+Editing.showOverlayEditor`, `commitOverlayEdit`, `handleOverlayTabNavigation`, `InlineEditEligibility.needsOverlayEditor` case
- `DataGridView+RowActions.undoInsertRow`'s `reloadData()` (use `removeRows(at:withAnimation:)`)

Code to add:
- `tableView.autosaveName = ...` and `tableView.autosaveTableColumns = true` in `makeNSView`
- `tableView(_:sortDescriptorsDidChange:)` on the data source (~10 lines)
- `windowWillReturnFieldEditor(_:to:)` on `EditorWindow` plus `MultilineFieldEditor` shared instance (~30 lines)
- `tableView(_:typeSelectStringFor:row:)` on the delegate (~10 lines)
- `tableView.menu = ...` (one line; populate via existing menu builder)
- One-time UserDefaults migration translating legacy `ColumnLayoutState` JSON into AppKit's `NSTableView Columns <autosaveName>` dictionary (~40 lines, runs once and is gone)

Net: roughly 700 lines removed, 100 lines added. Behavior identical or better (free incremental search, free multi-key sort with shift-click, free column-state restoration on relaunch).

---

## Summary table

| ID | Severity | TablePro file:line | Native API | Apple ref |
|---|---|---|---|---|
| T1 | HIGH | `DataGridCoordinator.swift:42, 56, 79`; `DataGridView.swift:218, 365`; `DataGridColumnPool.swift:27` | `NSTableView.autosaveName` + `autosaveTableColumns` | `nstableview/autosavename`, `nstableview/autosavetablecolumns` |
| T2 | HIGH | `SortableHeaderView.swift:207, 158`; `SortableHeaderCell.swift:32, 110`; `DataGridView.swift:264` | `sortDescriptorPrototype` + `tableView(_:sortDescriptorsDidChange:)` | `nstablecolumn/sortdescriptorprototype`, `nstableviewdatasource/tableview(_:sortdescriptorsdidchange:)` |
| T3 | HIGH | `CellOverlayEditor.swift:31, 148, 180`; `DataGridView+Editing.swift:78`; `KeyHandlingTableView.swift:209` | `editColumn:row:with:select:` + `windowWillReturnFieldEditor(_:to:)` returning multi-line `NSTextView` field editor | `nstableview/editcolumn(_:row:with:select:)`, `nswindowdelegate/windowwillreturnfieldeditor(_:to:)`, `nstextview/isfieldeditor` |
| T4 | MED | `DataGridCoordinator.swift:8` | Split into `DataGridDataSource`, `DataGridDelegate`, `DataGridFieldEditorController` | `nstableviewdatasource`, `nstableviewdelegate`, `nscontroltexteditingdelegate` |
| T5 | LOW | not implemented | `tableView(_:typeSelectStringFor:row:)` | `nstableviewdelegate/tableview(_:typeselectstringfor:row:)` |
| T6 | LOW | `DataGridView+RowActions.swift:36` (only mis-use) | `removeRows(at:withAnimation:)` | `nstableview/removerows(at:withanimation:)` |
| T7 | confirm | `DataGridView.swift:51` (set explicit `usesAutomaticRowHeights = false`) | `usesAutomaticRowHeights = false`, fixed `rowHeight` | `nstableview/usesautomaticrowheights` |
| T8 | LOW | `DataGridView.swift:65` | `intercellSpacing = .zero` (Gridex parity) | `nstableview/intercellspacing` |
| T9 | LOW | `DataGridView+RowActions.swift:178` (already correct) | Add `.tabularText` and `public.json` types | `nstableviewdatasource/tableview(_:pasteboardwriterforrow:)` |
| T10 | LOW | `DataGridView.swift:101, 154` | Set `draggingDestinationFeedbackStyle` once at construction | `nstableview/draggingdestinationfeedbackstyle` |
| T11 | LOW | not implemented | `tableView(_:selectionIndexesForProposedSelection:)` if/when needed | `nstableviewdelegate/tableview(_:selectionindexesforproposedselection:)` |
| T12 | MED | `KeyHandlingTableView.swift:333` | `tableView.menu` + `NSTableRowView.menu` | `nsview/menu`, `nsmenudelegate/menuneedsupdate(_:)` |
| T13 | LOW | `ColumnVisibilityPopover.swift` | Header `NSMenu` already does this; consolidate | `nstablecolumn/ishidden`, `nstableview/menu` |
| T14 | conditional | `CellOverlayEditor.swift:48, 60–66` | Place editor on `tableView` (Gridex `frameOfCell`) | `nstableview/frameofcell(atcolumn:row:)` |
| T15 | keep | `KeyHandlingTableView.swift:54–96` | Already routes through `editColumn(_:row:with:select:)` and `shouldEdit:row:` | `nstableviewdelegate/tableview(_:shouldedit:row:)` |
| T16 | LOW | `SortableHeaderView.swift:103–194` | Stock `NSTableHeaderView` cursor handling via `resizingMask` | `nstableheaderview` |

Severity legend: HIGH = correctness/maintenance debt that compounds over time, MED = cleanup that pays back across multiple files, LOW = quick win or polish.
