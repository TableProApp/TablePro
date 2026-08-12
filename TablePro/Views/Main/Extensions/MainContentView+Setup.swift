//
//  MainContentView+Setup.swift
//  TablePro
//
//  Extension containing initialization, command setup, and database switching
//  for MainContentView. Extracted to reduce main view complexity.
//

import os
import SwiftUI

extension MainContentView {
    // MARK: - Initialization

    func initializeAndRestoreTabs() async {
        guard !hasInitialized else {
            MainContentView.lifecycleLogger.info(
                "[open] initializeAndRestoreTabs skipped (already initialized) windowId=\(windowId, privacy: .public)"
            )
            return
        }
        hasInitialized = true
        let schemaTaskStart = Date()
        async let schemaLoad: Void = {
            await coordinator.loadSchemaIfNeeded()
            MainContentView.lifecycleLogger.info(
                "[open] loadSchemaIfNeeded done windowId=\(windowId, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(schemaTaskStart) * 1_000))"
            )
        }()

        guard let payload else {
            await handleRestoreOrDefault()
            _ = await schemaLoad
            return
        }

        MainContentView.lifecycleLogger.info(
            "[open] initializeAndRestoreTabs intent=\(String(describing: payload.intent), privacy: .public) windowId=\(windowId, privacy: .public) skipAutoExecute=\(payload.skipAutoExecute)"
        )

        switch payload.intent {
        case .openContent:
            if let selectedTab = tabManager.selectedTab,
                selectedTab.tabType == .table,
                let tableName = selectedTab.tableContext.tableName
            {
                coordinator.restoreLastHiddenColumnsForTable()
                if selectedTab.filterState.appliedFilters.isEmpty {
                    coordinator.restoreFiltersForTable(tableName)
                } else if let tabIndex = tabManager.selectedTabIndex {
                    coordinator.rebuildTableQuery(at: tabIndex)
                }
            }
            if payload.skipAutoExecute {
                await coordinator.rebuildSelectedTableQueryForHiddenColumnsIfNeeded()
                _ = await schemaLoad
                return
            }
            if let selectedTab = tabManager.selectedTab,
                selectedTab.tabType == .table,
                !selectedTab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                if let session = DatabaseManager.shared.activeSessions[connection.id],
                    session.isConnected
                {
                    coordinator.lazyLoadCurrentTabIfNeeded()
                } else {
                    coordinator.pendingLoadTrigger = .userInitiated
                }
            }
            if let sourceURL = payload.sourceFileURL {
                WindowLifecycleMonitor.shared.registerSourceFile(sourceURL, windowId: windowId)
            }

        case .newEmptyTab:
            _ = await schemaLoad
            return

        case .restoreOrDefault:
            await handleRestoreOrDefault()
        }

        _ = await schemaLoad
    }

    private func handleRestoreOrDefault() async {
        if let group = RestorationGroupRegistry.consume(for: payload?.id) {
            applyRestoredGroup(
                group.tabs,
                selectedTabId: group.selectedTabId,
                browseState: group.browseState,
                loadTiming: group.loadTiming,
                consumeDeferredWhenKey: true
            )
            return
        }

        /// The split view controller owns the window and is wired up before this view is built, unlike
        /// `viewWindow`, which arrives from `configureWindow` and can still be nil here.
        guard let window = coordinator.splitViewController?.view.window else {
            MainContentView.lifecycleLogger.error(
                "[open] handleRestoreOrDefault has no window windowId=\(windowId, privacy: .public)"
            )
            return
        }
        let windowIndex = WindowTabGroupOrder.index(of: window)
        let openWindowCount = WindowTabGroupOrder.size(containing: window)

        let restoreStart = Date()
        let result = await coordinator.persistence.restoreFromDisk()
        MainContentView.lifecycleLogger.info(
            "[open] restoreFromDisk done windowId=\(windowId, privacy: .public) tabsRestored=\(result.tabs.count) windowIndex=\(windowIndex) openWindowCount=\(openWindowCount) source=\(String(describing: result.source), privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(restoreStart) * 1_000))"
        )
        guard !result.tabs.isEmpty else { return }

        var restoredTabs = result.tabs
        for i in restoredTabs.indices where restoredTabs[i].tabType == .table {
            if let tableName = restoredTabs[i].tableContext.tableName {
                do {
                    restoredTabs[i].content.query = try QueryTab.buildBaseTableQuery(
                        tableName: tableName,
                        databaseType: connection.type,
                        schemaName: restoredTabs[i].tableContext.schemaName
                    )
                } catch {
                    MainContentView.lifecycleLogger.error(
                        "[open] buildBaseTableQuery failed for restored tab table=\(tableName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }

        let plan = WindowGroupAssignment.resolve(
            windowIndex: windowIndex,
            openWindowCount: openWindowCount,
            tabs: restoredTabs,
            windowGroupIndexByTabId: result.windowGroupIndexByTabId,
            selectedTabId: result.selectedTabId
        )

        if openWindowCount == 1 {
            restoreAsOnlyWindow(plan, result: result, windowIndex: windowIndex)
        } else {
            claimOwnTabs(plan, result: result, windowIndex: windowIndex, window: window)
        }
    }

    /// The connection has one window, so this window restores what it kept and opens a window for every
    /// other group. Nothing has focus yet, so the tab the user left selected is brought to the front.
    private func restoreAsOnlyWindow(
        _ plan: WindowGroupAssignment.Plan,
        result: RestoreResult,
        windowIndex: Int
    ) {
        let frontGroup = RestoreWindowPlan.resolveFrontGroup(
            ownTabIds: plan.ownTabs.map(\.id),
            orphanedGroups: plan.orphanedGroups.map { ($0.windowGroupIndex, $0.tabs.map(\.id)) },
            selectedId: result.selectedTabId
        )

        applyRestoredGroup(
            plan.ownTabs,
            selectedTabId: plan.ownSelectedTabId ?? plan.ownTabs.first?.id,
            browseState: result.browseState(forWindowGroupIndex: windowIndex),
            loadTiming: frontGroup == .own ? .immediate : .deferred
        )

        for group in plan.orphanedGroups {
            let isFront = frontGroup == .orphaned(windowGroupIndex: group.windowGroupIndex)
            openRestoredTabWindow(
                group.tabs,
                selectedTabId: group.selectedTabId,
                browseState: result.browseState(forWindowGroupIndex: group.windowGroupIndex),
                activate: isFront,
                loadTiming: isFront ? .immediate : .deferred
            )
        }
        if frontGroup == .own, !plan.orphanedGroups.isEmpty {
            viewWindow?.makeKeyAndOrderFront(nil)
        }
    }

    /// Other windows of this connection are already open and every one of them is restoring its own
    /// tabs right now, so this window takes only what was its own and never raises itself: the user is
    /// already looking at one of these windows. Only the window the user can see loads its data now,
    /// which also keeps a reconnect from firing one query per window.
    private func claimOwnTabs(
        _ plan: WindowGroupAssignment.Plan,
        result: RestoreResult,
        windowIndex: Int,
        window: NSWindow
    ) {
        applyRestoredGroup(
            plan.ownTabs,
            selectedTabId: plan.ownSelectedTabId ?? plan.ownTabs.first?.id,
            browseState: result.browseState(forWindowGroupIndex: windowIndex),
            loadTiming: window.isKeyWindow ? .immediate : .deferred
        )

        for group in plan.orphanedGroups {
            openRestoredTabWindow(
                group.tabs,
                selectedTabId: group.selectedTabId,
                browseState: result.browseState(forWindowGroupIndex: group.windowGroupIndex),
                activate: false,
                loadTiming: .deferred
            )
        }
    }

    /// `browseState` has no default on purpose: a group's container is part of restoring it, and a
    /// call site that omitted one would put its window back on the connection default instead.
    private func applyRestoredGroup(
        _ tabs: [QueryTab],
        selectedTabId: UUID?,
        browseState: WindowBrowseState,
        loadTiming: RestoreLoadTiming = .immediate,
        consumeDeferredWhenKey: Bool = false
    ) {
        guard let firstTab = tabs.first else { return }
        tabManager.tabs = tabs
        tabManager.selectedTabId = tabs.contains(where: { $0.id == selectedTabId }) ? selectedTabId : firstTab.id

        guard let selected = tabManager.selectedTab else { return }

        if selected.tabType == .table, let tableName = selected.tableContext.tableName,
            !selected.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            coordinator.restoreLastHiddenColumnsForTable()
            coordinator.restoreFiltersForTable(tableName)
        }

        restoreConnectionContext(
            for: selected,
            browseState: browseState,
            loadTiming: loadTiming,
            consumeDeferredWhenKey: consumeDeferredWhenKey
        )
    }

    /// Seed this window's own browse cursor from its own saved group, then load the selected tab.
    ///
    /// Seeding is local to the window, never a connection-wide switch, because N restoring windows
    /// would otherwise fire N switches at one driver and the last one to land would drag every
    /// window onto its database. That is the bug per-window browse state exists to close, and
    /// persistence was the last place still holding one container for the whole connection. (#2088)
    ///
    /// `consumeDeferredWhenKey` is true only for sibling windows opened by restoration, which
    /// may already be key because the user is showing them. The initial window is transiently
    /// key at launch before the front window activates, so it must never consume here — it loads
    /// its deferred tab through `windowDidBecomeKey` when the user switches back to it.
    private func restoreConnectionContext(
        for selected: QueryTab,
        browseState: WindowBrowseState,
        loadTiming: RestoreLoadTiming,
        consumeDeferredWhenKey: Bool
    ) {
        let isTableTab = selected.tabType == .table
            && !selected.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        coordinator.seedRestoredBrowseState(browseState)

        guard loadTiming == .immediate else {
            if isTableTab {
                coordinator.deferredRestoreLoadTabId = selected.id
                if consumeDeferredWhenKey {
                    coordinator.consumeDeferredRestoreLoadIfNeeded()
                }
            }
            return
        }

        guard let session = DatabaseManager.shared.activeSessions[connection.id], session.isConnected else {
            if isTableTab { coordinator.pendingLoadTrigger = .restore }
            return
        }

        guard requiresSharedBrowseCursor else {
            if isTableTab {
                coordinator.lazyLoadCurrentTabIfNeeded(trigger: .restore)
            }
            return
        }

        Task {
            if let database = browseState.database, database != session.resolvedDriverDatabase {
                await coordinator.switchDatabase(to: database)
            }
            if let schema = browseState.schema, schema != session.driverSchema {
                await coordinator.switchSchema(to: schema)
            }
            if isTableTab {
                coordinator.lazyLoadCurrentTabIfNeeded(trigger: .restore)
            }
        }
    }

    /// Whether every window of this connection has to share the driver's position.
    ///
    /// An engine that must reconnect to change database and cannot pool holds exactly one container
    /// at a time, so a restore that only seeded each window's own cursor would leave all but one
    /// window pointing at a database the connection is not on. Every other engine reaches a
    /// container per operation through `withScopedDriver`, so seeding is enough and a
    /// connection-wide switch per restored window is exactly what must not happen.
    private var requiresSharedBrowseCursor: Bool {
        PluginManager.shared.requiresReconnectForDatabaseSwitch(for: connection.type)
            && !connection.type.supportsConnectionPooling
    }

    /// Opens one window for a whole saved group. The payload describes the tab the window opens on so
    /// its native label reads right from creation; the group itself travels through the registry, which
    /// is what carries the state a payload cannot express.
    ///
    /// The payload's database and schema stay the lead tab's, because `WindowTitleResolver` reads them
    /// for the window's first title and a group can be browsing one container while its front tab
    /// reads another. They fall back to the group's cursor only when the tab names none, which is what
    /// `SessionStateFactory` seeds the new window's cursor from before the registry group arrives.
    private func openRestoredTabWindow(
        _ tabs: [QueryTab],
        selectedTabId: UUID?,
        browseState: WindowBrowseState,
        activate: Bool,
        loadTiming: RestoreLoadTiming
    ) {
        guard let leadTab = tabs.first(where: { $0.id == selectedTabId }) ?? tabs.first else { return }
        let leadDatabaseName = leadTab.tableContext.databaseName
        let restorePayload = EditorTabPayload(
            connectionId: connection.id,
            tabType: leadTab.tabType,
            tableName: leadTab.tableContext.tableName,
            databaseName: leadDatabaseName.isEmpty ? browseState.database : leadDatabaseName,
            schemaName: leadTab.tableContext.schemaName ?? browseState.schema,
            isView: leadTab.tableContext.isView,
            skipAutoExecute: true,
            erDiagramSchemaKey: leadTab.display.erDiagramSchemaKey,
            tabTitle: leadTab.title,
            intent: .restoreOrDefault
        )
        RestorationGroupRegistry.register(
            .init(
                tabs: tabs,
                selectedTabId: selectedTabId ?? leadTab.id,
                browseState: browseState,
                loadTiming: loadTiming
            ),
            for: restorePayload.id
        )
        WindowManager.shared.openTab(payload: restorePayload, activate: activate)
    }

    // MARK: - Command Actions Setup

    func updateToolbarPendingState() {
        if tabManager.selectedTab?.tabType == .createTable {
            toolbarState.hasDataPendingChanges = false
            toolbarState.hasPendingChanges = toolbarState.hasCreateTablePending
            return
        }
        let hasDataChanges =
            changeManager.hasChanges
            || !pendingTruncates.isEmpty
            || !pendingDeletes.isEmpty
            || toolbarState.hasStructureChanges
        let hasFileChanges = tabManager.selectedTab?.content.isFileDirty ?? false
        toolbarState.hasDataPendingChanges = hasDataChanges
        toolbarState.hasPendingChanges = hasDataChanges || hasFileChanges
    }

    /// Update window title, proxy icon, and dirty dot based on the selected tab.
    func updateWindowTitleAndFileState() {
        let selectedTab = tabManager.selectedTab
        let resolved = WindowTitleResolver.resolveWindow(
            pane: .content,
            connection: connection,
            tab: selectedTab,
            hasTabs: !tabManager.tabs.isEmpty,
            queryLanguageName: PluginManager.shared.queryLanguageName(for: connection.type)
        )
        windowTitle = resolved.title
        windowSubtitle = resolved.subtitle
        coordinator.splitViewController?.updateDetailMinimumThickness(for: selectedTab?.tabType)
        viewWindow?.representedURL = selectedTab?.content.sourceFileURL
        viewWindow?.isDocumentEdited = selectedTab?.showsUnsavedIndicator ?? false
    }

    /// Configure the hosting NSWindow — called by WindowAccessor when the window is available.
    func configureWindow(_ window: NSWindow) {
        let start = Date()
        MainContentView.lifecycleLogger.info(
            "[open] configureWindow start windowId=\(windowId, privacy: .public) connId=\(connection.id, privacy: .public)"
        )
        let isPreview = tabManager.selectedTab?.isPreview ?? payload?.isPreview ?? false

        let resolvedId = WindowManager.tabbingIdentifier(for: connection.id)
        window.tabbingIdentifier = resolvedId
        window.tabbingMode = .preferred
        coordinator.windowId = windowId

        WindowLifecycleMonitor.shared.register(
            window: window,
            connectionId: connection.id,
            windowId: windowId
        )
        viewWindow = window
        coordinator.contentWindow = window
        coordinator.isKeyWindow = window.isKeyWindow

        // Native proxy icon (Cmd+click shows path in Finder) and dirty dot
        window.representedURL = tabManager.selectedTab?.content.sourceFileURL
        window.isDocumentEdited = tabManager.selectedTab?.showsUnsavedIndicator ?? false

        commandActions?.window = window

        if let splitVC = window.contentViewController as? MainSplitViewController {
            splitVC.installToolbar(coordinator: coordinator)
        }
        MainContentView.lifecycleLogger.info(
            "[open] configureWindow done windowId=\(windowId, privacy: .public) tabbingId=\(resolvedId, privacy: .public) isPreview=\(isPreview) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
        )
    }

    func setupCommandActions() {
        let actions = MainContentCommandActions(
            coordinator: coordinator,
            connection: connection,
            selectionState: coordinator.selectionState,
            selectedTables: Binding(
                get: { coordinator.windowSidebarState.selectedTables },
                set: { coordinator.windowSidebarState.selectedTables = $0 }
            ),
            pendingTruncates: $pendingTruncates,
            pendingDeletes: $pendingDeletes,
            tableOperationOptions: $tableOperationOptions,
            rightPanelState: rightPanelState
        )
        actions.window = viewWindow
        coordinator.commandActions = actions
        commandActions = actions
        coordinator.splitViewController?.rebuildInspectorPane()
    }

    // MARK: - Database Switcher

    func switchDatabase(to database: String) {
        Task {
            await coordinator.switchDatabase(to: database)
        }
    }
}
