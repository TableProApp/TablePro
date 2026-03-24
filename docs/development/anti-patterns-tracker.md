# Anti-Patterns & Incorrect Behavior Tracker

Status legend: `[ ]` = TODO, `[x]` = Fixed, `[-]` = Won't fix

---

## 1. Window Lifecycle & Focus Management

### 1.1 [x] Active tab evicted on window focus loss (CRITICAL)
- **File**: `TablePro/Views/Main/MainContentView.swift:349-365`
- **Problem**: When the window loses focus, `evictInactiveRowData()` evicts ALL tabs including the currently visible one. When the user switches back, the visible grid re-fetches data, causing a visible refresh flicker.
- **Correct behavior**: Native macOS apps (Xcode, Safari, TablePlus) keep the active tab's content in memory. Only background/non-visible tabs should be eviction candidates.
- **Fix**: `evictInactiveRowData()` must skip the currently selected tab.

### 1.2 [x] Unreliable window discovery via NSApp.keyWindow (HIGH)
- **File**: `TablePro/Views/Main/MainContentView.swift:219-244`
- **Problem**: Window registration uses `DispatchQueue.main.async` then queries `NSApp.keyWindow`, which can return the wrong window in multi-window scenarios. Fallback uses fragile title-based matching.
- **Fix**: Capture the window through SwiftUI's view hierarchy (NSViewRepresentable) instead of querying global state.

### 1.3 [x] Duplicate window discovery pattern in command actions (HIGH)
- **File**: `TablePro/Views/Main/MainContentView.swift:624-633`
- **Problem**: `actions.window = NSApp.keyWindow` with async retry if nil. Same unreliable pattern as 1.2.
- **Fix**: Share the window reference captured in 1.2's fix.

### 1.4 [x] Fragile subtitle-based window matching (MEDIUM)
- **File**: `TablePro/Views/Main/MainContentView.swift:276-283`
- **Problem**: `window.subtitle == connectionName` is fragile -- subtitles can be empty, duplicated, or changed. Inconsistent with `WindowLifecycleMonitor.hasWindows()` used elsewhere.
- **Fix**: Always use `WindowLifecycleMonitor.hasWindows(for: connectionId)` as single source of truth.

### 1.5 [x] Notification observer fires before window registration (MEDIUM)
- **File**: `TablePro/Views/Main/MainContentView.swift:324-348`
- **Problem**: `viewWindow` is set asynchronously in `onAppear`, so `didBecomeKeyNotification` observers that compare `notificationWindow === viewWindow` silently miss early notifications when `viewWindow` is still nil.
- **Fix**: Ensure window registration completes before subscribing to notifications, or queue missed notifications.

### 1.6 [x] Stale isKeyWindow initialization (MEDIUM)
- **File**: `TablePro/Views/Main/MainContentView.swift:243`
- **Problem**: `isKeyWindow = window.isKeyWindow` is a single-point-in-time snapshot that's immediately stale. The notification handlers already track this separately, creating dual sources of truth.
- **Fix**: Remove the synchronous initialization; let `didBecomeKeyNotification`/`didResignKeyNotification` be the sole source.

### 1.7 [x] Inconsistent window identifier matching (LOW)
- **File**: `TablePro/AppDelegate+WindowConfig.swift:103-115`
- **Problem**: `isMainWindow` uses `.contains("main")`, `isWelcomeWindow` uses `== "welcome"` OR title fallback, `isConnectionFormWindow` uses `.contains("connection-form")`. Substring matching can match unintended windows.
- **Fix**: Use exact matching with a centralized `WindowIdentifier` enum/constants.

### 1.8 [-] ObjectIdentifier-based window tracking (LOW)
- **File**: `TablePro/AppDelegate+WindowConfig.swift:210-248`
- **Problem**: `configuredWindows` uses `ObjectIdentifier(window)` which is memory-address-based. If an NSWindow is deallocated and a new one allocated at the same address, they get the same identifier.
- **Fix**: Use UUID-based window identifiers.

### 1.9 [x] Unnecessary DispatchQueue.main.async in notification handlers (LOW)
- **File**: `TablePro/AppDelegate+WindowConfig.swift:263-282`
- **Problem**: Window operations dispatched async from notification handlers that already run on main thread. Introduces race windows where window state changes between check and action.
- **Fix**: Keep critical window operations synchronous when already on main thread.

### 1.10 [-] Duplicate observers for didBecomeKeyNotification (LOW)
- **Files**: `TablePro/AppDelegate+WindowConfig.swift:210+`, `TablePro/Views/Main/MainContentView.swift:324+`
- **Problem**: Both AppDelegate and MainContentView observe `NSWindow.didBecomeKeyNotification` independently. Both fire for every window focus change.
- **Fix**: Centralize in `WindowLifecycleMonitor` and have views subscribe to a custom signal.

---

## 2. Memory Management & Task Lifecycle

### 2.1 [x] Missing redisDatabaseSwitchTask cancellation in teardown (HIGH)
- **File**: `TablePro/Views/Main/MainContentCoordinator.swift:106-108, 350-355`
- **Problem**: `currentQueryTask` and `changeManagerUpdateTask` are cancelled in `teardown()`, but `redisDatabaseSwitchTask` is not. This leaves a dangling Task if coordinator is deallocated during a Redis database switch.
- **Fix**: Add `redisDatabaseSwitchTask?.cancel(); redisDatabaseSwitchTask = nil` to `teardown()`.

### 2.2 [x] Missing deinit in AIChatViewModel (HIGH)
- **File**: `TablePro/ViewModels/AIChatViewModel.swift:91-92`
- **Problem**: `streamingTask` is never cancelled if the view model is deallocated while streaming. The Task continues executing in the background.
- **Fix**: Add `deinit { streamingTask?.cancel() }`.

### 2.3 [x] Weak self with optional chaining in periodic Task loops (MEDIUM)
- **Files**:
  - `TablePro/Core/Services/Licensing/LicenseManager.swift:86-100`
  - `TablePro/Core/Services/Infrastructure/AnalyticsService.swift:63-75`
- **Problem**: Inside `while !Task.isCancelled` loops, `self?.revalidationInterval ?? 604_800` silently uses the fallback value if self is deallocated, then continues the loop with a default interval forever.
- **Fix**: Use `guard let self else { return }` at the top of the task, or re-check inside the loop with early exit.

### 2.4 [x] Eviction pending-changes check is incomplete (MEDIUM)
- **File**: `TablePro/Views/Main/MainContentView.swift:349-365`
- **Problem**: The pre-eviction check uses `changeManager.hasChanges` (in-memory changes), but `evictInactiveRowData()` checks `tab.pendingChanges.hasChanges` (tab-level). These are different — a tab may have tab-level changes even if `changeManager` is empty.
- **Fix**: Check both `changeManager.hasChanges` and `tab.pendingChanges.hasChanges` consistently, or defer the check to just before eviction runs.

### 2.5 [x] WindowLifecycleMonitor observer re-registration without full cleanup (LOW)
- **File**: `TablePro/Core/Services/Infrastructure/WindowLifecycleMonitor.swift:41-66`
- **Problem**: If `register()` is called twice with the same `windowId` but a different `NSWindow`, the old observer is removed but the old NSWindow is now orphaned without observation.
- **Fix**: Guard against re-registration with a different window or explicitly unregister the old window.

### 2.6 [-] Fire-and-forget disconnect Task in WindowLifecycleMonitor (LOW)
- **File**: `TablePro/Core/Services/Infrastructure/WindowLifecycleMonitor.swift:190-211`
- **Problem**: `Task { await DatabaseManager.shared.disconnectSession(...) }` has no error handling. If disconnect fails, the connection persists as a zombie.
- **Fix**: Log errors from the disconnect call.

---

## 3. Connection & Query Execution

### 3.1 [x] Missing trackOperation in reconnectDriver (CRITICAL)
- **File**: `TablePro/Core/Database/DatabaseManager.swift:599-632`
- **Problem**: `reconnectDriver()` does NOT call `trackOperation()`, so `queriesInFlight` is never incremented. The health monitor's ping (`SELECT 1`) can race with the reconnect on the same driver, causing concurrent driver access.
- **Fix**: Wrap reconnection in `trackOperation()` or stop the health monitor before reconnecting.

### 3.2 [x] Stale session reference in reconnectSession (HIGH)
- **File**: `TablePro/Core/Database/DatabaseManager.swift:601-632`
- **Problem**: Line 649 captures `session` into a local variable. Lines 682-690 re-fetch from `activeSessions[sessionId]`, creating inconsistency. The local `session` could have stale schema/database values.
- **Fix**: Always re-fetch from `activeSessions[sessionId]` before accessing mutable state, or pass all needed state as parameters.

### 3.3 [x] Fire-and-forget SSH tunnel close (HIGH)
- **Files**: `TablePro/Core/Database/DatabaseManager.swift:131-135, 220-224, 258-260`
- **Problem**: SSH tunnels are closed in `Task { try? await ... }` blocks. If the task is cancelled or fails, the tunnel remains open. No error logging. Appears in 3+ locations.
- **Fix**: `await` the tunnel close synchronously or at minimum log errors.

### 3.4 [x] Discarded schema/database switch errors during reconnect (HIGH)
- **File**: `TablePro/Core/Database/DatabaseManager.swift:620-629, 682-691`
- **Problem**: `try? await schemaDriver.switchSchema(to: savedSchema)` silently discards errors. If schema switch fails, the connection operates in the wrong schema without any warning.
- **Fix**: Log the error and optionally update session status to reflect the failure.

### 3.5 [-] No cancel-await-run synchronization for queries (MEDIUM → demoted to P3)
- **File**: `TablePro/Views/Main/MainContentCoordinator.swift:37-39`
- **Problem**: `currentQueryTask?.cancel()` followed immediately by `runQuery()`. Cancel doesn't wait for the running task to finish, so two queries can be in-flight simultaneously writing to the same `QueryTab`.
- **Fix**: `await` the cancelled task's completion before starting the new query, or use a serial queue.

### 3.6 [x] Health monitor ping skips when queriesInFlight exists (MEDIUM)
- **File**: `TablePro/Core/Database/DatabaseManager.swift:535`
- **Problem**: `guard await self.queriesInFlight[connectionId] == nil else { return true }` returns "healthy" if any query is in-flight. But a stuck query would keep the monitor returning true forever, masking a dead connection.
- **Fix**: Track query start time and consider connections unhealthy if a query has been in-flight beyond a threshold.

### 3.7 [x] Inconsistent exponential backoff between DatabaseManager and HealthMonitor (LOW)
- **Files**: `DatabaseManager.swift:745`, `ConnectionHealthMonitor.swift:38, 230-238`
- **Problem**: DatabaseManager uses `2.0 * pow(2.0, retryCount)` formula. HealthMonitor uses a predefined `[2.0, 4.0, 8.0]` array with different progression. Same app, different reconnect timing.
- **Fix**: Unify backoff strategy into a shared utility.

### 3.8 [x] Synchronous plugin loading fallback on main thread (MEDIUM)
- **File**: `TablePro/Core/Database/DatabaseDriver.swift:318-333`
- **Problem**: `PluginManager.shared.loadPendingPlugins()` is called synchronously on main thread when a plugin isn't loaded yet. Can freeze the UI if loading takes >100ms.
- **Fix**: Pre-load all plugins at app startup, or make this async with a loading indicator.

---

## 4. Architecture & State Management

### 4.1 [-] AppSettingsManager dual notification channels (HIGH → demoted to P3)
- **File**: `TablePro/Core/Storage/AppSettingsManager.swift:18-193`
- **Problem**: Settings changes fire BOTH `@Observable` property updates AND `NotificationCenter.post()`. Views that observe both channels get redundant updates. Unclear which to use.
- **Fix**: Use `@Observable` for local subscriptions, remove `NotificationCenter` posts for setting changes. Keep NotificationCenter only for system-wide events (accessibility).

### 4.2 [x] AppSettingsManager missing observer cleanup (MEDIUM)
- **File**: `TablePro/Core/Storage/AppSettingsManager.swift:179`
- **Problem**: `observeAccessibilityTextSizeChanges()` registers a NotificationCenter observer stored in `@ObservationIgnored`. No `deinit` removes it.
- **Fix**: Add `deinit { if let observer = accessibilityTextSizeObserver { NotificationCenter.default.removeObserver(observer) } }`.

### 4.3 [-] SharedSidebarState registry race condition (MEDIUM → demoted to P3)
- **File**: `TablePro/Models/UI/SharedSidebarState.swift:51-62`
- **Problem**: `static var registry: [UUID: SharedSidebarState]` with no synchronization. Concurrent calls from different threads can create duplicate instances for the same connection.
- **Fix**: Mark SharedSidebarState and registry as `@MainActor`, or use `OSAllocatedUnfairLock`.

### 4.4 [-] Static termination observer never removed (MEDIUM → demoted to P3)
- **File**: `TablePro/Views/Main/MainContentCoordinator.swift:197-203`
- **Problem**: `registerTerminationObserver` is static and called once. The observer is never removed and fires for every coordinator instance at app termination.
- **Fix**: Make instance-level, remove in teardown. Or use a dedicated `AppTerminationManager`.

### 4.5 [x] Undo stack destroyed on tab switch (MEDIUM)
- **File**: `TablePro/Core/ChangeTracking/DataChangeManager.swift:129-137`
- **Problem**: `clearChanges()` calls `undoManager.clearAll()`. When switching tabs, if `clearChanges()` is called, the undo history is permanently lost even though changes are persisted via `saveState()`/`restoreState()`.
- **Fix**: Separate `clearChanges()` (preserves undo) from `clearChangesAndUndoHistory()` (full reset on commit).

### 4.6 [x] Tab state save silently fails on disk errors (MEDIUM)
- **File**: `TablePro/Core/Storage/TabDiskActor.swift:79-81`
- **Problem**: File I/O errors during tab state save are logged but never returned. If write fails (disk full), tabs are lost silently.
- **Fix**: Return `Result<Void, Error>` so callers can retry or alert the user.

### 4.7 [x] Silent startup command failures (LOW)
- **File**: `TablePro/Core/Database/DatabaseManager.swift:783-793`
- **Problem**: User-defined startup SQL commands that fail are logged but the connection continues. User expects commands like `SET ROLE` to succeed but has no indication of failure.
- **Fix**: Collect errors and show a warning: "Startup commands failed. Continue anyway?"

---

## 5. SwiftUI Patterns

### 5.1 [-] Unnecessary DispatchQueue.main.async in SwiftUI callbacks (MEDIUM → demoted to P3)
- **Files** (8+ locations):
  - `TablePro/Views/Results/DataGridView.swift:400-403, 433-441, 537-545`
  - `TablePro/Views/AIChat/AIChatPanelView.swift:205-207, 225-227`
  - `TablePro/Views/Main/Child/MainEditorContentView.swift:348, 358-365`
  - `TablePro/Views/Toolbar/ConnectionSwitcherPopover.swift:351-352`
  - `TablePro/Views/Components/SQLReviewPopover.swift:90-91`
  - `TablePro/Views/Connection/WelcomeWindowView.swift:770-778`
  - `TablePro/Views/Results/Extensions/DataGridView+Editing.swift:164-166, 196-199, 218-221`
- **Problem**: `onAppear`, `onChange`, and body callbacks already execute on main thread. Wrapping in `DispatchQueue.main.async` adds latency and can cause visual glitches or double-renders.
- **Fix**: Remove unnecessary `DispatchQueue.main.async` wrappers. Use `Task { @MainActor in }` only when deferral is genuinely needed.

### 5.2 [-] Multiple onChange handlers on related state (LOW)
- **File**: `TablePro/Views/AIChat/AIChatPanelView.swift:210-228`
- **Problem**: Three separate `onChange` handlers for `messages.last?.content`, `messages.count`, and `activeConversationID` all trigger scrolling. If a new message arrives on a conversation switch, scrolling happens multiple times.
- **Fix**: Consolidate into a single scroll trigger.

### 5.3 [x] Recursive asyncAfter retry for window focus (LOW)
- **File**: `TablePro/Views/Connection/WelcomeWindowView.swift:770-778`
- **Problem**: Recursive `DispatchQueue.main.asyncAfter(deadline: .now() + 0.02)` with retry count. No cancellation if view disappears. Hardcoded timing.
- **Fix**: Use a cancellable `Task` with `Task.sleep`.

### 5.4 [-] DispatchQueue.main.async in updateNSView path (LOW)
- **File**: `TablePro/Views/Results/DataGridView.swift:400-403, 433-441`
- **Problem**: Inside `updateNSView` -> `updateColumns`, a binding update is dispatched to the next cycle. This causes the view to re-evaluate before the flag is cleared, potentially causing flicker.
- **Fix**: Use `Task.yield()` or accept the binding update synchronously.

---

## Priority Order for Fixes

### P0 - Critical (fix immediately)
1. **1.1** Active tab evicted on window focus loss
2. **3.1** Missing trackOperation in reconnectDriver

### P1 - High (fix soon)
3. **2.1** Missing redisDatabaseSwitchTask cancellation
4. **2.2** Missing deinit in AIChatViewModel
5. **3.3** Fire-and-forget SSH tunnel close
6. **3.4** Discarded schema/database switch errors
7. **3.2** Stale session reference in reconnectSession
8. **1.2** Unreliable window discovery via NSApp.keyWindow
9. **1.3** Duplicate window discovery pattern
10. **4.1** AppSettingsManager dual notification channels

### P2 - Medium (fix in next cycle)
11. **2.3** Weak self in periodic Task loops
12. **2.4** Eviction pending-changes check incomplete
13. **3.5** No cancel-await-run synchronization
14. **3.6** Health monitor ping masking stuck queries
15. **3.8** Synchronous plugin loading on main thread
16. **4.2** AppSettingsManager missing observer cleanup
17. **4.3** SharedSidebarState registry race condition
18. **4.4** Static termination observer never removed
19. **4.5** Undo stack destroyed on tab switch
20. **4.6** Tab state save silently fails
21. **1.4** Fragile subtitle-based window matching
22. **1.5** Notification observer fires before window registration
23. **5.1** Unnecessary DispatchQueue.main.async in SwiftUI

### P3 - Low (backlog)
24. **1.6** Stale isKeyWindow initialization
25. **1.7** Inconsistent window identifier matching
26. **1.8** ObjectIdentifier-based window tracking
27. **1.9** Unnecessary async in notification handlers
28. **1.10** Duplicate observers for didBecomeKeyNotification
29. **2.5** WindowLifecycleMonitor observer re-registration
30. **2.6** Fire-and-forget disconnect Task
31. **3.7** Inconsistent exponential backoff
32. **4.7** Silent startup command failures
33. **5.2** Multiple onChange handlers on related state
34. **5.3** Recursive asyncAfter retry
35. **5.4** DispatchQueue.main.async in updateNSView
