# 05 - SwiftUI / AppKit Interop Audit

Scope: every place SwiftUI hosts AppKit (or vice versa) inside the data grid surface and its surrounding chrome (sidebar, inspector, popovers, JSON viewer, filter panel). Goal: list every nested-hosting, double-source-of-truth, full-tree-rerender, and `NSViewRepresentable` misuse, then define a single boundary rule for the rewrite.

Companion to: `01-architecture-anti-patterns.md`, `03-hig-native-macos-delta.md`. Subsumes section 2.5 of `DATAGRID_PERFORMANCE_AUDIT.md`.

## 0. TL;DR

TablePro mixes SwiftUI and AppKit at four different layers, and most pain comes from doing it more than once per surface:

1. `DataGridView.updateNSView` (SwiftUI → AppKit) re-applies ~25 coordinator properties on every binding change because it has no last-applied snapshot. Apple's documented contract for `updateNSView` is "reconcile to current state" which is fine, but the implementation does no diff so every parent re-render walks the full property set and triggers `reloadData()` whenever the cached row count drifts.
2. The filter suggestion dropdown stacks three view systems on top of each other: `NSPopover` → `NSHostingController` → SwiftUI `ScrollView` driven by `@Published` properties on an `ObservableObject`. Every keystroke invalidates the whole `ForEach`.
3. The right-panel "inspector" is constructed twice. `MainSplitViewController` already uses `NSSplitViewItem(inspectorWithViewController:)` (the AppKit-correct inspector boundary), but the SwiftUI content inside it re-implements a header, segmented picker, and tab switching as a `VStack`, so we pay for two layers of chrome.
4. The Redis sidebar uses recursive SwiftUI `DisclosureGroup` for trees that can hold 50,000 keys. SwiftUI builds the entire tree eagerly per `displayNodes(searchText:)` call.
5. `searchText` is mirrored: the truth lives in `SharedSidebarState`, then is copy-pushed into `SidebarViewModel` via `onChange` and read back by the list. Two writers, two readers, eventual consistency by accident.
6. `EnumPopoverContentView` and `ForeignKeyPopoverContentView` re-implement a searchable list in SwiftUI for picker semantics that AppKit ships natively as `NSPopUpButton` and `NSComboBox`.
7. The general pattern for popover content is "wrap a SwiftUI view inside an `NSHostingController` inside an `NSPopover`". The hosting indirection is unavoidable when the content is SwiftUI, but the popovers contain content (lists, search, selection) that is more naturally AppKit and triggers an unnecessary boundary cross.

## 1. Findings

Severity: **CRIT** = blocks the rewrite or causes user-visible jank/correctness; **HIGH** = forces redundant rerenders or breaks single-source-of-truth; **MED** = duplicates platform behavior; **LOW** = isolated and acceptable but track.

### S1 - `DataGridView.updateNSView` reconciles with no diff (HIGH)

`Views/Results/DataGridView.swift:134-239`.

What's wrong:

- `updateNSView` re-assigns `coordinator.changeManager`, `isEditable`, `tableRowsProvider`, `tableRowsMutator`, `sortedIDs`, `displayFormats`, `delegate`, `dropdownColumns`, `typePickerColumns`, `customDropdownOptions`, `connectionId`, `databaseType`, `tableName`, `primaryKeyColumns`, `tabType` on every parent re-render. There is no equality check.
- It calls `coordinator.updateCache()` twice (`:185` and `:201`).
- It calls `coordinator.rebuildVisualStateCache()` unconditionally on every update (`:214`).
- It rebuilds the column metadata cache (`:186`) unconditionally.
- It always calls `delegate?.dataGridAttach(...)` (`:204`), which means the delegate sees a fresh attach on every binding change.
- "Structure changed" is detected by row/column count only (`:182`). Reordered columns or replaced rows of the same shape do not trigger a reload, but a benign `@Binding` ping does the full property dance.
- `reloadAndSyncSelection` (`:299`) has the inverse problem: it skips reload when row/column counts match, even if row IDs changed (this is what the comment at `:110-115` admits).

Why this matters: `updateNSView` is on the hot path for every SwiftUI parent invalidation. For a grid that already runs near `NSCell` redraw budget, this adds work proportional to property count, not to what actually changed. It also makes it impossible to reason about what triggers a reload.

Native-correct fix:

- Store a `LastApplied` snapshot inside the `Coordinator` (which is already provided by `NSViewControllerRepresentable`/`NSViewRepresentable` via `makeCoordinator` and exists here as `TableViewCoordinator`). Compare to the new state and apply only changed slices. This is the canonical pattern from Apple's "Communicate with the view by using a coordinator" section in *Interfacing with UIKit / AppKit* (Apple Developer documentation, "NSViewRepresentable" reference).
- Move the property fan-out into a single `Coordinator.apply(_ snapshot: DataGridSnapshot)` call. The snapshot is one `Equatable` struct; if `snapshot == coordinator.lastApplied` the function returns early.
- Detect structural changes by `(rowIDsHash, columnIDsHash)` rather than counts. The data path already owns stable `RowID` values.
- `delegate?.dataGridAttach(...)` should only fire when `delegate` identity changes.
- Drop the duplicate `updateCache()` call.

Reference: `NSViewRepresentable.updateNSView(_:context:)` documentation explicitly says "Update the configuration of your view to match the new state information provided in the `context` parameter." The supported pattern for expensive updates is to diff against the coordinator's last-applied state.

### S2 - Filter suggestion dropdown rebuilds the whole `ForEach` per keystroke (HIGH)

`Views/Filter/FilterValueTextField.swift:294-336` (the `SuggestionState` ObservableObject and `SuggestionDropdownView`).

What's wrong:

- `SuggestionState` is `ObservableObject` with `@Published var items` and `@Published var selectedIndex`. Both publishers fire on every keystroke (`updateSuggestions(for:)` writes both at `:184-185` and `:193-194`).
- `SuggestionDropdownView` observes the whole object via `@ObservedObject`. Any property change invalidates the body, which rebuilds the `ForEach(Array(state.items.enumerated()), id: \.offset)`.
- `id: \.offset` discards diffability. SwiftUI cannot reuse rows when the list shifts, so every keystroke is a full row reconstruction.
- The list is SwiftUI but lives inside an `NSHostingController` inside an `NSPopover` (see S3). One re-render here triggers a hosting-bridge layout pass.

Native-correct fix:

- Replace `ObservableObject` with `@Observable` (Swift Observation, `Observation` framework, macOS 14+, SE-0395). `@Observable` tracks property reads at the granularity of property access, so a body that reads only `state.items` does not invalidate when only `state.selectedIndex` changes (and vice versa). Selection redraws become row-local instead of list-wide.
- Switch `id: \.offset` to `id: \.self` (the items are `String`) so insertion/deletion is diffed properly.
- Better: replace this entire view with `NSTableView` content inside the popover (see the boundary rule in section 3). The dropdown is a list with single-selection, keyboard navigation, and a string per row - that is `NSTableView` shaped.

Reference: SE-0395 *Observability* and Apple's "Migrating from the Observable Object protocol to the Observable macro" article. The `@Observable` macro participates in SwiftUI's per-property dependency tracking; `ObservableObject` invalidates per object.

### S3 - Triple-nested hosting in popovers (MED)

`Views/Components/PopoverPresenter.swift:11-34` and every caller (`FilterValueTextField:203`, `EnumPopoverContentView`, `ForeignKeyPopoverContentView`, etc.).

What's wrong:

- Every popover is `NSPopover` → `NSHostingController(rootView: SwiftUIView)` → SwiftUI content. When that SwiftUI content is itself an `NSViewRepresentable` (e.g., `NativeSearchField` is wrapped inside `EnumPopoverContentView`), we cross the boundary three times: AppKit (popover) → SwiftUI host → AppKit (`NSSearchField`). Each boundary owns its own first-responder, layout, and intrinsic-size machinery.
- `popover.behavior = .semitransient` is hard-coded in `PopoverPresenter`; callers cannot opt into `.transient` (auto-dismiss on outside click) without a separate API. This forces `FilterValueTextField` to install a manual `NSEvent.addLocalMonitorForEvents` to capture arrow keys and Return (`:218-251`), because `.semitransient` does not steal key events.
- The hosting controller's `intrinsicContentSize` is driven by SwiftUI layout, but `popover.contentSize` is set imperatively from caller-computed numbers (`:201`). Two sizing systems fight.

Native-correct fix:

Pick one boundary per popover:

- **AppKit-content popover** (search/list/picker semantics): give `NSPopover` an `NSViewController` whose root view is `NSStackView { NSSearchField, NSScrollView { NSTableView } }`. No SwiftUI hosting, no `NSEvent.addLocalMonitorForEvents`, key handling is automatic via the responder chain. `NSPopover` already routes Escape via `cancelOperation(_:)`.
- **SwiftUI-content popover** (settings, simple forms): use SwiftUI's `.popover(isPresented:)` modifier directly. Do not route through `NSHostingController` manually. SwiftUI's popover modifier wraps an `NSPopover` for you with the correct first-responder semantics.

Apple's "Mixing AppKit and SwiftUI" guidance (WWDC22 "Use SwiftUI with AppKit", Apple Developer documentation "Adding AppKit Views to a SwiftUI View Hierarchy"): pick the host once per surface. Nested `NSViewRepresentable` inside `NSHostingController` inside `NSPopover` is the explicit anti-pattern.

The current `PopoverPresenter` should be deleted in favor of either pattern. Keep one helper *or* the other, not both.

### S4 - Right panel re-implements inspector chrome inside a native inspector (MED)

`Views/RightSidebar/UnifiedRightPanelView.swift:15-50`.
`Core/Services/Infrastructure/MainSplitViewController.swift:143-144` (the AppKit half, already correct).

What's wrong:

- `MainSplitViewController` already creates the inspector the AppKit-native way:
  ```swift
  inspectorHosting = NSHostingController(rootView: initialInspectorContent)
  inspectorSplitItem = NSSplitViewItem(inspectorWithViewController: inspectorHosting)
  ```
  This is correct: `NSSplitViewItem(inspectorWithViewController:)` (macOS 14+) gives us the system inspector behavior - collapse, drag-edge, sidebar inset, divider styling - without any SwiftUI involvement.
- But the SwiftUI content hosted inside that inspector (`UnifiedRightPanelView`) re-implements its own inspector chrome via `VStack { inspectorHeader; Divider(); content }` (`:41-50`). The header has its own segmented `Picker`, its own padding, its own divider - none of which matches the AppKit chrome the split-view item already provides. We pay for two layers of titles, two layers of dividers, and two coordinate systems for "is collapsed".
- `state.activeTab` (Details vs AI Chat) is application state but is rendered as if it were a tab control. AppKit's `NSTabViewController` is the native control for "two views, picker on top".

Native-correct fix:

- Drop the `inspectorHeader` from `UnifiedRightPanelView`. The split-view item already owns the inspector chrome.
- Render the tab picker as the toolbar's right-aligned segmented control (`NSToolbarItem` with `NSSegmentedControl`) - this is how Xcode and Mail do it. The active-tab state already exists; only the chrome moves.
- If we want to keep the picker inline with content, replace `UnifiedRightPanelView` with an `NSTabViewController` (macOS native) and host each tab's SwiftUI body individually in its own `NSHostingController`. Each tab gets a real responder boundary and the segmented control is the native chrome.
- Alternatively, since `NSSplitViewItem.behavior = .inspector` is already in use, the SwiftUI `.inspector` modifier (macOS 14+) is *not* the right pick here - we already have the AppKit version, and `.inspector` would compete. Stay with `NSSplitViewItem(inspectorWithViewController:)`.

Reference: `NSSplitViewItem` Apple Developer documentation, macOS 14 "Inspector style" section. `NSTabViewController` is the canonical "segmented chooser + content area".

### S5 - Redis key tree uses recursive SwiftUI `DisclosureGroup` for up to 50k nodes (MED → HIGH at scale)

`Views/Sidebar/RedisKeyTreeView.swift:42-66`.

What's wrong:

- `renderNodes(_:)` returns `AnyView(ForEach(items) { ... })` and recursively calls itself for each namespace's children. SwiftUI eagerly walks the whole tree to build the view graph - there is no lazy expansion. A 50k-key namespace materializes 50k `DisclosureGroup` bodies at first render even when collapsed.
- `AnyView` erases identity, defeating SwiftUI's diffing. Combined with recursive `ForEach`, this is O(total nodes) work on every parent re-render.
- The tree state lives in two places: `expandedPrefixes: Set<String>` (passed by `@Binding`, owned by `RedisKeyTreeViewModel.expandedPrefixes`) plus the implicit "is loaded" state inside the view. Keystrokes in the search field cause `displayNodes(searchText:)` to recompute the whole node array (`SidebarView:224`).
- `nodes.isEmpty` and `isLoading` are sibling parameters but `isTruncated` is rendered as a static string - none of this benefits from SwiftUI animation, list virtualization, or selection.

Native-correct fix:

- Use `NSOutlineView` with lazy expansion. The dataSource pattern: implement `outlineView(_:numberOfChildrenOfItem:)`, `outlineView(_:child:ofItem:)`, `outlineView(_:isItemExpandable:)`, `outlineView(_:objectValueFor:byItem:)`. NSOutlineView only asks for children of expanded items, so 50k keys nested under collapsed namespaces never get queried.
- Persist expansion via `NSOutlineView.autosaveExpandedItems = true` plus an `autosaveName`, or sync to `expandedPrefixes` via `outlineViewItemDidExpand/Collapse`.
- Selection: `outlineView(_:shouldSelectItem:)` and `outlineViewSelectionDidChange(_:)`.
- Search: filter `displayNodes` once on the model side; reload via `outlineView.reloadData()` when the filter changes. Or, for live filtering, `NSOutlineView` with a separate filtered tree - same data source, different root.
- Drop `AnyView` entirely; the outline view does its own diffing.

Reference: Apple's "Outline View Programming Guide for Mac" (legacy doc, still authoritative). The 1k-node threshold is the project's existing rule (`CLAUDE.md` performance pitfalls); Redis hits it routinely.

### S6 - `searchText` has two sources of truth (HIGH for correctness)

`Views/Sidebar/SidebarView.swift:67, 95-97`.
`ViewModels/SidebarViewModel.swift:18` (`var searchText = ""`).
`Models/UI/SharedSidebarState.swift:20` (`var searchText: String = ""`).

What's wrong:

- The canonical store is `SharedSidebarState.searchText` - it is owned per-connection and survives across native window tabs.
- `SidebarView.init` copies it into a local `SidebarViewModel.searchText` (`:67`).
- `.onChange(of: sidebarState.searchText)` writes back into the view model (`:95-97`). There is no inverse direction; if anyone writes to `viewModel.searchText`, `sidebarState.searchText` is stale.
- `filteredTables`, `noMatchState`, and `RedisKeyTreeView`'s search input all read from `viewModel.searchText` (`:30-31, 133, 164, 224`).
- The audit (`DATAGRID_PERFORMANCE_AUDIT.md` 2.5 row S6) names `SchemaService.shared` as the second source. That field was renamed/moved at some point; the dual-source pattern survives between `SharedSidebarState` and `SidebarViewModel`. Same shape, same fix.

Why this matters: any code that writes to `viewModel.searchText` directly (e.g., a future "Clear search" button on the view model) silently loses the value across tab switches. The "two stores, sync via onChange" pattern is exactly what `@Bindable` exists to eliminate.

Native-correct fix:

- Delete `SidebarViewModel.searchText`. Keep the value in `SharedSidebarState` only.
- Read directly from `sidebarState.searchText` in computed properties on the view (`filteredTables` becomes `tables.filter { $0.name.localizedCaseInsensitiveContains(sidebarState.searchText) }`).
- For places that need to mutate it (search field, "Clear" button), pass `Binding` to `sidebarState.searchText` via `@Bindable var sidebarState: SharedSidebarState`. `SharedSidebarState` is already `@Observable`, so `@Bindable` works directly.
- The view model becomes a pure command bus (batch operations, dialog state) with no synced state.

Reference: SE-0395 Observation. With `@Observable` plus `@Bindable`, the canonical pattern is one model, many readers, no copies.

### S7 - `NSHostingView(rootView:)` as JSON viewer window content (LOW, acceptable)

`Views/Results/JSONViewerWindowController.swift:54`.

What's there: `window.contentView = NSHostingView(rootView: contentView)`.

This is fine. `NSHostingView` is the right choice for a one-off window whose content is fully SwiftUI and whose lifecycle matches the window's. The general guidance from Apple ("Adding AppKit Views to a SwiftUI View Hierarchy" and reverse) is: avoid `NSHostingView` *inside cells of an `NSTableView`* (creates a hosting controller per row), inside `NSCollectionViewItem`s, or anywhere it gets created and destroyed at high rate. A whole-window root view is none of those.

Track only: if `JSONViewerView` itself starts using state that re-creates its `NSTextView` subview on every keystroke, we'd see frame thrash. As-is, the editor is bridged once and held alive by the window.

Keep as-is. Document the rule (see section 3) so we don't expand this pattern into cells.

### S8 - Enum/FK pickers re-implement `NSPopUpButton` / `NSComboBox` in SwiftUI (MED)

`Views/Results/EnumPopoverContentView.swift:36-66`.
`Views/Results/ForeignKeyPopoverContentView.swift:42-91`.

What's wrong:

- Both views are SwiftUI `List` + `NativeSearchField` (which itself is `NSViewRepresentable` wrapping `NSSearchField`) inside an `NSPopover` (via `PopoverPresenter`). That is the triple-host stack from S3.
- `EnumPopoverContentView` is, semantically, a single-selection picker over a fixed list. That is `NSPopUpButton` (with `pullsDown = false`) or, if the list is long enough to need search, `NSComboBox` with `usesDataSource = true`.
- `ForeignKeyPopoverContentView` adds async loading and a search field. Native equivalent: an `NSPopover` containing an `NSViewController` with `NSSearchField` + `NSTableView` (single column, single selection). The "load-then-display" lifecycle is one `Task` on `viewWillAppear`, and selection commits via `tableViewSelectionDidChange(_:)`.
- The SwiftUI `.onKeyPress(.return)` handlers (`Enum:59-63`, `FK:77-82`) are necessary because SwiftUI `List` does not give us first-responder keyboard handling for free in a popover. AppKit `NSTableView` does.
- `currentValue == row.id` styling is a one-off `if/else` in SwiftUI; in AppKit it's the table view's selection state plus a row highlight style.

Native-correct fix:

- `EnumPopoverContentView` → drop the popover wrapper entirely. The cell editor for an enum column should attach an `NSPopUpButton` as the edit control (or, for inline editing, the cell's `NSTextField` opens an `NSPopUpButton` programmatically). For "fits in a popover" UX, an `NSPopover` containing one `NSTableView` is the right shape; no SwiftUI list, no search field unless the enum has more than ~50 entries.
- `ForeignKeyPopoverContentView` → `NSPopover` with an `NSViewController` whose view is `NSStackView` { `NSSearchField`, `NSScrollView { NSTableView }` }. Async loading goes in `viewWillAppear()`. Commit on `doubleAction` or Return.
- This also removes `NativeSearchField` from these two callers, since `NSSearchField` is now the actual subview.

Reference: `NSPopUpButton`, `NSComboBox`, and "NSTableView Programming Guide" Apple Developer documentation.

### S9 - Other `NSViewRepresentable` wrappers worth a pass

Checked while auditing; all are appropriate single-boundary wraps of an AppKit primitive into SwiftUI. None nest hosting controllers:

- `NativeSearchField` - wraps `NSSearchField`. Correct.
- `JSONSyntaxTextView` - wraps `NSTextView`. Correct.
- `HighlightedSQLTextView`, `ChatComposerTextView`, `StartupCommandsEditor`, `AIRulesEditor` - all wrap `NSTextView` for editor surfaces. Correct.
- `HexDumpDisplayView`, `HexInputTextView` - wrap `NSTextView` for hex content. Correct.
- `ShortcutRecorderView` - wraps custom `NSView` for key recording. Correct.
- `WindowAccessor`, `WindowChromeConfigurator`, `TerminalFocusHelper` - empty view side-effect helpers. Correct *use* of `NSViewRepresentable`, but `WindowAccessor` style helpers are a code smell; track but don't refactor here.
- `DoubleClickDetector` - wraps gesture recognizer to add double-click semantics over a SwiftUI row. This is reasonable today, but if we move the sidebar to `NSOutlineView` (S5) it disappears.
- `TristateCheckbox` - wraps `NSButton` with `.allowsMixedState`. Correct.
- `QuerySplitView` - uses `NSViewControllerRepresentable` (the right pick for a parent that owns child VCs).

The only `NSViewRepresentable` that is *misused* is `DataGridView` itself - see S1. It is wrapping an `NSScrollView` whose document view is an `NSTableView` whose delegate is the `Coordinator`. That is conceptually three view controllers' worth of state living on a `Coordinator` object, which is why the `updateNSView` body is doing controller-level work. The right base type for that surface is `NSViewControllerRepresentable`, with a real `NSViewController` subclass (`DataGridViewController`) that owns the scroll view, table view, header view, drag types, autosave, and column pool. That viewController is also where `viewWillAppear` / `viewDidDisappear` give us natural hooks for `observeTeardown` and `dismantleNSView` work that today is scattered across `makeNSView` / `dismantleNSView` / `Coordinator`.

## 2. State-system mismatches: `@State` vs `@Binding` vs `@Observable`

Rules the rewrite should hold:

- **`@State`** for value-type UI state local to one view that no other view needs to read. Examples in current code that are correct: `FilterPanelView.showSQLSheet`, `EnumPopoverContentView.searchText` (popover is short-lived).
- **`@Binding`** for two-way handoff of `@State` or model properties owned elsewhere. Use only when the parent already owns the canonical store. Today's misuse: `RedisKeyTreeView.expandedPrefixes` is `@Binding Set<String>` constructed in `SidebarView:225` from `keyTreeVM.expandedPrefixes`. This works but the canonical pattern with `RedisKeyTreeViewModel` being `@Observable` is `@Bindable var keyTreeVM` and pass `$keyTreeVM.expandedPrefixes` directly - no manual `Binding(get:set:)` adapter.
- **`@Observable` (Swift Observation)** for reference-type state shared across views. Already adopted by `SharedSidebarState`, `SchemaService`, `SidebarViewModel`. Use `@Bindable` at the call site to derive bindings.
- **`ObservableObject` + `@Published`** is legacy. The only remaining offender after S2 is `FilterValueTextField.SuggestionState`. Migrate to `@Observable`.
- **`@StateObject`** does not appear in the audited files; if it shows up, it should be `@State` of an `@Observable` type.

Where TablePro picks the wrong one today:

- `SidebarViewModel.searchText` is `@Observable`-tracked but should not exist at all (S6).
- `FilterValueTextField.SuggestionState` is `ObservableObject` and should be `@Observable` (S2).
- `RedisKeyTreeView.expandedPrefixes` is `@Binding Set<String>` constructed via manual `Binding(get:set:)` rather than `@Bindable var keyTreeVM` (S5 cleanup).
- `DataGridView` uses `@Binding selectedRowIndices` etc., which is correct for SwiftUI parents, but the *coordinator* should be `@Observable` so the SwiftUI side can derive bindings without round-tripping through `@Binding`.

## 3. Target rule set

Adopt these as the single boundary contract for the rewrite. They are derived from Apple's documented patterns and the findings above.

### 3.1 The "AppKit-first surface" rule

If a surface is fundamentally one of the following, use AppKit directly. Do not wrap in `NSViewRepresentable`. Do not host in a SwiftUI parent except at the topmost split-view level.

| Surface | Native control | Why |
|---|---|---|
| Tabular data grid | `NSTableView` (in `NSScrollView`, in `NSViewController`) | Cell reuse, row redraw, drag, drop, autosave, accessibility for free |
| Hierarchical tree | `NSOutlineView` | Lazy expansion, autosave expansion, `NSTreeController` if needed |
| Window/workspace toolbar | `NSToolbar` + `NSToolbarItem` | Customization sheet, overflow menu, notarized look |
| Menu bar / context menu | `NSMenu` | Validation chain, key equivalents, services |
| Filter rules / predicate UI | `NSPredicateEditor` | Accessibility, localization of operators, undo |
| Single-choice picker (≤~50 fixed items) | `NSPopUpButton` | System styling, focus ring, `controlSize` |
| Searchable choice from a list | `NSComboBox` or `NSPopover { NSSearchField + NSTableView }` | Free first-responder, free arrow-key handling |
| Text editor (multi-line, syntax-aware) | `NSTextView` (inside `NSScrollView`) | Layout manager, find bar, ruler, accessibility |

Boundary rule: each AppKit-first surface gets exactly one `NSViewControllerRepresentable` (preferred) or `NSViewRepresentable` wrapper at the SwiftUI/AppKit seam. Inside that wrapper, the view controller is pure AppKit. No nested `NSHostingController`. No nested `NSViewRepresentable`.

### 3.2 The "SwiftUI-first surface" rule

If a surface is one of the following, use SwiftUI directly. Do not drop into AppKit unless wrapping a primitive that SwiftUI does not ship.

| Surface | SwiftUI |
|---|---|
| Settings panes | `Form { Section { ... } }` |
| Connection form | `Form` with `TextField`, `Picker`, `SecureField` |
| Modal dialogs (alert/confirmation) | `.alert`, `.confirmationDialog` |
| Inline popovers with simple state | `.popover(isPresented:)` |
| Onboarding / welcome flows | Plain SwiftUI views |

Boundary rule: a SwiftUI-first surface that needs an `NSTextField`, `NSSearchField`, etc. wraps that one primitive once via `NSViewRepresentable`. No going back into SwiftUI from inside that wrap.

### 3.3 The single-boundary invariant

For any visible surface, there is exactly one SwiftUI ↔ AppKit transition between the window's content view and the leaf widgets the user touches. Counting boundaries:

- `NSPopover` → `NSHostingController` → SwiftUI body containing an `NSViewRepresentable` of `NSSearchField` = **2 transitions**. Violates the invariant. (Today's S3.)
- `NSPopover` → `NSViewController` → `NSStackView` → `NSSearchField` + `NSTableView` = **0 transitions** (pure AppKit). Correct.
- `NSWindow` → `NSHostingView` → SwiftUI form = **1 transition**. Correct (today's `JSONViewerWindowController`).
- `NSSplitViewItem(viewController:)` → `NSHostingController` → SwiftUI body → `NSViewRepresentable` of `NSTableView` = **2 transitions**. Violates. The fix is to make the right pane an `NSViewController` directly (today's `DataGridView` lives one `NSHostingController` deeper than necessary).

### 3.4 `NSViewRepresentable` vs `NSViewControllerRepresentable`

- `NSViewRepresentable`: a single view with no lifecycle semantics. Use for `NSSearchField`, `NSTextField`, `NSButton`, custom one-off `NSView`s.
- `NSViewControllerRepresentable`: anything that owns subviews, has child view controllers, manages first-responder, or wants `viewWillAppear` / `viewDidDisappear` hooks. Use for the data grid, filter panel chrome (if it stays SwiftUI-hosted), Redis tree, FK/Enum popover content.

The current `DataGridView` is `NSViewRepresentable` but does view-controller work in `makeNSView`/`updateNSView` and `dismantleNSView`. Migrate to `NSViewControllerRepresentable` with a real `DataGridViewController`. This is the structural change behind S1.

### 3.5 The `@Observable` rule

- New shared state types: `@Observable` reference type. Read via `let` or `@Bindable`. No `@Published`, no `ObservableObject`.
- Inside SwiftUI: `@State var model = MyObservable()` for owned, `@Bindable var model: MyObservable` for borrowed.
- Bindings to properties: `$model.property` (works because `@Bindable` synthesizes them). Never `Binding(get:set:)` over an `@Observable` property.

### 3.6 The `updateNSView` rule

Every `updateNSView` body must be of the form:

```swift
func updateNSView(_ view: V, context: Context) {
    let snapshot = Snapshot(...)
    if context.coordinator.lastApplied == snapshot { return }
    context.coordinator.apply(snapshot, to: view)
    context.coordinator.lastApplied = snapshot
}
```

`Snapshot` is one `Equatable` struct that captures every input the AppKit view depends on. `apply` is the only place that touches AppKit. `lastApplied` lives on the coordinator (which is exactly what `makeCoordinator` is for, per Apple's "Coordinator" pattern in `NSViewRepresentable` / `NSViewControllerRepresentable` documentation).

## 4. References (Apple)

- "NSViewRepresentable" reference, Apple Developer documentation. Coordinator pattern, `update(_:context:)` contract.
- "NSViewControllerRepresentable" reference. Difference from `NSViewRepresentable`; when to choose which.
- "Adding AppKit Views to a SwiftUI View Hierarchy" article.
- "Adding SwiftUI Views to an AppKit App" article.
- WWDC22 "Use SwiftUI with AppKit" - explicit guidance against nested hosting.
- "Outline View Programming Guide for Mac" - `NSOutlineView` lazy data source pattern.
- "NSTableView Programming Guide" - view-based tables, cell reuse.
- `NSSplitViewItem` reference, macOS 14 inspector behavior.
- SE-0395 *Observability* and "Migrating from the Observable Object protocol to the Observable macro" article - `@Observable`, `@Bindable`, per-property dependency tracking.
- `NSPopover` reference - `behavior`, key event handling, sizing.
- `NSPopUpButton`, `NSComboBox` references - native picker primitives.

## 5. What this implies for the rewrite (handoff to task #10)

The interop work breaks into three independent vertical slices that can land in any order:

1. **Data grid boundary** - replace `DataGridView: NSViewRepresentable` with `DataGridViewControllerRepresentable: NSViewControllerRepresentable`. Pull the property fan-out into a `Snapshot` + `Coordinator.apply` pair. Resolves S1 and unblocks the rendering and threading work in tasks #1 and #4.
2. **Sidebar tree boundary** - replace `RedisKeyTreeView` (and `FavoritesTabView`'s tree) with an `NSOutlineView`-backed `NSViewControllerRepresentable`. Drop `SidebarViewModel.searchText`, route through `SharedSidebarState`. Resolves S5 and S6.
3. **Popover boundary** - replace `PopoverPresenter` with two helpers: `AppKitPopover.show(controller:)` for AppKit-content popovers (Enum, FK, filter suggestion), and let SwiftUI-content popovers use `.popover(isPresented:)` directly. Migrate `EnumPopoverContentView`, `ForeignKeyPopoverContentView`, and `FilterValueTextField`'s suggestion dropdown. Resolves S2, S3, S8.

The right-panel cleanup (S4) is a separate, smaller pass: drop `inspectorHeader` from `UnifiedRightPanelView`, move the segmented picker to the toolbar. No representable changes.

`NSHostingView` in `JSONViewerWindowController` (S7) stays. Document the "one-off window" exception in the rewrite checklist so it doesn't regress.
