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

    private func restoreConnectionContext(
        for selected: QueryTab,
        activeDatabase: String?,
        activeSchema: String?,
        loadTiming: RestoreLoadTiming,
        consumeDeferredWhenKey: Bool
    ) {
        let isTableTab = selected.tabType == .table
            && !selected.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

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

        Task {
            await coordinator.switchContainers(database: activeDatabase, schema: activeSchema)
            if isTableTab {
                coordinator.lazyLoadCurrentTabIfNeeded(trigger: .restore)
            }
        }
    }

    private func applyRestoredGroup(
        _ tabs: [QueryTab],
        selectedTabId: UUID?,
        activeDatabase: String? = nil,
        activeSchema: String? = nil,
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
            activeDatabase: activeDatabase,
            activeSchema: activeSchema,
            loadTiming: loadTiming,
            consumeDeferredWhenKey: consumeDeferredWhenKey
        )
    }

    private func handleRestoreOrDefault() async {
        if let group = RestorationGroupRegistry.consume(for: payload?.id) {
            applyRestoredGroup(
                group.tabs,
                selectedTabId: group.selectedTabId,
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
        let restoreStart = Date()
        let result = await coordinator.persistence.restoreFromDisk()
        MainContentView.lifecycleLogger.info(
            "[open] restoreFromDisk done windowId=\(windowId, privacy: .public) tabsRestored=\(result.tabs.count) source=\(String(describing: result.source), privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(restoreStart) * 1_000))"
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

        /// One window hosts every connection, so a connection's saved tabs all belong to the one
        /// tab list. The old shape split them across windows by a saved group index, which now
        /// has nowhere to go: a group handed back to `openTab` restores nothing and the next
        /// autosave erases it.
        applyRestoredGroup(
            restoredTabs,
            selectedTabId: result.selectedTabId ?? restoredTabs.first?.id,
            activeDatabase: result.lastActiveDatabase,
            activeSchema: result.lastActiveSchema,
            loadTiming: window.isKeyWindow ? .immediate : .deferred
        )
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
        coordinator.splitViewController?.updateDetailMinimumThickness(
            for: selectedTab?.tabType,
            connectionId: connection.id
        )
        viewWindow?.representedURL = selectedTab?.content.sourceFileURL
        viewWindow?.isDocumentEdited = selectedTab.map(coordinator.showsUnsavedIndicator) ?? false
    }

    /// Configure the hosting NSWindow — called by WindowAccessor when the window is available.
    func configureWindow(_ window: NSWindow) {
        let start = Date()
        MainContentView.lifecycleLogger.info(
            "[open] configureWindow start windowId=\(windowId, privacy: .public) connId=\(connection.id, privacy: .public)"
        )
        let isPreview = tabManager.selectedTab?.isPreview ?? payload?.isPreview ?? false

        window.tabbingIdentifier = WindowManager.mainTabbingIdentifier
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
        window.isDocumentEdited = tabManager.selectedTab.map(coordinator.showsUnsavedIndicator) ?? false

        commandActions?.window = window

        if let splitVC = window.contentViewController as? MainSplitViewController {
            splitVC.installToolbar(coordinator: coordinator)
        }

        ScreenshotEnvironment.pinWindowSize(window)
        MainContentView.lifecycleLogger.info(
            "[open] configureWindow done windowId=\(windowId, privacy: .public) isPreview=\(isPreview) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
        )
    }

    func setupCommandActions() {
        let actions = MainContentCommandActions(
            coordinator: coordinator,
            connection: connection,
            selectionState: coordinator.selectionState,
            selectedTables: Binding(
                get: { coordinator.windowSidebarState.selectedTables },
                set: { coordinator.windowSidebarState.selectTables($0) }
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
