# Known Issues & Improvement Tracker

Comprehensive analysis of incorrect approaches, bugs, and areas for improvement.
Last updated: 2026-03-16.

---

## 1. Data Change Protection (CRITICAL)

Unsaved data edits can be silently lost through multiple code paths.

### 1.1 `changeManager.saveState()` never called — tab switch loses changes

- **File:** `Views/Main/Extensions/MainContentCoordinator+TabSwitch.swift:12–110`
- **Problem:** When switching tabs, the outgoing tab's pending changes are never saved to `tab.pendingChanges`. `changeManager.saveState()` exists but is only called in tests.
- **Impact:** Edit cells in Tab A → switch to Tab B → Tab A's changes are gone.
- **Fix:** At the start of `handleTabChange(from:to:...)`, call `changeManager.saveState()` and store the result in the outgoing tab's `pendingChanges`.

### 1.2 `applyPhase1Result` unconditionally clears changes

- **File:** `Views/Main/MainContentCoordinator.swift:1367–1371`
- **Problem:** Every query result clears `changeManager` via `clearChanges()`, even if the query was triggered by sort, pagination, filter, or auto-reconnect — not by an intentional user refresh.
- **Impact:** Any action that triggers `runQuery()` silently wipes unsaved edits.
- **Fix:** Only clear changes when the user explicitly confirmed (e.g., via `handleRefresh`).

### 1.3 Sort on table tabs fires `runQuery()` without checking pending changes

- **File:** `Views/Main/MainContentCoordinator.swift:1158–1165`
- **Problem:** Clicking a column header to sort calls `runQuery()` directly with no pending-changes guard.
- **Fix:** Show confirmation dialog (like `handleRefresh`) before sorting with unsaved changes.

### 1.4 Pagination navigation loses unsaved changes

- **File:** `Views/Main/Extensions/MainContentCoordinator+Pagination.swift:14–108`
- **Problem:** `goToNextPage()`, `goToPreviousPage()`, etc. all call `reloadCurrentPage()` → `runQuery()` with no guard.
- **Fix:** Same confirmation pattern as `handleRefresh`.

### 1.5 Filter/search application loses unsaved changes

- **File:** `Views/Main/Extensions/MainContentCoordinator+Filtering.swift:13–128`
- **Problem:** `applyFilters()`, `applyQuickSearch()`, `clearFiltersAndReload()` all call `runQuery()` ungated.
- **Fix:** Same confirmation pattern.

### 1.6 Auto-reconnect can trigger `runQuery()` silently

- **File:** `Views/Main/MainContentView.swift:299–317`
- **Problem:** When the health monitor auto-reconnects, `connectionStatusVersion` increments, and if `needsLazyLoad` is true, `runQuery()` fires without checking pending changes.
- **Fix:** Add `!changeManager.hasChanges` guard. Don't clear `needsLazyLoad` if the guard blocks the load.

### 1.7 SSH tunnel death recovery can trigger silent refresh

- **File:** `Core/Database/DatabaseManager.swift:636–669`
- **Problem:** `handleSSHTunnelDied` reconnects and posts notifications that trigger `runQuery()` without pending-changes guard.

### 1.8 Eviction guards check `tab.pendingChanges.hasChanges` which is never populated

- **File:** `Views/Main/MainContentCoordinator.swift:196–202`
- **Problem:** Eviction correctly guards on `tab.pendingChanges.hasChanges`, but since Issue 1.1 means `saveState()` is never called, this guard is always `false`.
- **Impact:** Combined with Issue 1.1, eviction during tab switching can clear data for tabs with unsaved changes.

---

## 2. SSH Tunnel Thread Safety (CRITICAL)

### 2.1 Concurrent `relayQueue` allows simultaneous libssh2 calls on same session

- **File:** `Core/SSH/LibSSH2Tunnel.swift:35–39`
- **Problem:** libssh2 is NOT thread-safe per session. The concurrent queue allows multiple relay tasks + keep-alive to call libssh2 functions on the same session simultaneously. This is undefined behavior.
- **Impact:** Memory corruption, session state corruption, crashes under concurrent database connections through the same tunnel.
- **Fix:** Use a per-tunnel serial queue instead of a shared concurrent queue. Route ALL libssh2 calls (relays + keep-alive) through this serial queue.
- **Note:** The concurrent queue was added to fix a deadlock where the serial forwarding loop blocked relay tasks. The correct fix is to run the forwarding loop on a SEPARATE queue or thread, keeping libssh2 I/O serialized.

### 2.2 Jump-hop relay runs on cooperative pool, not on session queue

- **File:** `Core/SSH/LibSSH2TunnelFactory.swift:449–513`
- **Problem:** `startChannelRelay` runs as `Task.detached` on the cooperative pool, racing with `relayQueue` tasks on the same session.
- **Fix:** Route through the same per-tunnel serial queue.

### 2.3 Keep-alive fires on cooperative pool, not on session queue

- **File:** `Core/SSH/LibSSH2Tunnel.swift:118–135`
- **Problem:** `libssh2_keepalive_send` runs on the cooperative pool thread, racing with relay tasks.
- **Fix:** Dispatch keep-alive through the session's serial queue.

### 2.4 `close()` closes socketFD before relay tasks exit — fd reuse race

- **File:** `Core/SSH/LibSSH2Tunnel.swift:159`
- **Problem:** `Darwin.close(socketFD)` is called while relay tasks may be in the middle of `libssh2_channel_write`. The fd number can be reused by another `socket()` call, causing the relay to write to a completely different connection.
- **Fix:** Move `Darwin.close(socketFD)` into the deferred task, after `await task.value` completes.

### 2.5 Jump-hop socketpair fd double-close on error

- **File:** `Core/SSH/LibSSH2TunnelFactory.swift:155–163`
- **Problem:** Error cleanup closes `fds[0]`, but the relay task's `defer` also closes it. Double-close of an fd is undefined behavior.
- **Fix:** Don't close `fds[0]` in the error path — the relay task owns it.

---

## 3. Database Connection Issues (HIGH)

### 3.1 Health monitor ping races with user queries

- **File:** `Core/Database/DatabaseManager.swift:448–458`
- **Problem:** The ping handler and user queries share the same driver instance. Database client libraries (libmariadb, libpq) are not thread-safe per connection. Two concurrent calls corrupt the protocol state.
- **Fix:** Skip pings when a query is in-flight, or use a dedicated connection for health checks.

### 3.2 `handleSSHTunnelDied` retry loop silently no-ops

- **File:** `Core/Database/DatabaseManager.swift:636–669`
- **Problem:** After tunnel death, the session still has a (dead) driver. `connectToSession` sees `driver != nil` and returns without reconnecting. Every retry hits the same branch.
- **Fix:** Set `driver = nil` before retrying, or call `disconnectSession` first.

### 3.3 SSH death handler doesn't stop health monitor before retry

- **File:** `Core/Database/DatabaseManager.swift:636–669`
- **Problem:** Two independent reconnection loops run simultaneously (health monitor + tunnel death handler), potentially interfering with each other.
- **Fix:** Call `stopHealthMonitor(for: connectionId)` at the top of `handleSSHTunnelDied`.

### 3.4 `testConnection` tunnel close is fire-and-forget

- **File:** `Core/Database/DatabaseManager.swift:350–359`
- **Problem:** Tunnel close in `defer` block uses unstructured `Task`, not awaited. Rapid test button clicks can create/destroy tunnels concurrently.
- **Fix:** Await the close inline.

---

## 4. UI / UX Issues (MEDIUM)

### 4.1 Delete connection has no confirmation dialog

- **File:** `Views/Connection/ConnectionFormView.swift:796–798`
- **Problem:** "Delete" button fires immediately with no "Are you sure?" confirmation. Deleting is irreversible.

### 4.2 `testSucceeded` state persists after connection details change

- **File:** `Views/Connection/ConnectionFormView.swift:112, 1204–1217`
- **Problem:** Green checkmark from a successful test persists even after changing host/port/credentials. No reset on field change or on test failure.
- **Fix:** Set `testSucceeded = false` in the catch block and on relevant field changes.

### 4.3 SSH port not validated

- **File:** `Views/Connection/ConnectionFormView.swift:838–851`
- **Problem:** SSH port field accepts any string. Invalid values silently fall back to port 22.
- **Fix:** Validate `Int(sshPort)` is in range 1–65535.

### 4.4 Toolbar help tooltips hard-code shortcuts

- **File:** `Views/Toolbar/TableProToolbarView.swift`
- **Problem:** `.help("Toggle Filters (⌘F)")` etc. hard-code modifier symbols. If user remaps shortcuts, tooltips are wrong.
- **Fix:** Read configured shortcut from `AppSettingsManager.keyboard`.

### 4.5 Status bar Data/Structure picker has no accessibility label

- **File:** `Views/Main/Child/MainStatusBarView.swift:40–47`
- **Problem:** `Picker("", ...)` — empty label. VoiceOver announces "picker" with no context.

### 4.6 Status bar offset hack

- **File:** `Views/Main/Child/MainStatusBarView.swift:47`
- **Problem:** `.offset(x: -26)` is a fragile layout hack that breaks at different font sizes.

### 4.7 Menu "Toggle Filters" enabled on query tabs where it does nothing

- **File:** `TableProApp.swift:331–335`
- **Problem:** The menu command lacks the `.disabled(... || !state.isTableTab)` guard that the toolbar button has.

### 4.8 Connection failure alert may attach to no window

- **File:** `Views/Connection/ConnectionFormView.swift:1071–1076`
- **Problem:** After closing windows, `window: nil` alert may be invisible.

---

## 5. SSH Auth & Misc (MEDIUM/LOW)

### 5.1 `AgentAuthenticator` lock doesn't cover full auth cycle

- **File:** `Core/SSH/Auth/AgentAuthenticator.swift:19–39`
- **Problem:** Lock only covers `setenv/unsetenv`, not the agent connect/auth/disconnect. Concurrent tunnels with mixed socket paths can see wrong `SSH_AUTH_SOCK`.

### 5.2 `HostKeyVerifier` semaphore has theoretical deadlock path

- **File:** `Core/SSH/HostKeyVerifier.swift:94–122`
- **Problem:** `DispatchQueue.main.async` + `semaphore.wait()` — if the Task.detached is resumed on the main thread, deadlock occurs.

### 5.3 Jump-hop relay reads channel unconditionally

- **File:** `Core/SSH/LibSSH2TunnelFactory.swift:472–485`
- **Problem:** `tablepro_libssh2_channel_read` called on every 100ms loop iteration regardless of poll result. Unnecessary CPU cost.

---

## 6. Localization Gaps (LOW)

- `Views/Connection/ConnectionFormView.swift:477` — "Agent Socket" picker label
- `Views/Connection/ConnectionFormView.swift:484` — "Custom Path" text field
- `Views/Connection/ConnectionFormView.swift:489` — SSH agent description text
- `Views/Connection/ConnectionFormView.swift:735, 751` — Advanced tab description texts
- `Views/Main/Child/MainStatusBarView.swift:107` — `.help("Toggle Filters (Cmd+F)")` uses "Cmd" instead of ⌘

---

## Priority Order

1. **Issue 2.1** — SSH thread safety (concurrent queue) — causes crashes and corruption
2. **Issue 1.1 + 1.2** — Change protection (tab switch + applyPhase1Result) — causes data loss
3. **Issue 3.1** — Health monitor ping race — causes query corruption
4. **Issue 1.3–1.5** — Sort/pagination/filter change protection — causes data loss
5. **Issue 2.4** — close() fd reuse race — causes crashes
6. **Issue 3.2** — SSH tunnel death recovery no-op — causes stuck connections
7. **Issue 2.3 + 2.2** — Keep-alive and jump-hop thread safety
8. **Issue 3.3** — Double reconnect loops
9. **Issue 4.1–4.8** — UI/UX improvements
10. **Issue 5.1–5.3** — SSH auth and misc
11. **Issue 6** — Localization gaps
