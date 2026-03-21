# Performance & Architecture Audit

**Date**: 2026-03-21
**Scope**: Full codebase audit — CPU, memory, leaks, bottlenecks, incorrect Apple patterns
**Status**: Tracking document — check off items as they are fixed

---

## Critical Issues

### 1. MainActor.assumeIsolated in NSEvent Monitor Closures

**Files**:

- `TablePro/Core/Vim/VimKeyInterceptor.swift:85-91`
- `TablePro/Core/AI/InlineSuggestionManager.swift:373-378`
- `TablePro/Views/Editor/EditorEventRouter.swift:74,110,118`

**Problem**: `NSEvent.addLocalMonitorForEvents` callbacks may run on non-main threads. Using `MainActor.assumeIsolated` instead of proper async dispatch risks crashing if the callback fires off-main.

**Correct approach**: Use `DispatchQueue.main.async` or check `Thread.isMainThread` before assuming isolation. Alternatively, Apple docs state local event monitors run on the main thread, but `assumeIsolated` is still fragile if this changes.

**Impact**: Potential crash under rare threading conditions.

---

### 2. MainActor.assumeIsolated in SQLFormatterService

**File**: `TablePro/Core/Services/Formatting/SQLFormatterService.swift:117,156`

**Problem**: `MainActor.assumeIsolated` called in a static/background context without proven MainActor isolation:

```swift
let provider = MainActor.assumeIsolated { SQLDialectFactory.createDialect(for: dialect) }
```

**Impact**: Crash if called from background thread.

---

### 3. Task Leak in Periodic Services

**Files**:

- `TablePro/Core/Services/Infrastructure/AnalyticsService.swift:65-72`
- `TablePro/Core/Services/Licensing/LicenseManager.swift:88-98`

**Problem**: `while !Task.isCancelled` loops use `[weak self]` but continue running after self deallocates. Optional chaining silently no-ops, wasting CPU cycles on sleeping/waking an orphaned task.

**Fix**: Add `guard let self else { return }` after each `Task.sleep`.

---

### 4. Data Race in SchemaProviderRegistry

**File**: `TablePro/Core/Services/Query/SchemaProviderRegistry.swift:49`

**Problem**: Async removal task (5-second delay) races with new provider creation. If a provider is requested during the removal window, the removal completes and destroys the fresh provider.

**Fix**: Cancel the removal task when a new provider is requested for the same connection.

---

## High Priority

### 5. Non-Cached Formatters in Hot Paths

| File                                        | Line    | Formatter           | Context                                   |
| ------------------------------------------- | ------- | ------------------- | ----------------------------------------- |
| `Views/Editor/HistoryPanelView.swift`       | 299-303 | `DateFormatter()`   | Called per history entry on every preview |
| `Views/Structure/ClickHousePartsView.swift` | 121-125 | `NumberFormatter()` | Called per table cell (100+ rows)         |
| `Extensions/String+HexDump.swift`           | 67-70   | `NumberFormatter()` | Called on every large hex dump truncation |

**Fix**: Use `static let` cached formatters (pattern already used correctly in `MainStatusBarView`, `DatePickerCellEditor`, `RightSidebarView`).

---

### 6. Sync I/O on MainActor

**File**: `TablePro/Core/Sync/SyncCoordinator.swift:413`

**Problem**: `applyRemoteChanges()` does storage I/O on MainActor. A TODO comment acknowledges this:

```swift
// TODO: Move storage I/O off @MainActor for large datasets
```

**Fix**: Move to background actor (pattern: `TabDiskActor`).

---

### 7. DatabaseManager connectionStatusVersion Always Incremented

**File**: `TablePro/Core/Database/DatabaseManager.swift:20-27`

**Problem**: `activeSessions` didSet always bumps `connectionStatusVersion`, even when only internal state changes. This triggers re-evaluation in all views observing `sessionVersion`.

**Note**: The per-connection `connectionStatusVersions` dictionary provides fine-grained tracking, but `connectionStatusVersion` (global) still fires broadly.

---

### 8. SQLEditorView: O(n) String Comparison on Every Cursor Move

**File**: `TablePro/Views/Editor/SQLEditorView.swift:49-65`

**Problem**: `onChange(of: editorState.cursorPositions)` compares the full editor text (`currentString != bindingString`) on every cursor position change. For 40MB SQL documents, this is an O(n) comparison per keystroke/click.

**Fix**: Compare only string lengths first (already done), then skip the full comparison or use a hash/generation counter.

---

### 9. Cascading onChange Handlers in MainContentView

**File**: `TablePro/Views/Main/MainContentView.swift:273-375`

**Problem**: 7+ onChange handlers fire in sequence during tab switches: `pendingChangeTrigger`, `selectedTabId` (16ms debounce), `tabs`, `connectionStatus`, `selectedTables`, `tables`, `selectedRowIndices`. The `selectedRowIndices` handler at line 364-375 calls `scheduleInspectorUpdate()` which creates another 100ms delayed Task.

**Impact**: During tab switches, 5-7 handlers fire, creating cascading state updates and potential double-execution.

---

### 10. AIChatPanelView: Array(enumerated()) + Redundant onChange/task

**File**: `TablePro/Views/AIChat/AIChatPanelView.swift:173,50-54`

**Problem**:

- `ForEach(Array(viewModel.messages.enumerated()), id: \.element.id)` creates a new array on every body evaluation
- `.onChange(of: tables)` and `.task(id: tables)` both watch the same value — redundant

---

## Medium Priority

### 11. QueryResultRow O(n) Equality

**File**: `TablePro/Models/Query/QueryResult.swift:15-17`

**Problem**: `Equatable` compares `values: [String?]` array element-by-element. Rows with many columns trigger O(n) comparisons during SwiftUI diffing.

**Fix**: Consider comparing only `id` for SwiftUI identity, or add a generation counter.

---

### 12. ExportTableTreeView: Nested ForEach with Bindings

**File**: `TablePro/Views/Export/ExportTableTreeView.swift:29-37`

**Problem**: `ForEach($databaseItems)` → `DisclosureGroup` → `ForEach($database.tables)`. Expanding a database with 1000 tables triggers 1001 view recreations. Toggle callbacks do O(n) scans with `.contains(true)`.

---

### 13. ThemePreviewCard: Array(zip().enumerated())

**File**: `TablePro/Views/Settings/ThemePreviewCard.swift:159`

**Problem**: `Array(zip(widths, colors).enumerated())` creates new array on every body evaluation.

**Fix**: Use `zip().enumerated()` directly or extract to a computed property with stable IDs.

---

### 14. ConnectionFormView: 5 onChange Handlers Calling Same Function

**File**: `TablePro/Views/Connection/ConnectionFormView.swift:190-194`

**Problem**: Five separate `onChange` handlers (host, port, database, username, additionalFieldValues) all call `updatePgpassStatus()`. Changing database triggers only one handler, but the function is identical across all five.

**Fix**: Consolidate into a single `onChange` watching a tuple or custom struct of all fields.

---

### 15. QuickSwitcherView: withAnimation on Rapid Keypresses

**File**: `TablePro/Views/QuickSwitcher/QuickSwitcherView.swift:144-146`

**Problem**: `onChange(of: viewModel.selectedItemId)` calls `withAnimation(.easeInOut(duration: 0.15))` on every arrow key press. Rapid key presses stack animations causing jank.

**Fix**: Remove animation for keyboard navigation or use `.scrollTo()` without animation.

---

### 16. FilterRowView: Dual Animation on Hover

**File**: `TablePro/Views/Filter/FilterRowView.swift:96-100`

**Problem**: Both `withAnimation` inside `onHover` and `.animation()` modifier on the view. Double-animation during hover.

**Fix**: Use only one animation mechanism.

---

### 17. SidebarView: Animation on Tab Switch

**File**: `TablePro/Views/Sidebar/SidebarView.swift:97`

**Problem**: `.animation(.easeInOut(duration: 0.18), value: sidebarState.selectedSidebarTab)` applied to ZStack with opacity + frame modifiers. Both incoming and outgoing tabs animate simultaneously (3 view hierarchies).

---

### 18. UpdaterBridge: Potential Retain Cycle in KVO

**File**: `TablePro/Core/Services/Infrastructure/UpdaterBridge.swift:32-37`

**Problem**: KVO closure captures `[weak self]` but creates inner `Task { @MainActor [weak self] }`. The double-weak pattern is correct but fragile if the inner task outlives the outer closure.

---

### 19. DataGridView: Set Equality in Identity Struct

**File**: `TablePro/Views/Results/DataGridView.swift:181-189`

**Problem**: `DataGridIdentity` includes `hiddenColumns: Set<String>` comparison, which is O(n) per `updateNSView` call. Tables with 100+ columns make this expensive.

---

### 20. ThemeListView: Computed Filter Properties in Body

**File**: `TablePro/Views/Settings/Appearance/ThemeListView.swift:14-27`

**Problem**: `builtInThemes`, `registryThemes`, `customThemes` call `.filter()` on every body re-evaluation.

**Fix**: Cache in `@State` and update only when `engine.availableThemes` changes.

---

### 21. HistoryPanelView: onChange Without Debouncing

**File**: `TablePro/Views/Editor/HistoryPanelView.swift:143-148`

**Problem**: `onChange(of: dateFilter)` calls `loadData()` without debouncing. If dateFilter changes rapidly, data reloads pile up.

---

### 22. TableStructureView: Cascading onChange Handlers

**File**: `TablePro/Views/Structure/TableStructureView.swift:67-100`

**Problem**: Five onChange handlers on columns, indexes, foreignKeys, selectedTab, selectedRows. Tab change triggers `onSelectedTabChanged()` which may modify columns/indexes, firing their own onChange handlers in a cascade.

---

### 23. MainEditorContentView: onChange with Cache Invalidation

**File**: `TablePro/Views/Main/Child/MainEditorContentView.swift:124-128`

**Problem**: `onChange(of: tabManager.tabIds)` filters cache dictionaries. If `tabIds` is a computed property that recreates frequently, this fires unnecessarily. Filtering is O(n\*m).

---

### 24. AppSettingsManager: Cascading didSet Updates

**File**: `TablePro/Core/Storage/AppSettingsManager.swift:22-98`

**Problem**: Each setting's `didSet` makes multiple cascading updates (storage save, theme engine update, sync tracker notification). Not batched — multiple settings changing in succession cause repeated I/O and notifications.

---

## Verified Good Patterns

These areas were audited and found to be correctly implemented:

| Pattern                      | Files                                                                      | Status                                     |
| ---------------------------- | -------------------------------------------------------------------------- | ------------------------------------------ |
| O(1) string length checks    | SQLContextAnalyzer, CompletionEngine, SQLEditorView                        | ✅ Uses `(string as NSString).length`      |
| Static cached formatters     | MainStatusBarView, DatePickerCellEditor, Date+Extensions, RightSidebarView | ✅ `static let` pattern                    |
| @ObservationIgnored          | 86 occurrences across codebase                                             | ✅ Properly excludes internal state        |
| Actor-based concurrency      | ConnectionHealthMonitor, TabDiskActor, SSHTunnelManager                    | ✅ Proper isolation                        |
| Identity-based reload guards | DataGridView                                                               | ✅ Prevents redundant NSTableView reloads  |
| LazyVStack usage             | AIChatPanelView, ColumnVisibilityPopover, FilterPanelView                  | ✅ Correct for scroll perf                 |
| DateFormattingService cache  | DateFormattingService                                                      | ✅ NSCache with 10K entry limit            |
| RowBuffer eviction           | QueryTab                                                                   | ✅ Keeps only 2 most-recent tabs in memory |
| Generation counter           | queryGeneration in tabs                                                    | ✅ Prevents out-of-order result flashes    |
| Tab persistence truncation   | QueryTab.toPersistedTab, TabStateStorage                                   | ✅ 500KB cap                               |
| Window lifecycle             | WindowLifecycleMonitor                                                     | ✅ Proper weak refs, observer cleanup      |
| Health monitor skip routine  | ConnectionHealthMonitor                                                    | ✅ Skips healthy↔checking UI updates       |

---

## Fix Priority Guide

**Immediate** (potential crashes):

- [x] #1 MainActor.assumeIsolated in NSEvent monitors — Verified safe: Apple docs confirm local event monitors always run on main thread
- [x] #2 MainActor.assumeIsolated in SQLFormatterService — Fixed: Thread.isMainThread check with DispatchQueue.main.sync fallback
- [x] #4 Data race in SchemaProviderRegistry — Fixed: getOrCreate() cancels pending removal tasks

**High** (CPU/memory waste):

- [x] #3 Task leak in periodic services — Fixed: guard self != nil after Task.sleep in both AnalyticsService and LicenseManager
- [x] #5 Non-cached formatters in hot paths — Fixed: static let cached formatters in HistoryPanelView, ClickHousePartsView, String+HexDump
- [ ] #6 Sync I/O on MainActor — Deferred: requires larger refactor (move to background actor)
- [x] #8 O(n) string comparison on cursor move — Fixed: removed full string comparison, O(1) length check only
- [ ] #9 Cascading onChange handlers in MainContentView — Assessed: handlers are independent with debouncing where needed; no change required
- [x] #10 AIChatPanelView array enumeration — Fixed: ForEach uses messages directly, O(1) previous-message check

**Medium** (optimization):

- [ ] #7 connectionStatusVersion over-increment — Mitigated by per-connection version counters; global version used only by backward-compat alias
- [x] #11 QueryResultRow O(n) equality — Fixed: O(1) count check before element comparison
- [x] #12 ExportTableTreeView nested ForEach — Assessed: .contains(true) operates on 2-3 elements; export dialog is rare-use
- [x] #13 ThemePreviewCard array allocation — Assessed: Array() required for ForEach; arrays are 3-4 elements in rarely-rendered settings view
- [x] #14 ConnectionFormView onChange consolidation — Fixed: consolidated 5 onChange into single pgpassTrigger hash
- [x] #15 QuickSwitcherView animation stacking — Fixed: removed withAnimation wrapper, plain scrollTo
- [x] #16 FilterRowView dual animation — Fixed: removed redundant .animation() modifier

**Low** (minor improvements):

- [x] #17 SidebarView animation — Assessed: intentional UX, only fires on user-initiated tab switch
- [x] #18 UpdaterBridge KVO pattern — Verified: already uses [weak self] on both outer and inner closures
- [x] #19 DataGridView set equality — Assessed: Swift Set equality already checks count internally
- [x] #20 ThemeListView computed filters — Assessed: simple filters on small arrays in rarely-rendered settings view
- [x] #21 HistoryPanelView debouncing — Assessed: dateFilter is discrete picker, no debouncing needed
- [x] #22 TableStructureView cascade — Assessed: handlers already guarded with isReloadingAfterSave flag
- [x] #23 MainEditorContentView cache — Fixed: early-exit guard when caches are empty
- [ ] #24 AppSettingsManager cascading didSet — Low impact: only fires on user settings changes
