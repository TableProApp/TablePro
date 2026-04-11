//
//  MainContentView+Setup.swift
//  TablePro
//
//  Extension containing initialization, command setup, and database switching
//  for MainContentView. Extracted to reduce main view complexity.
//

import SwiftUI

extension MainContentView {
    // MARK: - Initialization

    func initializeAndRestoreTabs() async {
        guard !hasInitialized else { return }
        hasInitialized = true
        Task { await coordinator.loadSchemaIfNeeded() }

        guard let payload else {
            await handleRestoreOrDefault()
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
            return

        case .restoreOrDefault:
            await handleRestoreOrDefault()
        }
    }

    private func handleRestoreOrDefault() async {
        if WindowLifecycleMonitor.shared.hasOtherWindows(for: connection.id, excluding: windowId) {
            if tabManager.tabs.isEmpty {
                tabManager.addTab(databaseName: connection.database)
            }
            return
        }

        let result = await coordinator.persistence.restoreFromDisk()
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

            let selectedId = result.selectedTabId
            let selectedIndex = restoredTabs.firstIndex(where: { $0.id == selectedId }) ?? 0

            let selectedTab = restoredTabs[selectedIndex]
            tabManager.tabs = [selectedTab]
            tabManager.selectedTabId = selectedTab.id

            let remainingTabs = restoredTabs.enumerated()
                .filter { $0.offset != selectedIndex }
                .map(\.element)

            if !remainingTabs.isEmpty {
                Task { @MainActor in
                    for tab in remainingTabs {
                        let restorePayload = EditorTabPayload(
                            from: tab, connectionId: connection.id, skipAutoExecute: true)
                        WindowOpener.shared.openNativeTab(restorePayload)
                    }
                    viewWindow?.makeKeyAndOrderFront(nil)
                }
            }

            if selectedTab.tabType == .table,
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
        if selectedTab?.tabType == .createTable {
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
        let isPreview = tabManager.selectedTab?.isPreview ?? payload?.isPreview ?? false
        if isPreview {
            window.subtitle = "\(connection.name) — Preview"
        } else {
            window.subtitle = connection.name
        }

        let resolvedId = WindowOpener.tabbingIdentifier(for: connection.id)
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
        isKeyWindow = window.isKeyWindow

        if let payloadId = payload?.id {
            WindowOpener.shared.acknowledgePayload(payloadId)
        }

        // Native proxy icon (Cmd+click shows path in Finder) and dirty dot
        window.representedURL = tabManager.selectedTab?.sourceFileURL
        window.isDocumentEdited = tabManager.selectedTab?.isFileDirty ?? false

        // Update command actions window reference now that it's available
        commandActions?.window = window
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
