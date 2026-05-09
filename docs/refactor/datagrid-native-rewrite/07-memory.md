# DataGrid Native Rewrite - 07 Memory Model and Data Structures

**Scope:** retention bloat, hot-path singleton lookups, suboptimal containers, cache and eviction strategy, ref-count traffic in inner loops, plugin boundary copy cost, result-set RAM ceiling.
**Method:** static read of files listed in the prompt plus the call sites that drive the hot paths (`tableView(_:viewFor:row:)`, `applyContent`, `applyVisualState`, `updateWindowTitleAndFileState`).
**Cross-references:** audit sections 2.7 (memory) and 7 (open questions). Streaming storage at the plugin boundary overlaps with the data-path agent (§2.2 D5) and is recapped here for the memory dimension only.

---

## 0. Executive summary

The grid's memory model has four classes of issue:

1. **Unbounded growth.** `displayCache: [RowID: [String?]]` and `rowVisualStateCache: [Int: RowVisualState]` have no ceiling, no eviction, no cost accounting. A 1M-row paginated session that revisits pages keeps every formatted page resident until `releaseData()`.
2. **Hot-path singleton + bridging cost.** Every cell render reaches `ThemeEngine.shared.dataGridFonts` 3 to 4 times and `ThemeEngine.shared.colors.dataGrid` once; every keystroke in a file-backed query tab bridges the full query string and the saved snapshot to `NSString` to compute `isFileDirty`. These are not amortized.
3. **Reference-counted boxing in inner loops.** `[String?]` for row values is `Array<Optional<String>>` - each non-nil cell is a heap `_StringStorage` with retain/release on copy. `displayCache` rebuilds these arrays per row, doubling the retain traffic.
4. **Undo retains full row snapshots.** `recordRowDeletion(originalRow: [String?])` retains the entire row; batch deletes retain the full set of rows. There is no `levelsOfUndo` cap. A 1k-column wide-row delete keeps ~4k objects alive per entry.

Below: severity, file:line, current footprint, target state with the Apple API.

---

## 1. `displayCache` is unbounded - `NSCache` with cost accounting

**Severity:** CRIT (M1 in audit).
**Location:** `TablePro/Views/Results/DataGridCoordinator.swift:17, 266–283, 305–327`.

**Current footprint.**

```swift
private var displayCache: [RowID: [String?]] = [:]
```

- Keyed by `RowID` enum (`.existing(Int)` or `.inserted(UUID)`) - `Hashable` value type, fine.
- Per-entry cost: a `[String?]` of `cachedColumnCount`. For a 50-column row at average value width 32 chars, each row is roughly `50 × (8 byte tag + 16 byte String header) + 50 × ~48 byte storage = ~3.4 KB`. At 100k visited rows: **~340 MB** held in `displayCache` alone with no eviction signal.
- `releaseData()` (line 198) is the only purge path; pagination, sort, filter, or scroll never drop entries.
- `pruneDisplayCacheToAliveIDs()` (line 329) only runs on row removals, not on memory pressure.

**Why a Swift dictionary is wrong here.** `Dictionary<K, V>` does not respond to memory pressure. `NSCache` does - it auto-evicts on memory warnings (Foundation, available since OS X 10.6) and supports both `countLimit` and `totalCostLimit`. It is also thread-safe by contract (we still own this on `@MainActor`, but the contract avoids accidental crashes).

**Target state.**

```swift
private let displayCache: NSCache<RowIDKey, NSArray> = {
    let cache = NSCache<RowIDKey, NSArray>()
    cache.countLimit = 5_000
    cache.totalCostLimit = 32 * 1024 * 1024
    cache.evictsObjectsWithDiscardedContent = true
    return cache
}()
```

`NSCache` requires `AnyObject` keys and values, so:

- Wrap `RowID` in a small `final class RowIDKey: NSObject` with `isEqual` and `hash` derived from the underlying enum (`NSObject` keys are how `NSCache` is intended to be used; the documentation calls this out: "Unlike an `NSMutableDictionary` object, a cache does not copy the key objects").
- Wrap the per-row `[String?]` in `NSArray` (bridged from `[NSString?]`) or in a tiny `final class RowDisplayBox` holding `ContiguousArray<String?>`. The box wins because `NSArray` of optionals forces sentinels.
- Pass `cost:` proportional to `(columnCount * averageStringByteLen)` so `totalCostLimit` enforces a real RAM ceiling.

**Apple API references.**

- `NSCache` - countLimit, totalCostLimit, evictsObjectsWithDiscardedContent, automatic eviction under memory pressure.
- `NSDiscardableContent` - implement on the row box to opt into discardable eviction; pairs with `evictsObjectsWithDiscardedContent`.

**Sizing note.** macOS does not page-out aggressively; once the working set is wired the system swaps. A hard `totalCostLimit` is the only durable defense.

---

## 2. `isFileDirty` bridges full query string per keystroke

**Severity:** HIGH (M2 in audit).
**Location:** `TablePro/Models/Query/QueryTabState.swift:266–272`.
**Callers:** `MainContentView+Setup.swift:181, 207, 240`, `MainContentView+Bindings.swift:129`, `MainEditorContentView.swift:397`, `MainContentView.swift:230`, `MainContentCommandActions.swift:303, 422, 599`. The window title pipeline calls this on every editor change.

**Current footprint.**

```swift
var isFileDirty: Bool {
    guard sourceFileURL != nil, let saved = savedFileContent else { return false }
    let queryNS = query as NSString
    let savedNS = saved as NSString
    if queryNS.length != savedNS.length { return true }
    return queryNS != savedNS
}
```

- `query as NSString` and `saved as NSString` perform a String → NSString bridge each call. For a Swift `String` backed by a native `_StringStorage`, this is an `O(1)` allocation of a bridged `_StringStorage` proxy if the string is already UTF-8 - but the proxy is still a heap object that immediately gets refcounted twice (assignment + comparison) and released on scope exit.
- For very large dumps (the audit warns SQL dumps can be millions of chars on a single line), `queryNS != savedNS` falls through to a full character compare when lengths match.
- This runs **per keystroke** because `updateWindowTitleAndFileState()` and the SwiftUI binding chain re-evaluate it on every `query` mutation.

**Target state.** Cache a `(byteLength: Int, fnv64: UInt64)` snapshot of `savedFileContent` at the moment of save, then on each call:

```swift
struct SavedSnapshot: Equatable {
    let byteCount: Int
    let hash: UInt64
}

private(set) var savedSnapshot: SavedSnapshot?

var isFileDirty: Bool {
    guard sourceFileURL != nil, let saved = savedSnapshot else { return false }
    if query.utf8.count != saved.byteCount { return true }
    return query.fnv1a64() != saved.hash
}
```

`String.utf8.count` is O(1) on native Swift strings (the count is stored on the storage class). No `NSString` bridge, no second copy. Hash computation runs once per save, not once per keystroke.

**Apple API references.**

- `String.utf8.count` - documented O(1) on native UTF-8 storage (Swift evolution SE-0247).
- `Hasher` from Swift stdlib for the hash if cryptographic quality is not needed; otherwise `CryptoKit.SHA256` once at save time.
- For the original NSString approach, see the `String/NSString` bridging doc - bridging is "near-free" for ASCII but allocates for non-ASCII contiguous strings every call.

**Why not just compare `query == saved`?** Same complexity in the worst case (full compare), and Swift's `String == String` already has a `length` short-circuit. The bridge is what's removable - the snapshot pattern eliminates retaining `savedFileContent` as a full `String` copy in the tab.

---

## 3. `ThemeEngine.shared` lookups in the per-cell hot path

**Severity:** HIGH (M3 in audit).
**Location:** `TablePro/Views/Results/Cells/DataGridBaseCellView.swift:82, 149, 156, 166, 176, 190, 192, 194` and `TablePro/Views/Results/DataGridCoordinator.swift:519–525`.

**Current footprint.**

Per cell `configure(...)`:

- `applyContent` reads `ThemeEngine.shared.dataGridFonts.regular | .italic | .medium` (one of three branches).
- `applyVisualState` reads `ThemeEngine.shared.colors.dataGrid.deleted | .inserted | .modified` (one branch).

The singleton is annotated `@Observable` and `@MainActor`. Each `.shared` access is:

1. A static property fetch (cheap).
2. An Observation registration check - `@Observable` records a read into the current observation transaction. This is the real cost: `_$observationRegistrar.access(self, keyPath: \.dataGridFonts)` adds a tracked dependency, even if no SwiftUI view is observing. For a 30-column visible window scrolling at 60 fps, that's ~9k observation accesses per second purely from cell rendering.
3. A `MainActor.assertIsolated()` no-op in release, but tiny in debug.

**Target state.** Snapshot fonts and colors before the row loop. The cell already reads `state.visualState` and `content.placeholder`; pass the resolved `NSFont` and `NSColor` through `DataGridCellState` (or a sibling struct).

```swift
struct DataGridCellPalette {
    let fontRegular: NSFont
    let fontItalic: NSFont
    let fontMedium: NSFont
    let rowNumberFont: NSFont
    let deletedBg: CGColor
    let insertedBg: CGColor
    let modifiedBg: CGColor
}
```

The coordinator caches a `DataGridCellPalette` and updates it via the existing `themeChanged` Combine pipeline (`DataGridCoordinator.swift:177–183`). Cell render becomes a struct field read - no observation, no actor check.

**Why this matters more than the `.shared` lookup time.** The `@Observable` registrar uses a per-thread `_AccessList`; under SwiftUI's `update*View` it accumulates dependencies. If the singleton is read from inside `tableView(_:viewFor:row:)`, those dependencies leak into whatever transaction is active. The fix is to keep singletons out of inner-loop reads regardless of measured cost.

**Apple API references.**

- *Observation* framework - `@Observable`, `withObservationTracking`, registrar semantics (Swift evolution SE-0395).
- The pattern of "snapshot ambient state to a local before the loop" is the standard advice for `@Observable` types and predates it for `ObservableObject` - every NSTableView render guide since 10.7 has said the same thing.

---

## 4. `UndoManager` retains full row snapshots; no `levelsOfUndo`

**Severity:** HIGH (M4 in audit).
**Location:** `TablePro/Core/ChangeTracking/DataChangeManager.swift:148–173, 211–369`; `PendingChanges.swift:97–113, 167–171, 277, 300`.

**Current footprint.**

- `recordRowDeletion(rowIndex:originalRow: [String?])` retains the full row in the undo closure (line 151).
- `recordBatchRowDeletion(rows: [(Int, [String?])])` retains every row in the batch (line 164).
- Each registered undo block captures `originalRow` by closure, which retains its `[String?]` storage. The matching redo registration in `applyRowDeletionUndo` (line 302) re-captures the same array, doubling the retention until the next stack pop.
- `PendingChanges.changes: [RowChange]` also stores `originalRow` on `RowChange` (used for SQL generation). So a row deletion currently lives in three places:
  1. `pending.changes[i].originalRow`
  2. The undo block's captured `originalRow`
  3. The redo block's captured `originalRow`
- No `levelsOfUndo` cap. macOS default is unlimited; the user can keep editing for hours and accumulate every original row forever.
- `removeAllActions(withTarget:)` is only called on `clearChangesAndUndoHistory()` and `configureForTable()` (lines 91, 107). Switching tabs does not clear it.

**Target state.**

1. **Diff storage.** Keep `originalRow` only on `pending.changes[i]` (it is needed for SQL DELETE generation and that path is unavoidable). Do not also capture it in the undo closure - capture the *row index* and look the original up via `pending.change(forRow:type:)`. Cell edits should already be diffs and they are (`CellChange(oldValue:newValue:)`); audit confirms they're fine. The footprint reduction is on `.delete` and `.batchRowDeletion` only.

2. **Cap stack depth.**

   ```swift
   undoManager.levelsOfUndo = 100
   ```

   `UndoManager.levelsOfUndo` is the Cocoa-native ceiling; setting it drops oldest groups when the count exceeds the limit. Documentation: "Setting the value to 0 (the default) means there is no limit." We're currently at 0.

3. **Trim per-target.** When the user closes the tab or runs a DDL refresh, call `removeAllActions(withTarget: self)`. The current `releaseData()` in `DataGridCoordinator` does not - verify the tab teardown path clears the change manager's undo stack.

4. **Group at the right granularity.** `beginUndoGrouping` / `endUndoGrouping` around batch operations; the prompt notes batch deletes register a single undo block which is correct. Make sure cell edits during a paste are grouped too (`automaticallyGroupsByEvent` is on by default).

**Apple API references.**

- `UndoManager.levelsOfUndo` - caps the number of groups retained.
- `UndoManager.removeAllActions(withTarget:)` - drops every action whose target is the given object.
- `UndoManager.groupsByEvent` - true by default; one event loop pass = one group. Useful when a single user action records multiple `registerUndo` calls.

---

## 5. JSON highlight regexes are already cached - no fix needed

**Severity:** N/A (M5 in audit was a false alarm).
**Location:** `TablePro/Views/Results/JSONHighlightPatterns.swift:18–23`.

The audit suggested `static let regex = try! NSRegularExpression(...)` was not used. It is - the file is already:

```swift
internal enum JSONHighlightPatterns {
    static let string = compileJSONRegex("\"...\"")
    static let key = compileJSONRegex(...)
    static let number = compileJSONRegex(...)
    static let booleanNull = compileJSONRegex(...)
}
```

Swift `static let` on a type is lazily initialized once, threadsafe (`dispatch_once` semantics). The audit finding does not apply to current code - leave as is. Cross-reference: confirm callers do not re-instantiate a local `NSRegularExpression`; grep clean.

---

## 6. `var` on semantically immutable fields

**Severity:** MED (M6 in audit).
**Location:** `TablePro/Models/Query/QueryTabState.swift:255–273`.

**Current footprint.**

```swift
struct TabQueryContent: Equatable {
    var query: String = ""
    var queryParameters: [QueryParameter] = []
    var isParameterPanelVisible: Bool = false
    var sourceFileURL: URL?
    var savedFileContent: String?
    var loadMtime: Date?
    var externalModificationDetected: Bool = false
    ...
}
```

- `sourceFileURL` is set once at file-open and never re-assigned (search for callers confirms; the file URL ties the tab to disk).
- `savedFileContent` is reassigned on save - must remain `var` but should be `private(set)`. Currently it is fully writable from any caller, which makes the dirty calculation unreliable (anyone can stomp it).
- `loadMtime` same shape as `savedFileContent`.

**Target state.** `let sourceFileURL: URL?`. `private(set) var savedFileContent: String?`. The struct stays `Equatable`. This is not a perf fix; it's a correctness fence that prevents future regressions of the dirty-snapshot invariant proposed in §2.

**Apple API references.** Standard Swift access control.

---

## 7. `Optional<Optional<T>>` in `PaginationState`

**Severity:** MED (M7 in audit).
**Location:** `TablePro/Models/Query/QueryTabState.swift:103`.

**Current footprint.**

```swift
var baseQueryParameterValues: [String?]?
```

The outer `?` carries no extra information - `nil` and `[]` are semantically identical here ("no parameters bound for the load-more query"). Flattening:

```swift
var baseQueryParameterValues: [String?] = []
```

`MemoryLayout<[String?]>.size = 8` (one pointer-sized buffer header). `MemoryLayout<[String?]?>.size = 9` rounds up to 16. Per `PaginationState` instance it's 8 bytes saved - negligible. The win is API hygiene: callers no longer need to write `pagination.baseQueryParameterValues ?? []`.

**Apple API references.** N/A.

---

## 8. `[String?]` vs `ContiguousArray<String?>` for hot row data

**Severity:** LOW to MED (M8 in audit).
**Location:** `TablePro/Models/Query/Row.swift:20`; `displayCache` value type at `DataGridCoordinator.swift:17`.

**Current footprint.**

- `Row.values: [String?]` - `Array` is bridgeable to `NSArray`. The bridging witness adds a check on every Array access: a fast-path `_BridgeStorage` test that distinguishes native Swift storage from a wrapped `_NSArrayCore`. Cells iterate `displayRow.values[columnIndex]` per render; the check is present every time.
- `TableRows.rows: ContiguousArray<Row>` - already correct (audit credits this).
- `displayCache` value `[String?]` - same Array vs ContiguousArray distinction.

**Target state.**

```swift
struct Row: Equatable, Sendable {
    var id: RowID
    var values: ContiguousArray<String?>
}
```

`ContiguousArray` is documented as "the most efficient array type when [the] elements are not class instances or `@objc` protocol types." `String?` is exactly that - `String` is a Swift value type. Bridging cost vanishes. The only change at the call site is the literal `[]` becomes `ContiguousArray()` for empty inits, and pre-allocated arrays use `reserveCapacity` the same way.

**Sizing.** No size change per element (both are `(Optional<String>, ...)` contiguous storage). The win is purely on access checks and on retention semantics for `_modify` accessors - `ContiguousArray` exposes a stable `withUnsafeMutableBufferPointer` without the bridge dance.

**Apple API references.**

- `ContiguousArray` - Standard Library; "do not need to bridge to Objective-C."
- `_modify` accessor - Swift stdlib internal but underpins `Array.subscript`'s in-place mutation; `ContiguousArray` has the same guarantee without the bridge witness.

---

## 9. Broader `NSCache` adoption

**Severity:** LOW (M9 in audit).
**Locations and proposals.**

| Cache today | File | Type | Move to |
|---|---|---|---|
| `formatCache: NSCache<NSString, NSString>` | `Core/Services/Formatting/DateFormattingService.swift:28` | already `NSCache` | keep, add `countLimit` if not set |
| `displayCache: [RowID: [String?]]` | `Views/Results/DataGridCoordinator.swift:17` | dict | `NSCache` (see §1) |
| `columnCache: [String: [ColumnInfo]]` | `Core/Autocomplete/SQLSchemaProvider.swift:18` | dict | `NSCache<NSString, NSArray>` - schemas are large, rarely re-read after first autocomplete |
| `columnTypeCache: [String: ColumnType]` | `Core/Plugins/PluginDriverAdapter.swift:14` | dict | keep dict - small, bounded by table column count |
| `queryBuildingDriverCache: [String: (any PluginDatabaseDriver)?]` | `Core/Plugins/PluginManager.swift:93` | dict | keep dict - bounded by registered plugin count (~15) |
| `cache: [UUID: [String: PersistedColumnLayout]]` | `Core/Storage/ColumnLayoutPersister.swift:24` | dict | keep - bounded by connection × table count, persisted to disk |
| `lastFiltersCache: [String: [TableFilter]]` | `Core/Storage/FilterSettingsStorage.swift:94` | dict | keep - small |
| `visualStateCache: [VisualStateCacheKey: RowVisualState]` | `Core/SchemaTracking/StructureChangeManager.swift:43` | dict | bounded by changed rows; keep |
| `instances: [UUID: ConnectionDataCache]` | `ViewModels/ConnectionDataCache.swift:13` | strong dict, leaks per closed connection | move to `NSMapTable<NSUUID, ConnectionDataCache>.weakToWeakObjects()` so closed-connection caches deallocate |
| `querySortCache`, `displayFormatsCache` | `Views/Main/MainContentCoordinator.swift:144, 146` | tab-keyed dicts | guard with `removeValue(forKey:)` on tab close; otherwise persist forever |

**Apple API references.**

- `NSMapTable.weakToWeakObjects()` - Foundation; objects deallocate when no other strong reference remains. The map auto-clears the dead entry on next read.
- `NSCache` - see §1.

The single highest-value addition is `displayCache` from §1. Everything else is a minor tightening.

---

## 10. `PluginQueryResult.rows` - full copy across the bundle boundary

**Severity:** HIGH (cross-reference D5 in audit, owned by datapath agent).
**Location:** `Plugins/TableProPluginKit/PluginQueryResult.swift:6`.

**Memory dimension only - the data-path agent owns the streaming protocol design.**

```swift
public struct PluginQueryResult: Codable, Sendable {
    public let rows: [[String?]]
    ...
}
```

`PluginQueryResult` is a `Sendable` struct returned by value across the plugin bundle boundary. The `rows: [[String?]]` field is the result set in full. Costs:

1. **Allocation.** Every plugin driver allocates `[[String?]]`. For a 100k-row result with 50 columns, that's 100k inner arrays plus 5M `String?` slots - roughly 200 MB before any cell formatting.
2. **Crossing the boundary.** Swift values cross the bundle boundary by copy. `Array` is COW so the *header* is copied and the storage is retained; this is amortized per result, but the act of returning the struct from the plugin to `PluginDriverAdapter` and onward to `DatabaseManager` still bumps refcounts on each Array header.
3. **Sendable across actors.** `PluginQueryResult` is `Sendable`, so the buffer must be deeply immutable or transferable. Today it is immutable (all `let`), which means the storage is shared by ARC across the boundary - fine, but it also means we *cannot* mutate or chunk in-place; we must allocate a new Array to drop already-consumed rows.

**Memory ceiling.** With a 16 GB Mac, the practical ceiling is **~10M cells before pressure** (allowing ~200 byte per cell amortized including `String` heap), and **~3M cells before noticeable lag** from GC of `String` storage and from the dictionary overhead of `displayCache`. Above 100k rows, the user's Activity Monitor shows TablePro climbing into the GB range purely from result retention.

**Target state (memory dimension).**

- Plugin returns a `PluginQueryStream` protocol that emits `PluginRowChunk(rowsAffected:offset:rows:)` of bounded size. The Swift side accumulates into a streaming store modeled on Sequel-Ace's `SPDataStorage` - see audit §3.2.
- The grid's view of the store is a sliding window; only the "visible-rect rows ± preWarm" range is converted to display strings.
- Sequel-Ace caches `IMP` (method pointers) to avoid Objective-C messaging overhead in the cell access path. The Swift equivalent is to expose the store via a non-resilient protocol or pre-resolved closure (`@inlinable` is *not* available across module boundaries for non-frozen types; use a closure stored on the coordinator).

**Apple API references.**

- `Sendable` and `@Sendable` closures - Swift Concurrency Manifesto / SE-0302.
- `MemoryLayout<String?>.size = 16` (8 byte tag + 8 byte storage pointer) on 64-bit; useful when sizing the streaming chunk.
- `OSAllocatedUnfairLock` - for the streaming store's row-array guard if it must be read from non-main contexts. Apple's recommended replacement for `os_unfair_lock_t` since macOS 13: zero-overhead in the uncontended fast path, no priority inversion.

**Result-set memory ceiling worked example.**

For a typical query result:

- average value width: 32 chars UTF-8
- `MemoryLayout<String>.stride` (small string optimization): 16 bytes inline, 0 heap for ≤15-byte strings; otherwise 16 bytes + heap `_StringStorage` (rounded to 32 bytes).
- columns: 20

Per row in RAM: `20 × 16 byte slot + 20 × ~48 byte heap = 1.28 KB`.
- 10k rows: ~12 MB - fine.
- 100k rows: ~125 MB - degraded scroll.
- 1M rows: ~1.25 GB - unusable.
- The grid's `displayCache` (§1) at the same row count adds another 1×. Total for 1M rows: ~2.5 GB.

The streaming proposal caps the resident set to `pageSize × column count` regardless of underlying result size.

---

## 11. Reference counting in inner loops - `rowVisualStateCache` and friends

**Severity:** MED (audit M3 partial).
**Location:** `TablePro/Views/Results/DataGridCoordinator.swift:112, 533–584`.

**Current footprint.**

```swift
private var rowVisualStateCache: [Int: RowVisualState] = [:]
```

`RowVisualState` is a struct with three fields:

```swift
struct RowVisualState {
    let isDeleted: Bool
    let isInserted: Bool
    let modifiedColumns: Set<Int>
}
```

`Set<Int>` is a class-backed COW container. Reading `rowVisualStateCache[row] ?? .empty` (line 583) is fine - the dictionary lookup is O(1), the value is a struct copy, but `Set<Int>` retains its underlying storage on copy.

For visible-row rendering, `visualState(for:)` is called per cell, which is per row × per column. For a 30-column visible window, that's ~30 retains/releases per row per scroll frame on the `Set<Int>` storage - not catastrophic, but avoidable.

**Target state.**

- For the common case (no modified columns), use a sentinel: `static let empty` is already there. Confirm `RowVisualState.empty` is shared across all callers (it is - `static let`), so the fast-path retain hits a single global.
- For rows with modified columns, replace `Set<Int>` with a small inline storage: a 64-bit bitmap if the column count is ≤64, otherwise a `ContiguousArray<UInt64>` bitmap. The grid's column count is bounded by the table schema - most tables have <64 columns.

```swift
struct ColumnSet {
    private var bits: UInt64
    private var overflow: ContiguousArray<UInt64>?
    func contains(_ column: Int) -> Bool { ... }
    mutating func insert(_ column: Int) { ... }
}
```

This is a value type with no heap escape for tables ≤64 columns. The `displayCache` invalidation path that calls `state.visualState.modifiedColumns.contains(state.columnIndex)` (`DataGridBaseCellView.swift:193`) becomes a single AND.

**Apple API references.**

- `MemoryLayout<Set<Int>>.stride = 8` (one pointer); the heap allocation behind it is the cost.
- `MemoryLayout<UInt64>.stride = 8` - same slot size, zero heap for ≤64-column tables.
- `ContiguousArray.withUnsafeMutableBufferPointer` for the overflow path - keeps the bitmap dense.

This is opportunistic. If the grid is otherwise tuned (per §1, §3), `Set<Int>` is fine. List it as a tail optimization once the bigger items are paid down.

---

## 12. `_columnsStorage` defensive copy

**Severity:** LOW (cleanup).
**Location:** `TablePro/Core/ChangeTracking/DataChangeManager.swift:59–63`.

```swift
private var _columnsStorage: [String] = []
var columns: [String] {
    get { _columnsStorage }
    set { _columnsStorage = newValue.map { String($0) } }
}
```

The `.map { String($0) }` copies every column name. Swift `String` is COW - assignment alone retains storage; the explicit `String($0)` initializer forces a fresh `_StringStorage` (it goes through `init(_ other: String)` which on native strings is a no-op copy of the pointer, but for bridged NSStrings forces a deep copy).

Unless this guard exists to defend against incoming bridged NSStrings, it's redundant - and we now own all column names, since they come from the plugin's `PluginQueryResult.columns: [String]` which is already a Swift `[String]`.

**Target state.**

```swift
var columns: [String] = []
```

Drop the underscore field and the map. Saves ~`column count × ~48 byte` per `configureForTable` call on a large schema, plus the time to re-init each `String`.

If there's a known bug behind this defense, document it in a comment at the field - but per CLAUDE.md, the comment should explain *why* (the historical NSString issue), not *what*.

---

## 13. Summary table (severity × footprint × Apple API)

| # | Sev | Item | File:line | Fix | Apple API |
|---|---|---|---|---|---|
| §1 | CRIT | `displayCache` unbounded | `DataGridCoordinator.swift:17` | `NSCache` w/ countLimit + totalCostLimit | `NSCache`, `NSDiscardableContent` |
| §2 | HIGH | `isFileDirty` bridges per keystroke | `QueryTabState.swift:266` | `(byteCount, hash)` snapshot at save | `String.utf8.count`, `Hasher` |
| §3 | HIGH | `ThemeEngine.shared` 4×/cell | `DataGridBaseCellView.swift:149,156,166,176,190,192,194` | snapshot palette before row loop | Observation registrar semantics |
| §4 | HIGH | UndoManager retains rows + no cap | `DataChangeManager.swift:148–173` | diff capture + `levelsOfUndo = 100` | `UndoManager.levelsOfUndo`, `removeAllActions(withTarget:)` |
| §5 | n/a | regex already cached | `JSONHighlightPatterns.swift:18` | none | static let dispatch_once semantics |
| §6 | MED | `var` on immutable fields | `QueryTabState.swift:259, 260` | `let` / `private(set) var` | access control |
| §7 | MED | `Optional<Optional<T>>` flatten | `QueryTabState.swift:103` | `[String?] = []` | n/a |
| §8 | MED | `Row.values` Array → ContiguousArray | `Row.swift:20` | `ContiguousArray<String?>` | `ContiguousArray` |
| §9 | LOW | broader `NSCache` adoption | various | per-item table | `NSCache`, `NSMapTable.weakToWeakObjects` |
| §10 | HIGH | `PluginQueryResult.rows` full copy | `PluginQueryResult.swift:6` | streaming chunked protocol (datapath agent owns) | `Sendable`, `OSAllocatedUnfairLock` |
| §11 | MED | `Set<Int>` retain in cell loop | `DataGridView.swift:17–20` | inline bitmap `ColumnSet` | `MemoryLayout`, `ContiguousArray` |
| §12 | LOW | `_columnsStorage` defensive copy | `DataChangeManager.swift:59–63` | drop the wrapper | n/a |

---

## 14. Result-set memory ceiling - operator guidance

Use these as upper bounds before degradation, given today's architecture (no streaming, full result resident, `displayCache` unbounded):

| rows × cols | resident before fix | resident after §1 + §10 |
|---|---|---|
| 10k × 20 | ~25 MB | ~25 MB (no change - under cap) |
| 100k × 20 | ~250 MB | ~50 MB (cap + window) |
| 1M × 20 | ~2.5 GB (paging, lag) | ~50 MB (cap + window) |
| 100k × 100 | ~1.25 GB | ~150 MB (cap + window) |

The `NSCache` `totalCostLimit` of 32 MB in §1 is the durable defense; the streaming store in §10 is what makes the underlying result not need to be resident.

---

## 15. Out of scope for this audit

- Layer/render and `wantsLayer` (§2.1, layer agent).
- `reloadData()` overuse and incremental updates (§2.3, NSTableView agent).
- Threading and Combine debounce (§2.4, threading agent).
- SwiftUI/AppKit interop diff (§2.5, interop agent).

These cross at §1 (cache size affects scroll cost) and §10 (streaming affects threading). Cross-references noted; no work duplicated.

---

*End of memory audit. All Apple APIs cited are macOS 14.0+ (TablePro deployment target). No code modified.*
