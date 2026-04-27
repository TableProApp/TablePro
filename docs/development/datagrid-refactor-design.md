# DataGrid Performance Refactor — Design Document

Branch: refactor/delegate-dispatch (worktree datagrid-perf-arch)
Scope: Phases A through F, single PR

## Canonical Signal Taxonomy

| Signal | Type | Owner | Semantics |
|---|---|---|---|
| schemaVersion | Int on QueryTab | QueryTab | Columns changed: new query result with different column names, types, or count. Bumped by applyPhase1Result. Replaces resultVersion for schema-only concerns. |
| tabStructureVersion | Int on QueryTabManager | QueryTabManager | Tab list changed: add, remove, rename, title update, user-initiated query set. Drives persistence (debounced 300ms). |
| changeManager.reloadVersion | Int on DataChangeManager | DataChangeManager | Cell edit recorded or change state cleared. Drives per-row NSTableView reload. |
| Delegate row-delta calls | DataGridViewDelegate methods | DataGridViewDelegate | Row shape changed: addRow, deleteRows, insertRows. Drives insertRows(at:withAnimation:) / removeRows(at:withAnimation:) directly on NSTableView. No SwiftUI re-eval. |
| selectionState.indices | GridSelectionState | GridSelectionState | Row selection changed. Already isolated. |
| paginationVersion | Int on QueryTab | QueryTab | Page changed. Already correct. |
| metadataVersion | Int on QueryTab | QueryTab | FK / column-type metadata arrived. Already correct. |
| RightPanelState | @Observable class | RightPanelState | Inspector context updated. Already isolated. |

Signals removed: resultVersion as row-mutation counter; onChange(of: tabManager.tabs) driving persistence; queryTextBinding triggering persistence per keystroke.

## Ordering Rationale

A + B in parallel: independent. C requires A (persistence already decoupled from tabs writes) and B (inspectorTrigger already cleaned up). D requires C (DataGridIdentity is now keyed on schemaVersion). E requires D (delegate-delta path wired so RowDataStore can notify NSTableView directly). F always last.

## Phase A — Persistence Decoupling

### Goal
Tab persistence triggers only on structural tab changes, not row mutations or per-keystroke text edits.

### Changes

**`TablePro/Models/Query/QueryTabManager.swift`**
- Add `var tabStructureVersion: Int = 0`
- In each of `addTab`, `addTableTab` (new-tab path only), `addCreateTableTab`, `addERDiagramTab`, `addServerDashboardTab` (new path only), `addTerminalTab` (new path only), `addPreviewTableTab`, `replaceTabContent`: bump `tabStructureVersion += 1` after `selectedTabId = newTab.id`.
- Add `func markTabRenamed(_ tabId: UUID) { tabStructureVersion += 1 }`
- Do NOT bump in `updateTab` (used by result application paths).
- Audit removeTab/closeTab: must bump.

**`TablePro/Views/Main/Child/MainEditorContentView.swift`**
- Lines 129–141 `.onChange(of: tabManager.tabIds)` — replace with `.onChange(of: tabManager.tabStructureVersion)`. Same body.
- `queryTextBinding` lines 356–361 — REMOVE the saveLastQuery block. Per-keystroke persistence is eliminated.

**`TablePro/Views/Main/MainContentView.swift`**
- Line 351 `.onChange(of: tabManager.tabs)` — replace with `.onChange(of: tabManager.tabStructureVersion)` calling new `handleStructureChange()`.

**`TablePro/Views/Main/Extensions/MainContentView+EventHandlers.swift`**
- Remove `handleTabsChange(_:)`.
- Add `handleStructureChange()` body: window title update, preview promotion, `coordinator.persistence.saveNow(...)` with persistableTabs.

**`TablePro/Core/Services/Infrastructure/TabPersistenceCoordinator.swift`**
- If `saveLastQuery(_:)` only called from queryTextBinding, remove it. Otherwise, keep but ensure callers are intentional (tab switch, window close).
- saveNow itself debounces internally via 300ms; if not, add a `pendingSaveTask: Task<Void, Never>?` and 300ms sleep before encoding.

### Risk Callouts
- Loss-on-crash: bump `tabStructureVersion` inside `runQuery()` so every executed query is a structural event. This catches "user committed work."
- Audit all callers of saveLastQuery before removing.

## Phase B — Inspector Decoupling

### Goal
updateSidebarEditState runs inside the 50ms debounce. coordinator.tableMetadata removed from inspectorTrigger.

### Changes

**`TablePro/Views/Main/Extensions/MainContentView+Bindings.swift`**
- `inspectorTrigger` (lines 110–117): drop `metadataTableName` field. Drop `coordinator.tableMetadata?.tableName` read.
- `InspectorTrigger` struct (line 125): drop `metadataTableName: String?`.

**`TablePro/Views/Main/Extensions/MainContentView+Helpers.swift`**
- `scheduleInspectorUpdate(...)` (lines 65–76): move `updateSidebarEditState()` call INSIDE the Task body, after `Task.sleep`. Currently runs synchronously before the debounce.

**`TablePro/Views/Main/MainContentView.swift`**
- Existing `.task(id: currentTab?.tableContext.tableName)` block: extend to call `scheduleInspectorUpdate()` after `loadTableMetadataIfNeeded()` returns. This replaces the implicit observation of coordinator.tableMetadata via inspectorTrigger.

### Risk Callouts
- 50ms lag on inspector field updates after row click — already true for inspector context; making sidebar edit state match is correct.

## Phase C — Version Split + Signal Cleanup

### Goal
Replace QueryTab.resultVersion with QueryTab.schemaVersion (column shape only). Remove row-mutation counter entirely. Row operations drive NSTableView via insertRows/removeRows through DataGridViewDelegate.

### Changes

**`TablePro/Models/Query/QueryTab.swift`**
- Line 67: rename `var resultVersion: Int` → `var schemaVersion: Int`.
- Lines 94, 128: rename in initializers.
- Lines 193–207 `static func ==`: rename comparison.

**`TablePro/Views/Results/DataGridViewDelegate.swift`** (or wherever the protocol lives)
- Add three optional methods to protocol:
  - `func dataGridDidInsertRows(at indices: IndexSet)`
  - `func dataGridDidRemoveRows(at indices: IndexSet)`
  - `func dataGridDidReplaceAllRows()`
- Provide default empty implementations in extension.

**TableViewCoordinator (in DataGridView.swift or sibling)**
- Add `applyInsertedRows(_ indices: IndexSet)` calling `tableView.insertRows(at: indices, withAnimation: .slideDown)`
- Add `applyRemovedRows(_ indices: IndexSet)` calling `tableView.removeRows(at: indices, withAnimation: .slideUp)`
- Add `applyFullReplace()` calling `tableView.reloadData()`
- After each delta call, also call existing `updateCache()` so cachedRowCount stays in sync.

**`TablePro/Views/Main/Child/DataTabGridDelegate.swift`**
- Implement the three new protocol methods, forwarding to coordinator's apply* methods.

**`TablePro/Views/Main/MainContentCoordinator.swift`**
- Add `@ObservationIgnored weak var dataTabDelegate: DataTabGridDelegate?`
- Wire in MainEditorContentView.onAppear; clear in onTeardown.

**`TablePro/Views/Main/Extensions/MainContentCoordinator+RowOperations.swift`**
- Line 30 addNewRow: remove `resultVersion += 1`. Add `dataTabDelegate?.dataGridDidInsertRows(at: IndexSet(integer: result.rowIndex))`.
- Line 53 deleteSelectedRows: remove bump. Add `dataTabDelegate?.dataGridDidRemoveRows(at: IndexSet(indices))`.
- Line 74 duplicateSelectedRow: remove bump. Add insertRows.
- Line 85 undoInsertRow: remove bump. Add removeRows.
- Line 99 undoLastChange: remove bump. Add `dataTabDelegate?.dataGridDidReplaceAllRows()` (conservative).
- Line 113 redoLastChange: remove bump. Add replaceAllRows.
- Line 171 pasteRows: remove bump. Add insertRows with multiple indices.

**`TablePro/Views/Main/MainContentCoordinator.swift`**
- Lines 1395 and 1401: REMOVE `changeManager.reloadVersion += 1` from sort completion. Sort drives via querySortCache + provider rebuild via sortState mismatch.

**`TablePro/Views/Main/Extensions/MainContentCoordinator+MultiStatement.swift`**
- Line 252: rename to `schemaVersion += 1`.
- Line 271: REMOVE the `changeManager.reloadVersion += 1` (double-signal).

**`TablePro/Views/Main/Child/MainEditorContentView.swift`**
- Line 507 (pin toggle in resultTabBar): REMOVE the `resultVersion += 1`. Add a local `@State var displayRefreshToken: UUID = UUID()` toggled in onPin and use `.id(displayRefreshToken)` on the relevant subview if needed.
- Line 165 `.onChange(of: tabManager.selectedTab?.resultVersion)`: rename to schemaVersion.
- `RowProviderCacheEntry` (lines 23): rename resultVersion → schemaVersion.
- `cacheRowProvider`, `rowProvider(for:)`: rename version checks.
- DataGridView call site (lines 543–547): rename parameter resultVersion → schemaVersion.

**`TablePro/Views/Results/DataGridView.swift`**
- Line 67 `var resultVersion: Int = 0`: rename to schemaVersion.
- Lines 38–61 `DataGridIdentity` struct: rename field.
- Lines 239–248 identity construction: rename.

**`TablePro/Views/Main/MainContentCoordinator.swift`** applyPhase1Result
- Find the `updatedTab.resultVersion += 1` call. Rename to schemaVersion.

### Migration Sequence within Phase C
1. Rename resultVersion → schemaVersion across all files.
2. Add delegate protocol methods + extension defaults.
3. Implement TableViewCoordinator apply* methods.
4. Implement DataTabGridDelegate forwarding.
5. Add coordinator's weak dataTabDelegate reference.
6. Replace each row op's resultVersion bump with the appropriate delegate call.
7. Remove sort-completion reloadVersion bumps.
8. Remove pin-toggle resultVersion bump.
9. Remove double-signal in applyMultiStatementResults.

### Risk Callouts
- Row index ordering for removeRows: must use pre-deletion indices, sorted descending if mutating in single call. Verify rowOperationsManager returns correct sets.
- After each delta, update coordinator.cachedRowCount.
- Invalidate querySortCache on row add/delete (cache holds stale indices otherwise).
- Phase 2 metadata path still uses metadataVersion — separate from schemaVersion.

## Phase D — DataGridConfiguration Equatable + Body Cleanup

### Goal
DataGridConfiguration : Equatable; updateNSView short-circuits on equal config. Remove imperative dataTabDelegate writes from MainEditorContentView body.

### Changes

**`TablePro/Views/Results/DataGridConfiguration.swift`** (or wherever defined)
- Add `: Equatable`. Verify all fields are Equatable (DatabaseType is String-based; should already conform).

**`TablePro/Views/Results/DataGridView.swift`**
- DataGridIdentity: add `tabType: TabType` field if missing.
- updateNSView identity guard: no logic change; now correctly covers all relevant config fields.

**`TablePro/Views/Main/Child/MainEditorContentView.swift`**
- Lines 530–541: REMOVE the `let _ = { ... }()` imperative block.
- Stable refs (coordinator, columnVisibilityManager, selectionState, editingCell, onSort, onFilterColumn, onRefresh): set once in onAppear.
- Mutable refs that depend on isEditable (onCellEdit, onAddRow, onUndoInsert): set via `.onChange(of: tabManager.selectedTab?.tableContext.isEditable)` and any other dependent properties.
- Delegate computes `shouldShowEmptySpaceMenu` itself from coordinator instead of receiving via closure.

### Risk Callouts
- DatabaseType Equatable conformance: verify it's a String-based struct (it is per CLAUDE.md).
- Delegate property may be stale for one render frame after isEditable change; use `.onChange(initial: true)` if needed.

## Phase E — Move Row Data Out of QueryTab into RowDataStore

### Goal
Row data lives in RowDataStore keyed by tab.id. QueryTab becomes pure metadata. SwiftUI never sees row mutations.

### New Type

**New file: `TablePro/Core/Services/Query/RowDataStore.swift`**

```
@MainActor @Observable
final class RowDataStore {
    private var store: [UUID: RowBuffer] = [:]
    func buffer(for tabId: UUID) -> RowBuffer
    func setBuffer(_ buffer: RowBuffer, for tabId: UUID)
    func removeBuffer(for tabId: UUID)
    func evict(for tabId: UUID)
    func evictAll(except activeTabId: UUID?)
}
```

@ObservationIgnored on `store` so SwiftUI does not observe individual buffer changes through this dictionary. Reads/writes go through methods.

### Changes

**`TablePro/Views/Main/MainContentCoordinator.swift`**
- Add `let rowDataStore = RowDataStore()`.
- Pass through to MainEditorContentView as new parameter.

**`TablePro/Models/Query/QueryTab.swift`**
- Remove `var rowBuffer: RowBuffer`.
- Remove all proxy properties: resultColumns, columnTypes, columnDefaults, columnForeignKeys, columnEnumValues, columnNullable, resultRows.
- Keep schemaVersion, metadataVersion, paginationVersion, content, display, execution, filterState, sortState, columnLayout, tableContext.
- Update init(from persisted:) — no rowBuffer init.
- Update `==`: remove row-related field checks.

**Replace all `tab.rowBuffer` and proxy reads** across:
- MainContentCoordinator+RowOperations.swift (writes too)
- MainContentCoordinator+MultiStatement.swift (applyMultiStatementResults: write columns/rows to rowDataStore.buffer(for: tabId))
- MainContentCoordinator+LoadMore.swift (loadMoreRows / performFetchAll: append to buffer in store)
- MainContentView+EventHandlers.swift (updateSidebarEditState)
- MainContentView+Bindings.swift (selectedRowDataForSidebar)
- MainContentView+Helpers.swift (buildQueryResultsSummary)
- MainEditorContentView.swift (makeRowProvider, sortIndicesForTab, resultsSection, JSON view)
- Export paths in MainContentView.swift

with `coordinator.rowDataStore.buffer(for: tab.id)` accesses.

**`TablePro/Models/Query/QueryTabManager.swift`**
- replaceTabContent: remove `tab.rowBuffer = RowBuffer()`. Caller must clear via `coordinator.rowDataStore.setBuffer(RowBuffer(), for: selectedId)`.

**Eviction**
- evictInactiveRowData → delegate to `rowDataStore.evictAll(except: tabManager.selectedTabId)`.
- teardown → `rowDataStore.evictAll(except: nil)`.

### Migration Sequence
1. Create RowDataStore.swift.
2. Add to coordinator + pass into view.
3. Migrate write paths (applyPhase1Result, applyMultiStatementResults, RowOperations, LoadMore).
4. Migrate read paths (sidebar, json, sort, provider).
5. Remove rowBuffer + proxies from QueryTab.
6. Update teardown / eviction.

### Risk Callouts
- ResultSet buffers (tab.display.resultSets[i].rowBuffer) — out of scope for Phase E. Keep ResultSet local row data as-is.
- InMemoryRowProvider holds RowBuffer reference — must be invalidated on schemaVersion bump (already covered by RowProviderCacheEntry.schemaVersion check).
- PersistedTab does not reference rowBuffer — verify.
- All row-data access is on @MainActor — coordinator extensions already are.

## Phase F — Build, Lint, CHANGELOG, Manual Verify

### Commands
```
xcodebuild -project TablePro.xcodeproj -scheme TablePro -configuration Debug build -skipPackagePluginValidation
swiftlint lint --strict
```

### CHANGELOG.md (Unreleased > Changed)
- DataGrid persistence triggers only on structural tab changes (add/remove/rename), not on row mutations or keystrokes
- Inspector sidebar edit state updates inside 50ms debounce instead of immediately on every result version change
- DataGrid row operations (add/delete/duplicate/paste/undo/redo) use NSTableView insertRows/removeRows instead of full reloadData
- Row data moved out of QueryTab @Observable array into RowDataStore, eliminating SwiftUI observation cycles for row mutations
- Removed spurious resultVersion bumps from pin toggle, sort completion, and multi-statement double-signal

### Manual checklist
1. Connect to test DB; open table with 500+ rows.
2. Add/delete/duplicate/paste rows: verify NSTableView animations, no full reload.
3. Cell edit + save + undo + redo.
4. Sort large query result: no flicker.
5. Pin result set: data grid stays stable.
6. Multi-statement query: results appear once.
7. Switch tables rapidly: no stale data.
8. Type 100 chars: zero persistence I/O.
9. Tab restoration after close/reopen.
10. Inspector: 50ms debounced field display.

## Cross-Cutting

- No comments in source. No backward-compat shims. Native macOS only.
- New user-facing strings: none in this refactor.
- swiftlint --strict must pass.
- Tests: QueryTabManager tabStructureVersion increments correctly; RowDataStore CRUD; DataGridViewDelegate delta methods called with correct indices.
