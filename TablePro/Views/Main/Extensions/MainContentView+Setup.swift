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
            if payload.skipAutoExecute {
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
                    if !selectedTab.tableContext.databaseName.isEmpty,
                        selectedTab.tableContext.databaseName != session.activeDatabase
                    {
                        await coordinator.switchDatabase(to: selectedTab.tableContext.databaseName)
                    } else {
                        if !selectedTab.filterState.appliedFilters.isEmpty,
                            let tableName = selectedTab.tableContext.tableName,
                            let tabIndex = tabManager.selectedTabIndex
                        {
                            let filteredQuery = coordinator.queryBuilder.buildFilteredQuery(
                                tableName: tableName,
                                filters: selectedTab.filterState.appliedFilters,
                                columns: [],
                                limit: selectedTab.pagination.pageSize,
                                offset: selectedTab.pagination.currentOffset
                            )
                            tabManager.tabs[tabIndex].content.query = filteredQuery
                        }
                        if let tableName = selectedTab.tableContext.tableName {
                            coordinator.restoreLastHiddenColumnsForTable(tableName)
                        }
                        coordinator.executeTableTabQueryDirectly()
                    }
                } else {
                    coordinator.needsLazyLoad = true
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
        if WindowLifecycleMonitor.shared.hasOtherWindows(for: connection.id, excluding: windowId) {
            MainContentView.lifecycleLogger.info(
                "[open] handleRestoreOrDefault short-circuit (other windows exist) windowId=\(windowId, privacy: .public)"
            )
            return
        }

        let restoreStart = Date()
        let result = await coordinator.persistence.restoreFromDisk()
        MainContentView.lifecycleLogger.info(
            "[open] restoreFromDisk done windowId=\(windowId, privacy: .public) tabsRestored=\(result.tabs.count) source=\(String(describing: result.source), privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(restoreStart) * 1_000))"
        )
        guard !result.tabs.isEmpty else { return }
        do {
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

            let selectedId = result.selectedTabId

            // First tab in the array gets the current window to preserve order.
            // Remaining tabs open as native window tabs in order.
            let firstTab = restoredTabs[0]
            tabManager.tabs = [firstTab]
            tabManager.selectedTabId = firstTab.id

            let remainingTabs = Array(restoredTabs.dropFirst())

            if !remainingTabs.isEmpty {
                let selectedWasFirst = firstTab.id == selectedId
                for tab in remainingTabs {
                    let restorePayload = EditorTabPayload(
                        from: tab, connectionId: connection.id, skipAutoExecute: true)
                    WindowManager.shared.openTab(payload: restorePayload)
                }
                if selectedWasFirst {
                    viewWindow?.makeKeyAndOrderFront(nil)
                }
            }

            if firstTab.tabType == .table,
                !firstTab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                if let session = DatabaseManager.shared.activeSessions[connection.id],
                    session.isConnected
                {
                    if !firstTab.tableContext.databaseName.isEmpty,
                        firstTab.tableContext.databaseName != session.activeDatabase
                    {
                        Task { await coordinator.switchDatabase(to: firstTab.tableContext.databaseName) }
                    } else {
                        if let tableName = firstTab.tableContext.tableName {
                            coordinator.restoreLastHiddenColumnsForTable(tableName)
                        }
                        coordinator.executeTableTabQueryDirectly()
                    }
                } else {
                    coordinator.needsLazyLoad = true
                }
            }
        }
    }

    // MARK: - Command Actions Setup

    func updateToolbarPendingState() {
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
        if selectedTab?.tabType == .serverDashboard {
            windowTitle = String(localized: "Server Dashboard")
        } else if selectedTab?.tabType == .createTable {
            windowTitle = String(localized: "Create Table")
        } else if selectedTab?.tabType == .erDiagram {
            windowTitle = String(localized: "ER Diagram")
        } else if selectedTab?.tabType == .terminal {
            windowTitle = String(localized: "Terminal")
        } else if let fileURL = selectedTab?.content.sourceFileURL {
            windowTitle = selectedTab?.title ?? fileURL.deletingPathExtension().lastPathComponent
        } else {
            let langName = PluginManager.shared.queryLanguageName(for: connection.type)
            let queryLabel = String(format: String(localized: "%@ Query"), langName)
            windowTitle = (selectedTab?.tabType == .table ? selectedTab?.tableContext.tableName : nil)
                ?? selectedTab?.title
                ?? (tabManager.tabs.isEmpty ? connection.name : queryLabel)
        }
        viewWindow?.representedURL = selectedTab?.content.sourceFileURL
        viewWindow?.isDocumentEdited = selectedTab?.content.isFileDirty ?? false
    }

    /// Configure the hosting NSWindow — called by WindowAccessor when the window is available.
    func configureWindow(_ window: NSWindow) {
        let start = Date()
        MainContentView.lifecycleLogger.info(
            "[open] configureWindow start windowId=\(windowId, privacy: .public) connId=\(connection.id, privacy: .public)"
        )
        let isPreview = tabManager.selectedTab?.isPreview ?? payload?.isPreview ?? false
        if isPreview {
            window.subtitle = String(format: String(localized: "%@ — Preview"), connection.name)
        } else {
            window.subtitle = connection.name
        }

        let resolvedId = WindowManager.tabbingIdentifier(for: connection.id)
        window.tabbingIdentifier = resolvedId
        window.tabbingMode = .preferred
        coordinator.windowId = windowId

        WindowLifecycleMonitor.shared.register(
            window: window,
            connectionId: connection.id,
            windowId: windowId,
            isPreview: isPreview
        )
        viewWindow = window
        coordinator.contentWindow = window
        coordinator.isKeyWindow = window.isKeyWindow

        // Native proxy icon (Cmd+click shows path in Finder) and dirty dot
        window.representedURL = tabManager.selectedTab?.content.sourceFileURL
        window.isDocumentEdited = tabManager.selectedTab?.content.isFileDirty ?? false

        // Update command actions window reference now that it's available
        commandActions?.window = window

        // Publish command actions to the registry NOW. `windowDidBecomeKey`
        // also publishes, but for the first window after welcome→connect the
        // coordinator's `contentWindow` isn't set when AppKit's first
        // becomeKey fires — `coordinator(forWindow:)` returns nil and the
        // publish is skipped. configureWindow IS the moment the coordinator
        // gets linked to its NSWindow, so this is the earliest reliable
        // point to publish.
        //
        // No `window.isKeyWindow` guard: when this method runs, the window
        // has been ordered front but isn't yet key (becomeKey fires after
        // a runloop tick). We trust that newly opened windows will become
        // key shortly; overwriting from a non-key window is acceptable
        // because the next becomeKey on any window will rewrite the
        // registry anyway.
        if let actions = commandActions {
            CommandActionsRegistry.shared.current = actions
        }

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
                get: { sidebarState.selectedTables },
                set: { sidebarState.selectedTables = $0 }
            ),
            pendingTruncates: $pendingTruncates,
            pendingDeletes: $pendingDeletes,
            tableOperationOptions: $tableOperationOptions,
            rightPanelState: rightPanelState
        )
        actions.window = viewWindow
        coordinator.commandActions = actions
        commandActions = actions
    }

    // MARK: - Database Switcher

    func switchDatabase(to database: String) {
        Task {
            await coordinator.switchDatabase(to: database)
        }
    }
}
