//
//  MainContentView+Setup.swift
//  TablePro
//
//  Extension containing initialization, command setup, and database switching
//  for MainContentView. Extracted to reduce main view complexity.
//

import os
import SwiftUI

private let setupLogger = Logger(subsystem: "com.TablePro", category: "MainContentSetup")

extension MainContentView {
    // MARK: - Initialization

    func initializeAndRestoreTabs() async {
        let start = ContinuousClock.now
        guard !hasInitialized else { return }
        hasInitialized = true
        Task { await coordinator.loadSchemaIfNeeded() }

        guard let payload else {
            setupLogger.info("[PERF] initializeAndRestoreTabs: no payload, calling handleRestoreOrDefault")
            await handleRestoreOrDefault()
            setupLogger.info("[PERF] initializeAndRestoreTabs: total=\(ContinuousClock.now - start) (restoreOrDefault path)")
            return
        }

        switch payload.intent {
        case .openContent:
            if payload.skipAutoExecute { return }
            if let selectedTab = tabManager.selectedTab,
                selectedTab.tabType == .table,
                !selectedTab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                if let session = DatabaseManager.shared.activeSessions[connection.id],
                    session.isConnected
                {
                    if !selectedTab.databaseName.isEmpty,
                        selectedTab.databaseName != session.activeDatabase
                    {
                        Task { await coordinator.switchDatabase(to: selectedTab.databaseName) }
                    } else {
                        // columns is [] on initial load — buildFilteredQuery uses SELECT *
                        if !selectedTab.filterState.appliedFilters.isEmpty,
                            let tableName = selectedTab.tableName,
                            let tabIndex = tabManager.selectedTabIndex
                        {
                            let filteredQuery = coordinator.queryBuilder.buildFilteredQuery(
                                tableName: tableName,
                                filters: selectedTab.filterState.appliedFilters,
                                columns: [],
                                limit: selectedTab.pagination.pageSize,
                                offset: selectedTab.pagination.currentOffset
                            )
                            tabManager.tabs[tabIndex].query = filteredQuery
                        }
                        if let tableName = selectedTab.tableName {
                            coordinator.restoreColumnLayoutForTable(tableName)
                        }
                        coordinator.executeTableTabQueryDirectly()
                    }
                } else {
                    // Reactive path: fires via onChange(of: sessionVersion) when connection is ready
                    coordinator.needsLazyLoad = true
                }
            }
            if let sourceURL = payload.sourceFileURL {
                WindowLifecycleMonitor.shared.registerSourceFile(sourceURL, windowId: windowId)
            }

        case .newEmptyTab:
            setupLogger.info("[PERF] initializeAndRestoreTabs: newEmptyTab (total=\(ContinuousClock.now - start))")
            return

        case .restoreOrDefault:
            await handleRestoreOrDefault()
            setupLogger.info("[PERF] initializeAndRestoreTabs: restoreOrDefault (total=\(ContinuousClock.now - start))")
        }
    }

    private func handleRestoreOrDefault() async {
        let restoreStart = ContinuousClock.now
        if WindowLifecycleMonitor.shared.hasOtherWindows(for: connection.id, excluding: windowId) {
            if tabManager.tabs.isEmpty {
                let allTabs = MainContentCoordinator.allTabs(for: connection.id)
                let title = QueryTabManager.nextQueryTitle(existingTabs: allTabs)
                tabManager.addTab(title: title, databaseName: connection.database)
            }
            return
        }

        let preRestore = ContinuousClock.now
        let result = await coordinator.persistence.restoreFromDisk()
        setupLogger.info("[PERF] handleRestoreOrDefault: restoreFromDisk took \(ContinuousClock.now - preRestore), tabCount=\(result.tabs.count)")
        if !result.tabs.isEmpty {
            var restoredTabs = result.tabs
            for i in restoredTabs.indices where restoredTabs[i].tabType == .table {
                if let tableName = restoredTabs[i].tableName {
                    restoredTabs[i].query = QueryTab.buildBaseTableQuery(
                        tableName: tableName,
                        databaseType: connection.type,
                        schemaName: restoredTabs[i].schemaName
                    )
                }
            }

            // All tabs go into one QueryTabManager — no native window loop
            tabManager.tabs = restoredTabs
            tabManager.selectedTabId = result.selectedTabId ?? restoredTabs.first?.id

            // Execute the selected tab's query if it's a table tab
            if let selectedTab = tabManager.selectedTab,
                selectedTab.tabType == .table,
                !selectedTab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                if let session = DatabaseManager.shared.activeSessions[connection.id],
                    session.isConnected
                {
                    if !selectedTab.databaseName.isEmpty,
                        selectedTab.databaseName != session.activeDatabase
                    {
                        Task { await coordinator.switchDatabase(to: selectedTab.databaseName) }
                    } else {
                        if let tableName = selectedTab.tableName {
                            coordinator.restoreColumnLayoutForTable(tableName)
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
        let hasFileChanges = tabManager.selectedTab?.isFileDirty ?? false
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
        } else if let fileURL = selectedTab?.sourceFileURL {
            windowTitle = fileURL.deletingPathExtension().lastPathComponent
        } else {
            let langName = PluginManager.shared.queryLanguageName(for: connection.type)
            let queryLabel = "\(langName) Query"
            windowTitle = (selectedTab?.tabType == .table ? selectedTab?.tableName : nil)
                ?? selectedTab?.title
                ?? (tabManager.tabs.isEmpty ? connection.name : queryLabel)
        }
        viewWindow?.representedURL = selectedTab?.sourceFileURL
        viewWindow?.isDocumentEdited = selectedTab?.isFileDirty ?? false
    }

    /// Configure the hosting NSWindow — called by WindowAccessor when the window is available.
    func configureWindow(_ window: NSWindow) {
        let configStart = ContinuousClock.now
        let isPreview = tabManager.selectedTab?.isPreview ?? payload?.isPreview ?? false
        if isPreview {
            window.subtitle = "\(connection.name) — Preview"
        } else {
            window.subtitle = connection.name
        }

        let resolvedId = WindowOpener.tabbingIdentifier(for: connection.id)
        window.tabbingIdentifier = resolvedId
        // Disallow native window tabbing — tabs are managed in-app via EditorTabBar
        window.tabbingMode = .disallowed
        coordinator.windowId = windowId

        let registerStart = ContinuousClock.now
        WindowLifecycleMonitor.shared.register(
            window: window,
            connectionId: connection.id,
            windowId: windowId,
            isPreview: isPreview
        )
        setupLogger.info("[PERF] configureWindow: WindowLifecycleMonitor.register took \(ContinuousClock.now - registerStart)")

        viewWindow = window
        coordinator.contentWindow = window
        isKeyWindow = window.isKeyWindow

        if let payloadId = payload?.id {
            WindowOpener.shared.acknowledgePayload(payloadId)
        }

        // Native proxy icon (Cmd+click shows path in Finder) and dirty dot
        window.representedURL = tabManager.selectedTab?.sourceFileURL
        window.isDocumentEdited = tabManager.selectedTab?.isFileDirty ?? false

        // Update command actions window reference now that it's available
        commandActions?.window = window
        setupLogger.info("[PERF] configureWindow: total=\(ContinuousClock.now - configStart)")
    }

    func setupCommandActions() {
        let actions = MainContentCommandActions(
            coordinator: coordinator,
            filterStateManager: filterStateManager,
            connection: connection,
            selectedRowIndices: $selectedRowIndices,
            selectedTables: Binding(
                get: { sidebarState.selectedTables },
                set: { sidebarState.selectedTables = $0 }
            ),
            pendingTruncates: $pendingTruncates,
            pendingDeletes: $pendingDeletes,
            tableOperationOptions: $tableOperationOptions,
            rightPanelState: rightPanelState,
            editingCell: $editingCell
        )
        actions.window = viewWindow
        commandActions = actions
    }

    // MARK: - Database Switcher

    func switchDatabase(to database: String) {
        Task {
            await coordinator.switchDatabase(to: database)
        }
    }
}
