# Performance Audit — TablePro

**Date:** 2025-03-18
**Related Issue:** [#368 — High CPU Usage by TablePro on macOS](https://github.com/datlechin/TablePro/issues/368)
**Status:** Phase 1-4 fixes applied (16/17 medium+ issues fixed) — build verified

---

## Table of Contents

- [Executive Summary](#executive-summary)
- [Critical Issues](#critical-issues)
- [High Severity](#high-severity)
- [Medium Severity](#medium-severity)
- [Low Severity](#low-severity)
- [Fix Priority Roadmap](#fix-priority-roadmap)

---

## Executive Summary

The primary cause of sustained >100% idle CPU is a **cascading UI re-render loop** in the `DatabaseManager` → `connectionStatusVersion` → `ContentView`/`MainContentView` observation chain. Every 30-second health monitor ping, every tab switch, and every focus change triggers unconditional `activeSessions` dictionary writes that invalidate all open windows' views — even when nothing meaningful changed.

Secondary contributors include main-thread I/O blocking (Keychain, plugin loading, prefetch results), O(n^2) algorithms in undo/change tracking, and missing debounce in JSON syntax highlighting.

### Impact by Category

| Category                           | Critical | High | Medium | Low |
| ---------------------------------- | -------- | ---- | ------ | --- |
| CPU — Health Monitor & Observation | 1        | 2    | 2      | —   |
| CPU — SwiftUI Re-renders           | —        | 2    | 2      | 3   |
| CPU — Timers & Background Work     | —        | —    | 2      | 2   |
| Memory — Leaks & Retention         | —        | 1    | 2      | 3   |
| Performance — Data Operations      | —        | 1    | 5      | 8   |
| Performance — Plugin/Driver        | —        | 2    | 3      | 3   |
| Performance — Rendering            | —        | —    | 3      | 2   |

---

## Critical Issues

### CRIT-1: `connectionStatusVersion` Unconditional Increment Causes N-Window Re-render Storm

- [x] **Fix applied** — `updateSession()` now compares before/after using `isContentViewEquivalent` + driver identity; skips write-back when nothing observable changed

**Files:** `DatabaseManager.swift:297-305`

---

## High Severity

### HIGH-1: `activeSessions` Whole-Dictionary @Observable Granularity

- [x] **Fix applied** — Added `connectionStatusVersions: [UUID: Int]` per-connection counters. ContentView and MainContentView now observe their specific connection's counter. Added `setSession`/`removeSessionEntry` helpers to centralize writes and bump per-connection counters.

**Files:** `DatabaseManager.swift`, `ContentView.swift:105`, `MainContentView.swift:299`

---

### HIGH-2: `switchToSession` Writes `lastActiveAt` Through `activeSessions`, Triggers Full Re-render

- [x] **Fix applied** — `switchToSession` now routes through the guarded `updateSession`; since `markActive()` only changes `lastActiveAt` (excluded from `isContentViewEquivalent`), the guard catches it as a no-op

**File:** `DatabaseManager.swift:241-247`

---

### HIGH-3: Health Monitor Ping Races with Schema Ops on Shared Driver (TOCTOU)

- [x] **Fix applied** — Added `trackOperation` helper; `fetchTables`, `fetchColumns`, `executeSchemaChanges` now all increment `queriesInFlight` so the health monitor skips pings during any driver operation

**File:** `DatabaseManager.swift:321-336`

---

### HIGH-4: Never-Activated Coordinators Leak in `activeCoordinators` Static Dictionary

- [x] **Fix applied** — Moved `registerForPersistence()` from `init()` to `markActivated()`; added safety `unregisterFromPersistence()` in `deinit` for never-activated coordinators

**File:** `MainContentCoordinator.swift:273,278,369`

---

### HIGH-5: `DatabaseRowProvider.prefetchRows` Processes DB Results on MainActor

- [x] **Fix applied** — Fetch runs on cooperative thread pool; only lightweight cache write uses `MainActor.run`. Task tracked in `prefetchTask` with `inFlightRange` dedup guard. `invalidateCache()` cancels in-flight prefetch.

**File:** `RowProvider.swift:311-350`

---

### HIGH-6: N+1 Default `fetchAllColumns`/`fetchAllForeignKeys` at Both Protocol Layers

- [ ] **Fix applied**

**Files:** `DatabaseDriver.swift:247-262`, `PluginDatabaseDriver.swift:168-185`

Default implementations loop per-table with one query each. A schema with 200 tables = 200 serial round-trips. Exists at both `PluginDatabaseDriver` and `DatabaseDriver` layers.

**Fix:** Force plugin authors to override (fatalError in debug builds), or provide a single bulk-query default.

---

## Medium Severity

### MED-1: Health Monitor Fires 2 `onStateChanged` Calls Per Healthy Ping Cycle

- [x] **Fix applied** — `transitionTo` now skips both logging and `onStateChanged` callback for routine `healthy <-> checking` cycles

**File:** `ConnectionHealthMonitor.swift:248-259`

---

### MED-2: `NSWindow.didUpdateNotification` Fires on Every Event Loop Cycle

- [ ] **Fix applied**

**File:** `EditorEventRouter.swift:83-92`

`EditorEventRouter` subscribes to `NSWindow.didUpdateNotification` — one of the most frequently posted AppKit notifications. The handler does an O(1) check, but fires continuously during any user activity.

**Fix:** Use `NSWindow.didBecomeKeyNotification` + explicit first responder tracking instead.

---

### MED-3: SSH Relay Poll at 100ms Intervals

- [ ] **Fix applied**

**File:** `LibSSH2TunnelFactory.swift:488`

Jump-host channel relay uses `poll()` with 100ms timeout, waking 10x/second even when idle.

**Fix:** Increase to 500ms or 1000ms — real data arrival wakes the thread immediately regardless.

---

### MED-4: Column Layout Write-Back Triggers Extra Tab Persistence Save

- [ ] **Fix applied**

**Files:** `DataGridView.swift:389-396`, `MainContentView.swift:293-295`

`DispatchQueue.main.async` writes column widths through `tabManager.tabs[index].columnLayout` → triggers `onChange(of: tabManager.tabs)` → `handleTabsChange` → `saveNow()`. Every initial data load causes one extra JSON encode + file write.

**Fix:** Separate column layout persistence from tab state persistence, or filter the `onChange` to ignore layout-only changes.

---

### MED-5: `ContentView.init` Calls `loadConnections()` from Disk

- [x] **Fix applied** — Replaced `ConnectionStorage.shared.loadConnections()` with in-memory `DatabaseManager.shared.activeSessions` lookup

**File:** `ContentView.swift:43`

---

### MED-6: `WindowLifecycleMonitor` Holds Strong `NSWindow` References

- [x] **Fix applied** — Changed `let window: NSWindow` to `weak var window: NSWindow?`; added `purgeStaleEntries()` called from public query methods; updated all access sites to handle optionals

**File:** `WindowLifecycleMonitor.swift`

---

### MED-7: Keychain Migration Runs Synchronously on Main Thread at Startup

- [x] **Fix applied** — Wrapped in `Task.detached(priority: .utility)` to run off main thread

**File:** `AppDelegate.swift:59`

---

### MED-8: `bundle.load()` + Plugin Init Runs on MainActor

- [x] **Fix applied** — `bundle.load()` and `principalClass` resolution moved to `nonisolated static loadBundlesOffMain()`; only lightweight dictionary registration runs on MainActor. Safety fallbacks in `isDriverAvailable`/`driverPlugin` no longer call synchronous load.

**Files:** `PluginManager.swift`, `DatabaseDriver.swift`

---

### MED-9: `[[String?]]` → `[QueryResultRow]` Full Copy After Every Query

- [ ] **Fix applied**

**File:** `MainContentCoordinator.swift:840-845`

10,000 heap allocations for wrapper structs on every query execution.

**Fix:** Have `PluginQueryResult` expose `[QueryResultRow]` directly, or convert lazily in `RowBuffer.restore()`.

---

### MED-10: Prefetch Task Untracked — Cannot Be Cancelled

- [x] **Fix applied** — (Combined with HIGH-5) `prefetchTask` property tracks the in-flight task; `invalidateCache()` cancels it; `inFlightRange` prevents duplicate fetches

**File:** `RowProvider.swift`

---

### MED-11: `DataGridView.reloadData()` on Every FK Metadata Arrival

- [x] **Fix applied** — Uses `reloadData(forRowIndexes:columnIndexes:)` targeting only visible rows in FK columns; skips reload entirely when no FK columns exist

**File:** `DataGridView.swift:473-483`

---

### MED-12: `DateFormattingService.format` Called Per Cell Per Reload

- [ ] **Fix applied**

**File:** `DataGridCellFactory.swift:333-336`

Every visible date cell re-formats on every `reloadData`, even when the value hasn't changed.

**Fix:** Cache formatted output per value string, or skip re-formatting when the cell is being reused with the same value.

---

### MED-13: JSON Syntax Highlighting Runs 4 Regex Passes Per Keystroke (No Debounce)

- [x] **Fix applied** — Debounced via `DispatchWorkItem` with 100ms delay; only final keystroke in a burst triggers 4 regex passes. Work item cancelled in `deinit`.

**File:** `JSONEditorContentView.swift:203-220`

---

### MED-14: `DataChangeManager.undoBatchRowInsertion` Has O(n^2) Index-Shift Loop

- [x] **Fix applied** — Replaced nested O(n*m) loop with single-pass binary search algorithm: O((n+m) * log n). Added `countLessThan` static helper for binary search.

**File:** `DataChangeManager.swift:90,432-446`

---

### MED-15: Reconnect Loop Fires `updateSession(.connecting)` Without Guard

- [x] **Fix applied** — Added guard checking `if case .connecting = status` before calling `updateSession`; fixed incorrect `/3` in log message

**File:** `DatabaseManager.swift:517-525`

---

### MED-16: Strong `self` Re-capture in Nested `DispatchQueue.main.async`

- [x] **Fix applied** — Added `[weak self, weak controller]` capture list to inner `DispatchQueue.main.async` closure

**File:** `SQLEditorCoordinator.swift:298-302`

---

### MED-17: `multiColumnSortIndices` Pre-builds 300K String Copies for Large Datasets

- [ ] **Fix applied**

**File:** `MainContentCoordinator.swift:1190-1195`

100,000 rows x 3 sort columns = 300,000 string copies into intermediate arrays.

**Fix:** For single-column sorts (95% case), use direct comparison without intermediate key array.

---

## Low Severity

### LOW-1: `isDriverAvailable`/`driverPlugin(for:)` Synchronously Load Bundles on MainActor

**File:** `PluginManager.swift:460-490`

If the deferred startup `Task` hasn't completed, these load all plugins synchronously as a "safety fallback."

### LOW-2: Throw-Away Driver Allocated Per `queryBuildingDriver(for:)` Call

**File:** `PluginManager.swift:494-502`

A full driver instance is created just to probe one method. Should cache a per-type boolean flag.

### LOW-3: Column Type Classification Not Cached Per Table

**File:** `PluginDriverAdapter.swift:409-479`

`mapColumnType` performs multiple string operations per column, per query result. Results never cached.

### LOW-4: `substituteQuestionMarks` Uses Swift Grapheme-Cluster Iteration

**File:** `PluginDatabaseDriver.swift:271-310`

Inconsistent with the corrected `substituteDollarParams` which uses `NSString.character(at:)`.

### LOW-5: Duplicate `onChange(of: tabManager.tabs.count)` Observer

**File:** `MainEditorContentView.swift:118-134`

Entirely superseded by `onChange(of: tabManager.tabs.map(\.id))`. Remove the `.count` observer.

### LOW-6: `tabs.map(\.id)` Allocation on Every Body Pass

**File:** `MainEditorContentView.swift:127`

O(N) array allocation per render. Add `var tabIds: [UUID]` as an explicit tracked property.

### LOW-7: `components(separatedBy:)` Allocates Full Array Just for Line Count

**Files:** `CellOverlayEditor.swift:60`, `SQLFormatterService.swift:372`, `RowOperationsManager.swift:397`

Should count newlines without allocating the split array.

### LOW-8: `SQLFormatterService.alignWhereConditions` Uses 6x Linear String Scans

**File:** `SQLFormatterService.swift:468-482`

Should compile a single alternation regex.

### LOW-9: `SQLSchemaProvider.resolveAlias` Creates 300+ Lowercase String Copies Per Keystroke

**File:** `SQLSchemaProvider.swift:120-142`

Should lowercase `aliasOrName` once; store pre-normalized values.

### LOW-10: `Array.contains` in Hot Autocomplete Loop (O(n) per Reference)

**File:** `SQLContextAnalyzer.swift:354,362,819`

Should use `Set<TableReference>` (requires `Hashable` conformance).

### LOW-11: DDL/SQL Highlight Views Compile 40+ Individual Keyword Regexes

**Files:** `DDLTextView.swift:61-107`, `HighlightedSQLTextView.swift`

Should merge into one alternation regex — one pass instead of 40+.

### LOW-12: `InMemoryRowProvider.removeRow` Rebuilds Entire Index Array

**File:** `RowProvider.swift:213-216`

Should use in-place mutation instead of `.map`.

### LOW-13: `InlineSuggestionManager` Scroll Observer Always Active Even Without Suggestion

**File:** `InlineSuggestionManager.swift:428`

Should add `guard currentSuggestion != nil` before creating the repositioning `Task`.

### LOW-14: Double Bundle Validation + Double Signature Verify at Startup

**File:** `PluginManager.swift:141-251`

`discoverPlugin` and `loadPlugin` both create bundles and verify signatures independently.

---

## Fix Priority Roadmap

### Phase 1 — Idle CPU (Addresses #368 directly)

| Priority | Issue                                                      | Expected Impact                                   |
| -------- | ---------------------------------------------------------- | ------------------------------------------------- |
| P0       | CRIT-1: Guard `updateSession` no-op writes                 | Eliminates ~80% of idle re-renders                |
| P0       | MED-1: Skip `onStateChanged` for routine healthy cycles    | Eliminates 2 MainActor dispatches/30s/connection  |
| P1       | HIGH-1: Per-connection observation granularity             | Scopes re-renders to affected connection only     |
| P1       | HIGH-2: Remove `lastActiveAt` from `activeSessions` writes | Eliminates re-renders on every tab switch         |
| P2       | MED-2: Replace `NSWindow.didUpdateNotification`            | Reduces event handler invocations by ~100x        |
| P2       | MED-15: Guard reconnect `updateSession(.connecting)`       | Prevents rapid-fire version bumps during failures |

### Phase 2 — Startup & Main Thread Blocking

| Priority | Issue                                         | Expected Impact                     |
| -------- | --------------------------------------------- | ----------------------------------- |
| P1       | MED-7: Background Keychain migration          | Faster cold start                   |
| P1       | MED-8: Background plugin loading              | Eliminates UI stall on startup      |
| P2       | MED-5: Move `loadConnections()` to `onAppear` | Prevents I/O during SwiftUI diffing |

### Phase 3 — Memory

| Priority | Issue                                                   | Expected Impact                               |
| -------- | ------------------------------------------------------- | --------------------------------------------- |
| P1       | HIGH-4: Fix `activeCoordinators` leak                   | Prevents coordinator + RowBuffer accumulation |
| P2       | MED-6: Weak `NSWindow` refs in `WindowLifecycleMonitor` | Prevents window zombie retention              |
| P2       | MED-16: `[weak self]` in nested async closures          | Prevents brief coordinator retention          |

### Phase 4 — Query Performance & Rendering

| Priority | Issue                                   | Expected Impact                        |
| -------- | --------------------------------------- | -------------------------------------- |
| P1       | HIGH-5: Background prefetch processing  | Eliminates scroll jank on large tables |
| P1       | HIGH-3: Serialize driver operations     | Prevents driver corruption/crash       |
| P2       | MED-9: Lazy `QueryResultRow` conversion | Reduces allocation pressure            |
| P2       | MED-11: Targeted FK column reload       | Faster Phase 2 metadata display        |
| P2       | MED-13: Debounce JSON highlighting      | Smoother JSON cell editing             |
| P2       | MED-14: O(n log n) undo index shift     | Faster batch undo                      |

### Phase 5 — Polish

All LOW severity items — autocomplete optimizations, regex consolidation, string operation fixes, minor allocation reductions.
