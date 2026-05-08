# 00 - Master Blueprint: TablePro DataGrid Native Rewrite

Source of truth for the native AppKit rewrite of the TablePro DataGrid. Every commit in this rewrite cites a stage from §5 of this document. Reconciles 9 specialist reports (`01-rendering.md` through `09-dead-redundant.md`) and the prior performance audit (`~/Downloads/DATAGRID_PERFORMANCE_AUDIT.md`) against the project rules in `TablePro/CLAUDE.md`.

Author: synthesizer (task #10). Date frozen: 2026-05-08.

---

## 1. Executive verdict

The DataGrid renders correct AppKit foundations (view-based `NSTableView`, fixed row height, `makeView(withIdentifier:)` reuse, modern drag and drop) but layers seven anti-patterns on top. A single visible viewport (30 rows × 20 columns = 600 cells) currently allocates 2,400 to 3,600 `CALayer` instances, runs 600 `CATransaction` open/commit pairs per `reloadData()`, formats every cell on the main thread inside `tableView(_:viewFor:row:)`, performs `O(n²)` row lookups during sort layout, and holds an unbounded `[RowID: [String?]]` display cache that can climb past 2 GB resident on a 1M-row × 20-column scan. The plugin boundary forces a full `[[String?]]` copy per page and the grid never uses the streaming variant the export pipeline already consumes.

Target: collapse the cell to one `NSView` with one layer, move all formatting to an `actor CellDisplayWarmer` consumed via an `actor StreamingDataGridStore`, replace `NSViewRepresentable` boilerplate with `NSViewControllerRepresentable` plus a `Snapshot`+`lastApplied` diff, adopt the streaming `PluginStreamElement` envelope across the plugin ABI (one bump), and delete five files (700+ lines) that AppKit primitives replace. After landing: visible viewport = 601 layers, zero per-cell `CATransaction`, zero formatting on main during scroll, `O(1)` `RowID → Int` lookup, `NSCache`-bounded display memory at 32 MB regardless of result size, first-paint latency under 500 ms on 1M-row queries.

---

## 2. Reconciled contradictions

Eight points where the specialist reports disagree, with verdicts.

| # | Contradiction | Verdict | Reason | Right / Wrong / Citation |
|---|---|---|---|---|
| 1 | NSPredicateEditor vs FilterPanelView | **MIGRATE to NSPredicateEditor + write `NSPredicate`-to-dialect-SQL visitor** (user decision 2026-05-08) | The native AppKit primitive at the user-facing surface gets accessibility, Reduce Transparency / Increase Contrast, VoiceOver, and HIG conformance for free. The dialect-specific SQL translation moves into a `PredicateSQLEmitter` visitor that handles MySQL backticks vs Postgres double-quotes vs MSSQL brackets, `LIKE` wildcard cases, `BETWEEN` with two scalars, and the `__RAW__` raw-SQL escape via a custom `NSPredicateEditorRowTemplate`. Stage 14 owns this migration. | HIG (06-hig-design-system.md H4) right on the surface; custom-vs-native (08-custom-vs-native.md A6) right that translation is the work item. Cite `AppKit/NSPredicateEditor.h`, `AppKit/NSPredicateEditorRowTemplate.h`, `Foundation/NSPredicate.h`, TablePro `Views/Filter/FilterPanelView.swift:8-248`. |
| 2 | NSPopUpButton/NSComboBox vs custom enum/FK pickers | **KEEP custom popovers, but rebuild content as native AppKit (NSPopover + NSStackView + NSSearchField + NSTableView)** | `NSPopUpButton` is non-searchable and breaks past ~30 enum members. `NSComboBox` allows free-text entry which corrupts FK values (must be one of the predefined rows). The right native primitive is `NSPopover` containing an `NSViewController` whose root is `NSStackView { NSSearchField, NSScrollView { NSTableView } }`. That eliminates the SwiftUI list, drops `NativeSearchField` from these two callers, and removes the `.onKeyPress(.return)` shim in `EnumPopoverContentView`/`ForeignKeyPopoverContentView`. | custom-vs-native (08 A8/A9) right on "do not switch to NSPopUpButton/NSComboBox"; SwiftUI-interop (05 S8) right on "the SwiftUI list is the wrong content"; HIG (06 H5) wrong on its primitive choice. Cite `AppKit/NSPopover.h`, `AppKit/NSTableView.h`, TablePro `Views/Results/EnumPopoverContentView.swift:12-99`, `Views/Results/ForeignKeyPopoverContentView.swift:12-184`. |
| 3 | ConnectionDataCache: NSCache vs NSMapTable | **NSMapTable.weakToWeakObjects** | `NSCache` (`Foundation/NSCache.h`) auto-evicts under memory pressure. The cached value is a long-lived `@Observable` view model with active `@Bindable` SwiftUI subscriptions and Combine `cancellables`. Eviction would silently invalidate live bindings and detach observers - a correctness bug, not a performance win. `NSMapTable<NSUUID, ConnectionDataCache>` constructed with `.strongMemory` keys and `.weakMemory` values (`Foundation/NSMapTable.h`) deallocates the cache only when no SwiftUI view holds a reference, which is the correct semantic. | custom-vs-native (08 N1) right; memory (07 §9) wrong. Cite `Foundation/NSMapTable.h`, TablePro `ViewModels/ConnectionDataCache.swift:13`. |
| 4 | SortableHeaderView vs sortDescriptorPrototype | **REPLACE for single-column sort path; KEEP custom drawing only for multi-column priority badges** | AppKit's `NSTableColumn.sortDescriptorPrototype` plus `tableView(_:sortDescriptorsDidChange:)` natively handles click detection, modifier-aware shift-click multi-key append, and the standard chevron indicator. The 288-line `SortableHeaderView` reimplements all of that. The one feature it adds that AppKit does not is multi-column sort priority badges ("1↑ 2↓"). The Apple-correct shape is: stock `NSTableHeaderView` plus `sortDescriptorPrototype` on every column, and the `NSTableHeaderCell.drawSortIndicator(withFrame:in:ascending:priority:)` API already draws priority numbers when `priority > 0`. We do NOT need a custom header class for this. The custom `mouseDown:`, `resetCursorRects`, `mouseMoved:`, and `updateTrackingAreas` overrides are pure dead weight - `NSTableHeaderView` already handles resize cursors when `column.resizingMask.contains(.userResizingMask)`, which `DataGridColumnPool.swift:86` already sets. | NSTableView API (03 T2/T16) right; custom-vs-native (08 A5) partially right (multi-sort dispatch is custom, drawing is not). The correct verdict combines them: replace the custom view + cell, keep the multi-sort *dispatch logic* in the delegate's `sortDescriptorsDidChange` callback. Cite `AppKit/NSTableColumn.h` `sortDescriptorPrototype`, `AppKit/NSTableHeaderCell.h` `drawSortIndicator`, TablePro `Views/Results/SortableHeaderView.swift:84-287`, `Views/Results/SortableHeaderCell.swift:32-110`. |
| 5 | CellOverlayEditor vs native field editor | **REPLACE with native field editor returned via `windowWillReturnFieldEditor:to:`** | The custom `CellOverlayEditor` builds a borderless `NSPanel` in screen coordinates and observes `boundsDidChangeNotification`/`columnDidResizeNotification` to dismiss on scroll/resize. AppKit's documented pattern for "replace the default single-line field editor with a multi-line `NSTextView`" is `NSWindowDelegate.windowWillReturnFieldEditor(_:to:)` returning a long-lived shared `NSTextView` with `isFieldEditor = true`. That editor lives inside the cell rect (placed there by `editColumn:row:with:select:`), follows scroll and column resize automatically, routes Return/Esc/Tab through the existing `NSControlTextEditingDelegate.control(_:textView:doCommandBy:)` implementation, and commits on blur via `NSControlTextEditingDelegate.control(_:textShouldEndEditing:)` for free. Sequel-Ace ships exactly this pattern: `Sequel-Ace/Source/Views/TextViews/SPTextView.{h,m}` is a long-lived multi-line `NSTextView` returned as the field editor for SQL editing controls. | NSTableView API (03 T3) right; rendering report (01 §3 reference to Gridex `EditContainerView`) compatible (Gridex's editor on tableView is a stylistic alternative; the field-editor route is more conservative and matches Sequel-Ace). Custom-vs-native (08 A4) wrong - `NSPanel.nonactivatingPanel` IS a native primitive but it is not the right one for in-cell editing; it is the right one for floating tool palettes, which is not what we have. Cite `AppKit/NSWindow.h` `windowWillReturnFieldEditor:to:`, `AppKit/NSTextView.h` `isFieldEditor`, `AppKit/NSTableView.h` `editColumn:row:with:select:`, Sequel-Ace `Source/Views/TextViews/SPTextView.{h,m}`, TablePro `Views/Results/CellOverlayEditor.swift:13-243`. |
| 6 | EditorTabBar live vs deleted | **EditorTabBar is GONE; CLAUDE.md is stale** | `grep -rn "EditorTabBar" --include="*.swift"` returns zero results in the current tree. CLAUDE.md still claims `EditorTabBar - pure SwiftUI tab bar`. The audit (DATAGRID_PERFORMANCE_AUDIT.md row H1) and HIG report (06 H1) treat it as live. Editor tabs are now native NSWindow tabs (`NSWindow.tabbingMode = .preferred` at `Core/Services/Infrastructure/TabWindowController.swift:60-64`). | custom-vs-native (08 A3) right; audit and HIG report wrong. Cite `AppKit/NSWindow.h` `tabbingMode`, TablePro `Core/Services/Infrastructure/TabWindowController.swift:60-64`, CLAUDE.md "Editor Architecture" bullet. |
| 7 | JSONHighlightPatterns regex caching | **RESOLVED - already cached, audit M5 was wrong** | File at `Views/Results/JSONHighlightPatterns.swift:18-22` declares `static let string`, `static let key`, `static let number`, `static let booleanNull`, each calling `compileJSONRegex(...)` once per type. Swift `static let` is `dispatch_once`-equivalent, thread-safe, never recompiled. Verified by direct grep. | memory (07 §5) right; audit M5 wrong. Cite TablePro `Views/Results/JSONHighlightPatterns.swift:18-22`. |
| 8 | Accessibility row/column index ranges | **RESOLVED - already shipping, audit H8 was wrong** | `Cells/DataGridBaseCellView.swift:130-131` calls `setAccessibilityRowIndexRange(NSRange(location: state.row, length: 1))` and `setAccessibilityColumnIndexRange(NSRange(location: state.columnIndex, length: 1))`. Verified by direct grep. | rendering (01 R10) right; HIG (06 H9) right; audit H8 wrong. Cite `AppKit/NSAccessibilityProtocols.h`, TablePro `Views/Results/Cells/DataGridBaseCellView.swift:130-131`. |

---

## 3. Audit corrections (truth table)

For every audit item that the team marked stale or wrong, list the original claim, the ground truth, and the evidence. These corrections need to flow back into `DATAGRID_PERFORMANCE_AUDIT.md` if it is ever re-run.

| Audit ID | Original audit claim | Ground truth | Evidence |
|---|---|---|---|
| H1 | "Custom `ResultTabBar` and `EditorTabBar`" | `EditorTabBar` does not exist. `ResultTabBar` is live. Editor tabs use native `NSWindow.tabbingMode = .preferred`. | `Core/Services/Infrastructure/TabWindowController.swift:60-64`, `grep -rn "EditorTabBar" --include="*.swift"` returns zero. |
| H8 | "Cells do not announce 'row X of Y' to VoiceOver" | Cells DO set `setAccessibilityRowIndexRange` and `setAccessibilityColumnIndexRange`. | `Views/Results/Cells/DataGridBaseCellView.swift:130-131`. |
| M5 | "`static let regex = try! NSRegularExpression(...)` not used; compiled per pass" | `JSONHighlightPatterns` declares all four regexes as `static let`, lazily initialized once. | `Views/Results/JSONHighlightPatterns.swift:18-22`. |
| C6 | "`displayCache` mutation not atomic if accessed concurrently" | `displayCache` is mutated only on `@MainActor`; `TableViewCoordinator` is `@MainActor`, all callers are too. The contract is silent, not broken. | `Views/Results/DataGridCoordinator.swift:8` (`final class TableViewCoordinator: NSObject, NSTableViewDelegate, ...`). The risk is documentation, not data races today. |
| (audit table 2.6 referenced "tab replacement guard" as broken) | n/a - the guard is documented in CLAUDE.md as an invariant and operates correctly | The active-work check runs before the preview-tab branch, per CLAUDE.md "Tab replacement guard" invariant. | CLAUDE.md "Invariants" section. |
| (audit footnote on `usesAutomaticRowHeights`) | Implies risk of accidental enable | Not set anywhere; AppKit default is `false`. | `Views/Results/DataGridView.swift:51` does not assign it. Recommended (T7) to set explicitly to make the contract visible. |

CLAUDE.md edit required at the "Editor Architecture" bullet to remove the `EditorTabBar` reference. See §5 stage 13 for the explicit edit.

---

## 4. Target architecture

Layered diagram. Each layer names the framework, the protocol/file in the new design, the threading model, and the ownership story.

```
+----------------------------------------------------------+
|  Plugin process                                          |
|  (loaded by PluginManager from .tableplugin bundle)      |
|                                                          |
|  PluginDatabaseDriver                                    |
|    func executeStreamingQuery(_:rowCap:parameters:)      |
|        -> AsyncThrowingStream<PluginStreamElement, Error>|
|                                                          |
|  PluginStreamElement (already exists for export):        |
|    case header(PluginStreamHeader)                       |
|    case rows([PluginRow])                                |
|    case metadata(executionTime, isTruncated, ...)        |
|                                                          |
|  Threading: plugin's own queue / OracleNIO event loop    |
|  Sendable: yes (Codable values across bundle boundary)   |
+--------------------------+-------------------------------+
                           |
                           |  AsyncThrowingStream
                           v
+----------------------------------------------------------+
|  In-process bridge                                       |
|                                                          |
|  PluginDriverAdapter (Core/Plugins/PluginDriverAdapter)  |
|    bridges PluginDatabaseDriver -> DatabaseDriver        |
|                                                          |
|  Threading: nonisolated, called via await from MainActor |
+--------------------------+-------------------------------+
                           |
                           v
+----------------------------------------------------------+
|  Data layer                                              |
|                                                          |
|  actor StreamingDataGridStore                            |
|    var rows: ContiguousArray<RowSlot>                    |
|    var indexByID: [RowID: Int]            // O(1)        |
|    let displayCache: NSCache<NSNumber,NSArray>           |
|    let changes: AsyncStream<DataGridChange>              |
|                                                          |
|    func cellDisplay(at:column:) -> CellDisplay           |
|    func prefetchRows(in:) async                          |
|    func replaceCell(at:column:with:) async               |
|    func appendInsertedRow(values:) async -> Int          |
|                                                          |
|  Threading: actor isolation                              |
|  Apple API: SE-0306 actor, SE-0314 AsyncStream,          |
|             Foundation/NSCache.h                         |
|  File: TablePro/Core/DataGrid/StreamingDataGridStore.swift|
+--------------------------+-------------------------------+
                           |
                           v
+----------------------------------------------------------+
|  Display layer                                           |
|                                                          |
|  actor CellDisplayWarmer                                 |
|    func warm(chunk:[PluginRow], columnTypes:,            |
|              displayFormats:, previewLength:Int)         |
|        -> ContiguousArray<ContiguousArray<String?>>      |
|                                                          |
|  CellDisplayFormatter (nonisolated, was @MainActor)      |
|  DateFormattingService (nonisolated, was @MainActor)     |
|  BlobFormattingService (nonisolated, was @MainActor)     |
|                                                          |
|  Threading: actor isolation, called from store actor     |
|  Apple API: SE-0306 actor                                |
|  File: TablePro/Core/DataGrid/CellDisplayWarmer.swift    |
+--------------------------+-------------------------------+
                           |  AsyncStream<DataGridChange>
                           v
+----------------------------------------------------------+
|  Coordinator (replaces TableViewCoordinator + extensions)|
|                                                          |
|  @MainActor final class DataGridViewController :         |
|    NSViewController                                      |
|                                                          |
|    // owns:                                              |
|    let scrollView: NSScrollView                          |
|    let tableView: KeyHandlingTableView                   |
|    let dataSource: DataGridDataSource                    |
|    let delegate: DataGridDelegate                        |
|    let fieldEditor: DataGridFieldEditorController        |
|    let columnPool: DataGridColumnPool                    |
|    let visualIndex: RowVisualIndex                       |
|    let store: any DataGridStore                          |
|                                                          |
|    // lifecycle:                                         |
|    override viewDidLoad()                                |
|    override viewWillAppear()                             |
|    override viewDidDisappear()                           |
|                                                          |
|    func bind(to store: DataGridStore)                    |
|    func apply(_ snapshot: Snapshot)                      |
|                                                          |
|  Threading: @MainActor                                   |
|  Apple API: AppKit/NSViewController.h, AppKit/NSTableView.h|
|  File: TablePro/Views/Results/DataGridViewController.swift|
+----+--------------+--------------+--------------+--------+
     |              |              |              |
     v              v              v              v
+----------+ +-----------+ +------------+ +---------------+
|DataSource| |Delegate   | |FieldEditor | |ColumnPool     |
|          | |           | |Controller  | |               |
|numberOf  | |viewFor:   | |windowWill- | |reconcile      |
|Rows      | |row:       | |Return-     | |columns        |
|sortDesc- | |rowViewFor:| |FieldEditor:| |               |
|Changed   | |row:       | |to:         | |               |
|paste-    | |should-    | |control(_:  | |               |
|board-    | |Edit:row:  | |textView:   | |               |
|Writer-   | |sizeToFit: | |doCommandBy:|                 |
|ForRow:   | |menuNeeds- | |)           |                 |
|drag/drop | |Update:    | |            |                 |
|valdat-   | |type-      | |            |                 |
|ion       | |Select-    | |            |                 |
|          | |StringFor: | |            |                 |
|@MainActor| |@MainActor | |@MainActor  | |@MainActor     |
+----------+ +-----------+ +------------+ +---------------+
                           |
                           v
+----------------------------------------------------------+
|  Bridge to SwiftUI                                       |
|                                                          |
|  struct DataGridView: NSViewControllerRepresentable {    |
|      typealias NSViewControllerType = DataGridViewController|
|                                                          |
|      func makeNSViewController(context:)                 |
|          -> DataGridViewController                       |
|      func updateNSViewController(_:context:)             |
|          let snapshot = Snapshot(...)                    |
|          guard snapshot != context.coordinator.lastApplied|
|              else { return }                             |
|          controller.apply(snapshot)                      |
|          context.coordinator.lastApplied = snapshot      |
|      func dismantleNSViewController(_:coordinator:)      |
|                                                          |
|      class Coordinator { var lastApplied: Snapshot? }    |
|  }                                                       |
|                                                          |
|  Threading: @MainActor (NSViewControllerRepresentable    |
|             is @MainActor by default)                    |
|  Apple API: SwiftUI/NSViewControllerRepresentable        |
|  File: TablePro/Views/Results/DataGridView.swift         |
+--------------------------+-------------------------------+
                           |
                           v
+----------------------------------------------------------+
|  Cell layer (one type per kind, one layer per cell)      |
|                                                          |
|  final class DataGridCellView: NSView {                  |
|      override init(frame:)                               |
|          wantsLayer = true                               |
|          layerContentsRedrawPolicy = .onSetNeedsDisplay  |
|          canDrawSubviewsIntoLayer = true                 |
|          // suppress implicit layer animations:          |
|          // override action(for:forKey:) -> NSNull       |
|                                                          |
|      override func draw(_ dirtyRect: NSRect)             |
|          // 1. fill changeBackground if set              |
|          //    color.setFill(); bounds.fill()            |
|          // 2. draw cached NSAttributedString            |
|          //    via .draw(with:options:context:)          |
|          // 3. draw accessory glyphs via NSImage.draw    |
|                                                          |
|      override func prepareForReuse()                     |
|          cachedAttrString = nil                          |
|                                                          |
|      override func mouseDown(with:)                      |
|          // hit-test accessory rects directly            |
|                                                          |
|  No subviews. No NSTextField. No NSButton.               |
|  No CellFocusOverlay. No backgroundView.                 |
|                                                          |
|  Threading: @MainActor                                   |
|  Apple API: AppKit/NSView.h, Foundation/NSStringDrawing.h|
|  File: TablePro/Views/Results/Cells/DataGridCellView.swift|
+----------------------------------------------------------+

+----------------------------------------------------------+
|  Row view                                                |
|                                                          |
|  final class DataGridRowView: NSTableRowView             |
|      override func drawBackground(in:)                   |
|          // draw change-state tint here, once per row    |
|      override func drawSelection(in:)                    |
|          // honor isEmphasized for inactive-window dim   |
|                                                          |
|  Apple API: AppKit/NSTableRowView.h                      |
|  File: TablePro/Views/Results/DataGridRowView.swift      |
+----------------------------------------------------------+

+----------------------------------------------------------+
|  Header                                                  |
|                                                          |
|  Stock NSTableHeaderView. Stock NSTableHeaderCell.       |
|  Each NSTableColumn has sortDescriptorPrototype set.     |
|  Multi-column sort priority badges drawn by AppKit       |
|  (drawSortIndicator: handles priority arg).              |
|                                                          |
|  Sort dispatch via DataGridDataSource.tableView(         |
|     _:sortDescriptorsDidChange:).                        |
|                                                          |
|  Apple API: AppKit/NSTableHeaderView.h, AppKit/NSTableHeaderCell.h|
+----------------------------------------------------------+

+----------------------------------------------------------+
|  Field editor                                            |
|                                                          |
|  EditorWindow.windowWillReturnFieldEditor(_:to:)         |
|     -> if cell.usesMultilineFieldEditor:                 |
|            return MultilineFieldEditor.shared            |
|        else:                                             |
|            return nil  // AppKit default                 |
|                                                          |
|  final class MultilineFieldEditor: NSTextView            |
|      static let shared = MultilineFieldEditor(frame:.zero)|
|      // isFieldEditor = true, allowsUndo = true          |
|                                                          |
|  Apple API: AppKit/NSWindow.h, AppKit/NSTextView.h       |
+----------------------------------------------------------+

+----------------------------------------------------------+
|  Focus overlay (single, on tableView)                    |
|                                                          |
|  final class FocusOverlayView: NSView                    |
|      // pinned to one cell's rect via                    |
|      // tableView.frameOfCell(atColumn:row:)             |
|      // toggled hidden on focus change                   |
|      override func draw(_:)                              |
|          // draw rounded border via NSBezierPath         |
|                                                          |
|  Apple API: AppKit/NSTableView.h frameOfCell(atColumn:row:),|
|             AppKit/NSBezierPath.h                        |
+----------------------------------------------------------+

+----------------------------------------------------------+
|  Visual state                                            |
|                                                          |
|  @MainActor final class RowVisualIndex                   |
|      var deleted: Set<Int>                               |
|      var inserted: Set<Int>                              |
|      var modifiedColumnsByRow: [Int: Set<Int>]           |
|      func apply(_ change: ChangeManagerDelta)            |
|      func state(for row: Int) -> RowVisualState          |
|                                                          |
|  Replaces rowVisualStateCache rebuild-from-scratch.      |
|  Apple API: standard Swift                               |
|  File: TablePro/Views/Results/RowVisualIndex.swift       |
+----------------------------------------------------------+
```

Layer ownership rules:

- The plugin returns `AsyncThrowingStream<PluginStreamElement, Error>`. It never owns Swift state past the stream lifetime.
- `StreamingDataGridStore` owns the row buffer, the display cache, the index map, and the change stream. Nothing else holds these directly.
- `CellDisplayWarmer` is invoked from the store actor; it holds no state across calls.
- `DataGridViewController` is `@MainActor`. It binds to the store's `changes: AsyncStream<DataGridChange>` once on `viewWillAppear`, drives `tableView.beginUpdates()` / `insertRows(at:withAnimation:)` / `endUpdates()` from the stream, and cancels the binding `Task` on `viewDidDisappear`.
- The SwiftUI `DataGridView` is `NSViewControllerRepresentable`. `updateNSViewController` builds one `Equatable` `Snapshot` and only calls `controller.apply(snapshot)` when the snapshot differs from `lastApplied`.
- Cells own no state past `prepareForReuse`. The cached `NSAttributedString` is invalidated there.
- Row views own change-state tinting and selection rendering. Cells never read `backgroundStyle` to make those decisions.

Apple API references (frameworks and headers):
- `AppKit/NSView.h` (`wantsLayer`, `layerContentsRedrawPolicy`, `canDrawSubviewsIntoLayer`, `action(for:forKey:)`, `noteFocusRingMaskChanged`, `draw(_:)`, `menu`)
- `AppKit/NSTableView.h` (`autosaveName`, `autosaveTableColumns`, `frameOfCell(atColumn:row:)`, `editColumn:row:with:select:`, `intercellSpacing`, `usesAutomaticRowHeights`, `gridStyleMask`, `draggingDestinationFeedbackStyle`, `selectionIndexesForProposedSelection`, `typeSelectStringFor:row:`, `reloadData(forRowIndexes:columnIndexes:)`, `insertRows(at:withAnimation:)`, `removeRows(at:withAnimation:)`)
- `AppKit/NSTableColumn.h` (`sortDescriptorPrototype`, `isHidden`, `resizingMask`)
- `AppKit/NSTableHeaderView.h` (stock cursor handling)
- `AppKit/NSTableHeaderCell.h` (`drawSortIndicator(withFrame:in:ascending:priority:)`)
- `AppKit/NSTableRowView.h` (`drawBackground(in:)`, `drawSelection(in:)`, `isEmphasized`, `interiorBackgroundStyle`)
- `AppKit/NSWindow.h` (`windowWillReturnFieldEditor:to:`, `tabbingMode`, `isRestorable`, `representedURL`, `subtitle`)
- `AppKit/NSWindowRestoration.h` (`encodeRestorableState(with:)`, `restoreState(with:)`)
- `AppKit/NSTextView.h` (`isFieldEditor`)
- `AppKit/NSPanel.h` (`nonactivatingPanel` for QuickSwitcher only)
- `AppKit/NSPopover.h` (FK and Enum content rebuild)
- `AppKit/NSAccessibilityProtocols.h` (`setAccessibilityRowIndexRange`, `setAccessibilityColumnIndexRange`)
- `AppKit/NSBezierPath.h` (focus overlay drawing)
- `AppKit/NSGraphicsContext.h` (`NSColor.setFill`, `NSRect.fill`)
- `Foundation/NSCache.h` (`countLimit`, `totalCostLimit`, `evictsObjectsWithDiscardedContent`)
- `Foundation/NSMapTable.h` (`weakToWeakObjects`)
- `Foundation/NSStringDrawing.h` (`NSAttributedString.draw(with:options:context:)`)
- `QuartzCore/CAAction.h` (`NSNull` as no-op action)
- Swift Concurrency: SE-0306 (actors), SE-0314 (`AsyncStream`, `AsyncThrowingStream`), SE-0329 (`Clock`, `Duration`, `Task.sleep(for:)`), SE-0395 (`@Observable`)
- SwiftUI: `NSViewControllerRepresentable`

---

## 5. Refactor sequence

Each stage is one PR. Each PR compiles, passes tests, ships to users without regressions. Per CLAUDE.md "Atomic API changes" rule, every stage that renames or changes a signature updates every caller and every test in the same commit. No stage leaves the codebase mid-refactor between commits.

The sequence is ordered by dependency. Earlier stages set up the contracts later stages need. No stage may be reordered without re-validating that the codebase still compiles and ships.

### Stage 1 - Cell collapse: one NSView, one layer, redraw policy

Goal: replace `DataGridBaseCellView` plus seven empty subclasses with a single `DataGridCellView` that has one layer with `.onSetNeedsDisplay` redraw policy, removes `CellFocusOverlay`, removes the per-cell `backgroundView`, removes the per-cell `CATransaction`, and draws text and accessories directly via `NSAttributedString.draw(with:options:context:)` and `NSImage.draw(in:)`. Add `DataGridRowView: NSTableRowView` for change-state tinting and selection rendering. Add a single `FocusOverlayView` owned by the table view.

Touched files:
- Added: `Views/Results/Cells/DataGridCellView.swift`, `Views/Results/DataGridRowView.swift`, `Views/Results/FocusOverlayView.swift`
- Modified: `Views/Results/Cells/DataGridCellRegistry.swift` (collapse the seven kind-specific subclasses to a single `DataGridCellView` plus a `DataGridCellKind` flag), `Views/Results/Cells/DataGridCellAccessoryDelegate.swift`, `Views/Results/TableRowViewWithMenu.swift` (renamed/replaced by `DataGridRowView`), `Views/Results/KeyHandlingTableView.swift` (owns `focusOverlay`), `Views/Results/DataGridView.swift` (use `DataGridRowView` from `tableView(_:rowViewForRow:)`)
- Deleted: `Views/Results/Cells/DataGridBaseCellView.swift`, `Views/Results/Cells/CellFocusOverlay.swift`, `Views/Results/Cells/DataGridBlobCellView.swift`, `Views/Results/Cells/DataGridBooleanCellView.swift`, `Views/Results/Cells/DataGridDateCellView.swift`, `Views/Results/Cells/DataGridDropdownCellView.swift`, `Views/Results/Cells/DataGridJsonCellView.swift`, `Views/Results/Cells/DataGridChevronCellView.swift`, `Views/Results/Cells/DataGridForeignKeyCellView.swift`, `Views/Results/Cells/DataGridTextCellView.swift`, `Views/Results/Cells/AccessoryButtons.swift`

API surface delta:
- `DataGridBaseCellView` symbol gone. Coordinator references update to `DataGridCellView`.
- `DataGridCellKind` becomes a simple enum (`text`, `foreignKey`, `dropdown`, `boolean`, `date`, `json`, `blob`) used by `DataGridCellView` to decide accessory glyphs at draw time.
- No PluginKit ABI bump.

New tests required:
- `TableProTests/DataGridCellViewTests.swift` - drawing test that pre-renders an `NSImage` of a configured cell and asserts pixel-level equality vs a baseline. Use `bitmapImageRep(forCachingDisplayIn:)`/`cacheDisplay(in:to:)`.
- `TableProTests/DataGridRowViewTests.swift` - `drawBackground(in:)` produces the expected change-state fill.
- `TableProTests/FocusOverlayViewTests.swift` - overlay positions itself correctly via `tableView.frameOfCell(atColumn:row:)`.

Risk and rollback: high test surface (every cell kind), but the change is mechanical. If a regression appears, revert the deletion and the registry change as one PR.

Why this ordering: the cell layer is the largest single contributor to scroll lag (R1/R2/R3/R4/R5 all converge here). Stages 2 onwards depend on the cell being a single `NSView` for the snapshot diff (stage 9) and the data path (stages 3-7) to work without re-introducing per-cell layer cost.

---

### Stage 2 - Display cache as NSCache + index-aligned slots

Goal: replace the unbounded `[RowID: [String?]]` `displayCache` with `NSCache<NSNumber, NSArray>` (or `NSCache<NSNumber, RowDisplayBox>`) keyed by display index. Pre-allocate `ContiguousArray<String?>` slots once per row instead of `Array(repeating:)`-and-append on every cache miss. Add `indexByID: [RowID: Int]` to `TableRows` for `O(1)` reverse lookup. Replace `pruneDisplayCacheToAliveIDs()` filter-then-allocate with in-place removal.

Touched files:
- Modified: `Views/Results/DataGridCoordinator.swift` (cache type swap, `indexByID` use), `Models/Query/TableRows.swift` (add `indexByID`), `Models/Query/Row.swift` (use `ContiguousArray<String?>`)
- Added: `Core/DataGrid/RowDisplayBox.swift` (the boxed `NSArray`-compatible cache value)

API surface delta:
- `TableRows.index(of:)` becomes `O(1)` instead of `O(n)`. Same signature.
- `Row.values: [String?]` becomes `Row.values: ContiguousArray<String?>`. Every caller updates in the same commit.
- `displayCache` field type changes; the property is `private` so callers do not see the change.

New tests required:
- `TableProTests/TableRowsTests.swift` - `indexByID` stays in lockstep with `rows` across `appendInsertedRow`, `insertInsertedRow`, `appendPage`, `removeIndices`, `replace(rows:)`.
- `TableProTests/DisplayCacheBoundedTests.swift` - `NSCache.totalCostLimit` enforces an RAM ceiling under sustained insertion.
- `TableProTests/DisplayCacheCorrectnessTests.swift` - cache hit returns the same string the formatter would produce.

Risk and rollback: medium. The `Row.values` type change touches every caller; the compiler enforces atomicity. Revert is a single commit revert.

Why this ordering: the rest of the data-path stages assume `O(1)` `RowID → Int` and a bounded cache. Without those, stages 3-5 cannot demonstrate the latency wins.

---

### Stage 3 - RowVisualIndex incremental updates

Goal: replace `rebuildVisualStateCache()` (rebuilds `[Int: RowVisualState]` from scratch on every change) with `RowVisualIndex` that applies each `ChangeManagerDelta` incrementally. Drop the `currentVersion != lastVisualStateCacheVersion` short-circuit; it never short-circuited in practice because every edit bumps the version.

Touched files:
- Added: `Views/Results/RowVisualIndex.swift`
- Modified: `Views/Results/DataGridCoordinator.swift` (delete `rebuildVisualStateCache()` and `rowVisualStateCache`, route every delta through `visualIndex.apply(_:)`)

API surface delta:
- `TableViewCoordinator.rebuildVisualStateCache()` deleted. Callers (`applyInsertedRows`, `applyRemovedRows`, `applyDelta`, `updateNSView`) call `visualIndex.apply(delta)` instead.

New tests required:
- `TableProTests/RowVisualIndexTests.swift` - covers each delta kind (`cellEdited`, `rowDeleted`, `rowInserted`, `changesCommitted`, `changesDiscarded`).

Risk and rollback: low. Internal implementation change, no external API delta.

Why this ordering: stages 4 and beyond move work off-main; the visual index needs to be `@MainActor` only (it drives undo/redo and selection chrome). Settling its shape now lets the store actor in stage 4 ignore visual state entirely.

---

### Stage 4 - actor StreamingDataGridStore behind protocol

Goal: introduce `protocol DataGridStore: Sendable` and `actor StreamingDataGridStore`. The store owns the row buffer, the display cache (now living on the actor), and the change stream. The coordinator holds a `let store: any DataGridStore`. The store is initialized but does not yet stream; it loads via the existing non-streaming `executeUserQuery(query:rowCap:parameters:)` and yields one `.fullReplace` change to the coordinator. This lets us validate the actor isolation and the change-stream loop without bumping the plugin ABI.

Touched files:
- Added: `Core/DataGrid/DataGridStore.swift` (protocol), `Core/DataGrid/StreamingDataGridStore.swift` (actor implementation), `Core/DataGrid/DataGridChange.swift` (enum), `Core/DataGrid/DisplaySnapshot.swift` (Sendable struct), `Core/DataGrid/CellDisplay.swift`, `Core/DataGrid/CellState.swift`
- Modified: `Views/Results/DataGridCoordinator.swift` (subscribe to `store.changes` once on attach, replace the property fan-out with a `Snapshot` consumed via `apply(snapshot:)`), `Views/Main/MainContentCoordinator.swift` (creates `StreamingDataGridStore` instead of mutating `TableRows` directly)

API surface delta:
- `tableRowsProvider: () -> TableRows` and `tableRowsMutator: ((inout TableRows) -> Void) -> Void` closures gone from `DataGridView`. Replaced by `let store: any DataGridStore`.
- `Delta` enum (in `TableRowsController`) replaced by `DataGridChange`.
- `CellDisplayFormatter`, `DateFormattingService`, `BlobFormattingService` change from `@MainActor` to `nonisolated`. All callers updated.

New tests required:
- `TableProTests/StreamingDataGridStoreTests.swift` - actor init, `cellDisplay(at:column:)` returns expected formatted strings, `changes` stream emits in order, cancellation tears down cleanly.
- `TableProTests/CellDisplayFormatterNonisolatedTests.swift` - formatter produces identical output called from any context.

Risk and rollback: high. This is the largest single change. Mitigation: gate the new path behind a feature flag for one release if needed (per CLAUDE.md "no feature flags" rule, only if a regression is found in beta - and the flag is removed before final).

Why this ordering: stages 5-7 build on the actor. Without the store as the single owner of row state, off-main formatting and streaming have no coherent home.

---

### Stage 5 - Off-main CellDisplayWarmer

Goal: introduce `actor CellDisplayWarmer` invoked from `StreamingDataGridStore`. Move the formatting work that today runs in `preWarmDisplayCache(upTo:)` synchronously inside `updateNSView` to the warmer. The store calls `await warmer.warm(chunk:columnTypes:displayFormats:previewLength:)` and stores the result in its `NSCache`. The coordinator only ever reads the warmed cache synchronously from `tableView(_:viewFor:row:)`. Settings changes (date format, null display, smart value detection) trigger a re-warm of the visible window via the warmer; never on main.

Touched files:
- Added: `Core/DataGrid/CellDisplayWarmer.swift`
- Modified: `Core/DataGrid/StreamingDataGridStore.swift` (own and call the warmer), `Views/Results/DataGridCoordinator.swift` (delete `preWarmDisplayCache(upTo:)`, the settings-change handler now `await store.reformatVisibleWindow(...)`)
- Deleted: `preWarmDisplayCache(upTo:)` method on the coordinator (was at `DataGridCoordinator.swift:305-327`)

API surface delta:
- `TableViewCoordinator.preWarmDisplayCache(upTo:)` deleted. `DataGridView.updateNSView` no longer calls it.
- New `previewLength: Int` parameter on `cellDisplay`. Grid passes 300; export passes `Int.max`.

New tests required:
- `TableProTests/CellDisplayWarmerTests.swift` - warm produces correct strings for date, blob, JSON, NULL, large strings (truncation at `previewLength`).
- `TableProTests/DataGridStoreSettingsChangeTests.swift` - settings change triggers re-warm; no main-thread blocking occurs.

Risk and rollback: medium. Single-file revert.

Why this ordering: stage 6 (streaming plugin) needs the warmer to consume chunks as they arrive. Without off-main formatting, streaming would just move the bottleneck.

---

### Stage 6 - Plugin ABI bump: streaming envelope for grid path

Goal: `PluginDatabaseDriver` gains `executeStreamingQuery(_:rowCap:parameters:)` returning `AsyncThrowingStream<PluginStreamElement, Error>`. Default implementation wraps `execute(query:)` in chunks of 1,000. Built-in plugins (PostgreSQL, MySQL, ClickHouse) override with native streaming via wire-protocol-level cursors (PostgreSQL `PQgetRow`, MySQL `mysql_fetch_row`, ClickHouse native row decoder). `StreamingDataGridStore.start(...)` consumes the stream and yields `DataGridChange.rowsAppended` per chunk. Bump `currentPluginKitVersion` and every plugin's `TableProPluginKitVersion`. **This is a hard plugin compatibility break.**

Touched files:
- Modified: `Plugins/TableProPluginKit/Sources/TableProPluginKit/PluginDatabaseDriver.swift` (add the new method with default impl), `Plugins/TableProPluginKit/Sources/TableProPluginKit/PluginQueryResult.swift` (add `metadata` case to `PluginStreamElement` for executionTime/isTruncated/statusMessage flow), `Core/Plugins/PluginManager.swift` (bump `currentPluginKitVersion`), every plugin's `Info.plist` (`TableProPluginKitVersion`), every plugin's main class (override `executeStreamingQuery` for native streaming where available)
- Modified: `Core/Plugins/PluginDriverAdapter.swift` (bridge new method to `DatabaseDriver`)
- Modified: `Core/DataGrid/StreamingDataGridStore.swift` (consume the stream)

API surface delta:
- `PluginDatabaseDriver` adds a new required method (with default implementation, so old plugins compile against new headers, but ABI mismatch on load triggers `EXC_BAD_INSTRUCTION` per CLAUDE.md). Stale user-installed plugins refuse to load. Distribution must update every plugin in lockstep.
- `currentPluginKitVersion` bumps by 1.
- `PluginStreamElement.metadata(executionTime:rowsAffected:isTruncated:statusMessage:)` added.

New tests required:
- `TableProTests/PluginStreamingTests.swift` - default-impl bridge produces a stream that yields the same data as `execute(query:)`.
- `TableProTests/PluginStreamingPostgresTests.swift` (etc. for each native-streaming plugin) - large queries stream incrementally; first chunk arrives before query finishes.
- `TableProTests/PluginKitVersionMismatchTests.swift` - confirms `EXC_BAD_INSTRUCTION` is caught at load time when plugin's `TableProPluginKitVersion` does not match `currentPluginKitVersion`.

Risk and rollback: very high. This is a plugin ABI break. Per CLAUDE.md: "stale user-installed plugins with mismatched versions crash on load with `EXC_BAD_INSTRUCTION` (not catchable in Swift)." Mitigation: ship every plugin update simultaneously with the app update; never partial-roll. Revert is a single commit revert plus a coordinated plugin re-release.

Why this ordering: streaming is the prerequisite for the first-paint-under-500ms target on 1M-row queries. It must follow the store actor (stage 4) and the warmer (stage 5) so the chunks have somewhere coherent to land. It must precede the AsyncStream-driven coordinator binding (stage 8) so the change stream is the genuine driver.

---

### Stage 7 - Debounced AsyncStream + structured-concurrency cleanup

Goal: drop every redundant `Task { @MainActor in ... }` hop that already runs on main (CellOverlayEditor `boundsDidChange` observers - these go away in stage 11; `DataGridView+Editing.swift:202-205, 224-227` selectors; `DataGridCoordinator.swift:186-194` teardown). Replace `DispatchQueue.main.asyncAfter` with cancellable `Task.sleep(for:)` in `ResultsJsonView`, `JSONSyntaxTextView`, `HexEditorContentView`. Move `JsonRowConverter.generateJson` and `JSONTreeParser.parse` off main via `Task.detached(priority: .userInitiated)` with a generation token. Add a single coordinator-side debounce of 100ms on the `store.changes` stream. Replace the three `DataGridCoordinator` Combine cancellables (settings/theme/teardown) with one `eventTask: Task<Void, Never>?` consuming `AppEvents.shared.dataGridEvents: AsyncStream<DataGridEvent>`.

Touched files:
- Modified: `Views/Results/DataGridCoordinator.swift` (single event task replaces three cancellables, ensure `releaseData()` cancels it before nilling `delegate`), `Views/Results/Extensions/DataGridView+Editing.swift` (drop two unstructured Tasks), `Views/Results/ResultsJsonView.swift` (off-main JSON parse with token, cancellable cooldown), `Views/Results/JSONSyntaxTextView.swift`, `Views/Results/HexEditorContentView.swift`, `Core/Events/AppEvents.swift` (add `dataGridEvents` stream alongside the Combine subjects)
- Added: `Core/Concurrency/CooldownTimer.swift` (shared cancellable Task wrapper)

API surface delta:
- `AppEvents.shared.dataGridEvents: AsyncStream<DataGridEvent>` is new. The Combine `PassthroughSubject` properties stay for backward compatibility.
- `CooldownTimer` is a new helper. Internal use only.
- All settings-change / theme-change handlers move to the unified event loop.

New tests required:
- `TableProTests/DataGridCoordinatorEventLoopTests.swift` - single event Task receives every kind of `DataGridEvent`; cancellation on `releaseData()` cleanly tears down without leaking observers.
- `TableProTests/CooldownTimerTests.swift` - `schedule(after:_:)` cancels prior, fires once.
- `TableProTests/ResultsJsonViewOffMainTests.swift` - selection change does not block main thread for >16ms with 5K-row selections.

Risk and rollback: medium. The unstructured-Task cleanup is mechanical; the AppEvents AsyncStream addition is additive. Revert is a single commit revert.

Why this ordering: stages 4-6 introduced the store and the streaming plugin; stage 7 makes the coordinator's binding to those pure structured concurrency. Without this, the structured-concurrency story is half-done.

---

### Stage 8 - NSViewControllerRepresentable + Snapshot diff

Goal: replace `struct DataGridView: NSViewRepresentable` with `struct DataGridView: NSViewControllerRepresentable`. The new `DataGridViewController: NSViewController` owns the scroll view, the table view, the column pool, the data source, the delegate, the field editor controller, and the visual index. `updateNSViewController` builds one `Equatable` `Snapshot` and only calls `controller.apply(snapshot)` when the snapshot differs from `coordinator.lastApplied`. `dataGridAttach(...)` fires only when `delegate` identity changes. The duplicate `coordinator.updateCache()` call goes away.

Touched files:
- Added: `Views/Results/DataGridViewController.swift`, `Views/Results/DataGridSnapshot.swift`
- Modified: `Views/Results/DataGridView.swift` (becomes thin `NSViewControllerRepresentable`), `Views/Results/DataGridCoordinator.swift` (the existing class loses the AppKit ownership - `tableView`, scrollview lifetimes - to the view controller, becomes a context object)

API surface delta:
- `DataGridView` becomes `NSViewControllerRepresentable`. `makeNSView`/`updateNSView`/`dismantleNSView` replaced by `makeNSViewController`/`updateNSViewController`/`dismantleNSViewController`.
- `Snapshot` is a new `Equatable` struct.
- The 25 properties on the coordinator that today are reassigned per `updateNSView` move into `Snapshot`.

New tests required:
- `TableProTests/DataGridViewControllerTests.swift` - view controller lifecycle (`viewDidLoad`, `viewWillAppear`, `viewDidDisappear`) wires up cleanly; `apply(snapshot:)` only modifies AppKit when the snapshot changes.
- `TableProTests/DataGridSnapshotEquatableTests.swift` - `Snapshot` correctly identifies meaningful changes (rows reordered, columns hidden) and ignores no-op rebindings.

Risk and rollback: medium. The change is mechanical but touches the SwiftUI/AppKit seam, which is where misuse historically caused leaks. Revert is one PR.

Why this ordering: stages 1-7 reduced the work the coordinator does per `updateNSView`. Stage 8 makes that work conditional via the diff. Without 1-7, the diff would gate work that is itself slow.

---

### Stage 9 - Native AppKit table behaviors: autosave, sort, field editor, type-select, drag-drop, menu

Goal: drop ~700 lines of custom AppKit reimplementation. Specifically:
- Set `tableView.autosaveName` and `tableView.autosaveTableColumns = true`. Delete `FileColumnLayoutPersister`, `ColumnLayoutState`, `captureColumnLayout`, `persistColumnLayoutToStorage`, `savedColumnLayout(binding:)`, the `onColumnLayoutDidChange` callback, the `@Binding columnLayout`, and the `DataGridColumnPool.reconcile(savedLayout:)` parameter. Add a one-time `UserDefaults` migration from the legacy JSON file to the AppKit-native key (`NSTableView Columns <autosaveName>`).
- Set every `NSTableColumn.sortDescriptorPrototype = NSSortDescriptor(key: name, ascending: true)`. Implement `tableView(_:sortDescriptorsDidChange:)` on `DataGridDataSource`. Restore stock `NSTableHeaderView` and `NSTableHeaderCell`. Delete `SortableHeaderView.swift` (288 lines), `SortableHeaderCell.swift` (182 lines), `HeaderSortCycle` enum, `HeaderSortTransition`, `currentSortState` mirror.
- Add `usesMultilineFieldEditor: Bool` to `CellTextField`. Make `EditorWindow` implement `windowWillReturnFieldEditor(_:to:)` returning `MultilineFieldEditor.shared` (a long-lived `NSTextView` with `isFieldEditor = true`). Delete `CellOverlayEditor.swift` (243 lines), `CellOverlayPanel`, `OverlayTextView`, `showOverlayEditor`, `commitOverlayEdit`, `handleOverlayTabNavigation`, `InlineEditEligibility.needsOverlayEditor`, the `KeyHandlingTableView.insertNewline` overlay branch.
- Add `tableView(_:typeSelectStringFor:row:)` for free incremental search on the first non-row-number column.
- Replace `KeyHandlingTableView.menu(for:)` manual routing with `tableView.menu = makeEmptySpaceMenu()` plus `rowView.menu = makeRowMenu(for:)` set in `tableView(_:rowViewForRow:)`.
- Set `tableView.intercellSpacing = NSSize(width: 0, height: 0)` and `gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]` (Gridex parity).
- Set `tableView.usesAutomaticRowHeights = false` explicitly.
- Switch `undoInsertRow(at:)` from `tableView.reloadData()` to `tableView.removeRows(at: IndexSet(integer: index), withAnimation: .slideUp)`.
- Set `tableView.draggingDestinationFeedbackStyle = .gap` once in `viewDidLoad`, not inside the conditional drop-types block.

Touched files:
- Modified: `Views/Results/DataGridViewController.swift` (autosave name, type-select, menu wiring, intercell spacing, usesAutomaticRowHeights), `Views/Results/DataGridDataSource.swift` (split out in stage 8; `sortDescriptorsDidChange`), `Views/Results/DataGridFieldEditorController.swift` (split out in stage 8), `Views/Results/DataGridDelegate.swift`, `Views/Results/DataGridColumnPool.swift` (drop `savedLayout`), `Views/Results/CellTextField.swift` (add `usesMultilineFieldEditor`, the multi-line `MultilineFieldEditor.shared`), `Views/Results/Extensions/DataGridView+RowActions.swift` (`undoInsertRow` uses `removeRows`), `Views/Results/Extensions/DataGridView+Editing.swift` (drop `showOverlayEditor` and friends), `Core/Services/Infrastructure/EditorWindow.swift` or `MainContentView+Setup.swift` (`windowWillReturnFieldEditor`), `Views/Results/KeyHandlingTableView.swift` (drop `menu(for:)` override and `insertNewline` overlay branch)
- Added: `Views/Results/MultilineFieldEditor.swift` (one shared instance), `Core/Storage/LegacyColumnLayoutMigration.swift` (one-time migration helper)
- Deleted: `Views/Results/SortableHeaderView.swift`, `Views/Results/SortableHeaderCell.swift`, `Views/Results/CellOverlayEditor.swift`, `Core/Storage/FileColumnLayoutPersister.swift`, `Models/UI/ColumnLayoutState.swift` (kept only as a transient migration source)

API surface delta:
- `TableViewCoordinator.savedColumnLayout`, `captureColumnLayout`, `persistColumnLayoutToStorage`, `currentSortState`, `onColumnLayoutDidChange` deleted.
- `DataGridView.syncSortDescriptors` becomes a one-line `tableView.sortDescriptors = newDescriptors`.
- `KeyHandlingTableView.menu(for:)` override deleted.
- `InlineEditEligibility.needsOverlayEditor` case deleted.
- `CellTextField` gains `usesMultilineFieldEditor: Bool`.

New tests required:
- `TableProTests/AutosaveColumnLayoutTests.swift` - column resize/reorder/hide is persisted across `dismantleNSViewController`/`makeNSViewController` round-trip via UserDefaults; legacy JSON file is migrated once and deleted.
- `TableProTests/SortDescriptorsTests.swift` - single-column sort cycles asc → desc → cleared (third click clears via post-filter in `sortDescriptorsDidChange`); shift-click appends; multi-column priority badges render correctly via stock `NSTableHeaderCell.drawSortIndicator`.
- `TableProTests/FieldEditorTests.swift` - multi-line cells get the `MultilineFieldEditor`; single-line cells get the default; Return commits, Esc cancels, Tab advances, Option-Return inserts newline.
- `TableProTests/TypeSelectTests.swift` - typing prefix on the table view scrolls to and selects the matching row.
- `TableProTests/UndoInsertRowAnimatedTests.swift` - `undoInsertRow` uses animated removal, not full reload.

Risk and rollback: medium. Five files deleted, four added, large API contract change. Each sub-bullet is technically reversible independently, but the autosave migration is a UserDefaults write that should not be reverted blindly (the legacy JSON file is deleted post-migration).

Why this ordering: stages 1-8 stabilized the cell, the data path, the actor, the streaming plugin, the structured concurrency, and the snapshot diff. Stage 9 deletes the custom code that those stages obviated. It is the largest deletion in the rewrite (~700 lines net).

---

### Stage 10 - SwiftUI interop cleanups: Snapshot boundary, single-source searchText, popover content rebuild

Goal: replace `PopoverPresenter`'s "NSPopover → NSHostingController → SwiftUI body containing NSViewRepresentable" triple-nest (S3) with two helpers - `AppKitPopover.show(controller:)` for AppKit-content popovers and direct SwiftUI `.popover(isPresented:)` for SwiftUI-content popovers. Migrate `EnumPopoverContentView` and `ForeignKeyPopoverContentView` to `NSPopover` containing an `NSViewController` whose root is `NSStackView { NSSearchField, NSScrollView { NSTableView } }`. Migrate `FilterValueTextField`'s suggestion dropdown to the same shape. Drop `SidebarViewModel.searchText` (S6); keep the value only in `SharedSidebarState`; read directly via `@Bindable var sidebarState`. Replace `FilterValueTextField.SuggestionState` `ObservableObject` with `@Observable` (S2) and switch its `id: \.offset` to `id: \.self`.

Touched files:
- Added: `Views/Components/AppKitPopover.swift` (the `show(controller:)` helper), `Views/Results/EnumPopoverViewController.swift` (AppKit native), `Views/Results/ForeignKeyPopoverViewController.swift` (AppKit native), `Views/Filter/SuggestionDropdownViewController.swift` (AppKit native)
- Modified: `Views/Filter/FilterValueTextField.swift` (use `AppKitPopover.show(controller:)` and the new `SuggestionDropdownViewController`; drop the `NSEvent.addLocalMonitorForEvents` shim - `NSPopover` with the AppKit content routes Escape/Return through the responder chain natively), `ViewModels/SidebarViewModel.swift` (drop `searchText`), `Views/Sidebar/SidebarView.swift` (read `sidebarState.searchText` directly), `Views/Results/DataGridView+Popovers.swift` (callers use the AppKit popover for FK/Enum)
- Deleted: `Views/Components/PopoverPresenter.swift`, `Views/Results/EnumPopoverContentView.swift`, `Views/Results/ForeignKeyPopoverContentView.swift`, `Views/Filter/SuggestionDropdownView` (the SwiftUI inner view inside `FilterValueTextField.swift`)

API surface delta:
- `PopoverPresenter` deleted. Two new helpers replace it.
- `FilterValueTextField.SuggestionState` becomes an `@Observable` class.
- `SidebarViewModel.searchText` deleted; bindings to it from views replaced with bindings to `SharedSidebarState.searchText`.

New tests required:
- `TableProTests/AppKitPopoverTests.swift` - popover lifecycle, key event routing, dismiss on outside click.
- `TableProTests/EnumPopoverViewControllerTests.swift` - selection, search filter, Return commits, Esc cancels.
- `TableProTests/ForeignKeyPopoverViewControllerTests.swift` - async fetch cancellation on dismiss; large lists scroll smoothly.
- `TableProTests/SidebarSearchTextSingleSourceTests.swift` - writes to one source flow to all readers without sync drift.

Risk and rollback: medium. Several SwiftUI views become AppKit view controllers. Each is locally testable. Revert is per-component.

Why this ordering: stages 1-9 settled the data grid itself. Stage 10 is the surrounding chrome that depends on the same SwiftUI/AppKit boundary rules established in stage 8. Sidebar tree (Redis `NSOutlineView` migration, SwiftUI-interop S5) is **not** in this stage - it is independent and will be tracked separately.

---

### Stage 11 - HIG corrections: QuickSwitcher NSPanel, color assets, window restoration, Spotlight intents, services, toolbar identifier

Goal: address the remaining HIG findings that do not depend on the data grid rewrite.
- Replace QuickSwitcher's `.sheet(item:)` presentation with `NSPanel` styled `[.nonactivatingPanel, .titled, .fullSizeContentView]`, `becomesKeyOnlyIfNeeded = true`, `hidesOnDeactivate = true`, `level = .floating`. Drop the `.onKeyPress(.return)` SwiftUI shim - `NSPanel` routes Return through `cancelOperation:`/`insertNewline:` via the responder chain.
- Move every base UI color (`windowBackground`, `controlBackground`, `selectionBackground`, `separator`, `label`, etc.) into `Assets.xcassets` color sets with four variants (`Any Appearance`, `Dark`, `Any Appearance / High Contrast`, `Dark / High Contrast`). Custom themes substitute named asset entries; hex literals only allowed for syntax-highlighter colors where dark/light variants do not apply. Read `\.accessibilityReduceTransparency` and `\.colorSchemeContrast` at every site that uses `.ultraThinMaterial`.
- Set `window.isRestorable = true`. Implement `NSWindowRestoration` on a `MainSplitViewController` subclass (or a small responder subclass). Encode `connectionId`, `selectedTabId`, sidebar split position, scroll offset, selected row indexes, applied filter, schema. Decode in `restoreWindow(withIdentifier:state:completionHandler:)`.
- Add `OpenConnectionIntent` (`AppIntent` conforming to `OpenIntent`), `IndexedEntity` for connections, `AppShortcutsProvider` static list. Backfill `NSUserActivity.isEligibleForSearch = true` and `contentAttributeSet` at `TabWindowController.swift:198-233`.
- Implement `NSServicesMenuRequestor` on the SQL editor's `NSTextView` and on the data grid table view.
- Replace `NSToolbar(identifier: "com.TablePro.main.toolbar.\(UUID().uuidString)")` with stable `"com.TablePro.main.toolbar"`. Set `NSToolbar.centeredItemIdentifiers` for the principal item.
- Drop `inspectorHeader` from `UnifiedRightPanelView` (`NSSplitViewItem.behavior = .inspector` already provides the chrome). Move the segmented tab picker to a toolbar item.

Touched files:
- Modified: `Views/QuickSwitcher/QuickSwitcherView.swift` and `Views/QuickSwitcher/QuickSwitcherPanel.swift` (new `NSPanel`-hosted controller), `Views/Main/MainContentView.swift` (drop the `.sheet(item:)` for QuickSwitcher), `TablePro/Resources/Assets.xcassets/` (add color sets), `Theme/ResolvedThemeColors.swift` (resolve from named assets), `Core/Services/Infrastructure/TabWindowController.swift` (`isRestorable = true`, `NSUserActivity.isEligibleForSearch`), `Views/Infrastructure/WindowChromeConfigurator.swift` (default `isRestorable = true`), `Views/Main/MainSplitViewController.swift` (NSWindowRestoration), `Views/Toolbar/MainWindowToolbar.swift` (stable identifier, `centeredItemIdentifiers`), `Views/RightSidebar/UnifiedRightPanelView.swift` (drop inspectorHeader), `TableProApp.swift` (register `AppShortcutsProvider`)
- Added: `Core/AppIntents/OpenConnectionIntent.swift`, `Core/AppIntents/ConnectionEntity.swift`, `Core/AppIntents/AppShortcutsProvider.swift`, `Core/Restoration/MainWindowRestoration.swift`

API surface delta:
- QuickSwitcher presentation moves from SwiftUI `.sheet` to AppKit `NSPanel`. The activate-switch shortcut handler stays the same key chord.
- New AppIntents are additive.
- `NSToolbar` identifier changes from per-launch UUID to stable. Per-window state is autosaved by `NSToolbar.autosavesConfiguration = true` + `NSToolbar.configuration` (macOS 13+).

New tests required:
- `TableProTests/QuickSwitcherPanelTests.swift` - panel does not steal key from the previous window, dismisses on outside click and Esc.
- `TableProTests/WindowRestorationTests.swift` - encode/decode round-trip preserves connection, tab, sidebar, scroll, selection, filter.
- `TableProTests/AppIntentsTests.swift` - `OpenConnectionIntent` succeeds for a registered connection, fails gracefully for unknown.

Risk and rollback: medium. UserDefaults migration for color theme overrides, restoration coder is on-disk state. Revert is per-component.

Why this ordering: HIG corrections are independent of the grid rewrite; landing them after the grid is stable lets us focus reviews on the rewrite proper first.

---

### Stage 12 - Memory hygiene: NSCache for displayCache, snapshot palette, undo cap, NSMapTable for ConnectionDataCache, ContiguousArray, `_columnsStorage` cleanup

Goal: tighten the remaining memory hygiene items. (Note: `displayCache` already moved to `NSCache` in stage 2; this stage covers the remaining items.)
- Add `DataGridCellPalette` snapshot pre-loop: cache `dataGridFonts.regular/.italic/.medium`, `colors.dataGrid.deleted/.inserted/.modified` once per render pass. Pass through `DataGridCellState` so the cell render is a struct field read, not a `ThemeEngine.shared` access (which goes through the `@Observable` registrar).
- `UndoManager.levelsOfUndo = 100`. `removeAllActions(withTarget:)` on tab close. Store undo as `(column, oldValue, newValue)` diffs (cell edits already do this); for row deletes, store `rowIndex` only and look up `originalRow` from `pending.changes[i]`. For batch deletes, do the same.
- `ConnectionDataCache.instances` switches from `[UUID: ConnectionDataCache]` strong dict to `NSMapTable<NSUUID, ConnectionDataCache>.weakToWeakObjects()` (per §2 verdict 3).
- `isFileDirty` (`QueryTabState.swift:266`) caches `(byteCount: Int, hash: UInt64)` snapshot at save time; no `NSString` bridging per keystroke.
- `Row.values` already moved to `ContiguousArray<String?>` in stage 2; verify all callers updated.
- `_columnsStorage` defensive `.map { String($0) }` in `DataChangeManager.swift:59-63` removed.
- `TabQueryContent.sourceFileURL` becomes `let`. `savedFileContent`, `loadMtime` become `private(set) var`.
- `PaginationState.baseQueryParameterValues: [String?]?` flattened to `[String?] = []`.

Touched files:
- Modified: `Views/Results/Cells/DataGridCellView.swift` and the data source / delegate (palette pass-through), `Core/ChangeTracking/DataChangeManager.swift` (undo cap, diff storage, `_columnsStorage` cleanup), `ViewModels/ConnectionDataCache.swift` (NSMapTable), `Models/Query/QueryTabState.swift` (`isFileDirty` snapshot, `let sourceFileURL`, `private(set) var`, flatten `baseQueryParameterValues`)

API surface delta:
- `ConnectionDataCache.shared(for:)` semantics change: returns `nil` once no SwiftUI view holds the cache. Callers that assumed the cache outlives the connection need to retain it explicitly. Audit confirms no current callers do.
- `TabQueryContent.savedFileContent` and `loadMtime` become `private(set)`. External writes go through dedicated mutators (already exist for save flow).
- `DataChangeManager.columns` returns the underlying storage directly.

New tests required:
- `TableProTests/DataGridCellPaletteTests.swift` - palette is sampled once per render pass; `ThemeEngine.shared` not accessed in cell hot path.
- `TableProTests/UndoLevelsCapTests.swift` - undo stack respects `levelsOfUndo = 100`; `removeAllActions(withTarget:)` clears on tab close.
- `TableProTests/ConnectionDataCacheLifecycleTests.swift` - cache deallocates when no view holds it.
- `TableProTests/IsFileDirtySnapshotTests.swift` - `isFileDirty` does not bridge to NSString; produces correct result for ASCII and non-ASCII content.

Risk and rollback: low. Mostly mechanical cleanup. Revert per-item.

Why this ordering: memory cleanup follows the architectural changes so the new shapes are the targets. Doing this first would have meant migrating from the dictionary to `NSCache` twice.

---

### Stage 13 - Dead code deletion + CLAUDE.md updates

Goal: delete the unambiguously-dead code identified in §7 and update CLAUDE.md to remove the stale `EditorTabBar` reference and any other documentation drift surfaced by this rewrite.

Touched files:
- Deleted: `Views/Editor/QuerySuccessView.swift` (dead per 09 A.1), `Views/Results/JSONEditorContentView.swift` (single-caller wrapper, inlined into `DataGridView+Popovers.showJSONEditorPopover` per 09 A.5), `Views/Results/DataGridView+TypePicker.swift` (39-line single-caller file; inlined into `DataGridView+Click.swift` per 09 B.1), `Views/Results/TableViewCoordinating.swift` (one-conformer protocol with no DI seam in use, per 09 C.4)
- Modified: `Models/UI/TableSelection.swift` (delete `empty`, `hasFocus`, `clearFocus()`, `setFocus(row:column:)` per 09 A.2), `Views/Results/Extensions/DataGridView+RowActions.swift` (delete `setCellValue(_:at:)` per 09 A.3), `Views/Results/DataGridRowView.swift` (delete `undoInsertRow` `@objc` per 09 A.4), `Core/ChangeTracking/DataChangeManager.swift` (delete `_columnsStorage` defensive copy per 09 §6), `CLAUDE.md` ("Editor Architecture" bullet drops the `EditorTabBar` reference; add a note that file column layout is now AppKit autosave; update ID-to-Index map invariant for `TableRows`; document the new `actor StreamingDataGridStore` in the Architecture section)
- Modified: `docs/refactor/datagrid-native-rewrite/00-blueprint.md` (mark each stage with PR number once landed)

API surface delta:
- Six dead members deleted. No callers exist.
- CLAUDE.md updated to reflect the post-rewrite architecture.

New tests required:
- None. Deletion-only stage.

Risk and rollback: very low. Each deletion is independently verified by `grep` for callers.

Why this ordering: last. Documentation and dead-code cleanup go after the code is stable.

---

### Stage 14 - FilterPanelView → NSPredicateEditor + PredicateSQLEmitter visitor

Goal: replace the hand-rolled SwiftUI predicate editor with `NSPredicateEditor` at the user-facing surface, and add a `PredicateSQLEmitter` visitor that translates the resulting `NSPredicate` to dialect-specific SQL via the existing `quoteIdentifier(...)` and parameter-binding paths. Custom row templates handle the cases `NSPredicateEditor` does not ship: `LIKE` with leading/trailing wildcard distinction, `BETWEEN` with two scalar inputs, and the `__RAW__` raw-SQL escape.

Touched files:
- Added: `Views/Filter/FilterPredicateEditorViewController.swift` (the `NSPredicateEditor`-hosted view controller, embedded via `NSViewControllerRepresentable`), `Views/Filter/FilterPredicateEditorRowTemplates.swift` (custom `NSPredicateEditorRowTemplate` subclasses for the non-standard cases), `Core/Filter/PredicateSQLEmitter.swift` (the visitor; takes `NSPredicate` + `DatabaseDialect` -> `(sql: String, parameters: [Any?])`), `Core/Filter/PredicateSQLEmitter+Dialect.swift` per-dialect quoting tables
- Modified: `Views/Filter/FilterPanelView.swift` (becomes a thin SwiftUI shell that hosts `FilterPredicateEditorViewController` via `NSViewControllerRepresentable`; presets stored as `NSKeyedArchiver`-archived `NSPredicate`), `Core/Filter/FilterRule.swift` (replaced by `NSPredicate` directly; rule-based persistence migrates once to archived predicates), `Core/Filter/FilterStorage.swift` (one-time migration from JSON-encoded rules to `NSKeyedArchiver`-archived predicates), `Views/Results/FilterPresetMenu.swift`
- Deleted: `Views/Filter/FilterRuleRow.swift` (custom row UI), `Views/Filter/FilterValueTextField.swift` if no other caller (verify after Stage 10), and any other custom predicate-editor scaffolding surfaced by grep
- Deleted: any custom comparator enum that mirrors `NSComparisonPredicate.Operator` (use the AppKit enum)

API surface delta:
- `FilterRule` and the JSON-encoded filter format are gone. One-time migration converts existing user filter presets to archived `NSPredicate`. Archive format is forward-compatible: `NSPredicate` archives via `NSSecureCoding`.
- `FilterValueTextField` deletion is conditional on no other callers surviving stage 10.
- `applyFilter(_:)` on the data grid coordinator now takes an `NSPredicate` directly instead of a `[FilterRule]` array. Call sites update in the same commit per the atomic-API rule.

New tests required:
- `TableProTests/PredicateSQLEmitterMySQLTests.swift` - every operator, value type, and template emits correct backtick-quoted SQL with parameter array
- `TableProTests/PredicateSQLEmitterPostgresTests.swift` - same with `"` quoting and `$1, $2, ...` parameter placeholders
- `TableProTests/PredicateSQLEmitterMSSQLTests.swift` - same with `[]` quoting
- `TableProTests/PredicateSQLEmitterEdgeCasesTests.swift` - `LIKE` wildcard escaping, `BETWEEN` with NULL bounds, `__RAW__` template emits the literal string verbatim, NULL handling, type coercion
- `TableProTests/FilterPredicatePresetMigrationTests.swift` - legacy JSON filter file is migrated once; archived `NSPredicate` round-trips via `NSKeyedArchiver`/`NSKeyedUnarchiver`
- `TableProTests/FilterPredicateEditorViewControllerTests.swift` - row templates render correctly, accessibility passes baseline (test uses `XCUIApplication.runningQuery` against a labeled fixture)

Risk and rollback: high. The persistence format changes; one-time migration must be exhaustively tested. Revert is one PR plus a downgrade-path migration for users who roll back to the prior version.

Why this ordering: filter migration is independent of the data-grid rewrite (stages 1-13). It depends only on stage 10's `AppKitPopover` and the SwiftUI/AppKit boundary rules. Landing it after stage 13 (dead-code cleanup) lets the cleanup PR delete the SwiftUI filter scaffolding in one pass instead of two.

---

### Stage 15 - Redis sidebar `NSOutlineView` migration

Goal: replace the recursive SwiftUI `DisclosureGroup` tree at `Views/Sidebar/RedisKeyTreeView.swift:42-66` with `NSOutlineView` driven by a lazy `NSOutlineViewDataSource`. SwiftUI's tree builds the entire view graph eagerly; `NSOutlineView` expands children only on user action via `outlineView(_:numberOfChildrenOfItem:)`, `outlineView(_:child:ofItem:)`, `outlineView(_:isItemExpandable:)`. Persist expansion state via `NSOutlineView.autosaveExpandedItems = true` and a stable `autosaveName`.

Touched files:
- Added: `Views/Sidebar/RedisKeyOutlineViewController.swift` (NSViewController hosting NSScrollView + NSOutlineView), `Views/Sidebar/RedisKeyOutlineDataSource.swift`, `Views/Sidebar/RedisKeyOutlineDelegate.swift`, `Views/Sidebar/RedisKeyTreeNode.swift` (Hashable item type passed to the outline)
- Modified: `Views/Sidebar/RedisKeyTreeView.swift` (becomes a thin `NSViewControllerRepresentable` shell), `ViewModels/RedisSidebarViewModel.swift` (return root nodes as `[RedisKeyTreeNode]`; expansion is owned by `NSOutlineView`)
- Deleted: the recursive `DisclosureGroup` body and `AnyView` wrapper

API surface delta:
- `RedisSidebarViewModel.expandedNodeIDs` is gone. `NSOutlineView` autosaves expansion to UserDefaults under the autosave name.
- Selection callback on the outline view forwards to the same key-selected handler the SwiftUI tree calls today.

New tests required:
- `TableProTests/RedisKeyOutlineViewLazyExpandTests.swift` - 50K-key fixture: only top-level nodes load on initial render; child counts are reported correctly; expanding a node triggers exactly one fetch
- `TableProTests/RedisKeyOutlineExpansionAutosaveTests.swift` - expansion state persists across view-controller round-trip
- `TableProTests/RedisKeyOutlineSelectionTests.swift` - selection forwards to the existing key handler; multi-select works

Risk and rollback: medium. SwiftUI shell stays; only the inner content swaps. Revert is per-component.

Why this ordering: independent of the grid rewrite. Lands after stage 14 to keep the per-stage diff focused.

---

## 6. PluginKit ABI bumps required

Per CLAUDE.md "Plugin ABI versioning":

> When `DriverPlugin` or `PluginDatabaseDriver` protocol changes (new methods, changed signatures), bump `currentPluginKitVersion` in `PluginManager.swift` AND `TableProPluginKitVersion` in every plugin's `Info.plist`. Stale user-installed plugins with mismatched versions crash on load with `EXC_BAD_INSTRUCTION`.

This rewrite triggers exactly one ABI bump, in stage 6:

- `Plugins/TableProPluginKit/Sources/TableProPluginKit/PluginDatabaseDriver.swift` - adds `func executeStreamingQuery(_:rowCap:parameters:) -> AsyncThrowingStream<PluginStreamElement, Error>` with default implementation. Adding a method (with default impl) is a static-witness-table change per CLAUDE.md and DOES require an ABI bump.
- `Plugins/TableProPluginKit/Sources/TableProPluginKit/PluginQueryResult.swift` - adds `case metadata(executionTime:rowsAffected:isTruncated:statusMessage:)` to `PluginStreamElement` enum. Adding an enum case is a layout change and requires an ABI bump.
- `Core/Plugins/PluginManager.swift` - `currentPluginKitVersion` increments by 1 (e.g. from N to N+1). The exact current value is read from the file at PR time.
- Every plugin's `Info.plist` - `TableProPluginKitVersion` updates to N+1. This includes:
  - Built-in (in-app): `Plugins/MySQLDriverPlugin`, `Plugins/PostgreSQLDriverPlugin`, `Plugins/SQLiteDriverPlugin`, `Plugins/ClickHouseDriverPlugin`, `Plugins/RedisDriverPlugin`, `Plugins/CSVDriverPlugin`, `Plugins/JSONDriverPlugin`, `Plugins/SQLExportPlugin`, `Plugins/XLSXExportPlugin`, `Plugins/MQLExportPlugin`, `Plugins/SQLImportPlugin`
  - Separately distributed: `Plugins/MongoDBDriverPlugin`, `Plugins/OracleDriverPlugin`, `Plugins/DuckDBDriverPlugin`, `Plugins/MSSQLDriverPlugin`, `Plugins/CassandraDriverPlugin`, `Plugins/EtcdDriverPlugin`, `Plugins/CloudflareD1DriverPlugin`, `Plugins/DynamoDBDriverPlugin`, `Plugins/BigQueryDriverPlugin`, `Plugins/LibSQLDriverPlugin`

The default implementation of `executeStreamingQuery` wraps `execute(query:)` in chunks of 1,000 rows. Plugins that opt to ship native streaming (PostgreSQL via `PQgetRow`, MySQL via `mysql_fetch_row`, ClickHouse via native row decoder) override this method.

No other stage triggers an ABI bump.

---

## 7. Deletion list

Concrete files and symbols to delete after this rewrite. Sourced from `09-dead-redundant.md` and `08-custom-vs-native.md` after applying the §2 reconciliation. Lines saved are approximate.

| Item | Reason | Stage | ~Lines |
|---|---|---|---|
| `Views/Results/Cells/DataGridBaseCellView.swift` | Replaced by single `DataGridCellView`; per-cell `wantsLayer`/`CATransaction`/`CellFocusOverlay`/`backgroundView` patterns removed (R1-R5) | 1 | 280 |
| `Views/Results/Cells/CellFocusOverlay.swift` | Single overlay on table view replaces per-cell overlay (R4) | 1 | 50 |
| `Views/Results/Cells/DataGridBlobCellView.swift` | Empty subclass for unique reuse identifier; single `DataGridCellView` with `kind` flag replaces it | 1 | 15 |
| `Views/Results/Cells/DataGridBooleanCellView.swift` | Same | 1 | 15 |
| `Views/Results/Cells/DataGridDateCellView.swift` | Same | 1 | 15 |
| `Views/Results/Cells/DataGridDropdownCellView.swift` | Same | 1 | 15 |
| `Views/Results/Cells/DataGridJsonCellView.swift` | Same | 1 | 15 |
| `Views/Results/Cells/DataGridChevronCellView.swift` | Same | 1 | 30 |
| `Views/Results/Cells/DataGridForeignKeyCellView.swift` | Same | 1 | 30 |
| `Views/Results/Cells/DataGridTextCellView.swift` | Same | 1 | 25 |
| `Views/Results/Cells/AccessoryButtons.swift` | `FKArrowButton`, `CellChevronButton`, `AccessoryButtonFactory` all replaced by direct `NSImage.draw` in `DataGridCellView.draw(_:)` | 1 | 90 |
| `Views/Results/SortableHeaderView.swift` | Stock `NSTableHeaderView` plus `sortDescriptorPrototype` plus `sortDescriptorsDidChange` replaces the entire mouseDown/cursor/sort-cycle stack (T2/T16) | 9 | 288 |
| `Views/Results/SortableHeaderCell.swift` | Stock `NSTableHeaderCell.drawSortIndicator(withFrame:in:ascending:priority:)` draws priority arrows | 9 | 182 |
| `Views/Results/CellOverlayEditor.swift` | `windowWillReturnFieldEditor:to:` + `MultilineFieldEditor.shared` replaces the borderless `NSPanel` (T3) | 9 | 243 |
| `Core/Storage/FileColumnLayoutPersister.swift` | `tableView.autosaveName` + `autosaveTableColumns` replaces it (T1) | 9 | ~120 |
| `Models/UI/ColumnLayoutState.swift` | Migration-only struct after autosave conversion (kept transiently in `LegacyColumnLayoutMigration`) | 9 | ~50 |
| `Views/Editor/QuerySuccessView.swift` | Dead; `Views/Results/ResultSuccessView` replaced it; comment at `ResultSuccessView.swift:6` documents the supersedence | 13 | ~70 |
| `Views/Results/JSONEditorContentView.swift` | Single-caller wrapper inlined into `DataGridView+Popovers.showJSONEditorPopover` | 13 | 50 |
| `Views/Results/DataGridView+TypePicker.swift` | Single-caller file inlined into `DataGridView+Click.swift` | 13 | 39 |
| `Views/Results/TableViewCoordinating.swift` | One-conformer protocol with no DI seam in use; concrete `TableViewCoordinator` is the only type ever assigned | 13 | 17 |
| `Views/Components/PopoverPresenter.swift` | Replaced by `AppKitPopover.show(controller:)` for AppKit-content popovers and direct `.popover(isPresented:)` for SwiftUI-content (S3) | 10 | 35 |
| `Views/Results/EnumPopoverContentView.swift` | Replaced by `EnumPopoverViewController` (NSPopover + NSStackView + NSSearchField + NSTableView) (verdict §2.2) | 10 | 100 |
| `Views/Results/ForeignKeyPopoverContentView.swift` | Replaced by `ForeignKeyPopoverViewController` (verdict §2.2) | 10 | 184 |
| `Views/Filter/FilterRuleRow.swift` and supporting custom row UI | Replaced by `NSPredicateEditor` row templates (verdict §2.1, stage 14) | 14 | ~120 |
| `Core/Filter/FilterRule.swift` (struct + JSON encoding) | Replaced by `NSPredicate` archived via `NSKeyedArchiver` (stage 14) | 14 | ~80 |
| Recursive `DisclosureGroup` body and `AnyView` wrapper inside `Views/Sidebar/RedisKeyTreeView.swift` | Replaced by `NSOutlineView` lazy expand (stage 15) | 15 | ~60 |

Symbol-level deletions inside surviving files:

| Symbol | File | Reason | Stage | ~Lines |
|---|---|---|---|---|
| `TableSelection.empty` | `Models/UI/TableSelection.swift` | Zero callers (09 A.2) | 13 | 1 |
| `TableSelection.hasFocus` | same | Zero callers | 13 | 3 |
| `TableSelection.clearFocus()` | same | Zero callers | 13 | 4 |
| `TableSelection.setFocus(row:column:)` | same | Zero callers | 13 | 5 |
| `setCellValue(_:at:)` | `Views/Results/Extensions/DataGridView+RowActions.swift` | Zero external callers; only forwards to `setCellValueAtColumn` | 13 | 6 |
| `undoInsertRow()` `@objc` selector | `Views/Results/TableRowViewWithMenu.swift` | Never wired to any `NSMenuItem` | 13 | 4 |
| `_columnsStorage` defensive `.map { String($0) }` | `Core/ChangeTracking/DataChangeManager.swift` | Plugin produces native Swift strings; defensive copy is dead | 13 | 5 |
| `preWarmDisplayCache(upTo:)` | `Views/Results/DataGridCoordinator.swift` | Replaced by `CellDisplayWarmer.warm` on store actor | 5 | 25 |
| `rebuildVisualStateCache()` and `rowVisualStateCache` | `Views/Results/DataGridCoordinator.swift` | Replaced by `RowVisualIndex.apply` | 3 | 50 |
| `savedColumnLayout`, `captureColumnLayout`, `persistColumnLayoutToStorage`, `currentSortState`, `onColumnLayoutDidChange` | `Views/Results/DataGridCoordinator.swift` | Autosave + sortDescriptors native | 9 | ~80 |
| `KeyHandlingTableView.menu(for:)` override | `Views/Results/KeyHandlingTableView.swift` | Stock AppKit menu routing | 9 | 15 |
| `showOverlayEditor`, `commitOverlayEdit`, `handleOverlayTabNavigation`, `InlineEditEligibility.needsOverlayEditor` | `Views/Results/Extensions/DataGridView+Editing.swift` | Native field editor replaces them | 9 | ~60 |
| `HeaderSortCycle`, `HeaderSortTransition` | (in deleted `SortableHeaderView.swift`) | Stock `sortDescriptorsDidChange` replaces them | 9 | included above |

Estimated net lines deleted: roughly 2,200. Estimated lines added (the new `DataGridCellView`, store, warmer, view controller, snapshot, AppKit popovers, native field editor, AppIntents): roughly 1,400. Net: ~800 lines smaller, plus a coherent architecture.

---

## 8. Do-not-regress list

Sourced from agent reports' "already correct" callouts. These foundations exist in TablePro today and must survive every stage of the rewrite.

| Item | Where it lives | Why |
|---|---|---|
| View-based `NSTableView` with `tableView(_:viewFor:row:)` | `Views/Results/Cells/DataGridCellRegistry.swift:74` | Apple-recommended path for editable grids; cell-based is legacy (rendering R8) |
| `makeView(withIdentifier:owner:)` reuse | same | Cell reuse is the foundation of `NSTableView` performance |
| Modern drag and drop via `pasteboardWriterForRow:` | `Views/Results/DataGridView+RowActions.swift:178` | Preferred over deprecated `tableView(_:writeRowsWith:to:)` |
| Animated row insert/remove via `insertRows(at:withAnimation:)` / `removeRows(at:withAnimation:)` | `Views/Results/TableRowsController.swift:46, 49, 51` | Targeted updates, not `reloadData()` |
| Effective appearance handling in cells | (will move to `DataGridCellView`) | Dark mode adaptation per `NSAppearance` change |
| `actor SQLSchemaProvider` in-flight Task pattern | `Core/Autocomplete/SQLSchemaProvider.swift` | `loadTask: Task<Void, Never>?`; concurrent callers `await` the same Task. Per CLAUDE.md invariant. The new `StreamingDataGridStore` adopts the same pattern for concurrent fetch coalescing. |
| `@Observable` (Swift Observation) instead of `ObservableObject` | most ViewModels | Per-property dependency tracking |
| `os.Logger` structured logging | every Core service | Per CLAUDE.md mandate |
| Sparkle for updates | (TablePro top-level) | Auto-update infrastructure |
| `ConnectionHealthMonitor` actor with 30s ping + jittered start + auto-reconnect | `Core/Database/ConnectionHealthMonitor.swift` | Correct structured concurrency; do not regress (concurrency report HM1) |
| Accessibility row/column index ranges on cells | `Views/Results/Cells/DataGridBaseCellView.swift:130-131` (will move to `DataGridCellView`) | Already shipping; audit H8 was wrong. VoiceOver "row X of Y" announcement |
| `JSONHighlightPatterns` `static let` regex caching | `Views/Results/JSONHighlightPatterns.swift:18-22` | Already shipping; audit M5 was wrong. `dispatch_once` semantics |
| `AnyChangeManager` protocol abstraction | `Core/ChangeTracking/AnyChangeManager.swift` | Two real conformers (`DataChangeManager`, `StructureChangeManager`) and four real construction sites; not a single-conformer protocol |
| `DataGridCellFactory`/`DataGridCellRegistry`/`DataGridColumnPool` split | `Views/Results/` | Three orthogonal responsibilities (width measurement, cell resolution, column pool) - the split is correct, not redundant. `DataGridCellFactory` may be renamed to `ColumnWidthCalculator` for clarity (09 C.2) but the responsibility split stays |
| `DataGridView+Selection.swift`, `DataGridView+Sort.swift`, `DataGridView+Editing.swift`, `DataGridView+RowActions.swift` extensions | `Views/Results/Extensions/` | AppKit `@objc` selectors and `NSTableViewDelegate` protocol callbacks are file-organized by responsibility; the extension split is correct |
| Window tab titles resolved in `ContentView.init` and `MainContentView+Setup.swift updateWindowTitleAndFileState()` | per CLAUDE.md invariant | Both must stay in sync. The rewrite does not change this |
| `ConnectionStorage` persist-before-notify ordering | `Core/Storage/ConnectionStorage.swift` | Per CLAUDE.md invariant |
| `WelcomeViewModel.rebuildTree()` after every `connections` mutation | `ViewModels/WelcomeViewModel.swift` | Per CLAUDE.md invariant |
| Tab replacement guard | `MainContentCoordinator+Tabs.swift` | Per CLAUDE.md invariant |
| `EditorWindow.performClose:` Cmd+W routing | `Core/Services/Infrastructure/TabWindowController.swift` | Per CLAUDE.md invariant; AppKit's "File > Close" wins over SwiftUI commands |
| `usesAutomaticRowHeights = false` (default; will be made explicit in stage 9) | `Views/Results/DataGridView.swift` | Per CLAUDE.md invariant for large datasets |
| Tab persistence truncates queries >500KB | `QueryTab.toPersistedTab()`, `TabStateStorage.saveLastQuery()` | Per CLAUDE.md performance pitfalls |
| Window-level tabs use `NSWindow.tabbingMode = .preferred` | `Core/Services/Infrastructure/TabWindowController.swift:60-64` | User explicitly accepted Cmd+Number rapid-burst lag; do not refactor to custom tab bar (per user memory `feedback_native_tab_perf_accepted.md`) |

---

## 9. Test plan

For every stage in §5, the unit/integration tests that prove the stage works. Tests follow `TableProTests/` conventions per the `write-tests` skill (XCTest + `@MainActor`-aware suites; helper utilities in `TableProTests/Helpers/`; baseline-image snapshot helpers for AppKit drawing).

| Stage | Test file | What it proves |
|---|---|---|
| 1 | `TableProTests/DataGridCellViewTests.swift` | `DataGridCellView.draw(_:)` produces pixel-equal output to a baseline `NSImage` for each cell kind, focus state, change-state combination |
| 1 | `TableProTests/DataGridRowViewTests.swift` | `drawBackground(in:)` paints the right tint for `inserted`/`deleted`/`modified` row states; `drawSelection(in:)` honors `isEmphasized` |
| 1 | `TableProTests/FocusOverlayViewTests.swift` | Single overlay positions itself via `tableView.frameOfCell(atColumn:row:)`; toggles hidden on focus change; observers clean up on `viewDidDisappear` |
| 1 | `TableProTests/CellLayerCountTests.swift` | A 30-row × 20-column viewport renders with ≤601 layers (was 2,400-3,600) |
| 2 | `TableProTests/TableRowsTests.swift` | `indexByID` stays consistent across `appendInsertedRow`, `insertInsertedRow`, `appendPage`, `removeIndices`, `replace(rows:)`; `index(of:)` is `O(1)` |
| 2 | `TableProTests/DisplayCacheBoundedTests.swift` | `NSCache.totalCostLimit = 32 MB` enforces RAM ceiling; large dataset insertion does not OOM |
| 2 | `TableProTests/RowValuesContiguousArrayTests.swift` | Every caller that constructed `Row.values` with `[String?]` now uses `ContiguousArray<String?>`; bridging cost gone |
| 3 | `TableProTests/RowVisualIndexTests.swift` | Each `ChangeManagerDelta` produces correct `RowVisualState` for all rows; `O(1)` per delta, not `O(n)` rebuild |
| 4 | `TableProTests/StreamingDataGridStoreTests.swift` | Actor init succeeds; `cellDisplay(at:column:)` returns the formatted string; `changes` AsyncStream emits `header` then `rowsAppended` then `streamingFinished` in order; cancellation tears down |
| 4 | `TableProTests/CellDisplayFormatterNonisolatedTests.swift` | Formatter produces identical output called from any actor context (was `@MainActor`, now nonisolated) |
| 4 | `TableProTests/DataGridStoreSnapshotTests.swift` | `DisplaySnapshot` is `Sendable`; pushing a snapshot from actor to `@MainActor` coordinator preserves all data |
| 5 | `TableProTests/CellDisplayWarmerTests.swift` | `warm(...)` produces correct strings for date, blob, JSON, NULL, large-string truncation at `previewLength = 300` |
| 5 | `TableProTests/SettingsChangeReformatTests.swift` | Date format change triggers re-warm of visible window; main thread blocks for <16ms |
| 6 | `TableProTests/PluginStreamingDefaultImplTests.swift` | Default implementation of `executeStreamingQuery` produces same data as `execute(query:)` for plugins that have not overridden it |
| 6 | `TableProTests/PluginStreamingPostgresTests.swift` | PostgreSQL plugin's native streaming yields first chunk before query finishes; `Task.cancellation` cleanly aborts mid-stream |
| 6 | `TableProTests/PluginStreamingMySQLTests.swift` | Same for MySQL |
| 6 | `TableProTests/PluginStreamingClickHouseTests.swift` | Same for ClickHouse |
| 6 | `TableProTests/PluginKitVersionMismatchTests.swift` | Loading a plugin with mismatched `TableProPluginKitVersion` fails cleanly with a user-facing error (not `EXC_BAD_INSTRUCTION`) |
| 7 | `TableProTests/DataGridCoordinatorEventLoopTests.swift` | Single event Task receives every `DataGridEvent`; `releaseData()` cancels it before nilling `delegate`; no leaks |
| 7 | `TableProTests/CooldownTimerTests.swift` | `schedule(after:_:)` cancels prior task; fires once after the delay |
| 7 | `TableProTests/ResultsJsonViewOffMainTests.swift` | 5K-row JSON selection change does not block main thread for >16ms |
| 7 | `TableProTests/ChangeStreamDebounceTests.swift` | Debounced 100ms `AsyncStream` emits one event per quiet window even under sustained mutation pressure |
| 8 | `TableProTests/DataGridViewControllerTests.swift` | View controller lifecycle (`viewDidLoad`, `viewWillAppear`, `viewDidDisappear`) wires up cleanly; teardown observers run in order |
| 8 | `TableProTests/DataGridSnapshotEquatableTests.swift` | `Snapshot` correctly identifies meaningful changes (rows reordered, columns hidden) and ignores benign `@Binding` pings |
| 9 | `TableProTests/AutosaveColumnLayoutTests.swift` | Column resize/reorder/hide is persisted across `dismantleNSViewController`/`makeNSViewController` round-trip via UserDefaults |
| 9 | `TableProTests/LegacyColumnLayoutMigrationTests.swift` | Legacy JSON file is migrated once, the file is deleted afterward, AppKit-native UserDefaults key is populated correctly |
| 9 | `TableProTests/SortDescriptorsTests.swift` | Single-column sort cycles asc → desc → cleared (third click clears via `sortDescriptorsDidChange` post-filter); shift-click appends; multi-column priority badges render via stock `NSTableHeaderCell.drawSortIndicator` |
| 9 | `TableProTests/FieldEditorTests.swift` | Multi-line cells get the `MultilineFieldEditor`; single-line cells get the default; Return commits, Esc cancels, Tab advances, Option-Return inserts newline |
| 9 | `TableProTests/TypeSelectTests.swift` | Typing a prefix scrolls to and selects the matching row |
| 9 | `TableProTests/UndoInsertRowAnimatedTests.swift` | `undoInsertRow` uses `tableView.removeRows(at:withAnimation:.slideUp)`, not `reloadData()` |
| 10 | `TableProTests/AppKitPopoverTests.swift` | Popover lifecycle, key event routing, dismiss on outside click |
| 10 | `TableProTests/EnumPopoverViewControllerTests.swift` | Selection, search filter, Return commits, Esc cancels |
| 10 | `TableProTests/ForeignKeyPopoverViewControllerTests.swift` | Async fetch cancellation on dismiss; large lists scroll smoothly |
| 10 | `TableProTests/SidebarSearchTextSingleSourceTests.swift` | One source flows to all readers; no sync drift across tab switches |
| 11 | `TableProTests/QuickSwitcherPanelTests.swift` | `NSPanel` does not steal key from previous window; dismisses on outside click and Esc; Cmd+P toggles |
| 11 | `TableProTests/WindowRestorationTests.swift` | Encode/decode round-trip preserves connection, tab, sidebar split, scroll, selection, filter |
| 11 | `TableProTests/AppIntentsTests.swift` | `OpenConnectionIntent` succeeds for registered connection, fails gracefully for unknown |
| 11 | `TableProTests/ColorAccessibilityTests.swift` | Reduce Transparency and Increase Contrast environment values reach every site that today uses `.ultraThinMaterial` |
| 12 | `TableProTests/DataGridCellPaletteTests.swift` | Palette is sampled once per render pass; `ThemeEngine.shared` is not accessed in the cell hot path |
| 12 | `TableProTests/UndoLevelsCapTests.swift` | Undo stack respects `levelsOfUndo = 100`; `removeAllActions(withTarget:)` clears on tab close |
| 12 | `TableProTests/ConnectionDataCacheLifecycleTests.swift` | Cache deallocates when no view holds it; `NSMapTable.weakToWeakObjects` semantics correct |
| 12 | `TableProTests/IsFileDirtySnapshotTests.swift` | `isFileDirty` does not bridge to NSString; correct for ASCII and non-ASCII |
| 13 | (no new tests; deletion-only) | `swift build` and the existing test suite must pass with the deletions in place |

Performance regression tests (run on every PR via `RunSomeTests`):
- `TableProTests/DataGridScrollPerfTests.swift` - 50K-row table at 30 visible rows × 30 columns: zero `CellDisplayFormatter.format` invocations during steady-state scroll (verified by counting calls); scroll completes a 60-frame burst in ≤1 second
- `TableProTests/DataGridFirstPaintPerfTests.swift` - `SELECT * FROM table` against a 1M-row table renders the first 1K rows in ≤500ms regardless of total table size
- `TableProTests/DataGridMemoryCeilingTests.swift` - 1M-row × 20-column scan: resident memory after streaming finishes is ≤200 MB (`displayCache` `totalCostLimit` enforcement)

---

## 10. Open questions for the user

All resolved 2026-05-08. Decisions on file:

1. **Field editor** - Native field editor via `windowWillReturnFieldEditor:to:` returning a shared multi-line `NSTextView` (Sequel-Ace `SPTextView` precedent). `CellOverlayEditor` deleted in stage 9.
2. **Plugin ABI bump (stage 6)** - All 21 plugins re-released in lockstep with the app. Built-in plugins ship with the app build; 10 separately distributed plugins (MongoDB, Oracle, DuckDB, MSSQL, Cassandra, Etcd, CloudflareD1, DynamoDB, BigQuery, LibSQL) re-tagged and re-released the same day. Users with stale registry plugins see a load-time error rather than `EXC_BAD_INSTRUCTION` (release tests `PluginKitVersionMismatchTests` enforce this).
3. **Filter UI** - Migrate to `NSPredicateEditor` and write the `PredicateSQLEmitter` visitor. Stage 14 owns this. Native AppKit primitive at the user-facing surface trumps the convenience of keeping custom UI.
4. **Stage ordering** - Back-to-back PRs, stages 1 through 15. No release carve-out for stage 6; the plugin re-release is part of the same app version.
5. **Redis sidebar `NSOutlineView`** - In scope. Stage 15.

Stage 1 is ready to start.

---

End of blueprint.
