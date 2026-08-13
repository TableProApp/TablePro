# STATUS (updated 2026-08-13)

Branch `single-window-connections`, PR #2097.

**Done and pushed** (all four P0 data-loss bugs are closed):

- B1 restore returns one ordered tab list; window-group split deleted
- B2 `windowGroupIndex` removed from the model, save path and restore result
- B3 write gate: no save until a restore has read the disk; gate opens even on an empty read
- B4 window close saves and tears down every hosted workspace
- B7 per-connection undo via `TabWindowController.windowWillReturnUndoManager`
- B9 sample failure closes one connection, B10 Cmd+W dismisses a failed pane, B11 vim `:q` closes a tab
- B12 `coordinator(forWindow:)` returns the selected workspace's coordinator
- B13 `reconnectWorkspace(_:)` reconnects the connection named, not the selected one
- B5 detail pane carries `.id(connection.id)`
- B14 toolbar is rebuilt on a workspace switch (the `ToolbarContext` refinement below is still the better shape)
- Deleted: `WindowGroupAssignment`, `RestoreWindowPlan`, `WindowTabGroupOrder` and their four suites
- CLAUDE.md invariants corrected for the workspace model

**Not done**

- `WorkspaceLocator` (steps 3-4) and the deletion of `WindowLifecycleMonitor` (step 13, 12+ consumers across 6 files)
- B6 change-manager identity, B8 unsaved-work prompt across workspaces, B18 key-window broadcasts, B19 host selection, B20 row eviction
- Steps 8, 11, 12, 15: visibility over key-window, rail reads its host, Reopen Closed Tab adopts directly, MCP wire contract
- `ToolbarContext` observable box, replacing the toolbar rebuild
- **UI automation asserting two connections share one window.** This is the largest remaining gap: every test on this branch is a unit test, and two shipped bugs (a second table not opening, closed tabs returning after reconnect) were found by hand, not by the suite.

**Note for whoever continues:** another session has been editing `MainSplitViewController`, `MainWindowToolbar*`, `EditorTabStrip` and `MainContentCommandActions+BulkClose` in the same working tree. Check `git status` before assuming an uncommitted change is yours.

---

# THE SINGLE-WINDOW REFACTOR: ORDERED EXECUTION PLAN

## 1. THE ONE SENTENCE

**Make `ConnectionWorkspace` the unit of identity, scope and lifecycle everywhere the code still says "window": every resolver keys on `connectionId`, every genuine window-level event fans out across `MainSplitViewController.workspaces`, and every piece of machinery that existed to reconcile several windows of one connection is deleted rather than rewired.**

Two corollaries that decide most of the individual calls below:

- **"Focus" is no longer `makeKeyAndOrderFront`.** It is `select the workspace, select the tab, then raise the window`. One primitive, `WorkspaceLocator.reveal(connectionId:tabId:)`, and nothing else may spell it.
- **"The window closed" is not "a connection closed".** It is N connection closes. Every window-delegate callback that acts on one coordinator is a bug until it iterates workspaces.

---

## 2. BUGS TO FIX NOW

Ordered by user impact. P0 = irreversible data loss, P1 = data loss recoverable by not quitting, P2 = wrong-target actions, P3 = silent no-ops, P4 = leaks.

### P0: permanent data loss

| # | Bug | Location | Fix |
|---|---|---|---|
| B1 | Saved tab groups above index 0 are handed to `openTab` with `.restoreOrDefault`, which hits `case .restoreOrDefault: break`, so they are dropped and the next autosave erases them from disk | `MainContentView+Setup.swift:164-172, 191-198, 282-306` → `WindowManager.swift:25-46` → `EditorTabOpener.swift:41-42` | `handleRestoreOrDefault` restores **every** saved tab in file order into the one `QueryTabManager`; delete `openRestoredTabWindow` |
| B2 | A pre-`windowGroupIndex` file is expanded to one group per tab, so only tab 0 survives and the rest are erased | `WindowGroupAssignment.swift:65-70`, consumed at `TabPersistenceCoordinator.swift:181` and `MainContentView+Setup.swift:132-144` | Stop reading `windowGroupIndex` at all; ignoring the field is the migration for both file shapes |
| B3 | A save carrying only part of a connection's tabs replaces the full saved set and prunes the overflow sidecars of the omitted tabs | `TabQueryOverflowStore.swift:27-48, 81-87` via `TabDiskActor.swift:94-107, 161-189`; reached because `.openContent` never restores (`MainContentView+Setup.swift:41-73`) | A workspace always restores its saved tabs on bootstrap, then applies its payload; `TabPersistenceCoordinator` refuses every write until `hasObservedTabs` is set by an actual restore |
| B4 | Window close persists exactly one arbitrary hosted connection; the rest lose everything since the last periodic save | `TabWindowController.swift:191` → `MainContentCoordinator+Registry.swift:18-20` → `+WindowLifecycle.swift:68-88` | `MainSplitViewController.handleWindowWillClose()` iterates `workspaces.workspaces` and runs save + teardown per workspace |

### P1: state loss on switch

| # | Bug | Location | Fix |
|---|---|---|---|
| B5 | The detail pane has no identity keyed to its connection, so `@State hasInitialized`, `windowId`, `viewWindow`, `commandActions`, `cachedChangeManager` carry across a workspace switch (either the second connection never restores, or every switch overwrites live tabs with the disk snapshot at `MainContentView+Setup.swift:210`) | `MainSplitViewController.swift:512, 599-615`; `MainContentView.swift:54-61`; `MainEditorContentView.swift:56, 148, 151` | `.id(currentSession.connection.id)` on the built `MainContentView`, and move restore off view `@State` onto `ConnectionWorkspace.hasBootstrapped` |
| B6 | A cell edit made while connection B is displayed is recorded against A's change manager and dropped when B saves | `MainEditorContentView.swift:56, 148-151` (same root as B5) | Same fix as B5 |
| B7 | Undo/redo run on the shared `NSWindow.undoManager`, so Cmd+Z in B rolls back an edit in A | `MainContentCoordinator.swift:520`; `MainContentCommandActions.swift:1050, 1062`; `+UndoState.swift:14` | Route through `ConnectionWorkspace.undoManager` (`ConnectionWorkspace.swift:28`, currently read by nothing) |
| B8 | Closing the window discards unsaved edits in background connections with no prompt | `MainContentCommandActions.swift:367, 440, 492` | `hasUnsavedWorkInWindow` = `workspaces.workspaces.contains { $0.sessionState?.coordinator.hasAnyUnsavedWork() == true }` |
| B9 | Sample-database failure closes the whole window, taking every other connection with it | `WelcomeViewModel+Sample.swift:128-133` | `WindowManager.shared.closeWindow(for: connectionId)` |
| B10 | Cmd+W on a connecting or failed pane closes the entire window | `MainContentCommandActions.swift:421-425, 492-516` | Close the workspace: `WindowManager.shared.closeWindow(for: connectionId)` |
| B11 | Vim `:q` closes the whole app window | `MainEditorContentView.swift:376` | `coordinator.commandActions?.closeTab()` |

### P2: actions hit the wrong connection

| # | Bug | Location | Fix |
|---|---|---|---|
| B12 | `coordinator(forWindow:)` is `activeCoordinators.values.first { $0.contentWindow === window }` and every hosted coordinator matches; it feeds Cmd+W, Cmd+T, `validateMenuItem`, toolbar install, key/resign, window close, Handoff | `MainContentCoordinator+Registry.swift:18-20`; consumers `TabWindowController.swift:13, 22, 34, 141, 164, 191, 216` | Delete it. Resolve through `(window.contentViewController as? MainSplitViewController)?.workspaces.selected?.sessionState?.coordinator` |
| B13 | `TabRouter.openConnection` calls `splitVC.retryConnection()`, which reconnects the **selected** workspace, so clicking a disconnected B tears down and redials the A the user is working in | `TabRouter.swift:103-105` + `MainSplitViewController+Connection.swift:32-35` | `retryConnection(for: connectionId)`, forwarding to the already connection-addressed `connect(_:cancellingPrevious:)` (`+Connection.swift:81`) |
| B14 | The toolbar keeps the coordinator its SwiftUI item views captured at build time: it shows A's name, database, status and spinner while its buttons act on B | `MainSplitViewController.swift:336-347`; `MainWindowToolbar+Delegate.swift:19-141` | A `ToolbarContext` observable box owned by the window; item views read `context.coordinator`; `installToolbar` swaps the box's value instead of hoping `toolbarOwner?.coordinator` is enough |
| B15 | Menu key-equivalent yielding resolves through an arbitrary hosted coordinator, so a grid shortcut can keep or lose its key equivalent regardless of what has focus | `MainMenuBuilder.swift:65-67` | `(NSApp.keyWindow?.contentViewController as? MainSplitViewController)?.commandActions` |
| B16 | Rail context-menu Close resolves `mostRecentWindow` then `coordinator(forWindow:)`, closing tabs in the wrong connection or doing nothing | `WorkspaceRailViewController.swift:319, 375-377` | `host.workspaces.workspace(for:)?.sessionState?.coordinator` |
| B17 | The rail's `connectionId` is frozen at the window's first connection, so clicking row B switches then snaps the highlight back to A | `WorkspaceRailViewController.swift:28`; `NavigationSidebarViewController.swift:27`; `MainSplitViewController.swift:201`; `WorkspaceRailStore.swift:140` | Read `host.workspaces.selectedConnectionId` on every reload |
| B18 | Key-window-only broadcasts fire once per hosted workspace: Open SQL File opens a tab in every connection, Export can open two sheets | `MainContentCommandActions.swift:121, 184, 1157` | `isKeyWindow()` becomes `coordinator.isVisible` (window key **and** this workspace selected) |
| B19 | `frontmostHost()` filters on `isVisible` and casts after the fact, so a miniaturized window or a front `main-inspector` window produces a second host for an already-hosted connection | `WindowManager.swift:50-58, 197-200`; `InspectorWindowController.swift:44` | `hosts().first { $0.workspaces.contains(payload.connectionId) } ?? frontmostHost()`, and select hosts on `contentViewController is MainSplitViewController`, not on the `main-` prefix |
| B20 | Row eviction and Handoff run against whichever coordinator `windowDidResignKey` / `refreshUserActivity` picked | `TabWindowController.swift:164-169, 216-248` | Same resolver as B12 |

### P3: silent no-ops

| # | Bug | Location | Fix |
|---|---|---|---|
| B21 | Reopen Closed Tab (Cmd+Shift+T) does nothing whenever the connection has at least one open tab | `RecentlyClosedTabReopener.swift:25-31, 62-82`; `TabRouter.swift:86` | Adopt the reconstructed `QueryTab` into the target `QueryTabManager` directly, then `reveal(connectionId, tabId:)`; delete `openWindowTab` and `RestorationGroupRegistry` |
| B22 | `startActivationConnectIfNeeded` runs only at `viewWillAppear` and `windowDidBecomeKey`, so Reopen Last Session with three connections leaves the middle ones on the Not Connected pane forever | `MainSplitViewController.swift:276`; `+Connection.swift:15-30`; `AppLaunchCoordinator.swift:136-161` | `adoptWorkspace` calls `startActivationConnectIfNeeded(for: workspace.connectionId)`; the phase machine's `allowsActivationConnect` already makes it idempotent |
| B23 | Opening an already-hosted connection raises the window without selecting its workspace, from the connection switcher, welcome list, Dock menu, Handoff and `tablepro://` | `TabRouter.swift:97-110, 236-239, 383-390`; `MainContentCoordinator+WindowLifecycle.swift:104-109` | All of them go through `WorkspaceLocator.reveal` |
| B24 | Show ER Diagram / Users & Roles / Server Dashboard a second time raises an already-front window and never selects the existing tab | `+ERDiagram.swift:19-24`, `+UsersRoles.swift:6-11`, `+ServerDashboard.swift:15-20` | Take the tab id from the match and call `selectTabAndFocusWindow(match.id)` |
| B25 | MCP `focus_query_tab` returns `"focused"` while focusing nothing: it never sets `selectedTabId` and never selects the workspace, and `raised` can never be false | `FocusQueryTabTool.swift:36-53`; `MCPTabSnapshotProvider.swift:41` | `reveal(snapshot.connectionId, tabId: snapshot.tabId)`; derive `raised` from the reveal result |
| B26 | `.sql` file dedupe resolves URL → windowId → NSWindow through a map that is superseded on every workspace mount, so the same file opens a duplicate tab or raises the wrong tab | `WindowLifecycleMonitor.swift:28, 240-259, 53-62`; `TabRouter.swift:353-379`; `+Favorites.swift:42-51, 90-93` | Look the tab up by `content.sourceFileURL` across `workspaces`, then reveal workspace + tab |
| B27 | A failed open for a connection that has a **background** workspace reports nothing: the alert is suppressed and the inline `ConnectionUnavailableView` is only painted for the selected workspace | `LaunchIntentRouter.swift:99-106`; `MainSplitViewController.swift:470-479` | Suppress only when `workspaces.selectedConnectionId == connectionId`; otherwise reveal it first |
| B28 | `openTab` selects the adopted workspace even with `activate: false`, so background opens yank the visible connection away and launch lands on an arbitrary connection | `WindowManager.swift:30-35`; `ConnectionWorkspaceRegistry.swift:47-63` | Thread `select: activate` through `adoptWorkspace` into `insert(_:select:)` |
| B29 | Restored tabs deferred to `windowDidBecomeKey` never load: the gate is `isKeyWindow`, set by a handler dispatched to an arbitrary coordinator | `MainContentView+Setup.swift:239-257`; `+WindowLifecycle.swift:34, 188-194` | Consume the deferred load when the workspace becomes selected |
| B30 | `onMembershipChange` is fired but never assigned, so rail rows appear and disappear only on unrelated events | `ConnectionWorkspaceRegistry.swift:20, 58, 80`; `MainSplitViewController.swift:236` | Wire it to reload the rail and re-run `applyRailVisibility` |
| B31 | The split autosave name is never repointed on switch, so a divider drag while viewing B is persisted under A's key and B's layout never loads | `MainSplitViewController.swift:98-103, 934-946` | One window-level name, `com.TablePro.mainSplit` |
| B32 | `representedURL`, `isDocumentEdited` and the detail pane minimum are not reapplied on switch | `MainSplitViewController.swift:430-439` | `applySelectedWorkspace` pushes all three for the selected workspace's selected tab |
| B33 | A blank persisted `tab.title` renders as an empty strip label, tooltip and accessibility label | `EditorTabStrip.swift:146, 167, 174`; `QueryTabState.swift:95` | Heal at `QueryTab.title` (or at the strip) with the same rules `WindowTitleResolver.sanitizeTitle` applies |

### P4: leaks and orphaned sessions

| # | Bug | Location | Fix |
|---|---|---|---|
| B34 | Closing the window disconnects at most one of its connections; the rest keep drivers, SSH tunnels and 30s health pings until quit | `WindowLifecycleMonitor.swift:289-325` | Window close fans out over `workspaces.connectionIds` |
| B35 | N-1 coordinators never leave the strong static `activeCoordinators`, so they never deinit, keep their driver alive, and keep voting themselves into Reopen Last Session and the unsaved-changes alert | `MainContentCoordinator.swift:293, 305-307, 752`; `SessionRecoveryTracker.swift:16-22`; `AppDelegate.swift:147` | Same fan-out; `teardown()` per workspace |
| B36 | A pending connect for any workspace other than the window's original payload is never cancelled on close | `TabWindowController.swift:198-210` | Iterate `splitVC.workspaces.connectionIds`; drop the racy `hasOpenWindow` guard (the controller is still retained during `willClose`) |
| B37 | `WindowLifecycleMonitor.register` evicts every other connection's entry for the same NSWindow, so only the last-mounted connection is findable | `WindowLifecycleMonitor.swift:45-62`; `MainContentView+Setup.swift:354-358` | Delete the monitor (Step 13) |
| B38 | The object browser keeps the previous connection's `SharedSidebarState` when the selected workspace has no session | `MainSplitViewController.swift:506-511` | `updateSidebarState(workspaces.selected.map { SharedSidebarState.forConnection($0.connectionId) })`, unconditional |

---

## 3. THE REFACTOR, IN ORDERED STEPS

Every step compiles, passes `swiftlint lint --strict`, and leaves the app usable. Run `scripts/generate-project.sh` after any step that adds or deletes a file.

---

### STEP 1: Restore returns one ordered tab list

**Why first:** it is the only defect that destroys user data irreversibly (B1, B2), and it is a subtraction, not a redesign.

**Files touched**
- `TablePro/Views/Main/Extensions/MainContentView+Setup.swift` (86-199, 282-306)
- `TablePro/Core/Services/Infrastructure/TabPersistenceCoordinator.swift` (16-19, 181)

**Changes**
- `handleRestoreOrDefault` drops the `windowIndex` / `openWindowCount` computation (105-106), the `WindowGroupAssignment.resolve` call (132-138) and the `openWindowCount == 1` branch (140-144). It calls `applyRestoredGroup(restoredTabs, selectedTabId: result.selectedTabId, activeDatabase:, activeSchema:, loadTiming: .immediate)` once.
- `RestoreResult` loses `windowGroupIndexByTabId`; `restoreFromDisk` stops calling `normalizedGroupIndices` and returns tabs in file order.

**Deleted**
- `restoreAsOnlyWindow`, `claimOwnTabs`, `openRestoredTabWindow` (`MainContentView+Setup.swift:147-199, 282-306`)
- `TablePro/Core/Services/Infrastructure/WindowGroupAssignment.swift` (whole file)
- `TablePro/Core/Services/Infrastructure/RestoreWindowPlan.swift` (whole file)
- `TablePro/Core/Services/Infrastructure/WindowTabGroupOrder.swift` (whole file, after removing the two `MainContentCoordinator.swift:330-334, 346-348` uses in Step 2; if that ordering is inconvenient, keep the file one step longer)
- `TableProTests/Core/Services/WindowGroupAssignmentTests.swift`, `RestoreWindowPlanTests.swift`, `WindowTabGroupOrderTests.swift`

**Proven by unit tests**
- `TabRestoreMigrationTests.fileWithGroupIndicesRestoresEveryTabInFileOrder`
- `TabRestoreMigrationTests.fileWithoutGroupIndicesRestoresEveryTab`

**Needs the app run:** no.

---

### STEP 2: One connection, one tab list, on the write side too

**Files touched**
- `MainContentCoordinator.swift:313-348, 352-371, 427-455, 542`
- `TabPersistenceCoordinator.swift:44-46, 50-97`
- `TabPersistenceCoordinator+AggregatedSave.swift:15-50`
- `QueryTabState.swift:42, 110`; `QueryTab.swift:170, 205`

**Changes**
- `aggregatedTabs(for:)` becomes `coordinator.tabManager.tabs.map(enrichedForPersistence)`. **`enrichedForPersistence` (352-371) survives verbatim**: it is the only place restored sort column names and the selected tab's caret offset are resolved.
- `saveNow(windowedTabs:)` / `saveNowSync(windowedTabs:)` collapse into the existing `saveNow(tabs:selectedTabId:)` / `saveNowSync(tabs:selectedTabId:)` signatures; the tuple overloads go.
- `hasObservedTabs` is set **only** by `restoreFromDisk` (`:163`) and by the revived `markObservedTabs()` (`:44-46`). It is no longer self-armed by a non-empty save at `:63` and `:85`. Every save path guards on it. This is the write-side half of B3.
- `saveOrClearAggregatedSync`'s clear branch is deleted; the save branch stays and is called per workspace by Step 5. Consent lives only in `closeTabsByUser` (`+TabClosing.swift:16-24`).

**Deleted**
- `windowGroupIndex` on `QueryTab` and `PersistedTab` (extra keys in old JSON decode away harmlessly; nothing needs a version bump)
- `tabGroupPosition`, the `groupOrder` dictionary, `isFirstCoordinatorForConnection` (`:444-449, 451-455`), `WindowTabGroupOrder`
- `TabPersistenceCoordinatorTests.windowGroupIndexRoundTrip` (383-399); `PersistedTabRoundTripTests` 172-198

**Proven by unit tests**
- `TabPersistenceWriteGateTests.saveIsRefusedBeforeRestoreCompletes` (B3)
- `TabPersistenceCoordinatorTests` rewritten to the single-list signature
- `TabPersistenceClearGuardTests` unchanged and must stay green

**Needs the app run:** no.

---

### STEP 3: `WorkspaceLocator`, the one resolver

**New file:** `TablePro/Core/Services/Infrastructure/WorkspaceLocator.swift`

```
@MainActor internal enum WorkspaceLocator {
    static func host(for connectionId: UUID) -> MainSplitViewController?
    static func workspace(for connectionId: UUID) -> ConnectionWorkspace?
    static func coordinator(for connectionId: UUID) -> MainContentCoordinator?
    static func selectedCoordinator(in window: NSWindow) -> MainContentCoordinator?
    @discardableResult static func reveal(_ connectionId: UUID, tabId: UUID? = nil) -> Bool
}
```

`reveal` is the whole point: select the workspace in its host registry, call `applySelectedWorkspace()`, set `tabManager.selectedTabId` when a tab is named, then `makeKeyAndOrderFront` + `NSApp.activate`. It returns false when no host owns the connection, which is what MCP and `LaunchIntentRouter` need to branch on.

Add `MainSplitViewController.selectedCoordinator` (`workspaces.selected?.sessionState?.coordinator`) next to the existing `commandActions` (`:519`).

**Purely additive.** Nothing is rewired yet.

**Proven by unit tests:** `WorkspaceLocatorTests` against a `ConnectionWorkspaceRegistry` fixture: selection ordering, missing connection, tab id ignored when absent.

**Needs the app run:** no.

---

### STEP 4: Every window-keyed resolver routes through the locator

**Files touched:** `TabWindowController.swift:13, 22, 34, 141, 164, 191, 216`; `MainMenuBuilder.swift:65-67`; `WorkspaceRailViewController.swift:319, 375`; `MainContentCoordinator+Favorites.swift:43`; `TabRouter.swift:97-110, 228-243, 383-390`; `+ERDiagram.swift:19`, `+UsersRoles.swift:6`, `+ServerDashboard.swift:15`; `+WindowLifecycle.swift:104-109`; `LaunchIntentRouter.swift:99-106`; `WelcomeViewModel+Sample.swift:128-133`; `MainEditorContentView.swift:376`; `MainSplitViewController+Connection.swift:32-35`.

**Changes:** B9, B11, B12, B13, B15, B16, B20, B23, B24, B27 all land here. `retryConnection()` gains a `connectionId` parameter. `selectTabAndFocusWindow` becomes `reveal(connectionId, tabId:)`.

**Deleted**
- `MainContentCoordinator.coordinator(forWindow:)` (`+Registry.swift:18-20`)
- `MainContentCoordinator.coordinator(for windowId:)` (`+Registry.swift:14-16`, zero callers even today)

**Proven by unit tests:** `WindowCommandRoutingTests.selectedWorkspaceOwnsWindowCommands` (two workspaces in one registry, assert the resolved coordinator follows `select()`).

**Needs the app run:** yes, for B24 and B23 (tab focus is visual). Manual pass: two connections open, Cmd+W closes a tab in the visible one; connection switcher on a background connection switches the pane; Show ER Diagram twice selects the existing tab.

---

### STEP 5: Window close fans out over workspaces

**Files touched:** `TabWindowController.swift:191, 198-210`; new `MainSplitViewController.handleWindowWillClose()`; `MainContentCoordinator+WindowLifecycle.swift:68-88`; `WindowLifecycleMonitor.swift:289-325`.

**Changes**
- `MainSplitViewController.handleWindowWillClose()` iterates `workspaces.workspaces` and per workspace: cancel any in-flight attempt (`invalidateConnectionAttempt` + `cancelEnsureConnected`), `coordinator.handleWindowWillClose()` (save + teardown), then `disconnectSession` when no other host holds the connection.
- `TabWindowController.windowWillClose` calls `markWindowClosing()` then `handleWindowWillClose()` and nothing else. `cancelPendingConnectionIfNeeded` is folded into the fan-out and its `payload.connectionId` scoping and racy `hasOpenWindow` guard are gone.
- `WindowLifecycleMonitor.handleWindowClose` stops disconnecting (its remaining bookkeeping dies in Step 13).

**Fixes:** B4, B34, B35, B36.

**Proven by unit tests:** `WindowCloseFanOutTests.everyWorkspaceIsPersistedAndTornDown`, `.everyPendingAttemptIsCancelled` (fake coordinators recording calls).

**Needs the app run:** yes. Open three connections, edit a tab in each, close the window, relaunch, confirm all three restore.

---

### STEP 6: Adoption dials, and background opens do not steal the pane

**Files touched:** `MainSplitViewController.swift:133-186`; `MainSplitViewController+Connection.swift:15-30`; `WindowManager.swift:25-46`; `ConnectionWorkspaceRegistry.swift:47-63`; `AppLaunchCoordinator.swift:136-161`.

**Changes:** `adoptWorkspace(payload:autoConnect:select:)` threads `select` into `insert(_:select:)` and ends with `startActivationConnectIfNeeded(for: workspace.connectionId)`. `openTab` resolves the host by membership first (B19) and only selects when `activate` is true (B28). `LastOpenConnections` gains a recorded selected connection so Reopen Last Session lands where the user left off.

**Fixes:** B19, B22, B28.

**Proven by unit tests:** `WorkspaceAdoptionTests.backgroundAdoptionDoesNotChangeSelection`; `WindowManagerHostResolutionTests.hostIsTheWindowThatAlreadyHostsTheConnection`.

**Needs the app run:** yes. Reopen Last Session with four connections: all four dial, the last-selected one is showing.

---

### STEP 7 (riskiest): the workspace owns its bootstrap, and the detail pane gets an identity

Deliberately placed after Steps 1 to 6, because those steps installed the resolver, the fan-out and the persistence gate that make this safe to move.

**Files touched:** `ConnectionWorkspace.swift`; `MainSplitViewController.swift:393-412 (adoptSession), 505-514, 587-620`; `MainContentView.swift:54-61, 341-352`; `MainContentView+Setup.swift:15-84`; new `TablePro/Core/Services/Infrastructure/WorkspaceBootstrap.swift`.

**Changes**
- `ConnectionWorkspace` gains `private(set) var hasBootstrapped: Bool`. `bootstrapIfNeeded()` runs once per workspace: restore saved tabs from disk (always, whatever the payload intent), then apply the payload's own tab. That single rule kills the `.openContent`-never-restores divergence behind B3 and makes `.restoreOrDefault` a workspace concept rather than a payload the tab opener has to understand.
- `ConnectionWorkspace.open(_:)` intercepts `.restoreOrDefault` (bootstrap, do not add a tab) and forwards only `.openContent` / `.newEmptyTab` to `EditorTabOpener`.
- The bootstrap is triggered from `adoptSession(_:into:)` and from `viewDidLoad` for a pre-created session state, never from a SwiftUI `.task`.
- `initializeAndRestoreTabs` moves out of `MainContentView+Setup.swift` into `WorkspaceBootstrap`. `MainContentView` loses `hasInitialized` and the bare `.task`.
- `buildDetailView()` returns `MainContentView(...).id(currentSession.connection.id)`.

**Fixes:** B3 (behavioural half), B5, B6.

**Behaviour change to record in CHANGELOG:** opening a table on a connection that is not yet open now brings back that connection's saved tabs alongside it, instead of starting from one tab.

**Proven by unit tests:** `WorkspaceBootstrapTests.bootstrapRunsOncePerWorkspace`, `.openContentPayloadStillRestoresSavedTabs`, `.secondBootstrapDoesNotOverwriteLiveTabs`.

**Needs the app run:** yes, and this is the step to test hardest. Switch back and forth between two connections ten times with unsaved query text in each; confirm no tab list is replaced and no edit is attributed to the wrong connection.

---

### STEP 8: Visibility replaces key-window

**Files touched:** `MainContentCoordinator.swift` (`isKeyWindow` property); `+WindowLifecycle.swift:25-62, 188-194`; `MainContentCommandActions.swift:121, 184, 1157`; `MainSplitViewController.swift:430-439`.

**Changes:** rename `MainContentCoordinator.isKeyWindow` to `isVisible`, defined as *the hosting window is key **and** this workspace is the registry's selected one*. `applySelectedWorkspace` sets it on the incoming workspace and clears it on the outgoing one. `consumeDeferredRestoreLoadIfNeeded` (B29), the 5s row eviction, and `observeKeyWindowOnly` (B18) all read it.

**Proven by unit tests:** `WorkspaceVisibilityTests.deferredRestoreLoadFiresOnSelection`; `WorkspaceVisibilityTests.onlyTheSelectedWorkspaceObservesKeyWindowBroadcasts`.

**Needs the app run:** yes for the eviction timing and Open SQL File.

---

### STEP 9: Per-workspace undo

**Files touched:** `MainContentCoordinator.swift:520`; `MainContentCommandActions.swift:1050, 1062`; `+UndoState.swift:14`; `MainSplitViewController.swift:133-186` (wire `workspace.undoManager` onto the coordinator when the session state is attached).

**Fixes:** B7. **Proven by:** `WorkspaceUndoTests.undoTargetsTheWorkspaceThatRegisteredIt`. **Needs the app run:** yes, for the Edit menu titles.

---

### STEP 10: Toolbar and window chrome follow the selected workspace

**Files touched:** `MainSplitViewController.swift:98-103, 336-347, 430-439, 934-946`; `MainWindowToolbar+Delegate.swift:19-141`; `MainWindowToolbar+Validation.swift:59`.

**Changes:** introduce a per-window `ToolbarContext` observable box; every SwiftUI toolbar item view reads `context.coordinator` instead of capturing a coordinator by value. `installToolbar` swaps the box. `applySelectedWorkspace` additionally pushes `representedURL`, `isDocumentEdited`, `updateDetailMinimumThickness(for:)` and, one time only, sets `splitView.autosaveName = "com.TablePro.mainSplit"`.

**Fixes:** B14, B31, B32. Do **not** tear down and reinstall `NSToolbar` on every switch: that flickers and drops item state.

**Proven by:** unit test on `ToolbarContext` swap semantics only. The visible behaviour needs the app run: switch connections and watch the toolbar name, database, status badge and spinner follow.

---

### STEP 11: The rail reads its host

**Files touched:** `WorkspaceRailViewController.swift:28, 181, 188, 256-305, 353, 375`; `WorkspaceRailStore.swift:37-38, 120-130, 140, 145`; `MainSplitViewController.swift:201, 236, 296, 304, 724`; `NavigationSidebarViewController.swift:27`.

**Changes:** drop the frozen `connectionId`; entries and the selected row come from the hosting registry; `onMembershipChange` is wired and drives both the rail reload and `applyRailVisibility(workspaceCount: workspaces.count)`.

**Fixes:** B17, B30, and the app-global entry count. **Proven by:** `WorkspaceRailStoreTests` extended with a per-host fixture. **Needs the app run:** yes, for the highlight snap-back.

---

### STEP 12: Reopen Closed Tab adopts directly

**Files touched:** `RecentlyClosedTabReopener.swift:20-83`; `TabRouter.swift:86`.

**Changes:** one path for every case: reconstruct the `QueryTab`, adopt it into the target connection's `QueryTabManager` (creating the workspace through `LaunchIntentRouter` only when the connection is not open at all), then `WorkspaceLocator.reveal(connectionId, tabId:)`.

**Deleted:** `openWindowTab`, `emptyWindowCoordinator`, `TablePro/Core/Services/Infrastructure/RestorationGroupRegistry.swift`, `MultiWindowRestorationTests.swift:19-51`.

**Fixes:** B21. **Proven by:** `RecentlyClosedTabReopenerTests.reopenLandsInAConnectionThatAlreadyHasTabs`. **Needs the app run:** yes, once.

---

### STEP 13: Delete `WindowLifecycleMonitor`

Every reader has been migrated by now. Source-file dedupe becomes a tab lookup, which is the correct key and needs no separate store: the tabs already carry `content.sourceFileURL`.

**Files touched:** `TabRouter.swift:354, 384`; `MainContentCoordinator+Favorites.swift:42-51, 90-93`; `MainContentCommandActions.swift:525`; `WorkspaceRailStore.swift:38`; `OperationConfirming.swift:17`; `MainContentCoordinator+Registry.swift:66-79`; `MainContentView+Setup.swift:71-73, 344-358`; `MCPTabSnapshotProvider.swift:39`.

**New:** `OpenTabLocator.locate(sourceFileURL:) -> (connectionId: UUID, tabId: UUID)?`, scanning hosts' workspaces.

**Deleted:** `TablePro/Core/Services/Infrastructure/WindowLifecycleMonitor.swift` (whole file), `MainContentCoordinator.windowId` (`:109`), `MainEditorContentView.windowId` (`:30`), `MainContentView.@State windowId` (`:58`), `WindowLifecycleMonitorTests.swift`, `WindowLifecycleMonitorRegistrationTests.swift`, `SQLFileDeduplicationTests.swift:196-265`.

**Fixes:** B26, B37. **Proven by:** `OpenTabLocatorTests.findsTheTabHoldingASourceFile`, `.returnsNilWhenNoWorkspaceHoldsIt`. **Needs the app run:** yes. Open the same `.sql` file from Finder twice.

---

### STEP 14: Delete the window-close command family

**Files touched:** `MainContentCommandActions.swift:406-431, 436-661`; `MainContentCommandActions+BulkClose.swift:79-85`; `MainContentCoordinator.swift:198-200`; `+FKNavigation.swift:83`.

**Deleted:** `closeWindowAwaiting(asBatchSurvivor:)`, `finish`, `clearTabsInPlace`, `saveAndClose`, `discardAndClose`, `selectInTabGroup`, `captureClosingTabsForRecovery`, `WindowCloseOutcome`, the `asBatchSurvivor` parameter, `CommandActionsBulkCloseTests.survivorClearsTabsInPlace` (56-70).

`closeTab()`'s no-coordinator branch becomes `WindowManager.shared.closeWindow(for: connectionId)` (B10). `openTabInNewWindow` is renamed `openTab` (and its `FKNavigationTests` stub with it, in the same commit per the atomic-API-change rule).

**Proven by:** `CommandActionsCloseTests.closingTheLastTabLeavesSiblingWorkspacesAlone`. **Needs the app run:** yes for Cmd+W on a failed pane.

---

### STEP 15: MCP wire contract

**Files touched:** `OpenConnectionWindowTool.swift`, `OpenTableTabTool.swift`, `FocusQueryTabTool.swift`, `ListRecentTabsTool.swift`, `MCPTabSnapshotProvider.swift`.

Rename `open_connection_window` to `open_connection`; every tool returns `connection_id` and `tab_id`; `window_id` is dropped from results and descriptions. Update `docs/` and add a CHANGELOG entry under `Changed` (it is a breaking wire change for agent integrations).

**Proven by:** existing MCP tool tests updated. **Needs the app run:** no, but a live MCP smoke test is cheap.

---

### STEP 16: Vocabulary, invariants, docs

Rename `ConnectionWindowPhase` → `ConnectionWorkspacePhase`, `ConnectionWindowPhaseMachine.onWindowClosing` → `onWorkspaceClosing`, `ConnectionWindowPaneResolver` → `ConnectionWorkspacePaneResolver`, `WindowSidebarState` → `WorkspaceSidebarState`, `forceNewWindowTab` → `forceNewTab`, `TableLoadTracer.noteWindowTabHandoff` → `noteTabHandoff`, the `handoffToNewWindowTab` log string. Cosmetic, mechanical, one commit, no behaviour change. Then the CLAUDE.md edits in section 5, the `docs/` updates, and the CHANGELOG.

---

## 4. DELETIONS

Each is dead after the step named; the proof is the last remaining caller and where it goes.

| Type / file | Dead after | Proof |
|---|---|---|
| `WindowGroupAssignment.swift` | Step 1 | Sole call site `MainContentView+Setup.swift:132`; `normalizedGroupIndices`' only consumer is `TabPersistenceCoordinator.swift:181`, deleted in the same step |
| `RestoreWindowPlan.swift` | Step 1 | Sole call site `MainContentView+Setup.swift:150` |
| `WindowTabGroupOrder.swift` | Step 2 | Two call sites: `MainContentView+Setup.swift:105-106` (Step 1) and `MainContentCoordinator.swift:330-334, 346-348` (Step 2) |
| `RestoreResult.windowGroupIndexByTabId` | Step 1 | Read only at `MainContentView+Setup.swift:136` |
| `QueryTab.windowGroupIndex` / `PersistedTab.windowGroupIndex` | Step 2 | Written at `MainContentCoordinator.swift:319-348`, read only through `windowGroupIndexByTabId`, already gone. `decodeIfPresent`, so old files decode; unknown keys in new files are ignored |
| `saveNow(windowedTabs:)` / `saveNowSync(windowedTabs:)` | Step 2 | The tuple overloads' only remaining caller is the aggregated save, converted in the same step |
| `isFirstCoordinatorForConnection`, `tabGroupPosition` | Step 2 | Gate `scheduleDraftSave` (`:427`), `startPeriodicSave` (`:438`) and the willTerminate save (`:542`); trivially true with one coordinator per connection |
| `saveOrClearAggregatedSync`'s clear branch | Step 2 | Real consent is `closeTabsByUser` (`+TabClosing.swift:22-23`) |
| `MainContentCoordinator.coordinator(forWindow:)` | Step 4 | Nine call sites, all listed in B12/B15/B16/B20, all moved to `WorkspaceLocator` |
| `MainContentCoordinator.coordinator(for windowId:)` | Step 4 | Zero callers today (`+Registry.swift:14-16`) |
| `MainSplitViewController.transition(to:)` (the unqualified one, `:463-468`) | Step 4 | Superseded by `transition(to:for:)`; every caller names a connection |
| `RestorationGroupRegistry.swift` | Step 12 | Producers `MainContentView+Setup.swift:301` (deleted Step 1) and `RecentlyClosedTabReopener.swift:77` (deleted Step 12); consumer `MainContentView+Setup.swift:87` (deleted Step 7) |
| `EditorTabPayload` `Codable`, `CodingKeys`, legacy `isNewTab` decoding (`:23, 57-64, 102-145`) | Step 12 | No production encode or decode; only `TableProTests/Models/EditorTabPayloadTests.swift:74, 100`. The payload is passed by reference through `TabWindowController` / `MainSplitViewController` / `ConnectionWorkspace` |
| `WindowLifecycleMonitor.swift` (whole file) | Step 13 | Readers: `WorkspaceRailStore.swift:38` (Step 11), `TabRouter.swift:97, 354, 384` (Steps 4, 13), `WorkspaceRailViewController.swift:271, 375` (Steps 4, 11), `OperationConfirming.swift:17` (Step 13), `MainContentCoordinator+Registry.swift:77` (Step 13), `WelcomeViewModel+Sample.swift:130` (Step 4), `MainContentView+Setup.swift:71-73, 354` (Steps 7, 13). Its `lastFocusedWindowIds` / `resolveWindowId` / `mostRecentWindow` / `activeWindow(for:preferring:)` / `unregisterWindow(for:)` were already dead or single-caller |
| `MainContentCoordinator.windowId`, `MainEditorContentView.windowId`, `MainContentView.@State windowId` | Step 13 | Readers listed in the map: `coordinator(for windowId:)` (none), `registerWindowForSourceFile`, `selectTabAndFocusWindow`, `TabRouter.focusExistingQueryTab`, `MCPTabSnapshotProvider` |
| `closeWindowAwaiting`, `finish`, `clearTabsInPlace`, `saveAndClose`, `discardAndClose`, `selectInTabGroup`, `captureClosingTabsForRecovery`, `WindowCloseOutcome`, `asBatchSurvivor` | Step 14 | Single caller chain rooted at `MainContentCommandActions.swift:423`, plus one test |
| `WindowManager.findSibling` + the `addTabbedWindow` branch (`:93-115, 207-214`) | Step 6 | `openInNewWindow` only runs when no host exists; `findSibling` searches for exactly such a host. `mainTabbingIdentifier` (`:205`) **stays**: it is what makes user-driven Merge All Windows work |
| Test files | per step | `WindowGroupAssignmentTests`, `RestoreWindowPlanTests`, `WindowTabGroupOrderTests`, `MultiWindowRestorationTests:19-51`, `WorkspaceWindowScopeTests` (untracked, both cases unsatisfiable), `WindowLifecycleMonitorTests`, `WindowLifecycleMonitorRegistrationTests:47-66`, `CommandActionsBulkCloseTests:56-70`, `SQLFileDeduplicationTests:196-265` |

`MultiWindowRestorationTests.swift` is split before deletion: `resolveRestoredSortColumns` (53-76) moves to `RestoredSortColumnTests.swift`, the `LastOpenConnectionsStorage` round-trips (78-108) to `LastOpenConnectionsStorageTests.swift`.

---

## 5. CLAUDE.md INVARIANT EDITS

### 5.1 Tab replacement guard (line 176)

**Old:** "`openTableTab` checks for active work (unsaved edits, applied filters, sorting) before replacing the current tab. Tabs with active work open a new native window tab instead. This check runs before the preview tab branch."

**New:** "`openTableTab` checks for active work (unsaved edits, applied filters, sorting) before replacing the current tab. A tab with active work is left alone and the table opens as a new editor tab in the same window's strip. This check runs before the preview tab branch."

### 5.2 Window tab titles (line 178)

Keep the whole paragraph, which is still correct about the app window's titlebar, and append:

**New paragraph:** "Editor tabs are not windows, so there are two labels with two owners. The window titlebar goes through `WindowTitleResolver` and the guarded `windowTitle` sink. The editor tab label is `Text(tab.title)` in `EditorTabStrip`, with no resolver between it and the string, so the blank-title healing and the `.table` name recomputation must be applied at `QueryTab.title` itself. `PersistedTab`'s decoder defaults a missing or null title but not an empty string. Mutating `tab.title` plus `QueryTabManager.markTabRenamed(_:)` still drives both labels."

### 5.3 Cancelling a connect does not stop the driver (line 186)

The driver half is untouched. Replace the second half's scope words:

**Old:** "...the attempt is fenced by a per-window `attemptToken` plus `DatabaseManager.invalidateConnectionAttempt` so a late failure cannot write into a window that moved on."

**New:** "...the attempt is fenced by a per-workspace `attemptToken` (`ConnectionWorkspace.attemptToken`) plus `DatabaseManager.invalidateConnectionAttempt`, so a late failure cannot write into a workspace that moved on. The window did not move on; one of the connections it hosts did, which is why the token cannot live on the window."

**Old:** "...that distinction is `ConnectionWindowPhaseMachine.retainsRestoreIntent`..."

**New:** "...that distinction is `ConnectionWorkspacePhaseMachine.retainsRestoreIntent`, read per workspace through `ConnectionWorkspace.retainsRestoreIntent` and aggregated per window by `MainSplitViewController.connectionIdsRetainingRestoreIntent`. Closing a window has to cancel the in-flight attempt of **every** workspace it hosts, not just the one its original payload named."

### 5.4 A connection window's content is a function of its own `ConnectionWindowPhase` (line 188)

**Old title and first sentence:** "**A connection window's content is a function of its own `ConnectionWindowPhase`, never of `activeSessions` membership**..."

**New:** "**A workspace's content is a function of its own `ConnectionWorkspacePhase`, never of `activeSessions` membership**: the global session dictionary can only say *present* or *absent*, and that vocabulary cannot tell "never started" from "connecting" from "failed" from "the user cancelled" from "the window is closing"."

**Old:** "`MainSplitViewController` owns a `phase`, `ConnectionWindowPhaseMachine` owns the transitions..."

**New:** "`ConnectionWorkspace` owns the `phase`, one per hosted connection. `ConnectionWorkspacePhaseMachine` owns the transitions (pure, exhaustive, `.closing` absorbing) and `ConnectionWorkspacePaneResolver` owns the pane choice (pure). `MainSplitViewController` renders the selected workspace's phase and routes a transition by `connectionId`; it is only an adapter and its `phase` property is a pass-through to `workspaces.selected`."

**Old (last sentence):** "Only one presenter per failure: `LaunchIntentRouter.presentError` stays silent when a window for that connection exists."

**New:** "Only one presenter per failure: `LaunchIntentRouter.presentError` stays silent only when that connection is the **selected** workspace, because the inline pane is painted for the selected workspace alone. A window existing says nothing about whether this connection has a pane on screen."

### 5.5 An emptied tab manager is not the same as "the user closed every tab" (line 192)

**Old:** "`saveOrClearAggregatedSync()` is the one persistence path where an empty aggregate means *clear*, so it deletes the connection's saved tabs from disk. A coordinator torn down by a lost session has already emptied `tabManager.tabs`, so letting the window-close path run afterwards wipes tabs the user never closed. `handleWindowWillClose` guards on `isTearingDown` for that reason."

**New:** "Deleting a connection's saved tabs is a statement about user intent, so exactly one path may make it: `MainContentCoordinator.closeTabsByUser`, which clears the moment the connection's own tab list empties through a user-driven close (tab strip X, Cmd+W, Close Other/All Tabs, Close Tabs for Other Databases, close workspace from the rail). Closing a tab never closes the window and closing the window never clears: window close **saves** every workspace it hosts, one save per `ConnectionWorkspace`, and its persistence guards stay in place as the second line of defence. A coordinator torn down by a lost session has already emptied `tabManager.tabs`, which is why `hasObservedTabs` is set only by a completed restore and every save path refuses to write before then, and why `handleWindowWillClose` guards on `isTearingDown`. Both halves of this rule have shipped as bugs: letting window close clear wiped tabs the user never closed, and later, when tab close stopped closing the window, nothing reached the clear at all and closed tabs came back on reconnect."

### 5.6 Window Close (Cmd+W) section (line 212)

**Old:** "`EditorWindow` (NSWindow subclass in `TabWindowController.swift`) overrides `performClose:` to route Cmd+W through `closeTab()`. SwiftUI's `.commands { ... }` does NOT replace AppKit's built-in "File > Close"..."

**New:** "`EditorWindow` (NSWindow subclass in `TabWindowController.swift`) overrides `performClose:` to route Cmd+W through the **selected workspace's** `closeTab()`, resolved as `(window.contentViewController as? MainSplitViewController)?.workspaces.selected?.sessionState?.coordinator`, never by matching `contentWindow` (every hosted coordinator matches the same window). Cmd+W closes the front editor tab; with no tabs left it closes the workspace; the window itself closes only when the last workspace goes. SwiftUI's `.commands { ... }` does NOT replace AppKit's built-in "File > Close"..."

### 5.7 Two new invariants to add

**Add after 5.4:**

"**The workspace, not the window, is the unit of identity**: one window hosts N connections, so any lookup keyed by `NSWindow` or by a per-view `windowId` can only ever name one of them, and `Dictionary.values.first` over a matching predicate picks arbitrarily. Every resolution goes through `WorkspaceLocator` (`connectionId` in, workspace / coordinator / host out) and every "show this to the user" goes through `WorkspaceLocator.reveal(connectionId:tabId:)`, which selects the workspace, selects the tab and *then* raises the window. `makeKeyAndOrderFront` on its own is not focus any more: the window is usually already front and showing a different connection, so the command reads as doing nothing. This shipped as Cmd+W closing a background connection's tab, the connection switcher appearing dead, and MCP `focus_query_tab` reporting success while focusing nothing."

"**A window-level event is N workspace events**: `windowWillClose` must save, tear down, cancel the in-flight connect for, and disconnect **every** workspace in `MainSplitViewController.workspaces`, not the one an ambiguous lookup returned. `markWindowClosing` already does this correctly and is the reference shape. Dispatching a window callback to a single coordinator loses the other connections' tab edits since the last periodic save (up to 30s), leaks their coordinators in the strong static `activeCoordinators` map so they never deinit, and leaves their drivers, tunnels and health monitors running until quit."

---

## 6. TEST PLAN

### Unit tests, one per already-found bug

| Test | Suite (new or existing) | Guards |
|---|---|---|
| `fileWithGroupIndicesRestoresEveryTabInFileOrder` | `TabRestoreMigrationTests` | B1 |
| `fileWithoutGroupIndicesRestoresEveryTab` | `TabRestoreMigrationTests` | B2 |
| `saveIsRefusedBeforeRestoreCompletes` | `TabPersistenceWriteGateTests` | B3 |
| `overflowSidecarsSurviveAPartialSaveAttempt` | `TabPersistenceWriteGateTests` | B3 |
| `everyWorkspaceIsPersistedAndTornDown` | `WindowCloseFanOutTests` | B4, B35 |
| `everyPendingAttemptIsCancelled` | `WindowCloseFanOutTests` | B36 |
| `everyHostedSessionIsDisconnected` | `WindowCloseFanOutTests` | B34 |
| `bootstrapRunsOncePerWorkspace` | `WorkspaceBootstrapTests` | B5 |
| `secondBootstrapDoesNotOverwriteLiveTabs` | `WorkspaceBootstrapTests` | B5 |
| `openContentPayloadStillRestoresSavedTabs` | `WorkspaceBootstrapTests` | B3 |
| `undoTargetsTheWorkspaceThatRegisteredIt` | `WorkspaceUndoTests` | B7 |
| `unsavedWorkIsCheckedAcrossEveryWorkspace` | `WindowCloseFanOutTests` | B8 |
| `selectedWorkspaceOwnsWindowCommands` | `WindowCommandRoutingTests` | B12 |
| `retryTargetsTheRequestedConnection` | `WorkspaceConnectRoutingTests` | B13 |
| `adoptionStartsTheConnectForItsOwnWorkspace` | `WorkspaceAdoptionTests` | B22 |
| `backgroundAdoptionDoesNotChangeSelection` | `WorkspaceAdoptionTests` | B28 |
| `hostIsTheWindowThatAlreadyHostsTheConnection` | `WindowManagerHostResolutionTests` | B19 |
| `revealSelectsWorkspaceThenTabThenRaises` | `WorkspaceLocatorTests` | B23, B24, B25 |
| `revealReturnsFalseWhenNoHostOwnsTheConnection` | `WorkspaceLocatorTests` | B25, B27 |
| `reopenLandsInAConnectionThatAlreadyHasTabs` | `RecentlyClosedTabReopenerTests` | B21 |
| `deferredRestoreLoadFiresOnSelection` | `WorkspaceVisibilityTests` | B29 |
| `onlyTheSelectedWorkspaceObservesKeyWindowBroadcasts` | `WorkspaceVisibilityTests` | B18 |
| `findsTheTabHoldingASourceFile` | `OpenTabLocatorTests` | B26 |
| `membershipChangeReloadsTheRail` | `WorkspaceRailStoreTests` | B30 |
| `railSelectionFollowsTheHostRegistry` | `WorkspaceRailStoreTests` | B17 |
| `closingTheLastTabLeavesSiblingWorkspacesAlone` | `CommandActionsCloseTests` | B10, and bug #1 from the brief, which has never had a test |
| `closingEveryTabByUserClearsSavedState` | `CommandActionsCloseTests` | bug #3 from the brief: close through `closeTabsByUser`, then assert `restoreFromDisk()` returns `.none` |
| `payloadForAnOpenConnectionOpensItsTab` | `EditorTabOpenerTests` (exists as `tableOpensIntoPopulatedList`) | bug #2 from the brief, already covered, keep |
| `blankTitleRendersANonEmptyStripLabel` | `EditorTabStripLayoutTests` | B33 |

### Tests to rewrite rather than delete

- `WindowGroupAssignmentTests.legacyFileKeepsOneTabPerWindow` (161-170) becomes `TabRestoreMigrationTests.fileWithoutGroupIndicesRestoresEveryTab`, asserting one list.
- `CommandActionsBulkCloseTests` 74-122: one coordinator holding tabs in two databases, not two coordinators. `canCloseTabsForOtherDatabasesWhenSiblingIsForeign` is currently red and must go.
- `WindowLifecycleMonitorTests`: delete with the type; the pure `resolveWindowId` cases (345-388) have no home left.
- `RecoveryConnectionListTests` 60-94, `TabScopeIsWindowIndependentTests` 5-8, `WorkspaceRailStoreTests` wording: rename tests and doc comments, leave every assertion. `TabScopeIsWindowIndependentTests`' property matters more now, not less: a tab's scope being a pure function of the tab and its connection is what lets one strip hold tabs across several databases.

### Tests to keep untouched

`WindowTabGroupingTests`, `ConnectionWindowIdentityTests`, `WindowOpenerTests`, `ConnectionWindowPhaseMachineTests`, `ConnectionWindowPaneResolverTests`, `SessionStateFactoryTests`, `ConnectionWorkspaceRegistryTests`, `EditorTabOpenerTests`, `QueryTabManagerCloseTests`, `EditorTabStripLayoutTests`, `TabPersistenceClearGuardTests`, `QueryTabManagerAdoptTabTests`.

### UI automation (`TableProUITests`)

Four flows that unit tests cannot reach, all deterministic against two SQLite connections:

1. `testSwitchingWorkspacesKeepsEachTabList`: two connections with distinct tabs, switch five times, assert both strips are intact and the toolbar name follows.
2. `testCmdWClosesTheVisibleConnectionsTab`: two connections, Cmd+W, assert the background strip is unchanged.
3. `testWindowCloseRestoresEveryConnectionsTabs`: three connections with tabs, close, relaunch, assert all three restore.
4. `testReopenClosedTabWithOtherTabsOpen`: close one of three tabs, Cmd+Shift+T, assert it returns and is selected.

Toolbar repointing (B14), undo menu titles (B7) and the rail highlight (B17) are visual and are covered by the manual checks in their steps; they are not deterministic enough for automation, and that should be said in the PR description per the mandatory-tests rule.

---

## 7. WHAT NOT TO DO

Traps this specific refactor will walk into. Most are already CLAUDE.md invariants; the rest are landmines this branch created.

1. **Do not delete `enrichedForPersistence`** (`MainContentCoordinator.swift:352-371`) while simplifying `aggregatedTabs`. It looks like part of the aggregation, and it is the only place restored sort column names and the selected query tab's caret offset and length are resolved. Deleting it silently strips sort columns and the caret from every restored tab.

2. **Do not delete `normalizedGroupIndices` without deleting its read in the same commit.** Its no-index branch turns tab *i* into group *i*, so leaving it while removing the fan-out, or removing the field while leaving it, both keep one tab and drop the rest. Removal is atomic: field, function, `windowGroupIndexByTabId`, `resolve`, fan-out, all in Step 1 and 2.

3. **Do not add a "clear saved tabs" call anywhere new.** Empty is not consent. The automatic paths already refuse an empty aggregate (`TabPersistenceCoordinator.swift:58-62, 80-84`; `+AggregatedSave.swift:15-16, 27-28`) and that is correct. Exactly one path may clear: `closeTabsByUser`.

4. **Do not make a refresh clear the cache it is refreshing.** Bootstrap-on-select must fetch first and commit over the old value. Writing `tabManager.tabs = restored` before checking whether the workspace already has live tabs is the same shape as the `SchemaService.runLoad` bug (#1916).

5. **Do not reintroduce a SwiftUI `App`.** The app runs the AppKit lifecycle; `MainMenuBuilder.install` runs in `applicationWillFinishLaunching`. Any attempt to express the workspace switch through a SwiftUI scene wipes `NSApp.mainMenu` half a second after launch, which is #2057 and had to be reverted as #2071.

6. **Do not give any split pane a `holdingPriority` at or above 490**, and do not drop `sizingOptions = []` from `detailHosting` / `inspectorHosting` while reworking `rebuildPanes`. Both dead-divider bugs (#1872) live exactly in the code this refactor edits.

7. **Do not swap `ResizeCursorSplitViewController` back to a plain `NSSplitViewController`** while touching the pane construction. The stock cursor does not fire under an `NSHostingController` (#1905).

8. **Do not write `window.title` or `NSApp.keyWindow?.title` directly** when making the title follow the workspace. The `windowTitle` `didSet` (`MainSplitViewController.swift:66-72`) is the single guarded sink and it is the only thing keeping a blank restored title off the titlebar.

9. **Do not version the split autosave key.** `com.TablePro.mainSplit` already exists as the fallback. Moving to it is the correct semantic (one window cannot have per-connection widths); appending a suffix to force a relayout throws away every user's sidebar and inspector geometry and orphans keys in `UserDefaults`.

10. **Do not assume `Task.cancel()` stopped a connect.** Every workspace that adopts a driver still validates its `ConnectionAttemptRegistry` generation, and a cancelled connect still drops the connection from `LastOpenConnections` while a merely *failed* one keeps its place. Collapsing `retainsRestoreIntent` and `isActivated` back into one flag makes one launch against a stopped server erase the session permanently. This area has shipped the same bug four times.

11. **Do not switch `MainContentView` to `ForEach($bindable.array)` anywhere** while restructuring the strip or the tab list. Index-based bindings crash out of bounds when the array shrinks during SwiftUI evaluation.

12. **Do not remove a published `TableProPluginKit` requirement** if the vocabulary rename brushes against it. Nothing in this refactor should touch `Plugins/TableProPluginKit/`, and if a rename tempts you across that line, run `scripts/check-pluginkit-abi.sh` first.

13. **Do not leave a rename split across commits.** `retryConnection(for:)`, `openTabInNewWindow` → `openTab`, `isKeyWindow` → `isVisible`, `ConnectionWindowPhase` → `ConnectionWorkspacePhase`: each rename updates every caller and every test in the same commit, or `git bisect` gets a broken commit.

14. **Do not add explanatory comments** while moving `initializeAndRestoreTabs` out of the view. The codebase has none; the doc comments that exist on these types are contract statements, and the stale ones (`SessionTabStatePersister`'s "saveAggregatedSync collects the tabs of every window", `RecentlyClosedTabReopener`'s "Brings a closed tab back into a native window tab", `WindowLifecycleMonitor`'s supersede rationale) must be rewritten or deleted with the code, not left behind to mislead the next reader.

15. **Do not write `window_id` into any new MCP result** to preserve compatibility. There are two incompatible `window_id` spaces in the tools today (`payload.id` and `coordinator.windowId`), neither names a window, and nothing consumes either. Break it cleanly in Step 15 with a CHANGELOG entry.

16. **Do not use em dashes, and do not reach for "seamless", "robust" or "comprehensive"** in the CHANGELOG entries, the CLAUDE.md rewrites or the PR body. Run the pre-commit grep from CLAUDE.md before every commit in this series.