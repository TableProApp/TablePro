# DataGrid Refactor — Handoff Doc

This doc lets a fresh Claude Code session pick up the data grid refactor without re-deriving context from chat history. Read it top-to-bottom before touching DataGrid code.

## Goal

Replace the data grid's tangled state (six parallel collections, three reload paths, type-erased managers, counter-driven SwiftUI bridge) with a clean, native AppKit architecture: value-type model + delta-driven view updates + controller-owned `NSUndoManager`.

The work is split into 7 + 2 phases. Each phase ships as its own PR and leaves the app fully working between merges. Don't compress phases into one PR — the value of the plan is that it's bisectable.

---

## Phase plan

| Phase | Title | Status | PR | Risk | Notes |
|---|---|---|---|---|---|
| A | TableSelection value type | **MERGED** | #926 | Low | Self-contained; pattern test for value-type approach. |
| B | PendingChanges value type | **OPEN** | #928 | Med | DataChangeManager 962→190 LOC. Three buglets fixed during review (see "Known gotchas"). |
| C | TableRows value type + Delta | Next | — | High | Replaces RowBuffer + InMemoryRowProvider + RowDataStore. Big one. |
| D | Drop SwiftUI counter bridge | After C | — | Med | Removes `reloadVersion` / `lastIdentity` / `lastReapplyVersion` after C lets us drive reloads from deltas. |
| E | Native NSPopover editor | Independent | — | Low | Replaces `CellOverlayEditor` (custom panel). Can run parallel to C/D. |
| F | Controller-owned NSUndoManager | After C | — | Med | Override `NSResponder.undoManager` on the data grid controller. Drops `undoManagerProvider` closure + `onUndoApplied` callback. |
| G | Cleanup | Last | — | Low | Drop `AnyChangeManager`, `RowDeltaApplying`, consolidate extension files. |
| H | Structure tab: selection | After G | — | Low | Reuse `TableSelection`. |
| I | Structure tab: rows + undo | After H | — | Med | Reuse `TableRows` + controller pattern. |

**Decisions locked in** (don't relitigate without explicit user approval):
- One PR per phase
- Controller-owned `NSUndoManager` (separate from the SQL editor, NOT unified through window — see "Known gotchas: window.undoManager is chain-walking")
- Plugin breaking change OK; bump `currentPluginKitVersion` in `PluginManager.swift` when needed
- Tests with each phase
- Performance target: NSTableView's built-in virtualization handles 1M+ rows when paired with server-side pagination (industry standard — TablePlus, DataGrip, Sequel Ace all do this). Don't try to keep 1M rows in memory.

---

## Phases A and B — what landed

### Phase A: `TableSelection`
- File: `TablePro/Views/Results/TableSelection.swift`
- Replaces 4 stored properties on `KeyHandlingTableView` (`focusedRow`, `focusedColumn`, `selectionAnchor`, `selectionPivot`) with one `selection: TableSelection` value type
- Centralized `didSet` calls `selection.reloadIndexes(from: oldValue)` to compute affected cells, replacing two divergent didSet blocks
- Backward-compat accessors keep all call sites unchanged
- Tests: `TableProTests/Views/Results/TableSelectionTests.swift` (17 cases)

### Phase B: `PendingChanges`
- File: `TablePro/Core/ChangeTracking/PendingChanges.swift`
- Consolidates 6 collections into one value type with mutating methods that own cross-collection invariants:
  - `changes`, `changeIndex` (lookup cache), `deletedRowIndices`, `insertedRowIndices`, `modifiedCells`, `insertedRowData`, `changedRowIndices`
- `DataChangeManager` shrunk from ~960 → ~190 LOC; keeps undo/redo registration, plugin SQL generation, `@Observable` integration only
- `applyDataUndo` split into 5 focused per-action helpers
- Renamed `TabPendingChanges` → `TabChangeSnapshot` (it's a serialization DTO, distinct from the live tracker)
- Tests: `TableProTests/Core/ChangeTracking/PendingChangesTests.swift` (~30 cases including regressions)

---

## Known gotchas (don't re-discover these)

### `window.undoManager` walks the responder chain

NSWindow's `undoManager` property walks the responder chain. When a text field is being edited, the field editor (NSTextView) is in the chain and may provide its own undoManager (especially if `allowsUndo = true`). Registering data grid undos on `window.undoManager` while a cell is being edited can land them on the wrong manager, where they're lost when editing ends.

**Current workaround**: `DataChangeManager.undoManagerProvider = { contentWindow?.undoManager }` reads the manager fresh each registration. Works because data grid commits happen from `control(_:textShouldEndEditing:)` which fires after the field editor is leaving the chain. Fragile.

**Phase F fix**: Override `NSResponder.undoManager` on the data grid controller. Then the responder chain finds the controller's manager directly, regardless of whether a field editor is also in the chain. The SQL editor keeps its own; Cmd+Z does the right thing based on focus.

### `changedRowIndices` must be populated by every undo path

The data grid's partial-reload optimization in `DataGridView.reloadAndSyncSelection` reads `consumeChangedRowIndices()`. If empty, it falls through to a `!changeManager.hasChanges` branch that does a **full** `reloadData()` over all rows.

During Phase B I forgot to insert into `changedRowIndices` from PendingChanges' replay methods. Result: every undo back to a clean state did a 33ms full reload over 1k rows (gets worse with more rows).

**Fixed**: every replay/undo method in PendingChanges now calls `changedRowIndices.insert(rowIndex)`. Six regression tests in `PendingChangesChangedRowIndicesTests` enforce this. Don't add a new mutator without preserving this invariant.

### `cellChange.oldValue` must be the original DB value across redo

The OLD `recordCellChangeForRedo` set the cellChange's `oldValue` from the action's `newValue` parameter (which IS the original DB value in the redo direction). I lost that in `reapplyCellChange` and set `oldValue: nil`. Result: edit→undo→redo→undo failed to collapse the change because `revertUpdateCell` couldn't match `previousValue` against the stale `nil` oldValue. Yellow modified-bg stuck on.

**Fixed**: `reapplyCellChange` takes an `originalDBValue` parameter; call site passes `action.newValue`. Regression test: `editUndoRedoUndoCollapses` in `DataChangeManagerExtendedTests`.

### Test fixture must wire up `undoManagerProvider` AND set `groupsByEvent = false`

`DataChangeManager` defaults to no undo manager (provider is nil) so `canUndo`/`canRedo` return false. Tests that exercise undo must:

```swift
let manager = DataChangeManager()
let undoManager = UndoManager()
undoManager.groupsByEvent = false  // tests don't run a runloop
manager.undoManagerProvider = { undoManager }
```

`DataChangeManagerExtendedTests.makeManager` already does this. `DataChangeManagerTests.makeManagerWithUndo` is the equivalent for the smaller test suite.

### NSTableView reloadData() with cellCalls=0 still costs ~37ms per 1k rows

When `tableView.reloadData()` is called with no visible cells re-rendered (because they're not yet drawn or layout hasn't run), it still pays internal bookkeeping cost. We confirmed this with the OSLog trace technique below.

**Implication**: avoid calling `reloadData()` more than once per user action. The data grid's two reload paths (`applyFullReplace` from delegate + SwiftUI's `reloadAndSyncSelection`) used to both fire on undo. Phase 3 (#924) fixed this for undo by replacing `applyFullReplace` with `invalidateCachesForUndoRedo` (cache only, no reload), letting the SwiftUI path do the partial reload.

### Embedded repos in the workspace

Your local workspace likely has `Sequel-Ace/`, `beekeeper-studio/`, `licenseapp/`, `pgadmin4/` checked out as reference. Add them to `.git/info/exclude` (NOT `.gitignore`, since they're personal):

```
Sequel-Ace/
beekeeper-studio/
licenseapp/
pgadmin4/
```

Otherwise `git status` is noisy and `gh pr create` warns about uncommitted changes.

---

## Trace technique for performance investigations

When a user reports lag, don't guess — instrument. Pattern that worked twice:

1. Add `Logger(subsystem: "com.TablePro", category: "UndoTrace")` instances at suspect call sites
2. Wrap key blocks with `let start = Date()` ... `Date().timeIntervalSince(start) * 1000`
3. Have user run:
   ```bash
   log stream --predicate 'subsystem == "com.TablePro" AND category == "UndoTrace"' --level info
   ```
4. They reproduce the lag, paste logs back
5. You find the bottleneck from real measurements
6. Fix
7. Remove tracing (keep timing pattern in head, not in code)

This caught: (a) the 37ms double-reload bug in Phase 3 #924, (b) the missing `changedRowIndices` insert in Phase B.

---

## Repo layout (files most likely to touch in remaining phases)

```
TablePro/
  Core/
    ChangeTracking/
      DataChangeManager.swift        # Phase B/C/F target
      PendingChanges.swift           # Phase B (done)
      AnyChangeManager.swift         # Phase G (delete)
      ChangeManaging.swift           # Phase G (delete)
      DataChangeModels.swift         # mostly stable
    Services/Query/
      RowOperationsManager.swift     # Phase C target (applyUndoResult logic)
  Models/Query/
    RowBuffer.swift                  # Phase C target (replace)
    RowProvider.swift                # Phase C target (InMemoryRowProvider)
    QueryTab.swift                   # uses TabChangeSnapshot
    QueryTabState.swift              # TabChangeSnapshot lives here
  Views/
    Results/
      DataGridView.swift             # Phase D target (drop counter bridge)
      DataGridCoordinator.swift      # Phase D/F target
      KeyHandlingTableView.swift     # Phase A done; Phase F (drop @objc undo:)
      TableSelection.swift           # Phase A (done)
      RowDeltaApplying.swift         # Phase G (delete)
      CellOverlayEditor.swift        # Phase E (replace with NSPopover)
      Extensions/
        DataGridView+*.swift         # many; consolidate in Phase G
    Main/
      MainContentCoordinator.swift   # wires undoManagerProvider/onUndoApplied
      Extensions/
        MainContentCoordinator+RowOperations.swift  # handleUndoResult
  Core/Services/Query/
    RowDataStore.swift               # Phase C target (replace)
TableProTests/
  Core/ChangeTracking/
    PendingChangesTests.swift        # Phase B
    DataChangeManagerTests.swift     # has makeManagerWithUndo
    DataChangeManagerExtendedTests.swift  # has makeManager with provider
  Views/Results/
    TableSelectionTests.swift        # Phase A
```

---

## How to continue

### Picking up where I left off

1. Pull latest main: `git checkout main && git pull`
2. Check #928 (Phase B) status: `gh pr view 928 --json state,mergeable`
   - If still open, give it a `gh pr review --approve` mental pass and merge or wait
   - If merged, you're clear to start Phase C
3. Read this file end to end
4. Start the next phase (currently Phase C unless #928 hasn't merged yet)

### Phase C plan (next up)

Goal: replace `RowBuffer` + `InMemoryRowProvider` + `RowDataStore` with a single `TableRows` value type that emits `Delta`s on mutation.

Sketch:
```swift
struct TableRows: Equatable {
    private(set) var rows: ContiguousArray<Row>
    private(set) var sortIndices: [Int]?
    var pending: PendingChanges    // composes Phase B
    
    @discardableResult
    mutating func edit(row: Int, column: Int, value: String?) -> Delta { ... }
    @discardableResult
    mutating func insert(row: Int, values: [String?]) -> Delta { ... }
    @discardableResult
    mutating func delete(row: Int) -> Delta { ... }
}

enum Delta {
    case cellChanged(row: Int, column: Int)
    case rowsInserted(IndexSet)
    case rowsRemoved(IndexSet)
    case fullReplace
}
```

Controller applies `Delta` to NSTableView via `insertRows(at:)` / `removeRows(at:)` / `reloadData(forRowIndexes:)`. No more `reloadVersion` int counter.

Phase C is high-risk. Expect 2 PRs split:
- C.1: introduce `TableRows` alongside existing types, no callers yet
- C.2: migrate callers, remove old types

### Branch naming

Match the existing convention: `refactor/datagrid-phase4{letter}-{slug}`. Examples:
- `refactor/datagrid-phase4-selection` (A, merged)
- `refactor/datagrid-phase4b-pending-changes` (B, open)
- `refactor/datagrid-phase4c-table-rows` (C, next)

### Commit message style

Project follows Conventional Commits, single line. Examples from this work:
- `refactor(datagrid): extract TableSelection value type from KeyHandlingTableView`
- `fix(datagrid): undo replay paths now mark affected rows as changed`

Don't use AI-generated filler ("seamless", "robust", "comprehensive"). No em dashes. Plain words.

### PR description style

Use the layout: Summary → Why → What → Tests → Files → Test plan. PRs #921, #924, #926, #928 are good templates.

### Don't push without

- `xcodebuild ... build` passes
- Tests for the new code pass
- For visible UI changes: tested manually in the running app

### When the user asks for a "review"

The `/codex:review` plugin works on the current branch's diff vs main. If the workspace has untracked external repos, Codex flags them every time — they're harmless, just paste the verdict and move on. If you've added them to `.git/info/exclude` (see Known gotchas), Codex's noise goes away.

---

## Open questions / parking lot

- **Phase E ordering**: said "after data tab is done" but it's independent and low-risk. If the user wants progress in parallel with C/D, it's a free win.
- **`removeChangeAt` O(n) reindex** in `PendingChanges`: deferred. Pre-existing behavior, not a regression. Could become O(1) with sentinel deletion if profiling shows it's hot — Phase G or later.
- **iOS support**: `Libs/ios/` exists. `TableSelection` and `PendingChanges` are platform-agnostic. View layer (KeyHandlingTableView, DataGridView) is AppKit-only by design. No active iOS work.
- **Multi-cursor in editor + data grid undo**: Phase 3 (#924) made data grid undo go through window.undoManager. Editor uses its own undoManager (CodeEditSourceEditor). Both work today via the responder chain. Phase F formalizes this with `NSResponder.undoManager` override on the data grid controller.

---

## Past audit items already shipped

For reference, the data grid audit produced numbered issues. These are already merged:

- #6 single-click edit on focused cell (#921)
- #7 native NSButton checkbox for booleans → REVERTED, kept text + dropdown (user preference)
- #8 system focus ring (#921)
- #9 VoiceOver above 5k rows (#921)
- #10 Escape no-op outside edit (#924)
- #11 right-click during edit shows native text menu (#924)
- #12 Ctrl+H/J/K/L override deleted then restored (Ctrl+H = deleteBackward in Emacs bindings; Phase F may revisit)
- #24 NSUndoManager unified through window (#924) — Phase F will refine to controller-owned
- #32 tabular clipboard with TSV + HTML (#924)
- #33 multi-cell paste with undo grouping (#924)
- #35 Shift+Tab backward navigation (#924)
- #36 row drag carries TSV + HTML (#924)
- #50 hardcoded date picker font 13 (#921)
- #51 focus border color (#921)
- #52 a11y row/col index ranges (#921)

Issues #19, #20, #54 from the audit: not found in current code; skipped.
