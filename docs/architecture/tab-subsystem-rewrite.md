# Tab/Window Subsystem Rewrite

**Status:** PRs 1-5 completed (migration done)
**Branch:** `refactor/tab-subsystem`
**Owner:** Ngo Quoc Dat

## Why

The current tab/window subsystem grew organically and has accumulated structural debt that prevents reliable feature work and causes the Cmd+Number lag bug. Specific problems:

- **God-object**: `MainContentCoordinator` is 1465 lines + 35 extension files (~2000 lines total) covering 12 distinct domains: tab state, window lifecycle, query execution, sorting, filtering, undo, row operations, dialogs, schema loading, plugin-specific logic, file watching, command actions.
- **State fragmentation**: Per-tab state is split across 13 stores — `QueryTabManager`, `DataChangeManager`, `FilterStateManager`, `ColumnVisibilityManager`, `TableRowsStore`, `TabPersistenceCoordinator`, `ConnectionToolbarState`, `GridSelectionState`, plus 5 coordinator-local caches. Tab switching has to manually save/restore from each. `TabFilterState` lives in 3 places at once (live state, snapshot, UserDefaults) and drifts.
- **Two-way coupling**: `MainContentView` creates `MainContentCoordinator` and stores it as `@State`; the coordinator stores weak refs back into the view layer (`dataTabDelegate`, `rightPanelState`, `inspectorProxy`, `commandActions`). Stored closures (`onWindowBecameKey`, `onTeardown`, `onWindowWillClose`) capture view state and fire from AppKit delegate methods — no compile-time lifetime guarantees.
- **Misplaced lifecycle work**: `handleWindowDidBecomeKey` does 4 unrelated jobs (lazy-load, schema refresh, sidebar sync, menu-bounce gate) in 50 lines. Apple's `windowDidBecomeKey(_:)` is documented for lightweight focus-state updates only — heavy work there is the root cause of the Cmd+Number rapid-switch lag.
- **Naming lie**: `MainContentCoordinator` is not Apple's Coordinator pattern; it's a mega-presenter that aggregates everything for a window.

## North star (Apple-documented patterns)

The rewrite targets Apple's documented architecture for macOS multi-window apps. Citations are inline in each section.

**Ownership chain** (from [NSWindowController](https://developer.apple.com/documentation/appkit/nswindowcontroller)):
```
Model → Window Controller (NSWindowController) → View Controller (NSViewController) → SwiftUI views (via NSHostingController)
```

**Lifecycle ownership** (from [viewWillAppear()](https://developer.apple.com/documentation/appkit/nsviewcontroller/1434415-viewwillappear), [viewDidAppear()](https://developer.apple.com/documentation/appkit/nsviewcontroller/viewdidappear()), [windowDidBecomeKey(_:)](https://developer.apple.com/documentation/appkit/nswindowdelegate/1419737-windowdidbecomekey)):

| Event | Apple-documented hook |
|---|---|
| Tab/view became visible to user | `NSViewController.viewWillAppear()` / `viewDidAppear()` |
| Tab/view about to disappear | `NSViewController.viewWillDisappear()` / `viewDidDisappear()` |
| Window became key (focus) | `NSWindowDelegate.windowDidBecomeKey(_:)` — lightweight only |
| Window will close | `NSWindowDelegate.windowWillClose(_:)` |
| Async work tied to view visibility | SwiftUI `.task(id:)` modifier (auto-cancels on disappear) |

**State ownership** (from [Observable](https://developer.apple.com/documentation/observation/observable)): per-tab state lives in one `@Observable` class instance per tab; SwiftUI tracks changes automatically via the Observation framework.

**AppKit ↔ SwiftUI bridging** (from [NSHostingController](https://developer.apple.com/documentation/swiftui/nshostingcontroller), [WWDC22-10075 "Use SwiftUI with AppKit"](https://developer.apple.com/videos/play/wwdc2022/10075/)): NSHostingController owns the SwiftUI view hierarchy; pass state objects as properties; no stored callbacks back from coordinator into views.

**Async cancellation** (from [Task.cancel()](https://developer.apple.com/documentation/swift/task/cancel())): SwiftUI's `.task(id:)` automatically cancels the previous task and starts a new one when the identifier changes. AppKit-side tasks must check `Task.isCancelled` cooperatively.

## Layered architecture

```
┌────────────────────────────────────────────────────────────────┐
│  AppKit Lifecycle Layer                                         │
│   TabWindowController (NSWindowController + NSWindowDelegate)   │
│   MainSplitViewController (NSSplitViewController)               │
│   - viewWillAppear/viewDidAppear drives tab visibility events   │
│   - windowDidBecomeKey is lightweight (focus state only)        │
└────────────────────────────────────────────────────────────────┘
                          ↓ owns
┌────────────────────────────────────────────────────────────────┐
│  Coordinator Layer (1 per NSWindow / window-tab)                │
│   TabGroupCoordinator                                            │
│   - openTab / closeTab / selectTab                               │
│   - owns one TabSession (each NSWindow = 1 tab in current model) │
│   - bridges AppKit lifecycle → TabSession state transitions      │
└────────────────────────────────────────────────────────────────┘
                          ↓ owns
┌────────────────────────────────────────────────────────────────┐
│  TabSession (@Observable @MainActor class — 1 per tab)          │
│   - Replaces 13 scattered stores: filters, columns, rows,       │
│     changes, cursor, schema, results, loading state             │
│   - SwiftUI tracks mutations via Observation framework          │
│   - Conversion to/from QueryTab struct for legacy interop       │
└────────────────────────────────────────────────────────────────┘
                          ↓ uses
┌────────────────────────────────────────────────────────────────┐
│  Service Layer (focused, testable, no UI dependencies)          │
│   QueryExecutor — runs queries, emits results                   │
│   SchemaService — already exists, keep                          │
│   TabPersistenceService — preserves cross-window save invariant │
│   EvictionService — memory pressure / inactive eviction         │
└────────────────────────────────────────────────────────────────┘
                          ↓ rendered by
┌────────────────────────────────────────────────────────────────┐
│  SwiftUI View Layer (thin renderer)                             │
│   TabContentView, MainContentView                                │
│   - Read TabSession via Observation tracking                     │
│   - .task(id: tabSession.loadKey) for query execution           │
│   - No stored closures back to coordinator                      │
└────────────────────────────────────────────────────────────────┘
```

## Concrete type list

| Type | Layer | Responsibility |
|---|---|---|
| `TabWindowController` | AppKit | NSWindowController; routes Cmd+W, owns NSWindowDelegate, hosts MainSplitViewController. Already exists; minor cleanup. |
| `MainSplitViewController` | AppKit | NSSplitViewController; sidebar + content + inspector. Drives `viewWillAppear`/`viewDidAppear`. Already exists; expand lifecycle ownership. |
| `TabGroupCoordinator` | Coordinator | New. Owns one `TabSession`, dispatches lifecycle events to it, manages tab open/close. |
| `TabSession` | Session | New. `@Observable @MainActor` class with all per-tab state. Replaces QueryTabManager+FilterStateManager+ColumnVisibilityManager+TableRowsStore+per-tab DataChangeManager state+ToolbarState. |
| `QueryTab` | Model | Existing struct; kept for persistence (Codable round-trip). TabSession can convert to/from. |
| `QueryExecutor` | Service | New. Runs queries asynchronously, returns results. Replaces 432-line query path inside MainContentCoordinator. |
| `SchemaService` | Service | Existing (`SQLSchemaProvider`); rename and tighten interface. |
| `TabPersistenceService` | Service | Existing logic, refactor name and ownership. Preserves cross-window aggregated-save invariant. |
| `EvictionService` | Service | New. Encapsulates 5s grace period and inactive-tab eviction. |
| `TabContentView` | SwiftUI | Existing `MainEditorContentView`, refactored to read TabSession directly. |

## Per-tab state migration: before → after

| State | Before (current) | After (TabSession field) |
|---|---|---|
| Tab metadata | `QueryTab` struct in `QueryTabManager.tabs` | `TabSession.title`, `tabType`, `isPreview` |
| Query content | `QueryTab.content` | `TabSession.content` |
| Execution state | `QueryTab.execution` | `TabSession.execution` |
| Table context | `QueryTab.tableContext` | `TabSession.tableContext` |
| Display state | `QueryTab.display` | `TabSession.display` |
| Pending edits | `DataChangeManager` (global, multiplexed) | `TabSession.pendingChanges` |
| Filters | `FilterStateManager` (global, snapshot in tab, UserDefaults) | `TabSession.filterState` (single source) |
| Hidden columns | `ColumnVisibilityManager` (global, multiplexed) | `TabSession.columnLayout` |
| Row selection | `GridSelectionState` (global) | `TabSession.selectedRowIndices` |
| Sort state | `QueryTab.sortState` | `TabSession.sortState` |
| Pagination | `QueryTab.pagination` | `TabSession.pagination` |
| Row data | `TableRowsStore[id: tab.id]` | `TabSession.tableRows` |
| Schema/metadata versions | `QueryTab.schemaVersion` etc. | `TabSession.schemaVersion` etc. |
| Load epoch | `QueryTab.loadEpoch` (added in earlier work) | `TabSession.loadEpoch` |
| Toolbar state | `ConnectionToolbarState` (per-coordinator) | `TabSession.toolbarState` |

Result: 13 stores → 1 owner per tab. SwiftUI Observation tracks mutations natively.

## Lifecycle migration: before → after

| Event | Before | After |
|---|---|---|
| Tab visible | `handleWindowDidBecomeKey` lazy-load + 200ms menu-bounce gate | `viewWillAppear` → `.task(id: tabSession.loadKey)` (auto-cancels) |
| Tab hidden | `windowDidResignKey` schedules 5s eviction | `viewWillDisappear` → cancels `.task` + `EvictionService.scheduleEvict` |
| Window key | `windowDidBecomeKey` does 4 jobs | `windowDidBecomeKey` does only focus-state UI (toolbar, command registry, Handoff) |
| Window close | Stored closures + manual ordering invariants | `windowWillClose` → `TabGroupCoordinator.closeAll()` (explicit) |
| Cmd+W | Custom NSWindow subclass intercepts | Same; clean dispatch through coordinator |
| Tab switch (in-window) | Synchronous `handleTabChange` saves/restores from 6 stores | TabSession reference swap (atomic); state lives in session |

## Migration plan (strangler-fig, 5 PRs) — completed

| PR | Status | Deliverable | Removed |
|---|---|---|---|
| PR1 | done | `TabSession` foundation type + tests + this design doc | nothing |
| PR2 | done | Row data + load epoch on TabSession; `TabSessionRegistry` introduced | `TableRowsStore` (later) |
| PR3 | done | `QueryExecutor` service extracted from `MainContentCoordinator` query path | query logic out of coordinator |
| PR4 | done | Lifecycle migration to `.task(id:)` + lightweight `windowDidBecomeKey`; stored closures gone | `onWindowBecameKey`, `onTeardown`, `onWindowWillClose`, `lastResignKeyDate` |
| PR5 | done | Per-tab state ownership: `TableRowsStore`, `ColumnVisibilityManager`, `FilterStateManager` deleted; consumers read/write through coordinator helpers that mutate the active tab. Empty `+MongoDB` extension dropped. Tab-switch save/restore swap removed. | three scattered stores + four extensions |

Each PR shipped independently against `refactor/tab-subsystem`. The Cmd+Number bug fix landed in PR4 as an emergent property of the lifecycle migration; remaining rapid-burst behavior is documented as a platform trade-off in D2 below.

## Migration completed — what changed

**Per-tab state is now in one place.** Each `QueryTab` value owns the runtime state for its tab (`filterState`, `columnLayout.hiddenColumns`, `pendingChanges`, `selectedRowIndices`, `sortState`, `pagination`, etc.). The matching `TabSession` reference (held in `TabSessionRegistry`) holds session-only state (`tableRows`, `isEvicted`, `loadEpoch`) and mirrors `columnLayout`/`filterState` for `@Observable` SwiftUI tracking.

**No more shared per-window managers.** `TableRowsStore`, `ColumnVisibilityManager`, and `FilterStateManager` are gone. Their methods are now instance methods on `MainContentCoordinator` that mutate `tabManager.tabs[selectedTabIndex]` directly and mirror into the matching session.

**No more save/restore swap on tab switch.** `handleTabChange` no longer copies global state in/out of the outgoing/incoming tab snapshots. Switching tabs is a `selectedTabId` change; views observe `tab.filterState` / `tab.columnLayout.hiddenColumns` reactively.

**Persistence moved to small services where appropriate.** `ColumnVisibilityPersistence` (UserDefaults, per-table key) replaced the manager's persistence methods. `FilterSettingsStorage` (already file-based) is unchanged; coordinator helpers just call it at the right boundaries.

**Out of scope (deferred):** `ConnectionToolbarState` per-tab semantics (UX-behavior change), `TabGroupCoordinator` (the design-doc target was a more aggressive split that wasn't necessary once the manager classes were gone), full removal of `MainContentCoordinator` (it remained as the per-window owner — its responsibilities are now scoped properly). The 35 coordinator extension files are kept as domain-cohesive groupings per CLAUDE.md.

## Architectural decisions

### D1. TabSession is a class, not a struct
**Why:** `@Observable` requires a reference type. SwiftUI's Observation framework tracks property accesses on observed instances; structs don't fit this model.
**Cite:** [Observable | Apple Developer](https://developer.apple.com/documentation/observation/observable)
**Alternative considered:** Keep `QueryTab` as struct, wrap in `ObservableObject` with `@Published`. Rejected — `@Published` is legacy Combine; Observation framework (WWDC23) is the documented modern pattern.

### D2. Each NSWindow = 1 TabSession (current native-tab model preserved)
**Why:** The codebase already uses `NSWindow.tabbingMode = .preferred` with one window per tab. Apple documents this as the native pattern. Switching to a custom in-window tab bar would lose native window-tab features (drag-to-detach, OS tab restoration, Cmd+Shift+] navigation).

**Known trade-off (measured 2026-05-03):** With one NSWindow per tab, rapid Cmd+Number bursts (e.g. 100+ presses with key-repeat) are *inherently* slow on macOS. Each press triggers a full window-focus-change: `windowDidResignKey` + `windowDidBecomeKey` + Window Server roundtrip + `NSHostingView` layout pass + SwiftUI Observation invalidation across the shared sidebar state. Our handlers are `0 ms` per event; the cost is in AppKit/Window Server itself. We do NOT use a debouncer/coalescer: the user has explicitly rejected that approach as a hack, and a custom in-window tab bar (the only architectural alternative) was considered and rejected here in favor of native integration. **This is an accepted platform-behavior trade-off, not a bug.** Mitigations applied:
- `selectTab(number:)` wraps `tabGroup.selectedWindow = target` in `NSAnimationContext.runAnimationGroup(duration: 0)` so the AppKit tab-bar transition does not animate or queue (eliminates the "tail of switching after key release" symptom).
- `windowDidBecomeKey` is the lightweight Apple-documented contract (focus-state work only; no data loading) so our per-event cost is `0 ms`.
- Shared per-connection sidebar state is mutated only when the selection actually changes (see `syncSidebarToSelectedTab`).

If a future use case demands sustained-burst Cmd+Number throughput (e.g. power users with 50+ tabs per window), the architecturally clean fix is a custom in-window tab bar (one NSWindow, SwiftUI tab list inside) — that's how Chrome, VS Code, and Linear achieve instant rapid switching. Revisiting D2 should be the first step.
**Cite:** [NSWindow.TabbingMode | Apple Developer](https://developer.apple.com/documentation/appkit/nswindow/tabbingmode-swift.enum)
**Alternative considered:** Multiple TabSessions per window (custom tab bar). Rejected — re-introduces complexity we just removed.

### D3. Strong ownership, no stored closures
**Why:** Current `onWindowBecameKey`/`onTeardown`/`onWindowWillClose` closures capture view state with implicit lifetime. Apple's documented pattern (NSHostingController + property injection) uses strong refs from coordinator → view, with cleanup on dealloc.
**Cite:** [WWDC22-10075 "Use SwiftUI with AppKit"](https://developer.apple.com/videos/play/wwdc2022/10075/) — "A single instance of the coordinator stays for the lifetime of the view."
**Alternative considered:** Keep closures but document lifetime invariants. Rejected — invariants aren't compile-checked, will rot.

### D4. `.task(id:)` for visibility-scoped async work
**Why:** SwiftUI auto-cancels on view disappear and re-fires on identifier change. This is the documented hook for "load when visible, cancel when away" — exactly our lazy-load semantic.
**Cite:** [task(id:priority:_:)](https://developer.apple.com/documentation/swiftui/view/task(id:priority:_:))
**Alternative considered:** Manual `Task` + cancellation in lifecycle methods. Rejected — error-prone; .task(id:) is the documented pattern.

### D5. Coordinator pattern as Apple uses it (not navigation Coordinator)
**Why:** Apple uses `NSWindowController` as the per-window coordinator. Our `TabGroupCoordinator` plays this role. We do NOT introduce a "navigation Coordinator" — Apple's NSWindowController is enough.
**Cite:** [NSWindowController | Apple Developer](https://developer.apple.com/documentation/appkit/nswindowcontroller)

### D6. No `TabSwitchSequencer` / no `EvictionProtocol`
**Why:** Designer's draft proposed a 5-phase tab-switch sequencer and a single-impl `Evictable` protocol. Both are over-engineering. With unified TabSession, switching IS just changing which session SwiftUI displays — there's no multi-phase save/restore. Eviction is a method on TabSession + EvictionService, not a protocol.

### D7. Defer `QueryExecutor` protocol until 2nd implementation exists (YAGNI)
**Why:** Designer's draft has `QueryExecutor` as a protocol. With one implementation, the protocol adds no value. Introduce as a concrete class; protocolize later if a test mock is needed (unit tests can use Swift's mocking via classes).

### D8. Hard-coded 5s eviction grace period
**Why:** Current behavior. Not user-configurable — settings noise users don't want. CLAUDE.md: "don't design for hypothetical future requirements."

### D9. Per-window NSUndoManager scope (Apple-native)
**Why:** Apple's `NSWindow.undoManager` is per-window. Each window/tab session gets its own undo stack. Matches current behavior; no change needed.
**Cite:** [NSWindow.undoManager](https://developer.apple.com/documentation/appkit/nswindow/undomanager)

## Open questions (answered)

1. ✅ Native NSWindow tabs vs custom tab bar — **keep native** (D2).
2. ✅ Migration: strangler-fig vs big-bang — **strangler-fig**, 5 PRs.
3. ✅ Branch — fresh `refactor/tab-subsystem` from main.
4. ✅ Eviction grace — **5s, hardcoded** (D8).
5. ✅ Undo scope — **per-window** (D9).
6. ✅ Plugin-side impact — **app-side only**, `TableProPluginKit` ABI unchanged.

## How the Cmd+Number lag bug is fixed

The bug — rapid Cmd+Number presses cause CPU spike and switching that continues after key release — is fixed in PR4 as an emergent property of the lifecycle migration. Specifically:

1. **`windowDidBecomeKey` becomes lightweight** — no more `runQuery()`, no more schema refresh dispatch in this hook. It only updates focus state (toolbar, Handoff). Fast return = AppKit event queue never backs up.
2. **Tab content lazy-load lives in `.task(id:)`** — SwiftUI auto-cancels on view disappear; rapid switches cancel previous loads instead of stacking them.
3. **No multi-phase save/restore on tab switch** — TabSession swap is atomic. The current handleTabChange's 6 sequential save/restore phases are gone.

The fix is not a "debouncer" or "coalescer." It's the natural consequence of using Apple's documented lifecycle hooks for the right purposes.

## Out of scope

- `TableProPluginKit` ABI / plugin protocol changes
- Plugin-specific code paths (Redis, MongoDB, ClickHouse) — refactored only where they live in `MainContentCoordinator`; plugin contracts unchanged
- AI/sidebar/settings UI
- Database connection lifecycle (`DatabaseManager`, sessions)
- Testing infrastructure changes (still uses Swift Testing)
