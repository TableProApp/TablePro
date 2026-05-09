# 02 - Data path, display cache, streaming storage

Scope: TablePro's display value pipeline, the per-row display cache, the row-visual-state cache, the page-load model, and the plugin transfer boundary. Compared against Gridex's pre-computed `[[String]]` cache and Sequel-Ace's streaming `SPDataStorage`. Output is a target architecture in concrete Apple-Foundation terms.

Source files inspected (TablePro at audit time):
- `TablePro/Views/Results/DataGridCoordinator.swift`
- `TablePro/Views/Results/DataGridView.swift`
- `TablePro/Views/Results/Extensions/DataGridView+Columns.swift`
- `TablePro/Views/Results/Extensions/DataGridView+Selection.swift`
- `TablePro/Views/Results/TableRowsController.swift`
- `TablePro/Models/Query/TableRows.swift`
- `TablePro/Models/Query/Row.swift`
- `TablePro/Core/Database/DatabaseManager.swift`
- `TablePro/Core/Services/Query/QueryExecutor.swift`
- `TablePro/Core/Services/Query/TableQueryBuilder.swift`
- `TablePro/Core/Services/Formatting/CellDisplayFormatter.swift`
- `TablePro/Models/Query/QueryTabState.swift` (PaginationState)
- `Plugins/TableProPluginKit/PluginQueryResult.swift`
- `Plugins/TableProPluginKit/PluginDatabaseDriver.swift`
- `Plugins/TableProPluginKit/PluginStreamTypes.swift`

Reference codebases:
- Gridex `gridex/macos/Presentation/Views/DataGrid/AppKitDataGrid.swift`
- Gridex `gridex/macos/Presentation/Views/DataGrid/DataGridView.swift`
- Sequel-Ace `Sequel-Ace/Source/Other/CategoryAdditions/SPDataStorage.{h,m}`
- Sequel-Ace `Sequel-Ace/Source/Other/CategoryAdditions/SPNotLoaded.h`
- Sequel-Ace `Sequel-Ace/Source/Controllers/MainViewControllers/SPCustomQuery.m` (`updateResultStore:`, `QueryProgressHandler`)

Cross-reference: `DATAGRID_PERFORMANCE_AUDIT.md` sections 0, 1, 2.2, 3.1, 3.2, 6, 7.

---

## 0. Architecture comparison (data path only)

| Aspect | TablePro (today) | Gridex | Sequel-Ace |
|---|---|---|---|
| Backing store | `TableRows` = `ContiguousArray<Row>` of `Row { id, values: [String?] }`, fully materialised in main-actor RAM. | `[[RowValue]]` materialised in `DataGridViewState`; UI also keeps a separate `[[String]] displayCache` of pre-formatted strings. | `SPDataStorage` wraps `SPMySQLStreamingResultStore`. Untouched rows are proxied from the streaming store; edits live in a parallel `NSPointerArray editedRows`. Never holds the full result in RAM in the UI layer. |
| Display value | Computed on-demand inside `tableView(_:viewFor:row:)` via `displayValue(forID:column:rawValue:columnType:)` (DataGridCoordinator.swift:266). Calls `CellDisplayFormatter.format` (DateFormatter / blob / `nsString.length` truncate) per cell during scroll. | Pre-computed once at load into `vm.displayCache: [[String]]`. Cell render only does an array index read (AppKitDataGrid.swift:319-324). | Truncated at storage layer. Edited rows hard-truncate at 150 chars (`SPDataStorage.m:189`); streaming preview goes through `SPMySQLResultStorePreviewAtRowAndColumn` with caller-supplied `previewLength` (typically 150). |
| Cache shape | `[RowID: [String?]]` dictionary keyed by RowID. Unbounded. (DataGridCoordinator.swift:17) | `[[String]]` index-aligned with `rows`. Bounded by row count (which is itself the page). | Pointer-array of edited rows + pass-through to streaming store. The "cache" is the streaming store itself, which buffers fixed memory. |
| Reverse lookup | `TableRows.index(of: RowID)` is a `for` loop over all rows (TableRows.swift:42). Called from `tableRowsIndex(forDisplayRow:)`, `row(withID:)`, `pruneDisplayCacheToAliveIDs`. | Indices match positionally; no reverse map needed because the cache is index-aligned. | Indices are positional; the streaming store owns the row index space and edited rows are pointer-array slots at the same index. |
| Row visual state | `rowVisualStateCache: [Int: RowVisualState]` rebuilt from scratch on every change (DataGridCoordinator.swift:534). | Two `Set<Int>` (`deletedRows`, `insertedRowIndices`) and one `Set<String>` (`modifiedCells`) recomputed from `pendingChanges` only when the change set actually differs (AppKitDataGrid.swift:108-119). | Pending edits live in the pointer array; "is row edited" is `editedRows.pointerAt(index) != NULL` - O(1) per row. |
| Plugin boundary | `PluginQueryResult.rows: [[String?]]` - Codable, copied across the plugin boundary (PluginQueryResult.swift:6). One full-page allocation per fetch. | N/A (Gridex has no plugin boundary - adapters are in-process actors). | `SPMySQLStreamingResultStore` is the storage. Rows arrive incrementally over the socket; UI reads through `cellDataAtRow:column:` without ever owning the row array. |
| Page loading | SQL `LIMIT/OFFSET` (or `OFFSET … FETCH NEXT`) per page. Each page is a fresh round-trip; previous pages are discarded. (TableQueryBuilder.swift:221, QueryExecutor.swift:131, MainContentCoordinator+Pagination.swift:70). `PluginDatabaseDriver` exposes a streaming variant (`streamRows(query:)`) but it is wired only to export, not to the grid. | Page size 300 in-memory; pagination reloads the whole page. | True streaming. `SPCustomQuery.updateResultStore:` calls `[resultStore startDownload]` and the UI is updated via a poll timer while data still arrives (`SPCustomQuery.m:1149-1155`). |
| Concurrency | `@MainActor` everything. Format runs on main during `viewFor:row:` and during `preWarmDisplayCache(upTo:)` invoked synchronously from `updateNSView` (DataGridView.swift:188-194). | `Combine.debounce(0.1)` on `viewModel.objectWillChange`, snapshot copied to coordinator on main (AppKitDataGrid.swift:153-162). Formatting runs off-main inside the view model. | `pthread_mutex_t` and `@synchronized(self)` in `SPDataStorage`; UI reads from main while a worker thread fills the streaming store. |

Net: TablePro is the only one of the three that formats during scroll, holds the entire page in RAM with an unbounded auxiliary dictionary cache, and runs an O(n) reverse lookup from `RowID` to index.

---

## 1. Issue catalogue

Severity: **CRIT** = visible scroll lag/freeze, **HIGH** = perf or correctness, **MED** = cleanup, **LOW** = polish.

### D1 - On-demand `DateFormatter` / blob / `nsString.length` inside `viewFor:row:`

- Severity: **CRIT**
- TablePro: `DataGridCoordinator.swift:266-283` (`displayValue(forID:column:rawValue:columnType:)`), invoked from `DataGridView+Columns.swift:42-47`.
- Why it lags: `viewFor:row:` is the AppKit hot path during scroll. On a cache miss it allocates a `String?` row cache, calls `CellDisplayFormatter.format` (which calls `DateFormattingService.format(dateString:)`, `BlobFormattingService.formatIfNeeded`, an `NSString` length check, and `sanitizedForCellDisplay`), then back-fills the row cache. First-paint cost is hidden because the run loop yields between cells, but during fast scroll AppKit re-asks for the same rows and the cache is dictionary-keyed by `RowID` (allocated UUID for inserted rows, enum payload otherwise) - every read walks a hash and an `Optional` unwrap chain. `CellDisplayFormatter.maxDisplayLength = 10_000` (CellDisplayFormatter.swift:13) is a 10K char cap; that is too generous for a cell that physically renders ~200 glyphs at the widest column.
- Reference patterns: Gridex `AppKitDataGrid.swift:319-324` only reads `vm.displayCache[row][col]`; formatting was done by the view model when rows landed. Sequel-Ace `SPDataStorage.m:189` returns a 150-char preview at the storage layer.
- Apple-correct equivalent: The format step belongs in the storage layer, not the view layer. Run `CellDisplayFormatter.format` on a background actor when a page lands, store the formatted string into the cache, and have `viewFor:row:` do nothing but `cache[row][col]`. Pre-truncate to ~300 glyphs (the practical width of a wide column on a 27" display at the smallest grid font) to keep `NSAttributedString` allocations bounded. Apple guidance: "Avoid expensive work in `tableView(_:viewFor:row:)`. Prepare data ahead of time." (`NSTableView` documentation, "Tips for displaying large numbers of rows".)

### D2 - `TableRows.index(of:)` is O(n)

- Severity: **CRIT**
- TablePro: `TableRows.swift:42-47`. Used by `tableRowsIndex(forDisplayRow:)` (DataGridCoordinator.swift:259), `row(withID:)` (TableRows.swift:50), `pruneDisplayCacheToAliveIDs()` (DataGridCoordinator.swift:329-338), `removeMissingIDsFromSortedIDs()` (DataGridCoordinator.swift:403-412).
- Why it lags: When the grid is sorted, `displayRow(at:)` does `tableRows.row(withID: sorted[displayIndex])` → `index(of:)` → linear scan. A 5K-row sorted page asks for 5K cell views during initial layout, each one paying O(n) to resolve its row. Net cost is O(n²) per layout. Same scan happens in `pruneDisplayCacheToAliveIDs()` (called on every `rowsRemoved` delta) which builds an O(n) `Set<RowID>` of survivors and then filters the cache.
- Reference patterns: Sequel-Ace and Gridex don't have this problem because their primary key is the integer index. Sequel-Ace's `SPDataStorage` uses pointer-array slot equals row index. Gridex's `displayCache` is index-aligned with `rows`.
- Apple-correct equivalent: Maintain `private var indexByID: [RowID: Int]` in `TableRows`, kept in lockstep with the rows array. Update on `appendInsertedRow`, `insertInsertedRow`, `appendPage`, `removeIndices`, `replace(rows:)`. `index(of:)` becomes `indexByID[id]`. Use `Dictionary.reserveCapacity(rows.count)` after a full replace. Apple Swift documentation: "Dictionary lookup is O(1) on average; resizing when adding many keys is amortised by `reserveCapacity(_:)`" (`Dictionary` reference).

### D3 - `displayCache` is unbounded `[RowID: [String?]]`

- Severity: **HIGH**
- TablePro: `DataGridCoordinator.swift:17`, mutated in `displayValue(forID:column:rawValue:columnType:)` (line 282), `preWarmDisplayCache(upTo:)` (line 305), invalidation paths at lines 285-302, 340-345, 414.
- Why it lags: For a 100K-row paginated view (filter off, sort off, page = 100K because the user bumped the page-size setting) the cache holds 100K × column-count `String?` values. Each `String` is heap-allocated. There is no eviction; the cache is only cleared on `invalidateDisplayCache()` (full clear), `pruneDisplayCacheToAliveIDs()` (filter-into-new-dict copy), `releaseData()` (teardown).
- Reference patterns: Sequel-Ace doesn't keep a UI-side cache - the streaming store owns the bytes. Gridex's `displayCache` is bounded by the rows currently in the view model (page size 300).
- Apple-correct equivalent: `NSCache<NSNumber, NSArray>`, keyed by `displayIndex` (or compound `(pageGeneration, row)` so cache survives across pages of the same query). `NSCache` already implements purgeable-memory eviction under memory pressure (Apple `NSCache` reference: "When the system needs to free memory, it can begin removing cached objects"). Set `countLimit` to 5× the visible-rect row count plus a small padding. `NSCache` is thread-safe by default, which removes the "is the cache mutated off main?" worry from audit C6.
  - Alternative for predictable footprint: a windowed `[String?]?` array sized to `rowCount`, only the visible-range slot populated. Beats `NSCache` for hit rate when scrolling continuously, loses on memory bound. Recommend `NSCache` because the win is bounding worst-case memory, not cache hit rate (the formatter is fast enough to recompute).

### D4 - `rowVisualStateCache` rebuilt O(n) per edit

- Severity: **HIGH**
- TablePro: `DataGridCoordinator.swift:533-577` (`rebuildVisualStateCache()`). Invoked from `applyInsertedRows`, `applyRemovedRows`, `applyDelta(.cellChanged…)`, `applyDelta(.cellsChanged…)`, `applyDelta(.rowsRemoved…)`, `updateNSView`.
- Why it lags: The guard at line 536 (`currentVersion != lastVisualStateCacheVersion`) only short-circuits when the change manager's version did not bump. Any edit bumps the version, so the entire cache is rebuilt. The rebuild iterates `changeManager.rowChanges` plus `insertedRowIndices`. For 5K pending edits this is 5K dictionary writes per single-cell edit.
- Reference patterns: Gridex `AppKitDataGrid.swift:108-120` uses two flat sets and recomputes only when `pendingChanged` is true. Sequel-Ace asks `editedRows.pointerAtIndex(row) != NULL` - O(1) per row, no auxiliary state.
- Apple-correct equivalent: Replace `[Int: RowVisualState]` with three primitive sets:
  ```swift
  struct RowVisualIndex {
      var deleted: Set<Int>
      var inserted: Set<Int>
      var modifiedRows: Set<Int>
      var modifiedColumnsByRow: [Int: Set<Int>]
  }
  ```
  On `applyDelta(.cellChanged(row, column))`: `index.modifiedRows.insert(row); index.modifiedColumnsByRow[row, default: []].insert(column)`. On `.rowsInserted(indices)`: `index.inserted.formUnion(indices)`. Cost is proportional to changed rows, not total rows. Drop the version-counter short-circuit.

### D5 - Plugin boundary returns a full `[[String?]]` copy per page

- Severity: **HIGH**
- TablePro: `PluginQueryResult.swift:6` (`public let rows: [[String?]]`). Created by every `PluginDatabaseDriver.execute(query:)` and `executeUserQuery(query:rowCap:parameters:)`. Consumed at `QueryExecutor.swift:131,153`. The plugin already exposes a streaming variant `streamRows(query:)` (PluginDatabaseDriver.swift:142) wired only to the export pipeline (`StreamingQueryExportDataSource`, `ExportDataSourceAdapter`, `QueryResultExportDataSource`), not to the grid.
- Why it lags: A 100K-row page builds a `[[String?]]` of 100K `Array<Optional<String>>` instances inside the plugin process, then ships it across the Codable boundary, where the grid copies it into a `ContiguousArray<Row>`. Two allocations per row, one full graph traversal per page. Worse, every cell is `String?` regardless of width - a 4-byte int comes across as a heap-allocated `String("123")`.
- Reference patterns: Sequel-Ace `SPDataStorage` consumes rows from `SPMySQLStreamingResultStore` lazily; rows are decoded only when the UI asks for `cellDataAtRow:column:`. Sequel-Ace ships a `previewLength` parameter so the storage truncates the bytes before allocating the `NSString`.
- Apple-correct equivalent: Adopt the streaming protocol that the export layer already uses (`PluginStreamElement.header` / `.rows([PluginRow])`) for the grid path. The bridge across the plugin boundary becomes:
  ```swift
  public protocol PluginDatabaseDriver: AnyObject, Sendable {
      func executeStreamingQuery(
          _ query: String,
          rowCap: Int?,
          parameters: [String?]?
      ) -> AsyncThrowingStream<PluginStreamElement, Error>
  }
  ```
  with a default implementation that wraps `execute(query:)` for plugins that haven't been migrated. This is a `currentPluginKitVersion` bump (CLAUDE.md mandate).
  - Concrete cell-width win: chunk size 1K rows. Header arrives first; the grid reconciles columns and starts rendering placeholders. As `.rows` chunks arrive, the storage layer (see §2) materialises rows incrementally and tells the table view to insert them via `insertRows(at:withAnimation:)`. Memory footprint is bounded by the storage layer's eviction policy, not by the page size.
  - Codable cost: `PluginQueryResult` is `Codable` for cross-process plugin transport. The streaming variant must use the same encoding (each `PluginStreamElement` chunk is itself `Codable`). The chunked encoding cost is amortised across smaller payloads, so the steady-state cost is the same; the win is end-to-end latency (first-paint when the first 1K rows arrive vs when the full 100K-row page lands).

### D6 - `preWarmDisplayCache(upTo:)` runs on main inside `updateNSView`

- Severity: **HIGH**
- TablePro: `DataGridCoordinator.swift:305-327`, called from `DataGridView.swift:188-194` ("If we just got the first page, format `visibleRows + 5` rows synchronously").
- Why it lags: `updateNSView` runs on main during a SwiftUI render pass. Pre-warming N rows × M columns means N×M `CellDisplayFormatter.format` calls - each potentially a `DateFormatter` invocation - before SwiftUI returns from the update. On wide tables (100 columns × 50 visible rows = 5000 format calls) the SwiftUI frame budget is gone before the table draws.
- Reference patterns: Gridex pushes formatting into the view model, off the SwiftUI update path. Sequel-Ace runs the streaming-store fill on a worker thread.
- Apple-correct equivalent: Move pre-warming into the storage layer (§2). When a page lands, dispatch to a background actor:
  ```swift
  actor DisplayCache {
      func warm(rows: ContiguousArray<Row>, columnTypes: [ColumnType], formats: [ValueDisplayFormat?]) async -> ContiguousArray<ContiguousArray<String?>> {
          var out = ContiguousArray<ContiguousArray<String?>>()
          out.reserveCapacity(rows.count)
          for row in rows {
              var cached = ContiguousArray<String?>(repeating: nil, count: columnTypes.count)
              for col in 0..<min(row.values.count, columnTypes.count) {
                  cached[col] = CellDisplayFormatter.format(row.values[col], columnType: columnTypes[col], displayFormat: formats[col])
              }
              out.append(cached)
          }
          return out
      }
  }
  ```
  Then on the main actor, hand the warmed cache to the coordinator and call `tableView.reloadData(forRowIndexes:columnIndexes:)` for the visible range only. Apple guidance: WWDC 2021 "Discover concurrency in SwiftUI" - defer expensive computation to a `Task` and only assign results back on the main actor.
  - Note: `CellDisplayFormatter` is currently `@MainActor` (CellDisplayFormatter.swift:11). It must be relaxed to nonisolated or moved into the actor; `DateFormattingService.shared` and `BlobFormattingService.shared` need the same treatment (today both are main-actor singletons).

### D7 - `Array(repeating: nil, count: …)` on every cache miss

- Severity: **HIGH**
- TablePro: `DataGridCoordinator.swift:273-280`. On a cache miss, allocates a fresh `[String?]`, copies the existing partial cache, appends fresh `nil`s, writes the formatted value, stores back. For a `1000 × 50` grid that pays 50K array allocations during the first scroll pass.
- Apple-correct equivalent: Pre-allocate the row slot the first time the row is cached, use `ContiguousArray<String?>(repeating: nil, count: columnCount)` once, and write into it in place. Even better: store `ContiguousArray<ContiguousArray<String?>>` index-aligned with `rows`, indexed by `Int` not `RowID`. Pair this with §D2's reverse map.

### D8 - `displayCache.filter { aliveIDs.contains($0.key) }` allocates a new dict

- Severity: **MED**
- TablePro: `DataGridCoordinator.swift:337` (`pruneDisplayCacheToAliveIDs`). `Dictionary.filter` returns a new dictionary, copying every kept entry.
- Apple-correct equivalent: In-place removal:
  ```swift
  let stale = Set(displayCache.keys).subtracting(aliveIDs)
  for id in stale { displayCache.removeValue(forKey: id) }
  ```
  Or, with the index-aligned cache from §D7, `cache.removeSubrange(deletedRange)`. `Array.removeSubrange` is in-place and amortised O(removed).

### D9 - `tableRowsProvider()` closure called repeatedly inside loops

- Severity: **MED** (audit C7)
- TablePro: `DataGridCoordinator.swift:259, 263, 397, 405`, `preWarmDisplayCache` line 305-327. Each call hits the SwiftUI binding indirection.
- Apple-correct equivalent: Capture the `TableRows` once at the start of the loop body. Cheap fix; mention here because the streaming-storage refactor will collapse this entirely (§2).

### D10 - Pagination is `LIMIT/OFFSET`, not streaming

- Severity: **HIGH**
- TablePro: `TableQueryBuilder.swift:221-226` (`buildPaginationClause`), `MainContentCoordinator+Pagination.swift:70-76` (`reloadCurrentPage()`), `QueryExecutor.swift:130-133`. Default page size 1000 (`PaginationState.defaultPageSize` = 1000, QueryTabState.swift:107). The grid does NOT use the existing `PluginDatabaseDriver.streamRows(query:)`.
- Why it costs: Each page change re-runs the SQL with a new `OFFSET`. For deep pagination (`OFFSET 100000`) Postgres and MySQL both scan-and-discard the offset rows. Worse, the user perceives the page change as a full reload (`Delta.fullReplace` → `tableView.reloadData()` at DataGridCoordinator.swift:243). There is no way to scroll past the bottom of a page into the next page; the user must click pagination controls.
- Reference patterns: Sequel-Ace's "show contents" view streams the full table via `SPMySQLStreamingResultStore` - there is no UI pagination. The streaming store reads rows from the wire as the user scrolls, and reuses the connection. `SPCustomQuery.m:1149-1155` shows the integration: open the store, kick off `[startDownload]`, let the UI poll for new rows via `initQueryLoadTimer`. `awaitDataDownloaded` blocks the worker thread until the store is full but the UI is responsive throughout.
- Apple-correct equivalent: Two-tier loading.
  - **Window query**: keep `LIMIT/OFFSET` for the user's "go to page" controls (preserves existing UX). Use small windows (1K rows each) so the cost of `OFFSET` is bounded.
  - **Streaming fill**: when the user scrolls to the bottom of the current window, kick off `executeStreamingQuery` for the next window in the background and merge with `tableView.beginUpdates() / insertRows(at:) / endUpdates()` as chunks arrive. Use `AsyncThrowingStream<PluginStreamElement, Error>` (SE-0314) to consume chunks; cancel the stream on tab close, sort change, filter change, or schema change via the `Task` cancellation that's already wired into `MainContentCoordinator`.
  - **Progress decoupling**: model the existing `PluginStreamElement.header` / `.rows([PluginRow])` envelope as the single transport for both export and grid (§D5). Collapse `executeUserQuery` into a `collect()` over the streaming variant for plugins that want the legacy interface.
  - Apple references: `AsyncThrowingStream` (SE-0314), `Task { … }.cancel()` (Swift Concurrency), `NSTableView.beginUpdates()` (animatable batched mutations).

### D11 - Settings observer fires `tableView.reloadData(forRowIndexes:columnIndexes:)` over the visible range on any data-format change

- Severity: **MED**
- TablePro: `DataGridCoordinator.swift:139-173` - when `dateFormat`, `nullDisplay`, or `enableSmartValueDetection` changes, the coordinator clears the entire `displayCache` and reloads the visible range. Correct in spirit, but pairs with §D6 (formatter on main) to produce a hitch when settings change while a large table is open.
- Apple-correct equivalent: With the streaming storage in §2, settings change becomes "tell the storage layer the format changed", storage re-warms the visible window off-main, then signals the coordinator with the warmed slice. Same UX, no main-thread stall.

---

## 2. Target architecture

The target is a layered storage abstraction modelled on `SPDataStorage` (Sequel-Ace), with the formatting cache modelled on Gridex's `[[String]]` displayCache, and the transport modelled on the existing `PluginStreamElement` envelope. Three layers, each behind a Swift protocol with a clear ownership story.

### 2.1 `DataGridStore` - streaming row storage (replaces `TableRows`)

```swift
public enum CellState: Sendable, Equatable {
    case notLoaded
    case null
    case loaded(String)
}

public struct CellDisplay: Sendable, Equatable {
    public let raw: CellState
    public let formatted: String?
    public let isTruncated: Bool
}

public enum DataGridChange: Sendable {
    case header(columns: [String], columnTypes: [ColumnType])
    case rowsAppended(range: Range<Int>)
    case rowsReplaced(indices: IndexSet)
    case rowsRemoved(indices: IndexSet)
    case cellsChanged(positions: Set<CellPosition>)
    case streamingFinished(totalCount: Int)
    case streamingFailed(error: Error)
}

public protocol DataGridStore: Sendable {
    var rowCount: Int { get async }
    var columnCount: Int { get async }
    var columns: [String] { get async }
    var columnTypes: [ColumnType] { get async }

    func cellRaw(at row: Int, column: Int) async -> CellState
    func cellDisplay(at row: Int, column: Int) async -> CellDisplay
    func cellDisplay(at row: Int, column: Int, previewLength: Int) async -> CellDisplay

    func prefetchRows(in range: Range<Int>) async
    func cancelPrefetch(in range: Range<Int>) async

    func replaceCell(at row: Int, column: Int, with value: String?) async
    func appendInsertedRow(values: [String?]) async -> Int
    func remove(rows: IndexSet) async

    var changes: AsyncStream<DataGridChange> { get }
}
```

Why this shape:
- `cellDisplay` is the hot path. Cell render reads it directly. The default implementation pre-formats on warm-in (background actor) so the read is O(1) dictionary lookup or array index.
- `previewLength` parameter mirrors `SPDataStoragePreviewAtRowAndColumn(_:_:_:_)` (Sequel-Ace `SPDataStorage.h:117-123`). The grid passes 300 (truncate at view layer); export passes `Int.max` (full string).
- `CellState.notLoaded` is the Swift translation of Sequel-Ace's `SPNotLoaded` sentinel (`SPNotLoaded.h:31-42`). Distinguishing "not yet streamed" from `null` matters during the streaming window - placeholder cells display "…" with an italic dimmed style, never "NULL".
- `prefetchRows(in:)` lets the table view ask the store to warm display strings for the visible-rect-plus-margin. Implementation kicks off a `Task` on a background actor and emits `.cellsChanged` when the slot is ready.
- `changes` is an `AsyncStream<DataGridChange>` (SE-0314 `AsyncStream`). The coordinator subscribes once on attach, drives `tableView.beginUpdates()/insertRows(at:)/endUpdates()` from the stream. `AsyncStream` (vs `AsyncThrowingStream`) because errors travel as `.streamingFailed` so the coordinator can render an inline error row instead of unwinding.

Concrete implementation sketch - `StreamingDataGridStore`:

```swift
public actor StreamingDataGridStore: DataGridStore {
    private var columns: [String] = []
    private var columnTypes: [ColumnType] = []
    private var rows: ContiguousArray<RowSlot> = []
    private var indexByID: [RowID: Int] = [:]
    private let displayCache = NSCache<NSNumber, NSArray>()
    private var streamTask: Task<Void, Never>?
    private let continuation: AsyncStream<DataGridChange>.Continuation

    public nonisolated let changes: AsyncStream<DataGridChange>

    public init(driver: PluginDatabaseDriver, query: String, rowCap: Int?, parameters: [String?]?, settings: DataGridSettings) {
        let (stream, continuation) = AsyncStream<DataGridChange>.makeStream()
        self.changes = stream
        self.continuation = continuation
        displayCache.countLimit = max(2_000, settings.streamingCacheCountLimit)
        Task { await self.start(driver: driver, query: query, rowCap: rowCap, parameters: parameters) }
    }

    private func start(driver: PluginDatabaseDriver, query: String, rowCap: Int?, parameters: [String?]?) async {
        do {
            for try await element in driver.streamRows(query: query) {
                if Task.isCancelled { return }
                switch element {
                case .header(let header):
                    columns = header.columns
                    columnTypes = ColumnType.parseAll(header.columnTypeNames)
                    continuation.yield(.header(columns: columns, columnTypes: columnTypes))
                case .rows(let chunk):
                    let firstIndex = rows.count
                    rows.reserveCapacity(rows.count + chunk.count)
                    for values in chunk {
                        let id = RowID.existing(rows.count)
                        rows.append(RowSlot(id: id, values: ContiguousArray(values)))
                        indexByID[id] = rows.count - 1
                    }
                    let lastIndex = rows.count - 1
                    continuation.yield(.rowsAppended(range: firstIndex..<lastIndex + 1))
                }
            }
            continuation.yield(.streamingFinished(totalCount: rows.count))
        } catch {
            continuation.yield(.streamingFailed(error: error))
        }
    }
}
```

Notes:
- `NSCache<NSNumber, NSArray>` because `NSCache` is documented as thread-safe ("It also incorporates various auto-removal policies, which ensure that it does not use too much of the system's memory" - `NSCache` reference). Keys are boxed `Int` (row index). Values are `NSArray` of `NSString`/`NSNull`, sized to `columnCount`. `countLimit` defaults to 5× the visible-row count from settings (no hard cap; bound by reachable memory pressure).
- `OSAllocatedUnfairLock` (Apple `os` framework, macOS 13+) is the right primitive for a non-actor variant if profiling shows actor-hop cost dominates. For now `actor` is the simpler, correct default; document `OSAllocatedUnfairLock` as the escape hatch in the rewrite plan.
- `AsyncStream.makeStream()` was added in Swift 5.9 / macOS 14, which is TablePro's deployment target - no back-compat issue.
- `Task.isCancelled` honours the structured concurrency cancellation that already exists when a tab closes or the user re-runs a query.

### 2.2 `RowVisualIndex` - incremental edit-state tracking (replaces `rowVisualStateCache`)

```swift
@MainActor
final class RowVisualIndex {
    private(set) var deleted: Set<Int> = []
    private(set) var inserted: Set<Int> = []
    private(set) var modifiedColumnsByRow: [Int: Set<Int>] = [:]

    func apply(_ change: ChangeManagerDelta) {
        switch change {
        case .cellEdited(let row, let column):
            modifiedColumnsByRow[row, default: []].insert(column)
        case .rowDeleted(let row):
            deleted.insert(row)
        case .rowInserted(let row):
            inserted.insert(row)
        case .changesCommitted, .changesDiscarded:
            deleted.removeAll(keepingCapacity: true)
            inserted.removeAll(keepingCapacity: true)
            modifiedColumnsByRow.removeAll(keepingCapacity: true)
        }
    }

    func state(for row: Int) -> RowVisualState {
        RowVisualState(
            isDeleted: deleted.contains(row),
            isInserted: inserted.contains(row),
            modifiedColumns: modifiedColumnsByRow[row] ?? []
        )
    }
}
```

Cost is O(1) per delta, O(1) per cell render. Replaces DataGridCoordinator.swift:533-577 entirely. The change manager already emits per-cell deltas; the rebuild-on-version pattern goes away.

### 2.3 `CellDisplayWarmer` - off-main formatting (replaces `preWarmDisplayCache`)

```swift
public actor CellDisplayWarmer {
    public func warm(
        chunk: [PluginRow],
        columnTypes: [ColumnType],
        displayFormats: [ValueDisplayFormat?],
        previewLength: Int
    ) -> ContiguousArray<ContiguousArray<String?>> {
        var out = ContiguousArray<ContiguousArray<String?>>()
        out.reserveCapacity(chunk.count)
        for values in chunk {
            var cached = ContiguousArray<String?>(repeating: nil, count: columnTypes.count)
            let upper = min(values.count, columnTypes.count)
            for col in 0..<upper {
                cached[col] = CellDisplayFormatter.formatNonisolated(
                    values[col],
                    columnType: columnTypes[col],
                    displayFormat: col < displayFormats.count ? displayFormats[col] : nil,
                    previewLength: previewLength
                )
            }
            out.append(cached)
        }
        return out
    }
}
```

`CellDisplayFormatter`, `DateFormattingService`, and `BlobFormattingService` need to be relaxed from `@MainActor` to `nonisolated` (they're pure functions over the input - there is no main-actor-isolated state). The actor boundary then lives at the warmer, not the formatter.

`previewLength` is the storage-layer truncate parameter. Grid renders 300; export uses `Int.max`. Compare Sequel-Ace `SPDataStorage.m:189` (hard-truncate at 150 for edited rows).

### 2.4 Coordinator changes

`TableViewCoordinator` becomes a thin observer:

```swift
@MainActor
final class TableViewCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let store: any DataGridStore
    private let visualIndex = RowVisualIndex()
    private var streamObserver: Task<Void, Never>?

    func attach(to tableView: NSTableView) {
        self.tableView = tableView
        streamObserver = Task { @MainActor [weak self] in
            guard let self else { return }
            for await change in await self.store.changes {
                self.applyStreamChange(change)
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        cachedRowCount
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = resolveColumn(tableColumn) else { return nil }
        let display = store.cachedCellDisplay(row: row, column: column)
        let cell = cellRegistry.dequeueCell(of: kind, in: tableView)
        cell.configure(content: .init(text: display.formatted ?? ""), state: cellState(row: row, column: column))
        return cell
    }
}
```

Key shifts:
- `viewFor:row:` reads the cache only. `store.cachedCellDisplay(row:column:)` is a synchronous nonisolated read of the warmed slot (or returns "…" placeholder if the slot is `notLoaded`).
- `applyStreamChange(_:)` translates `DataGridChange` into `tableView.insertRows(at:withAnimation:)`, `tableView.reloadData(forRowIndexes:columnIndexes:)`, etc. No more `Delta` struct duplication between `TableRowsController` and the coordinator.
- `displayCache` lives entirely in the store, behind `NSCache`. The coordinator never touches it.
- `rowVisualStateCache` becomes `RowVisualIndex`, applied on each `ChangeManagerDelta`. No version short-circuit.

### 2.5 Plugin boundary

Add to `PluginDatabaseDriver`:

```swift
public extension PluginDatabaseDriver {
    func executeStreamingQuery(
        _ query: String,
        rowCap: Int?,
        parameters: [String?]?
    ) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result: PluginQueryResult
                    if let parameters {
                        result = try await self.executeParameterized(query: query, parameters: parameters)
                    } else {
                        result = try await self.execute(query: query)
                    }
                    continuation.yield(.header(.init(
                        columns: result.columns,
                        columnTypeNames: result.columnTypeNames,
                        estimatedRowCount: result.rows.count
                    )))
                    let chunkSize = 1_000
                    var startIndex = 0
                    while startIndex < result.rows.count {
                        if Task.isCancelled { continuation.finish(); return }
                        let endIndex = min(startIndex + chunkSize, result.rows.count)
                        continuation.yield(.rows(Array(result.rows[startIndex..<endIndex])))
                        startIndex = endIndex
                        await Task.yield()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
```

This is a default-implementation bridge for plugins that haven't been migrated. Native plugins (PostgreSQL, MySQL, ClickHouse, MongoDB) override `executeStreamingQuery(_:rowCap:parameters:)` directly to feed rows from the wire (PostgreSQL: `PQgetRow` per row; MySQL: `mysql_fetch_row` per row; MongoDB: cursor batches). `currentPluginKitVersion` bumps from N to N+1; every plugin's `Info.plist` `TableProPluginKitVersion` advances in lockstep (CLAUDE.md Plugin ABI invariant).

`PluginQueryResult` stays for non-grid uses (DDL, status messages). Keep backward compat: `PluginQueryResult.empty`, the `isTruncated` flag, `executionTime`, and `statusMessage` flow through the streaming envelope as a final `.metadata(executionTime:rowsAffected:isTruncated:statusMessage:)` element.

### 2.6 Pagination model

Pagination becomes "request a window from the streaming store":

```swift
public struct DataGridWindow: Sendable {
    public let offset: Int
    public let limit: Int
}

extension StreamingDataGridStore {
    public func loadWindow(_ window: DataGridWindow) async throws { … }
    public func extendWindowToBottom(by additional: Int) async throws { … }
}
```

`MainContentCoordinator+Pagination.swift:70-76` `reloadCurrentPage()` becomes `await store.loadWindow(DataGridWindow(offset: pagination.currentOffset, limit: pagination.pageSize))`. The user still sees explicit "Page N of M" controls (PaginationControlsView.swift). The win is that within a page, scroll-driven prefetch can extend the visible window without a full reload - Sequel-Ace's "show me everything" UX for the cases where the page boundary is artificial.

---

## 3. Migration order

Match the audit's Sprint structure (DATAGRID_PERFORMANCE_AUDIT.md §4) so this slot fits cleanly.

1. **Sprint 1 (data path quick wins)**
   - D2: `indexByID` in `TableRows` (~1 file, 30 lines).
   - D7: pre-allocate `[String?]` slots; switch `displayCache` to index-aligned `ContiguousArray<ContiguousArray<String?>>` keyed by display index.
   - D8: in-place dict pruning.
   - D4: `RowVisualIndex` with incremental updates.
   - These four ship without a plugin ABI change; they are the highest-ROI items.

2. **Sprint 2 (architecture)**
   - D5, D6, D10: introduce `DataGridStore` protocol + `StreamingDataGridStore` actor.
   - Bump `currentPluginKitVersion`. Add default `executeStreamingQuery` extension. Migrate built-in PostgreSQL and MySQL plugins to native streaming.
   - Move formatting off-main into `CellDisplayWarmer`. Relax `CellDisplayFormatter` from `@MainActor` to `nonisolated`.
   - D11 falls out: settings-change rewarms the visible window via the warmer, off-main.

3. **Sprint 3 (cleanup)**
   - Collapse `TableRowsController` into the coordinator (it's now redundant; the coordinator subscribes to `store.changes` directly).
   - Replace `Delta` enum with `DataGridChange`.
   - D9: closure-call elision is automatic once `TableRows` is gone.

---

## 4. Apple references

- `AsyncStream`, `AsyncThrowingStream`: SE-0314 ("AsyncSequence"), Swift Evolution. Used for `changes` and `executeStreamingQuery`.
- `NSCache` thread-safety and auto-eviction: Apple Foundation Reference, "NSCache". Used for `displayCache`.
- `OSAllocatedUnfairLock`: Apple `os` framework, macOS 13+, "OSAllocatedUnfairLock". Documented escape hatch when actor-hop cost is unacceptable.
- `Sendable`: SE-0302 ("Sendable and `@Sendable` closures"). All transfer types in §2.1 are `Sendable`.
- `NSTableView.beginUpdates()` / `insertRows(at:withAnimation:)`: AppKit Reference, "NSTableView". Animatable batched mutations driven by `DataGridChange`.
- `Task.isCancelled`, `Task.yield()`: Swift Concurrency, "Cancellation". Honoured throughout the streaming pipeline so tab close / re-run cleanly tears down in-flight fetches.
- `Date.FormatStyle`: macOS 12+, replaces `DateFormatter` for new format paths (audit N3). Optional follow-up - `DateFormattingService` already caches `DateFormatter` instances, so the win is style consistency, not raw perf.

---

## 5. Concrete success criteria

- Scrolling a 50K-row table at 120 fps with 50 visible rows × 30 columns shows zero `CellDisplayFormatter.format` invocations during scroll (verified via Instruments, Time Profiler).
- `TableRows.index(of:)` does not appear in the top-100 hottest functions (verified via Instruments).
- `displayCache` memory bounded by `NSCache.countLimit × columnCount × averageStringLength`, observable in Instruments Allocations.
- A `SELECT * FROM table` against a 1M-row table renders the first 1K rows in <500ms (first-paint latency), regardless of total table size, because the streaming store starts emitting before the query finishes.
- Filter / sort / settings changes never block the main thread for >16ms (verified via Hangs Instrument, "Hangs (All)").

---

## 6. Open questions

1. The export pipeline already consumes `streamRows(query:)`. Confirm that the chunk size used by built-in plugins (PostgreSQL, MySQL) is small enough to stream cleanly into the grid, or recommend a chunk-size knob in `PluginCapabilities`.
2. `RowID.inserted(UUID())` allocates a UUID per inserted row. With the `indexByID` map + position-keyed `displayCache`, the UUID becomes pure equality identity for inserted rows - confirm no other code path relies on the UUID for diffing or persistence.
3. Sequel-Ace's `SPNotLoaded` is a singleton; the Swift translation `CellState.notLoaded` is a stack value. Confirm that the cell renderer can branch on `CellState` without re-allocating per cell render. (It can - enum cases without payload are tag-only.)
4. The coordinator currently depends on `tableRowsProvider: () -> TableRows` and `tableRowsMutator: ((inout TableRows) -> Void) -> Void` closures threaded through SwiftUI. Replace with `let store: any DataGridStore` injected via the SwiftUI environment; confirm that hot-reload (`updateNSView`) of the store reference works correctly under SwiftUI's identity rules.
