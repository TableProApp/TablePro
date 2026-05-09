# DataGrid Native Rewrite, 04. Threading & Concurrency

**Audit scope:** every off-main violation, redundant Task hop, missing debounce, leaked Combine subscription, and unstructured async on the read/render and selection paths of the TablePro DataGrid. Defines the structured-concurrency target architecture grounded in Apple's documented APIs.

**Source basis:**
- TablePro: `Views/Results/DataGridCoordinator.swift`, `Views/Results/DataGridView.swift`, `Views/Results/ResultsJsonView.swift`, `Views/Results/TableRowsController.swift`, `Views/Results/CellOverlayEditor.swift`, `Views/Results/Extensions/DataGridView+Editing.swift`, `Views/Results/Extensions/DataGridView+Selection.swift`, `Core/Database/DatabaseManager.swift`, `Core/Plugins/PluginDriverAdapter.swift`, `Core/Database/ConnectionHealthMonitor.swift`, `Core/Events/AppEvents.swift`
- Gridex: `gridex/macos/Presentation/Views/DataGrid/AppKitDataGrid.swift`
- Sequel-Ace: `Source/Controllers/MainViewControllers/SPCustomQuery.{h,m}` (`SPQueryProgressUpdateDecoupling`)
- Audit context: `docs/refactor/datagrid-native-rewrite/../DATAGRID_PERFORMANCE_AUDIT.md` §2.4

**No code changes.** This file is the structured-concurrency target architecture for sprint planning.

---

## 0. TL;DR

The render path is `@MainActor` end-to-end, which is correct, but it is not *structured*: heavy work (`JSONTreeParser.parse`, `JsonRowConverter.generateJson`, `preWarmDisplayCache`) runs on main, debounces use `DispatchQueue.main.asyncAfter` instead of cancellable tasks, an event subscription drives `reloadData` with no coalescing, and several `Task { @MainActor in ... }` jumps fire from contexts that are already on the main actor. The blueprint replaces all of this with:

- An `actor DataGridStore` that owns the row buffer, change manager, and prepared display cache.
- A `@MainActor final class DataGridCoordinator` that only renders, never formats.
- One `AsyncStream<DataGridChange>` per attached coordinator, debounced through `swift-async-algorithms` `.debounce(for: .milliseconds(100))`.
- Heavy work (`JSON parse`, `format pre-warm`, `DDL render`) on `Task.detached(priority: .userInitiated)` with explicit cancellation tokens.

Citations: SE-0306 actors, SE-0314 `AsyncStream`, swift-async-algorithms `AsyncDebounceSequence`, Apple's "Updating an app to use Swift concurrency" (WWDC21 720), `NSDataAsset`, OSAllocatedUnfairLock.

---

## 1. Findings, by severity

Severity legend: **CRIT** (visible jank or correctness), **HIGH** (perf/leak), **MED** (correctness without user-visible impact today), **LOW** (style).

### 1.1 Redundant Task hops while already on main

**C1, HIGH, `Task { self?.releaseData() }` inside a main-thread Combine callback**
- **Where:** `Views/Results/DataGridCoordinator.swift:186-194` (`observeTeardown`).
- **Why it is wrong:** `AppEvents.shared.mainCoordinatorTeardown` is a `PassthroughSubject` declared on `@MainActor final class AppEvents`. The pipeline `.receive(on: RunLoop.main).sink { ... }` is already executing on the main thread when the closure fires, and `releaseData()` is `@MainActor`-annotated. Wrapping it in `Task { ... }` enqueues an additional unstructured task hop, which (a) defers teardown by at least one runloop turn, leaving the table view alive while subsequent work assumes it is gone, and (b) detaches the work from any caller cancellation chain. This is the pattern the team-lead flagged at the line referenced in the brief.
- **Apple-correct fix:** call `self?.releaseData()` directly. If you want to ensure the dispatch lands after the current draw cycle, schedule via `RunLoop.main.perform`, not `Task { ... }`. Because the closure already captures `[weak self]`, no `Task` wrapper is needed for nil-safety.
- **References:** WWDC21 720 "Swift concurrency: Update a sample app", "If you are already on the actor you want to run on, just call the function." SE-0316 §2.

**C1b, HIGH, `Task { @MainActor in ... }` inside `controlTextDidEndEditing` selectors**
- **Where:** `Views/Results/Extensions/DataGridView+Editing.swift:202-205`, `Views/Results/Extensions/DataGridView+Editing.swift:224-227`.
- **Why it is wrong:** these closures run synchronously from `NSControl` text field delegate callbacks, which are already on the main thread (NSControl text editing always dispatches via the NSResponder chain on main). Wrapping `selectRowIndexes` and `editColumn` in a Task delays the move to the next column by one runloop and competes with the "did finish editing" cleanup, occasionally causing the cell editor to dismiss mid-creation.
- **Apple-correct fix:** schedule the next-column edit via `RunLoop.main.perform { ... }` so it lands on the next runloop turn *after* AppKit has finished tearing down the previous field editor. `Task` is not the tool for "step over to the next runloop turn", that is what `RunLoop.perform` and `OperationQueue.main.addOperation` exist for.

**C1c, MED, `Task { @MainActor in ... }` inside `boundsDidChange` notification observers**
- **Where:** `Views/Results/CellOverlayEditor.swift:131-134`, `:142-145`.
- **Why it is wrong:** the observer is registered with `queue: .main`, so the closure already runs on main. The `Task { @MainActor in ... }` hop loses cancellability (the observer holds no reference to it) and creates a dependency on the runtime's task scheduler latency. If two notifications fire in the same runloop, two Tasks are enqueued, both calling `dismiss(commit:)`.
- **Apple-correct fix:** the observer block already runs on main; call `self?.dismiss(commit:)` directly. If overlay editor dismissal needs to defer until end-of-runloop, use `RunLoop.main.perform`.

### 1.2 Heavy work on main

**C2, CRIT, `JsonRowConverter.generateJson` + `JSONTreeParser.parse` on main inside `onChange(selectedRowIndices)`**
- **Where:** `Views/Results/ResultsJsonView.swift:154-169`, fired from `onChange(of: selectedRowIndices) { rebuildJson() }` at line 60.
- **Why it lags:** with a 50k-row result set and a 5k-row selection, `generateJson` builds a `[[String?]]`-to-JSON encoded string on main, then `JSONTreeParser.parse` re-decodes that string and walks it into an `JSONTreeNode` tree, both O(n) over the full payload. Because they are inside an `onChange` handler attached to the SwiftUI view body, they run synchronously on the main actor and freeze the UI for the duration of the parse.
- **Apple-correct fix:** Move both operations off main with `Task.detached(priority: .userInitiated)`. Push the result back to the view via `@State` set on the main actor:

```swift
@State private var generationToken = UUID()

private func rebuildJson() {
    let token = UUID()
    generationToken = token
    let columns = tableRows.columns
    let columnTypes = tableRows.columnTypes
    let rows = displayRows
    Task.detached(priority: .userInitiated) {
        let converter = JsonRowConverter(columns: columns, columnTypes: columnTypes)
        let json = converter.generateJson(rows: rows)
        let pretty = json.prettyPrintedAsJson() ?? json
        let parse = JSONTreeParser.parse(json)
        await MainActor.run {
            guard token == generationToken else { return }
            cachedJson = json
            prettyText = pretty
            switch parse {
            case .success(let node): parsedTree = node; parseError = nil
            case .failure(let err): parsedTree = nil; parseError = err
            }
        }
    }
}
```

The `generationToken` guard discards stale results when the user changes selection mid-parse. `Task.detached` is required because we need to run *off* `@MainActor`, a plain `Task { ... }` from a SwiftUI view body inherits the main actor.

- **References:** SE-0304 (Structured concurrency); WWDC21 720 "Run heavy work off the main actor with `Task.detached`."

**C2b, HIGH, `preWarmDisplayCache` runs synchronously inside `updateNSView`**
- **Where:** `Views/Results/DataGridView.swift:188-194`, calling `coordinator.preWarmDisplayCache(upTo:)` defined at `DataGridCoordinator.swift:305-327`.
- **Why it lags:** `preWarmDisplayCache` calls `CellDisplayFormatter.format` once per (row, column) cell across the visible viewport (≈ visible rows × column count). For 30 visible rows × 40 columns = 1,200 formatter calls on main, each potentially building a `DateFormatter` or escaping a JSON blob. This blocks the first frame after a result returns.
- **Apple-correct fix:** Off-load to `Task.detached`, push the formatted snapshot back to the coordinator via an actor-confined cache:

```swift
actor DisplayFormatCache {
    private var entries: [RowID: ContiguousArray<String?>] = [:]
    func warm(rows: [Row], columnTypes: [ColumnType], formats: [ValueDisplayFormat?]) { ... }
    func snapshot() -> [RowID: ContiguousArray<String?>] { entries }
}
```

When the snapshot is ready the coordinator (`@MainActor`) pulls it via `await store.displayFormats.snapshot()` and assigns into its own dictionary. Pre-warming during `updateNSView` should never block the paint cycle.

### 1.3 Missing debounce

**C5, CRIT, No debounce between ViewModel change and `reloadData` / `reconcileColumnPool`**
- **Where:** `Views/Results/DataGridView.swift:134-239`, every SwiftUI binding tick re-enters `updateNSView`, which recomputes `latestRows = tableRowsProvider()`, walks `reconcileColumnPool`, calls `coordinator.updateCache()`, possibly triggers `tableView.reloadData()`. Gridex solves this with `viewModel.objectWillChange.receive(on: RunLoop.main).debounce(for: .milliseconds(100), scheduler: RunLoop.main)` at `gridex/macos/Presentation/Views/DataGrid/AppKitDataGrid.swift:153-162`.
- **Why it lags:** rapid edits, sort changes, and `selectedRowIndices` changes each cause a SwiftUI invalidation, and SwiftUI fires `updateNSView` per invalidation. With no debounce, a multi-row delete (drag-select 200 rows, hit Delete) fires 200 `updateNSView` calls in quick succession, each rebuilding the visual state cache and reloading visible rows.
- **Apple-correct fix (preferred):** stop driving `updateNSView` for this. Mirror Gridex by attaching the coordinator to the ViewModel directly via Combine *or* an `AsyncStream`:

```swift
@MainActor
final class DataGridCoordinator: NSObject {
    private var changeStreamTask: Task<Void, Never>?

    func bind(to store: DataGridStore) {
        changeStreamTask?.cancel()
        changeStreamTask = Task { @MainActor [weak self] in
            for await change in store.changes.debounce(for: .milliseconds(100)) {
                self?.apply(change)
            }
        }
    }
}
```

`AsyncStream` is created inside `DataGridStore` actor (SE-0314). `swift-async-algorithms` provides `AsyncDebounceSequence` which suspends until 100 ms of silence elapses, then emits the latest value, exactly the Combine `.debounce` behavior, but cancellable and structured.

- **Apple-correct fix (Combine, if SAA is not pulled in):** keep Combine, mirror Gridex's pattern: `viewModel.objectWillChange.receive(on: DispatchQueue.main).debounce(for: .milliseconds(100), scheduler: DispatchQueue.main).sink { ... }`. Two notes: (1) prefer `DispatchQueue.main` to `RunLoop.main` for `.debounce`, `RunLoop.main` only fires while the runloop is in `.default` mode, so it stalls during scrollwheel events (`NSEventTrackingRunLoopMode`); (2) `.debounce` fires *after* the silence window, so a single change still has a 100 ms delay, combine with `.throttle(for: .milliseconds(100), latest: true)` if first-change-fast + coalesced-after is desired (Sequel-Ace's `SPQueryProgressUpdateDecoupling` is a hand-rolled equivalent of `.throttle`, see §3).

- **References:** swift-async-algorithms `AsyncDebounceSequence` (https://github.com/apple/swift-async-algorithms/blob/main/Sources/AsyncAlgorithms/AsyncDebounceSequence.swift), Combine `Publisher.debounce(for:scheduler:)`. WWDC22 110355 "Meet Swift Async Algorithms".

### 1.4 `DispatchQueue.main.asyncAfter` for debounce/cooldown

**C3, MED, `DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }`**
- **Where:** `Views/Results/ResultsJsonView.swift:89-91`.
- **Why it is wrong:** the closure captures `copied` by reference and there is no cancellation token. If the user clicks Copy twice, two timers fire and the second resets `copied = false` 1.5 s after the second click, fine for this case, but the pattern leaks into others that *do* care about cancellation (e.g. `JSONSyntaxTextView.swift:215`, `HexEditorContentView.swift:128`). It also dispatches via `DispatchQueue` rather than the structured-concurrency runtime, so it is invisible to `Task.cancel()`.
- **Apple-correct fix:** replace with a cancellable `Task`:

```swift
@State private var copyResetTask: Task<Void, Never>?

Button {
    ClipboardService.shared.writeText(cachedJson)
    copied = true
    copyResetTask?.cancel()
    copyResetTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(1500))
        guard !Task.isCancelled else { return }
        copied = false
    }
}
```

Or use `swift-async-algorithms` `AsyncTimerSequence.timer(interval:)` if you want to broadcast the same tick to multiple awaits.

- **References:** `Task.sleep(for:)` (SE-0329 Clock, Instant, Duration). `Task.isCancelled` after suspension is the canonical cancellation read-back.

**C3b, MED, `DispatchQueue.main.asyncAfter` for "lazy reload" debounce in JSON syntax view**
- **Where:** `Views/Results/JSONSyntaxTextView.swift:215`, `Views/Results/HexEditorContentView.swift:128`.
- Same fix shape; consolidate into a single `Debouncer<Action>` actor reused across the codebase.

### 1.5 Combine subscription lifecycle

**C4, HIGH, `themeCancellable` not cancelled when the table view detaches from a window mid-session**
- **Where:** `Views/Results/DataGridCoordinator.swift:176-183` (`observeThemeChanges`), nominal cleanup at `Views/Results/DataGridView.swift:363-369` (`dismantleNSView`).
- **Why it leaks:** `dismantleNSView` is only called when SwiftUI tears down the `NSViewRepresentable`. If the SwiftUI parent stays alive but the underlying `NSTableView` is replaced (which happens on tab type toggles per `DataGridView.swift:113-115` comment), the coordinator persists and the theme/settings cancellables fire `Self.updateVisibleCellFonts(tableView: tableView)` on a stale or already-detached table view. The closure captures `[weak self]` but the subscription itself is not stored in a way that is invalidated when `releaseData()` runs, `releaseData()` at lines 196-215 nils out `delegate` but does not cancel `settingsCancellable` or `themeCancellable`.
- **Apple-correct fix:** cancel both in `releaseData()`. Better, replace the three Combine pipelines with a single `Task { for await event in AppEvents.shared.dataGridEvents { ... } }` and bind its lifetime to the coordinator via a `Task.cancel()` in `releaseData`:

```swift
@MainActor
final class AppEvents {
    let dataGridEvents: AsyncStream<DataGridEvent>
    private let dataGridContinuation: AsyncStream<DataGridEvent>.Continuation

    init() {
        var cont: AsyncStream<DataGridEvent>.Continuation!
        dataGridEvents = AsyncStream { cont = $0 }
        dataGridContinuation = cont
    }

    func emit(_ event: DataGridEvent) { dataGridContinuation.yield(event) }
}

enum DataGridEvent: Sendable {
    case settingsChanged
    case themeChanged
    case mainCoordinatorTeardown(connectionId: UUID)
}
```

Coordinator binds:

```swift
private var eventTask: Task<Void, Never>?

func observeAppEvents() {
    eventTask?.cancel()
    eventTask = Task { @MainActor [weak self] in
        for await event in AppEvents.shared.dataGridEvents {
            guard let self else { return }
            switch event {
            case .settingsChanged: handleSettingsChanged()
            case .themeChanged: Self.updateVisibleCellFonts(tableView: self.tableView)
            case .mainCoordinatorTeardown(let id) where id == self.connectionId: self.releaseData()
            default: break
            }
        }
    }
}

func releaseData() {
    eventTask?.cancel()
    eventTask = nil
    ...
}
```

This collapses three Combine pipelines into one structured-concurrency loop with one cancellation token. `AsyncStream` is multi-producer-single-consumer; if multiple coordinators need the same stream, use an `AsyncBroadcastChannel` (swift-async-algorithms) or split the stream at `AppEvents` per consumer.

- **Note:** if the team prefers to keep Combine, the minimum fix is: `releaseData()` must run `settingsCancellable = nil; themeCancellable = nil; teardownCancellable = nil` to break the retain on subscription closures.

### 1.6 displayCache concurrency contract

**C6, MED, `displayCache` mutation contract is implicit, not enforced**
- **Where:** `Views/Results/DataGridCoordinator.swift:17`, mutations at lines 199, 281, 286, 290, 296, 302, 325, 337, 344.
- **Current state:** `TableViewCoordinator` is `@MainActor`, so all coordinator methods are main-isolated. `PluginDriverAdapter` is a `final class` (no actor isolation, no `@MainActor`), but it is only invoked via `await` from `@MainActor` callers (`DatabaseManager`, `MainContentCoordinator`). The plugin's `executeUserQuery` is `async throws`, so the `await` hops to the plugin's nonisolated executor for the network call, then resumes on `MainActor` after the call returns. Result: `displayCache` is *currently* main-only.
- **Risk:** the `tableRowsProvider: @MainActor () -> TableRows` closure depends on the `@MainActor` annotation on the closure type, which is preserved through `DataGridView.tableRowsProvider`. If anyone refactors `tableRowsProvider` to drop `@MainActor` (e.g. to permit fetching from a background actor), the implicit safety vanishes silently. The compiler will not warn, it will accept the closure if no captured state requires main isolation, but the *callers* of `displayValue(forID:column:rawValue:columnType:)` from `tableView(_:viewFor:row:)` will then race.
- **Apple-correct fix:** make the contract explicit. Either (a) keep the cache on `@MainActor` and document it loudly:

```swift
/// MUST be mutated only on @MainActor. The coordinator's @MainActor isolation
/// is the only enforcement; do not re-enter from `tableRowsProvider` callers.
private var displayCache: [RowID: ContiguousArray<String?>] = [:]
```

Or (b) move it into the `DataGridStore` actor:

```swift
actor DataGridStore {
    private var displayCache: [RowID: ContiguousArray<String?>] = [:]
    func displayValue(forID id: RowID, column: Int) -> String? { ... }
    func warm(visibleRange: Range<Int>, columnCount: Int) async { ... }
}
```

The (b) form is the path forward, it lets the pre-warm step run off main without the coordinator holding the data, and avoids the "silent contract" failure mode. The cell render path then queries `await store.displayValue(forID:, column:)`. `await` from `tableView(_:viewFor:row:)` is forbidden (NSTableView doesn't suspend), so the coordinator caches a synchronous main-actor copy of the prepared dictionary that the store updates atomically:

```swift
@MainActor
final class DataGridCoordinator {
    private var renderedDisplayCache: [RowID: ContiguousArray<String?>] = [:]

    func ingest(_ snapshot: [RowID: ContiguousArray<String?>]) {
        renderedDisplayCache = snapshot
    }
}
```

This is a "snapshot the actor's state to main on push" pattern, same as Gridex's `snapshotFromViewModel()` at `AppKitDataGrid.swift:173-186`.

### 1.7 Hot-path closure caching

**C7, LOW, `tableRowsProvider()` invoked repeatedly per operation**
- **Where:** `DataGridCoordinator.swift:220, 247, 259, 261, 305-307, 331, 397, 405, 450`. Each call materialises a `TableRows` value (a struct, but with `[Row]` and dictionary fields). Inside `applyDelta`, `applyInsertedRows`, `applyRemovedRows`, etc., the closure may be invoked 3-5 times per delta.
- **Why it matters:** `tableRowsProvider` is `@MainActor () -> TableRows`. If the underlying source is a `@Bindable` view model with `@Observable`, each call reads the latest published state. For deltas, that is fine. For *batches* (e.g. iterating over inserted indices to append to `sortedIDs`), the value should be cached once.
- **Apple-correct fix:** snapshot once at the top of each delta-handling method:

```swift
func applyDelta(_ delta: Delta) {
    let tableRows = tableRowsProvider()
    switch delta { ... use `tableRows` everywhere ... }
}
```

For idempotent reads this is safe; for cases where you want to *observe* the post-mutation value, take a second snapshot after the mutator. This is pure micro-optimisation, but the Sequel-Ace IMP-cache pattern (`SPDataStorage.h:93-123`) demonstrates the value of caching the lookup once per inner loop.

### 1.8 ConnectionHealthMonitor

**HM1, sanity OK, 30s ping pattern is correctly off-main**
- **Where:** `Core/Database/ConnectionHealthMonitor.swift`.
- **State:** `actor ConnectionHealthMonitor`, `monitoringTask: Task<Void, Never>?`, `Task.sleep(for: .seconds(Self.pingInterval))` inside a `while !Task.isCancelled` loop. `pingHandler` and `reconnectHandler` are `@Sendable () async -> Bool`. State transitions go through `await onStateChanged(...)` to `@MainActor` callers. Initial jitter `Double.random(in: 0...10)` correctly de-syncs multiple monitors.
- **One observation:** `lastPingTime: ContinuousClock.Instant?` is read/written from the actor's executor, race-free. Logging warns if the interval drifts under 5 s, which is the right canary. The actor is the canonical structured-concurrency pattern for this kind of long-running background work; **do not regress it.**
- **Citations:** SE-0306 actors; Apple's "Connection lifecycle" sample (WWDC21 10133).

### 1.9 Sequel-Ace `IMP` caching → Swift equivalents

Sequel-Ace's `SPDataStorage.h:93-123` caches Objective-C method `IMP` pointers (`cellDataAtRowAndColumn`, `rowAtIndex`, etc.) so the cell render loop can call them as bare C function pointers, bypassing `objc_msgSend` dispatch. In Swift, the equivalent levers are:

- **`final class`** for protocol-witness elimination. Methods on `final class` are statically dispatched, no witness table lookup. The coordinator is already final (`DataGridCoordinator.swift:8`); good. `DataGridStore` (the proposed actor) should be `actor DataGridStore` (actors are implicitly final).
- **`@inlinable` + `@usableFromInline`** for cross-module inlining of hot accessors. Only useful if the type is exposed across module boundaries (e.g. into `TableProPluginKit`). Not needed for in-process render path.
- **`KeyPath<Root, Value>`** lookups compile to a constant offset for stored properties; faster than `dynamicMember` reflection. `Row.values[col]` and `TableRows.rows[index]` are already direct array indexing, already optimal.
- **`ContiguousArray<Element>`** for cache locality. Per audit M8: `Row.values` is `[String?]` (`Array`), which on small sizes is fine, but the prepared display row should be `ContiguousArray<String?>`. Bridging: `Array(contiguousArray)` is O(1) when the source is unique.
- **`OSAllocatedUnfairLock`** instead of `os_unfair_lock_t` (Sequel-Ace's `qpLock` at `.m:3831`). Use this only if you need a non-actor synchronisation primitive in `Sendable` value types, e.g. inside a `final class`-but-not-actor cache that must be passed across isolation domains. Reference: WWDC22 110351 "Eliminate data races using Swift Concurrency".

The render path should not need explicit locks: actor isolation + `@MainActor` is the model. Locks come back if (and only if) we need a `nonisolated let` synchronous accessor across isolation domains.

---

## 2. Structured target architecture

### 2.1 Type roles

```
┌─────────────────────────────────────────┐
│ @MainActor final class                  │
│ DataGridCoordinator (NSTableViewDelegate│
│                      / DataSource)      │
│ - renders cells from `renderedSnapshot` │
│ - owns NSTableView reference            │
│ - emits user-input events to store      │
└──────────┬───────────────────┬──────────┘
           │ async push         │ user events (Sendable)
           │ (snapshot)         ▼
           │              ┌───────────────────────┐
           │              │ actor DataGridStore   │
           │              │ - row buffer (paged)  │
           │              │ - displayCache        │
           │              │ - sortedIDs           │
           │              │ - pendingChanges      │
           └──────────────┤ - changes: AsyncStream│
                          └───────────────────────┘
                                  ▲
                                  │ async fetch
                                  │
                          ┌───────────────────────┐
                          │ DatabaseManager       │
                          │ (@MainActor today)    │
                          │ + plugin executors    │
                          └───────────────────────┘
```

`DataGridStore` is an `actor` (SE-0306). It owns mutable state. Its public surface is async. The coordinator drives input by sending events (`await store.applyEdit(rowID:column:value:)`) and drives output by reading `store.changes` as an `AsyncStream<DataGridChange>`.

### 2.2 The change stream

```swift
enum DataGridChange: Sendable {
    case rowsInserted(IndexSet, snapshot: DisplaySnapshot)
    case rowsRemoved(IndexSet, snapshot: DisplaySnapshot)
    case cellsChanged([CellPosition], snapshot: DisplaySnapshot)
    case fullReplace(snapshot: DisplaySnapshot)
}

struct DisplaySnapshot: Sendable {
    let columns: [String]
    let columnTypes: [ColumnType]
    let rowIDs: [RowID]
    let cells: [RowID: ContiguousArray<String?>]
    let visualState: [RowID: RowVisualState]
}
```

The store yields a snapshot per change. The snapshot is `Sendable` (the cells map carries only `String?` and value types). The coordinator consumes the snapshot on `@MainActor`, atomically replaces `renderedSnapshot`, and calls the matching `NSTableView.insertRows / removeRows / reloadData(forRowIndexes:columnIndexes:)`.

### 2.3 Debounce point

The coordinator binds with a single debounced loop:

```swift
@MainActor
func bind(to store: DataGridStore) {
    changeStreamTask?.cancel()
    changeStreamTask = Task { @MainActor [weak self] in
        let debounced = await store.changes.debounce(for: .milliseconds(100))
        for await change in debounced {
            self?.apply(change)
        }
    }
}
```

`AsyncDebounceSequence` from swift-async-algorithms is the structured-concurrency equivalent of Gridex's `objectWillChange.debounce(for: .milliseconds(100))` at `AppKitDataGrid.swift:153-162`. 100 ms matches the empirical Gridex threshold; 80–120 ms is the acceptable range based on Apple's HIG guidance for "perceptual continuity" (under 100 ms = imperceptible to most users; 200 ms+ = noticeable lag).

If `swift-async-algorithms` is not desired as a dependency, a hand-rolled debounce is short:

```swift
extension AsyncSequence where Element: Sendable, Self: Sendable {
    func debounced(for interval: Duration) -> AsyncStream<Element> {
        AsyncStream { continuation in
            let task = Task {
                var pending: Element?
                var timer: Task<Void, Never>?
                for try await value in self {
                    pending = value
                    timer?.cancel()
                    timer = Task {
                        try? await Task.sleep(for: interval)
                        guard !Task.isCancelled, let v = pending else { return }
                        continuation.yield(v)
                        pending = nil
                    }
                }
                timer?.cancel()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

(The library version is preferred, battle-tested, throttle/debounce/buffer all in one place.)

### 2.4 Off-main heavy work

Every formatter, parser, and serializer runs on `Task.detached(priority: .userInitiated)`:

```swift
func warmDisplayCache(visibleRange: Range<Int>) {
    warmTask?.cancel()
    warmTask = Task.detached(priority: .userInitiated) { [store] in
        await store.warm(visibleRange: visibleRange)
    }
}
```

`Task.detached` is required to escape `@MainActor` inheritance. Inside the detached task, the work happens on the cooperative thread pool, then `await store.ingest(...)` posts the formatted snapshot back to the actor. The coordinator never sees the formatter; it only sees finished `String?` cells in `DisplaySnapshot`.

JSON parse and JSON tree build (the C2 path) follow the same shape:

```swift
func rebuildJsonTree(from snapshot: SelectionSnapshot) {
    jsonTask?.cancel()
    jsonTask = Task.detached(priority: .userInitiated) {
        let json = JsonRowConverter.generate(snapshot)
        let pretty = json.prettyPrintedAsJson() ?? json
        let parsed = JSONTreeParser.parse(json)
        await MainActor.run {
            self.cachedJson = json
            self.prettyText = pretty
            self.applyParse(parsed)
        }
    }
}
```

Cancellation: every time the user changes selection, the previous task is cancelled before it can post stale results.

### 2.5 Cancellation tokens

All `DispatchQueue.main.asyncAfter` delays go through `Task.sleep` with cancellation:

```swift
@MainActor
final class CooldownTimer {
    private var task: Task<Void, Never>?
    func schedule(after: Duration, _ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: after)
            guard !Task.isCancelled else { return }
            action()
        }
    }
    func cancel() { task?.cancel(); task = nil }
}
```

ResultsJsonView's `copied = false` cooldown becomes one `CooldownTimer.schedule(after: .seconds(1.5)) { copied = false }`. The timer auto-cancels on view disappear via a `.task { ... }` lifecycle.

### 2.6 Combine → AsyncStream migration for AppEvents

`AppEvents` keeps its `PassthroughSubject` API for now (used in 20+ files), but adds an AsyncStream view for new consumers:

```swift
@MainActor
final class AppEvents {
    let dataGridSettingsChanged = PassthroughSubject<Void, Never>()
    var dataGridSettingsStream: AsyncStream<Void> {
        AsyncStream { continuation in
            let cancellable = dataGridSettingsChanged.sink { continuation.yield($0) }
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }
}
```

The coordinator binds via `for await _ in AppEvents.shared.dataGridSettingsStream { ... }` inside its single `eventTask`. This avoids the leak in C4 (the stream's `onTermination` cancels the underlying Combine subscription when the consuming Task is cancelled in `releaseData`).

For greenfield events (post-rewrite), use `AsyncStream` directly, drop the Combine subject.

---

## 3. Reference patterns

### 3.1 Gridex (`AppKitDataGrid.swift`)

- **Bind on attach with debounce:** lines 146-163. `bind(to:)` sets `cancellables`, snapshots VM state, then subscribes to `objectWillChange.receive(on: RunLoop.main).debounce(for: .milliseconds(100), scheduler: RunLoop.main)`. This is the empirical "100 ms debounce works" anchor.
- **Visible-rect-only refresh:** lines 274-279. After a non-structural change, walk `tableView.rows(in: tableView.visibleRect)` and call `refreshRow(_:in:)` per row instead of `reloadData()`. Save: O(rows-on-screen) instead of O(rows-in-grid).
- **`MainActor.assumeIsolated` on nonisolated delegate methods:** lines 384-407 (`numberOfRows`, `viewFor`, `rowViewForRow`). NSTableView protocol conformance is declared `nonisolated` so the table view can call them without the runtime asserting actor isolation; `MainActor.assumeIsolated` is the structured-concurrency way to declare "this *is* on main, statically prove it" without paying the cost of a hop. This is the canonical pattern for AppKit delegate methods on `@MainActor` types and we should adopt it.
- **`releaseData()`:** lines 166-171. `cancellables.removeAll()` then nils the data. This is the leak-fix shape for C4.

### 3.2 Sequel-Ace (`SPCustomQuery.m` and `SPQueryProgressUpdateDecoupling`)

Sequel-Ace's progress-update decoupler at lines 3824-3870 implements a hand-rolled coalescing pattern:

1. Background query thread calls `setQueryProgress:` on the decoupler.
2. The decoupler takes `qpLock` (`os_unfair_lock`), writes the new progress, sets `dirtyMarker` if not already set, releases the lock.
3. If `dirtyMarker` flipped from 0 to 1, it does `performSelectorOnMainThread:@selector(_updateProgress) ... waitUntilDone:NO`, this enqueues *one* main-thread call regardless of how many `setQueryProgress:` calls happened in between.
4. `_updateProgress` runs on main, drains the latest value, clears `dirtyMarker`, calls the user-supplied block.

This is a single-flight throttle: the foreground thread sees the *latest* progress, never a queue of stale values. The Swift equivalent for our render path is `AsyncStream` with `.bufferingNewest(1)` on the continuation (SE-0314):

```swift
let (stream, continuation) = AsyncStream<ProgressEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
```

That gives the same coalesce-to-latest behaviour without an explicit lock. The store's `changes` stream uses `bufferingPolicy: .bufferingNewest(16)`, one slot per change kind so that a `cellsChanged` does not get coalesced with a structural `rowsInserted`. The downstream `.debounce(for: .milliseconds(100))` then picks the last value within the window.

Sequel-Ace also hot-caches `objc_msgSend` IMPs at `SPDataStorage.h:93-123` to dodge dispatch overhead. Swift equivalents, `final class`, `actor` (final by definition), `ContiguousArray`, `KeyPath`, were covered in §1.9.

### 3.3 Apple sample reference

- **WWDC21 720, "Update a sample app to Swift concurrency":** the canonical "remove unstructured `Task { ... }` hops when already on main" example.
- **WWDC22 110351, "Eliminate data races":** `OSAllocatedUnfairLock`, `Sendable` checking, actor isolation.
- **WWDC22 110355, "Meet Swift Async Algorithms":** debounce, throttle, merge, combineLatest. The `AsyncDebounceSequence` is exactly the tool we need for C5.
- **`NSDataAsset`:** for any blob preview that loads from the asset catalog. Not directly applicable to live query results, but if the plugin returns binary blobs via asset URLs, prefer `NSDataAsset(name:)` over `Data(contentsOf:)`, NSDataAsset memory-maps under the hood and decompresses lazily.

---

## 4. Action checklist (sprint-ready)

### Sprint 1, quick wins (1–2 days)
- [ ] **C1**: drop `Task { ... }` wrapper at `DataGridCoordinator.swift:190-193`. Call `releaseData()` directly.
- [ ] **C1b**: replace `Task { @MainActor in ... }` at `DataGridView+Editing.swift:202-205, 224-227` with `RunLoop.main.perform { ... }`.
- [ ] **C1c**: drop `Task { @MainActor in ... }` at `CellOverlayEditor.swift:131-134, 142-145`. Call `dismiss(commit:)` directly.
- [ ] **C3**: convert `DispatchQueue.main.asyncAfter` at `ResultsJsonView.swift:89-91` to a cancellable `Task` with `Task.sleep(for: .milliseconds(1500))` and cancel-on-tap.
- [ ] **C4 (minimum)**: nil out `settingsCancellable`, `themeCancellable`, `teardownCancellable` in `releaseData()` before nilling `delegate`. Verify no observers fire on detached table views.

### Sprint 2, architecture
- [ ] **C2**: move `JsonRowConverter.generateJson` + `JSONTreeParser.parse` off main via `Task.detached(priority: .userInitiated)` with a generation token guard.
- [ ] **C2b**: move `preWarmDisplayCache` onto a future `actor DataGridStore` so warming runs detached and pushes a snapshot back to main.
- [ ] **C5**: add `.debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)` between the change source and the coordinator's reload path. Prefer `swift-async-algorithms` `.debounce` if/when SAA is adopted.
- [ ] **C6**: declare the `displayCache` isolation contract explicitly. Migrate to `actor DataGridStore` ownership (push snapshots to a main-actor `renderedSnapshot`).
- [ ] **C7**: snapshot `tableRowsProvider()` once per delta in `applyDelta`, `applyInsertedRows`, `applyRemovedRows`, `displayValue(forID:column:rawValue:columnType:)`.

### Sprint 3, wider concurrency cleanup
- [ ] **C3b**: same Task-based replacement at `JSONSyntaxTextView.swift:215`, `HexEditorContentView.swift:128`. Extract a shared `CooldownTimer` actor.
- [ ] **C4 (preferred)**: replace the three Combine pipelines with a single `AsyncStream<DataGridEvent>` driven from `AppEvents`, consumed in one Task in the coordinator.
- [ ] Adopt `MainActor.assumeIsolated { ... }` on `nonisolated` NSTableView delegate methods (Gridex pattern at `AppKitDataGrid.swift:384-407`).
- [ ] Audit every other `Task { @MainActor in ... }` in `Views/Results/`, `Views/Filter/`, `Views/Connection/`, eliminate if already on main.

### Invariants to preserve
- `ConnectionHealthMonitor` actor pattern (HM1), do not regress.
- `SQLSchemaProvider` in-flight-task pattern (CLAUDE.md), same shape applies to `DataGridStore` for "concurrent callers await the same fetch" if the store fetches lazily.
- `releaseData()` ordering: cancel observers before nilling `delegate` and detaching the table view (mirrors the `ConnectionStorage` "persist before notify" invariant, here "cancel before detach").
- `tableRowsProvider: @MainActor () -> TableRows` annotation. If anyone strips `@MainActor` from this, displayCache races silently.

---

## 5. Open questions for downstream tasks

1. Will `swift-async-algorithms` be added as a SPM dependency? If yes, every debounce/throttle path collapses to one operator. If no, we maintain a small `Debouncer` actor and an `AsyncStream` extension.
2. Should `AppEvents` migrate fully to `AsyncStream`, or stay Combine and add streams as views? 20+ existing call sites today, full migration is a separate task.
3. `DataGridStore` actor: does it own the `DataChangeManager` too, or does the coordinator keep a `@MainActor` change manager and only push deltas to the store? Recommendation: change manager stays main (it drives undo/redo, which is main UI state); store owns the prepared display cache only.
4. Is `RunLoop.main.perform` acceptable for "next runloop turn" semantics, or do we want everything to be a Task? `RunLoop.perform` is the AppKit-native shape for "after the current event loop drains", Tasks are unbounded by event loop modes. For NSTableView edit-step-over (C1b), `RunLoop.perform` is correct; for app logic, Tasks are correct.
5. Plugin drivers are `Sendable` and `async`. If a future plugin spawns its own background task to push streaming rows, the store needs an `ingest(_ row: Row)` async path, confirm the plugin protocol supports that before extending the store.

---

*End of concurrency analysis. Cross-references: §2.4 of the audit, §1.6 of the architecture-anti-patterns doc (TablePro coupling), and Gridex `AppKitDataGrid.swift:146-279` for the empirical reference implementation.*
