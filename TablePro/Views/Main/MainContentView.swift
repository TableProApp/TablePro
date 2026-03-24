//
//  MainContentView.swift
//  TablePro
//
//  Main content view combining query editor and results table.
//  Refactored to use coordinator pattern for business logic separation.
//

import Combine
import SwiftUI

/// Main content view - thin presentation layer
struct MainContentView: View {
    // MARK: - Properties

    let connection: DatabaseConnection
    /// Payload identifying what this window-tab should display (nil = default query tab)
    let payload: EditorTabPayload?

    // Shared state from parent
    @Binding var windowTitle: String
    @Binding var tables: [TableInfo]
    var sidebarState: SharedSidebarState
    @Binding var pendingTruncates: Set<String>
    @Binding var pendingDeletes: Set<String>
    @Binding var tableOperationOptions: [String: TableOperationOptions]
    @Binding var inspectorContext: InspectorContext
    var rightPanelState: RightPanelState

    // MARK: - State Objects

    let tabManager: QueryTabManager
    let changeManager: DataChangeManager
    let filterStateManager: FilterStateManager
    let toolbarState: ConnectionToolbarState
    let coordinator: MainContentCoordinator

    // MARK: - Local State

    @State var selectedRowIndices: Set<Int> = []
    @State private var previousSelectedTabId: UUID?
    @State private var previousSelectedTables: Set<TableInfo> = []
    @State private var editingCell: CellPosition?
    @State private var commandActions: MainContentCommandActions?
    @State private var queryResultsSummaryCache: (tabId: UUID, version: Int, summary: String?)?
    @State private var inspectorUpdateTask: Task<Void, Never>?
    @State private var lazyLoadTask: Task<Void, Never>?
    @State private var pendingTabSwitch: Task<Void, Never>?
    @State private var evictionTask: Task<Void, Never>?
    /// Stable identifier for this window in WindowLifecycleMonitor
    @State private var windowId = UUID()
    @State private var hasInitialized = false
    /// Tracks whether this view's window is the key (focused) window
    @State private var isKeyWindow = false
    /// Reference to this view's NSWindow for filtering notifications
    @State private var viewWindow: NSWindow?

    /// Grace period for onDisappear: SwiftUI fires onDisappear transiently
    /// during tab group merges, then re-fires onAppear shortly after.
    private static let tabGroupMergeGracePeriod: Duration = .milliseconds(200)

    // MARK: - Environment

    @Environment(AppState.self) private var appState

    // MARK: - Initialization

    init(
        connection: DatabaseConnection,
        payload: EditorTabPayload?,
        windowTitle: Binding<String>,
        tables: Binding<[TableInfo]>,
        sidebarState: SharedSidebarState,
        pendingTruncates: Binding<Set<String>>,
        pendingDeletes: Binding<Set<String>>,
        tableOperationOptions: Binding<[String: TableOperationOptions]>,
        inspectorContext: Binding<InspectorContext>,
        rightPanelState: RightPanelState,
        tabManager: QueryTabManager,
        changeManager: DataChangeManager,
        filterStateManager: FilterStateManager,
        toolbarState: ConnectionToolbarState,
        coordinator: MainContentCoordinator
    ) {
        self.connection = connection
        self.payload = payload
        self._windowTitle = windowTitle
        self._tables = tables
        self.sidebarState = sidebarState
        self._pendingTruncates = pendingTruncates
        self._pendingDeletes = pendingDeletes
        self._tableOperationOptions = tableOperationOptions
        self._inspectorContext = inspectorContext
        self.rightPanelState = rightPanelState
        self.tabManager = tabManager
        self.changeManager = changeManager
        self.filterStateManager = filterStateManager
        self.toolbarState = toolbarState
        self.coordinator = coordinator
    }

    // MARK: - Body

    var body: some View {
        bodyContent
            .sheet(item: Bindable(coordinator).activeSheet) { sheet in
                sheetContent(for: sheet)
            }
            .modifier(FocusedCommandActionsModifier(actions: commandActions))
    }

    // MARK: - Sheet Content

    /// Returns the appropriate sheet view for the given `ActiveSheet` case.
    /// Uses a dismissal binding that sets `coordinator.activeSheet = nil` when the
    /// child view sets `isPresented = false`.
    @ViewBuilder
    private func sheetContent(for sheet: ActiveSheet) -> some View {
        let dismissBinding = Binding<Bool>(
            get: { coordinator.activeSheet != nil },
            set: { if !$0 { coordinator.activeSheet = nil } }
        )

        switch sheet {
        case .databaseSwitcher:
            let session = DatabaseManager.shared.session(for: connection.id)
            let activeDatabase = session?.currentDatabase ?? connection.database
            let activeSchema = session?.currentSchema
            let currentSelection = PluginManager.shared.supportsSchemaSwitching(for: connection.type)
                ? (activeSchema ?? activeDatabase)
                : activeDatabase
            DatabaseSwitcherSheet(
                isPresented: dismissBinding,
                currentDatabase: currentSelection,
                currentSchema: activeSchema,
                databaseType: connection.type,
                connectionId: connection.id,
                onSelect: switchDatabase,
                onSelectSchema: { schema in
                    Task { await coordinator.switchSchema(to: schema) }
                }
            )
        case .exportDialog:
            ExportDialog(
                isPresented: dismissBinding,
                mode: .tables(
                    connection: connection,
                    preselectedTables: Set(sidebarState.selectedTables.map(\.name))
                )
            )
        case .exportQueryResults:
            if let tab = coordinator.tabManager.selectedTab {
                ExportDialog(
                    isPresented: dismissBinding,
                    mode: .queryResults(
                        connection: connection,
                        rowBuffer: tab.rowBuffer,
                        suggestedFileName: tab.tableName ?? "query_results"
                    )
                )
            }
        case .importDialog:
            ImportDialog(
                isPresented: dismissBinding,
                connection: connection,
                initialFileURL: coordinator.importFileURL
            )
        case .quickSwitcher:
            QuickSwitcherSheet(
                isPresented: dismissBinding,
                schemaProvider: coordinator.schemaProvider,
                connectionId: connection.id,
                databaseType: connection.type,
                onSelect: { item in
                    coordinator.handleQuickSwitcherSelection(item)
                }
            )
        }
    }

    /// Trigger for toolbar pending-changes badge — combines all four sources that
    /// contribute to `hasPendingChanges`. Replaces four separate handlers that each
    /// called `updateToolbarPendingState()`.
    private var pendingChangeTrigger: PendingChangeTrigger {
        PendingChangeTrigger(
            hasDataChanges: changeManager.hasChanges,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            hasStructureChanges: appState.hasStructureChanges
        )
    }

    /// Split into two halves to help the Swift type checker with the long modifier chain.
    private var bodyContent: some View {
        bodyContentCore
            .background {
                WindowAccessor { window in
                    configureWindow(window)
                }
            }
            .task(id: currentTab?.tableName) {
                // Only load metadata after the tab has executed at least once —
                // avoids a redundant DB query racing with the initial data query
                guard currentTab?.lastExecutedAt != nil else { return }
                await loadTableMetadataIfNeeded()
            }
            .onChange(of: inspectorTrigger) {
                scheduleInspectorUpdate()
            }
            .onAppear {
                coordinator.markActivated()

                // Set window title for empty state (no tabs restored)
                if tabManager.tabs.isEmpty {
                    windowTitle = connection.name
                }
                setupCommandActions()
                updateToolbarPendingState()
                updateInspectorContext()
                rightPanelState.aiViewModel.schemaProvider = coordinator.schemaProvider
                coordinator.aiViewModel = rightPanelState.aiViewModel
                coordinator.rightPanelState = rightPanelState

                // Window registration is handled by WindowAccessor in .background
            }
            .onDisappear {
                // Mark teardown intent synchronously so deinit doesn't warn
                // if SwiftUI deallocates the coordinator before the delayed Task fires
                coordinator.markTeardownScheduled()

                let capturedWindowId = windowId
                let connectionId = connection.id
                let connectionName = connection.name
                Task { @MainActor in
                    // Grace period: SwiftUI fires onDisappear transiently during tab group
                    // merges/splits, then re-fires onAppear shortly after. The onAppear
                    // handler re-registers via WindowLifecycleMonitor on DispatchQueue.main.async,
                    // so this delay must exceed that dispatch latency to avoid tearing down
                    // a window that's about to reappear.
                    try? await Task.sleep(for: Self.tabGroupMergeGracePeriod)

                    // If this window re-registered (temporary disappear during tab group merge), skip cleanup
                    if WindowLifecycleMonitor.shared.isRegistered(windowId: capturedWindowId) {
                        coordinator.clearTeardownScheduled()
                        return
                    }

                    // Window truly closed — teardown coordinator
                    coordinator.teardown()
                    rightPanelState.teardown()

                    // If no more windows for this connection, disconnect.
                    // Tab state is NOT cleared here — it's preserved for next reconnect.
                    // Only handleTabsChange(count=0) clears state (user explicitly closed all tabs).
                    guard !WindowLifecycleMonitor.shared.hasWindows(for: connectionId) else { return }
                    await DatabaseManager.shared.disconnectSession(connectionId)

                    // Give SwiftUI/AppKit time to deallocate view hierarchies,
                    // then hint malloc to return freed pages to the OS
                    try? await Task.sleep(for: .seconds(2))
                    malloc_zone_pressure_relief(nil, 0)
                }
            }
            .onChange(of: pendingChangeTrigger) {
                updateToolbarPendingState()
            }
    }

    private var bodyContentCore: some View {
        mainContentView
            .openTableToolbar(state: toolbarState)
            .modifier(ToolbarTintModifier(connectionColor: connection.color))
            .task { await initializeAndRestoreTabs() }
            .onChange(of: tabManager.selectedTabId) { _, newTabId in
                pendingTabSwitch?.cancel()
                pendingTabSwitch = Task { @MainActor in
                    // Let other onChange handlers (tabs, resultColumns) settle first
                    try? await Task.sleep(for: .milliseconds(16))
                    guard !Task.isCancelled else { return }
                    handleTabSelectionChange(from: previousSelectedTabId, to: newTabId)
                    previousSelectedTabId = newTabId
                }
            }
            .onChange(of: tabManager.tabs) { _, newTabs in
                handleTabsChange(newTabs)
            }
            .onChange(of: currentTab?.resultColumns) { _, newColumns in
                handleColumnsChange(newColumns: newColumns)
            }
            .task { handleConnectionStatusChange() }
            .onReceive(
                NotificationCenter.default.publisher(for: .connectionStatusDidChange)
                    .filter { ($0.object as? UUID) == connection.id }
            ) { _ in
                handleConnectionStatusChange()
            }

            .onChange(of: sidebarState.selectedTables) { _, newTables in
                handleTableSelectionChange(from: previousSelectedTables, to: newTables)
                previousSelectedTables = newTables
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                guard let notificationWindow = notification.object as? NSWindow,
                      notificationWindow === viewWindow else { return }
                isKeyWindow = true
                evictionTask?.cancel()
                evictionTask = nil
                DispatchQueue.main.async {
                    syncSidebarToCurrentTab()
                }
                // Lazy-load: execute query for restored tabs that skipped auto-execute,
                // or re-query tabs whose row data was evicted while inactive.
                // Skip if the user has unsaved changes (in-memory or tab-level).
                let hasPendingEdits = changeManager.hasChanges
                    || (tabManager.selectedTab?.pendingChanges.hasChanges ?? false)
                let isConnected = DatabaseManager.shared.activeSessions[connection.id]?.isConnected ?? false
                let needsLazyLoad = tabManager.selectedTab.map { tab in
                    tab.tabType == .table
                        && (tab.resultRows.isEmpty || tab.rowBuffer.isEvicted)
                        && (tab.lastExecutedAt == nil || tab.rowBuffer.isEvicted)
                        && !tab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                } ?? false
                if needsLazyLoad && !hasPendingEdits && isConnected {
                    coordinator.runQuery()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
                guard let notificationWindow = notification.object as? NSWindow,
                      notificationWindow === viewWindow else { return }
                isKeyWindow = false

                // Schedule row data eviction for inactive native window-tabs.
                // 5s delay avoids thrashing when quickly switching between tabs.
                // Per-tab pendingChanges checks inside evictInactiveRowData() protect
                // tabs with unsaved changes from eviction.
                evictionTask?.cancel()
                evictionTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    coordinator.evictInactiveRowData()
                }
            }
            .onChange(of: tables) { _, newTables in
                let syncAction = SidebarSyncAction.resolveOnTablesLoad(
                    newTables: newTables,
                    selectedTables: sidebarState.selectedTables,
                    currentTabTableName: tabManager.selectedTab?.tableName
                )
                if case let .select(tableName) = syncAction,
                   let match = newTables.first(where: { $0.name == tableName }) {
                    sidebarState.selectedTables = [match]
                }
            }
            .onChange(of: selectedRowIndices) { _, newIndices in
                // Synchronous: cheap state updates that don't cascade
                AppState.shared.hasRowSelection = !newIndices.isEmpty
                if !newIndices.isEmpty,
                   AppSettingsManager.shared.dataGrid.autoShowInspector,
                   tabManager.selectedTab?.tabType == .table
                {
                    rightPanelState.isPresented = true
                }
                // Deferred: expensive inspector rebuild coalesced with other triggers
                scheduleInspectorUpdate()
            }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContentView: some View {
        MainEditorContentView(
            tabManager: tabManager,
            coordinator: coordinator,
            changeManager: changeManager,
            filterStateManager: filterStateManager,
            columnVisibilityManager: coordinator.columnVisibilityManager,
            connection: connection,
            windowId: windowId,
            connectionId: connection.id,
            selectedRowIndices: $selectedRowIndices,
            editingCell: $editingCell,
            onCellEdit: { rowIndex, colIndex, value in
                coordinator.updateCellInTab(
                    rowIndex: rowIndex, columnIndex: colIndex, value: value)
                scheduleInspectorUpdate()
            },
            onSort: { columnIndex, ascending, isMultiSort in
                coordinator.handleSort(
                    columnIndex: columnIndex, ascending: ascending,
                    isMultiSort: isMultiSort,
                    selectedRowIndices: &selectedRowIndices)
            },
            onAddRow: {
                coordinator.addNewRow(
                    selectedRowIndices: &selectedRowIndices, editingCell: &editingCell)
            },
            onUndoInsert: { rowIndex in
                coordinator.undoInsertRow(at: rowIndex, selectedRowIndices: &selectedRowIndices)
            },
            onFilterColumn: { columnName in
                filterStateManager.addFilterForColumn(columnName)
            },
            onApplyFilters: { filters in
                coordinator.applyFilters(filters)
            },
            onClearFilters: {
                coordinator.clearFiltersAndReload()
            },
            onQuickSearch: { searchText in
                coordinator.applyQuickSearch(searchText)
            },
            onRefresh: {
                coordinator.runQuery()
            },
            onFirstPage: {
                coordinator.goToFirstPage()
            },
            onPreviousPage: {
                coordinator.goToPreviousPage()
            },
            onNextPage: {
                coordinator.goToNextPage()
            },
            onLastPage: {
                coordinator.goToLastPage()
            },
            onLimitChange: { newLimit in
                coordinator.updatePageSize(newLimit)
            },
            onOffsetChange: { newOffset in
                coordinator.updateOffset(newOffset)
            },
            onPaginationGo: {
                coordinator.applyPaginationSettings()
            }
        )
    }

    // MARK: - Initialization

    private func initializeAndRestoreTabs() async {
        guard !hasInitialized else { return }
        hasInitialized = true
        Task { await coordinator.loadSchemaIfNeeded() }

        // If payload provided a specific tab (not connection-only), execute its query immediately
        if let payload, !payload.isConnectionOnly {
            if payload.skipAutoExecute {
                // Don't execute now — query will fire when user clicks this tab
                // (handled by didBecomeKeyNotification)
                return
            }
            if let selectedTab = tabManager.selectedTab,
               selectedTab.tabType == .table,
               !selectedTab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                // Fast path: connection already ready
                if let session = DatabaseManager.shared.activeSessions[connection.id],
                   session.isConnected
                {
                    if !selectedTab.databaseName.isEmpty,
                       selectedTab.databaseName != session.activeDatabase
                    {
                        Task { await coordinator.switchDatabase(to: selectedTab.databaseName) }
                    } else {
                        if !selectedTab.filterState.appliedFilters.isEmpty,
                           let tableName = selectedTab.tableName,
                           let tabIndex = tabManager.selectedTabIndex
                        {
                            // columns is [] on initial load — buildFilteredQuery uses SELECT *
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
            return
        }

        // Connection-only payload or nil payload -- restore tabs from storage
        // If other windows already exist for this connection, this is a "new tab"
        // from the native macOS "+" button -- just add a single empty query tab.
        if WindowLifecycleMonitor.shared.hasOtherWindows(for: connection.id, excluding: windowId) {
            tabManager.addTab(databaseName: connection.database)
            return
        }

        // No existing windows -- restore tabs from storage (first window on connection)
        let result = await coordinator.persistence.restoreFromDisk()
        if !result.tabs.isEmpty {
            // Rebuild base queries for table tabs to strip stale filter/sort WHERE clauses.
            // Filter state is not persisted, so the stored query may contain orphaned conditions
            // that reference columns from a different schema — causing errors on restore.
            var restoredTabs = result.tabs
            for i in restoredTabs.indices where restoredTabs[i].tabType == .table {
                if let tableName = restoredTabs[i].tableName {
                    restoredTabs[i].query = QueryTab.buildBaseTableQuery(
                        tableName: tableName,
                        databaseType: connection.type
                    )
                }
            }

            // Find the selected tab, or use the first one
            let selectedId = result.selectedTabId
            let selectedIndex = restoredTabs.firstIndex(where: { $0.id == selectedId }) ?? 0

            // Keep only the selected tab for this window
            let selectedTab = restoredTabs[selectedIndex]
            tabManager.tabs = [selectedTab]
            tabManager.selectedTabId = selectedTab.id

            // Open remaining tabs as new native window-tabs
            let remainingTabs = restoredTabs.enumerated()
                .filter { $0.offset != selectedIndex }
                .map(\.element)

            if !remainingTabs.isEmpty {
                // Delay to let the first window finish setup
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    for tab in remainingTabs {
                        let payload = EditorTabPayload(from: tab, connectionId: connection.id, skipAutoExecute: true)
                        WindowOpener.shared.openNativeTab(payload)
                        // Small delay between opens to avoid overwhelming AppKit
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    // Re-activate the selected tab's window so it stays in front
                    viewWindow?.makeKeyAndOrderFront(nil)
                }
            }

            // Execute query for the selected tab if it's a table tab
            if selectedTab.tabType == .table,
               !selectedTab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                // Fast path: connection already ready
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
                    // Reactive path: fires via onChange(of: sessionVersion) when connection is ready
                    coordinator.needsLazyLoad = true
                }
            }
        }
    }

    // MARK: - Command Actions Setup

    private func updateToolbarPendingState() {
        toolbarState.hasPendingChanges = changeManager.hasChanges
            || !pendingTruncates.isEmpty
            || !pendingDeletes.isEmpty
            || AppState.shared.hasStructureChanges
    }

    /// Configure the hosting NSWindow — called by WindowAccessor when the window is available.
    private func configureWindow(_ window: NSWindow) {
        let isPreview = tabManager.selectedTab?.isPreview ?? payload?.isPreview ?? false
        if isPreview {
            window.subtitle = "\(connection.name) — Preview"
        } else {
            window.subtitle = connection.name
        }
        window.tabbingIdentifier = "com.TablePro.main.\(connection.id.uuidString)"
        window.tabbingMode = .preferred
        coordinator.windowId = windowId

        WindowLifecycleMonitor.shared.register(
            window: window,
            connectionId: connection.id,
            windowId: windowId,
            isPreview: isPreview
        )
        viewWindow = window
        isKeyWindow = window.isKeyWindow

        // Update command actions window reference now that it's available
        commandActions?.window = window
    }

    private func setupCommandActions() {
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

    private func switchDatabase(to database: String) {
        Task {
            await coordinator.switchDatabase(to: database)
        }
    }

    // MARK: - Event Handlers

    private func handleTabSelectionChange(from oldTabId: UUID?, to newTabId: UUID?) {
        coordinator.handleTabChange(
            from: oldTabId,
            to: newTabId,
            selectedRowIndices: &selectedRowIndices,
            tabs: tabManager.tabs
        )

        // Update window title to reflect selected tab
        let langName = PluginManager.shared.queryLanguageName(for: connection.type)
        let queryLabel = "\(langName) Query"
        windowTitle = tabManager.selectedTab?.tableName
            ?? (tabManager.tabs.isEmpty ? connection.name : queryLabel)

        // Sync sidebar selection to match the newly selected tab.
        // Critical for new native windows: localSelectedTables starts empty,
        // and this is the only place that can seed it from the restored tab.
        syncSidebarToCurrentTab()

        // Persist tab selection explicitly (skip during teardown)
        guard !coordinator.isTearingDown else { return }
        coordinator.persistence.saveNow(
            tabs: tabManager.tabs,
            selectedTabId: newTabId
        )
    }

    private func handleTabsChange(_ newTabs: [QueryTab]) {
        // Always update window title to reflect current tab, even during restoration
        let langName = PluginManager.shared.queryLanguageName(for: connection.type)
        let queryLabel = "\(langName) Query"
        windowTitle = tabManager.selectedTab?.tableName
            ?? (tabManager.tabs.isEmpty ? connection.name : queryLabel)

        // Don't persist during teardown — SwiftUI may fire onChange with empty tabs
        // as the view is being deallocated
        guard !coordinator.isTearingDown else { return }
        guard !coordinator.isUpdatingColumnLayout else { return }

        // Promote preview tab if user has interacted with it
        if let tab = tabManager.selectedTab, tab.isPreview, tab.hasUserInteraction {
            coordinator.promotePreviewTab()
        }

        // Persist tab changes (exclude preview tabs from persistence)
        let persistableTabs = newTabs.filter { !$0.isPreview }
        if persistableTabs.isEmpty {
            coordinator.persistence.clearSavedState()
        } else {
            let normalizedSelectedId = persistableTabs.contains(where: { $0.id == tabManager.selectedTabId })
                ? tabManager.selectedTabId : persistableTabs.first?.id
            coordinator.persistence.saveNow(
                tabs: persistableTabs,
                selectedTabId: normalizedSelectedId
            )
        }
    }

    private func handleColumnsChange(newColumns: [String]?) {
        // Skip during tab switch — handleTabChange already configures the change manager
        guard !coordinator.isHandlingTabSwitch else { return }

        // Prune hidden columns that no longer exist in results
        if let newColumns = newColumns {
            coordinator.pruneHiddenColumns(currentColumns: newColumns)
        }

        guard let newColumns = newColumns, !newColumns.isEmpty,
              let tab = tabManager.selectedTab,
              !changeManager.hasChanges
        else { return }

        // Reconfigure if columns changed OR table name changed (switching tables)
        let columnsChanged = changeManager.columns != newColumns
        let tableChanged = changeManager.tableName != (tab.tableName ?? "")

        guard columnsChanged || tableChanged else { return }

        changeManager.configureForTable(
            tableName: tab.tableName ?? "",
            columns: newColumns,
            primaryKeyColumn: newColumns.first,
            databaseType: connection.type
        )
    }

    private func handleTableSelectionChange(
        from oldTables: Set<TableInfo>, to newTables: Set<TableInfo>
    ) {
        let action = TableSelectionAction.resolve(oldTables: oldTables, newTables: newTables)

        guard case let .navigate(tableName, isView) = action else {
            AppState.shared.hasTableSelection = !newTables.isEmpty
            return
        }

        // Only navigate when this is the focused window.
        // Prevents feedback loops when shared sidebar state syncs across native tabs.
        guard isKeyWindow else {
            AppState.shared.hasTableSelection = !newTables.isEmpty
            return
        }

        let isPreviewMode = AppSettingsManager.shared.tabs.enablePreviewTabs
        let hasPreview = WindowLifecycleMonitor.shared.previewWindow(for: connection.id) != nil

        let result = SidebarNavigationResult.resolve(
            clickedTableName: tableName,
            currentTabTableName: tabManager.selectedTab?.tableName,
            hasExistingTabs: !tabManager.tabs.isEmpty,
            isPreviewTabMode: isPreviewMode,
            hasPreviewTab: hasPreview
        )

        switch result {
        case .skip:
            AppState.shared.hasTableSelection = !newTables.isEmpty
            return
        case .openInPlace:
            selectedRowIndices = []
            coordinator.openTableTab(tableName, isView: isView)
        case .revertAndOpenNewWindow:
            coordinator.openTableTab(tableName, isView: isView)
        case .replacePreviewTab, .openNewPreviewTab:
            coordinator.openTableTab(tableName, isView: isView)
        }

        AppState.shared.hasTableSelection = !newTables.isEmpty
    }

    /// Keep sidebar selection in sync with the current window's tab.
    /// Only writes when the value actually changes, preventing spurious onChange triggers.
    /// Navigation safety is guaranteed by `SidebarNavigationResult.resolve` returning `.skip`
    /// when the selected table matches the current tab.
    private func syncSidebarToCurrentTab() {
        let target: Set<TableInfo>
        if let currentTableName = tabManager.selectedTab?.tableName,
           let match = tables.first(where: { $0.name == currentTableName }) {
            target = [match]
        } else {
            target = []
        }
        if sidebarState.selectedTables != target {
            // Don't clear sidebar selection while the table list is still loading.
            // Clearing it prematurely triggers SidebarSyncAction to re-select on
            // tables load, causing a double-navigation race condition.
            if target.isEmpty && tables.isEmpty { return }
            sidebarState.selectedTables = target
        }
    }

    // MARK: - Helper Methods

    private func loadTableMetadataIfNeeded() async {
        guard let tableName = currentTab?.tableName,
              coordinator.tableMetadata?.tableName != tableName
        else { return }
        await coordinator.loadTableMetadata(tableName: tableName)
    }

    private func handleConnectionStatusChange() {
        let sessions = DatabaseManager.shared.activeSessions
        guard let session = sessions[connection.id] else { return }
        if session.isConnected && coordinator.needsLazyLoad {
            let hasPendingEdits = changeManager.hasChanges
                || (tabManager.selectedTab?.pendingChanges.hasChanges ?? false)
            guard !hasPendingEdits else { return }
            coordinator.needsLazyLoad = false
            if let selectedTab = tabManager.selectedTab,
               !selectedTab.databaseName.isEmpty,
               selectedTab.databaseName != session.activeDatabase
            {
                Task { await coordinator.switchDatabase(to: selectedTab.databaseName) }
            } else {
                coordinator.runQuery()
            }
        }
        let mappedState = mapSessionStatus(session.status)
        if mappedState != toolbarState.connectionState {
            toolbarState.connectionState = mappedState
        }
    }

    private func mapSessionStatus(_ status: ConnectionStatus) -> ToolbarConnectionState {
        switch status {
        case .connected: return .connected
        case .connecting: return .executing
        case .disconnected: return .disconnected
        case .error: return .error("")
        }
    }

    // MARK: - Sidebar Edit Handling

    private func updateSidebarEditState() {
        guard let tab = coordinator.tabManager.selectedTab,
              !selectedRowIndices.isEmpty
        else {
            rightPanelState.editState.fields = []
            rightPanelState.editState.onFieldChanged = nil
            return
        }

        var allRows: [[String?]] = []
        for index in selectedRowIndices.sorted() {
            if index < tab.resultRows.count {
                allRows.append(tab.resultRows[index])
            }
        }

        // Enrich column types with loaded enum values from Phase 2b
        var columnTypes = tab.columnTypes
        for (i, col) in tab.resultColumns.enumerated() where i < columnTypes.count {
            if let values = tab.columnEnumValues[col], !values.isEmpty {
                let ct = columnTypes[i]
                if ct.isEnumType {
                    columnTypes[i] = .enumType(rawType: ct.rawType, values: values)
                } else if ct.isSetType {
                    columnTypes[i] = .set(rawType: ct.rawType, values: values)
                }
            }
        }

        // Clear stale sidebar edits after refresh/discard
        if !changeManager.hasChanges {
            rightPanelState.editState.clearEdits()
        }

        // Collect columns modified in data grid so sidebar shows green dots
        var modifiedColumns = Set<Int>()
        for rowIndex in selectedRowIndices {
            modifiedColumns.formUnion(changeManager.getModifiedColumnsForRow(rowIndex))
        }

        let excludedNames: Set<String>
        if let tableName = tab.tableName {
            excludedNames = Set(coordinator.columnExclusions(for: tableName).map(\.columnName))
        } else {
            excludedNames = []
        }

        rightPanelState.editState.configure(
            selectedRowIndices: selectedRowIndices,
            allRows: allRows,
            columns: tab.resultColumns,
            columnTypes: columnTypes,
            externallyModifiedColumns: modifiedColumns,
            excludedColumnNames: excludedNames
        )

        guard isSidebarEditable else {
            rightPanelState.editState.onFieldChanged = nil
            return
        }

        let capturedCoordinator = coordinator
        let capturedEditState = rightPanelState.editState
        rightPanelState.editState.onFieldChanged = { columnIndex, newValue in
            guard let tab = capturedCoordinator.tabManager.selectedTab else { return }
            let columnName = columnIndex < tab.resultColumns.count ? tab.resultColumns[columnIndex] : ""

            for rowIndex in capturedEditState.selectedRowIndices {
                guard rowIndex < tab.resultRows.count else { continue }
                let originalRow = tab.resultRows[rowIndex]

                // Use full (lazy-loaded) original value if available, not truncated row data
                let oldValue: String?
                if columnIndex < capturedEditState.fields.count, !capturedEditState.fields[columnIndex].isTruncated {
                    oldValue = capturedEditState.fields[columnIndex].originalValue
                } else {
                    oldValue = columnIndex < originalRow.count ? originalRow[columnIndex] : nil
                }

                capturedCoordinator.changeManager.recordCellChange(
                    rowIndex: rowIndex,
                    columnIndex: columnIndex,
                    columnName: columnName,
                    oldValue: oldValue,
                    newValue: newValue,
                    originalRow: originalRow
                )
            }
        }

        // Lazy-load full values for excluded columns when a single row is selected
        if !excludedNames.isEmpty,
           selectedRowIndices.count == 1,
           let tableName = tab.tableName,
           let pkColumn = tab.primaryKeyColumn,
           let rowIndex = selectedRowIndices.first,
           rowIndex < tab.resultRows.count {
            let row = tab.resultRows[rowIndex]
            if let pkColIndex = tab.resultColumns.firstIndex(of: pkColumn),
               pkColIndex < row.count,
               let pkValue = row[pkColIndex] {
                let excludedList = Array(excludedNames)

                lazyLoadTask?.cancel()
                lazyLoadTask = Task { @MainActor in
                    let expectedRowIndex = rowIndex
                    do {
                        let fullValues = try await capturedCoordinator.fetchFullValuesForExcludedColumns(
                            tableName: tableName,
                            primaryKeyColumn: pkColumn,
                            primaryKeyValue: pkValue,
                            excludedColumnNames: excludedList
                        )
                        guard !Task.isCancelled,
                              capturedEditState.selectedRowIndices.count == 1,
                              capturedEditState.selectedRowIndices.first == expectedRowIndex else { return }
                        capturedEditState.applyFullValues(fullValues)
                    } catch {
                        guard !Task.isCancelled,
                              capturedEditState.selectedRowIndices.count == 1,
                              capturedEditState.selectedRowIndices.first == expectedRowIndex else { return }
                        for i in 0..<capturedEditState.fields.count where capturedEditState.fields[i].isLoadingFullValue {
                            capturedEditState.fields[i].isLoadingFullValue = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - Inspector Context

    /// Coalesces multiple onChange-triggered updates into a single deferred call.
    /// During tab switch, onChange handlers fire 3-4x — this ensures we only rebuild once,
    /// and defers the work so SwiftUI can render the tab switch first.
    private func scheduleInspectorUpdate() {
        inspectorUpdateTask?.cancel()
        inspectorUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            updateSidebarEditState()
            updateInspectorContext()
        }
    }

    private func updateInspectorContext() {
        inspectorContext = InspectorContext(
            tableName: currentTab?.tableName,
            tableMetadata: coordinator.tableMetadata,
            selectedRowData: selectedRowDataForSidebar,
            isEditable: isSidebarEditable,
            isRowDeleted: isSelectedRowDeleted,
            currentQuery: coordinator.tabManager.selectedTab?.query,
            queryResults: cachedQueryResultsSummary()
        )
    }

    private func cachedQueryResultsSummary() -> String? {
        guard let tab = currentTab else { return nil }
        if let cache = queryResultsSummaryCache,
           cache.tabId == tab.id, cache.version == tab.resultVersion {
            return cache.summary
        }
        let summary = buildQueryResultsSummary()
        queryResultsSummaryCache = (tabId: tab.id, version: tab.resultVersion, summary: summary)
        return summary
    }

    private func buildQueryResultsSummary() -> String? {
        guard let tab = currentTab,
              !tab.resultColumns.isEmpty,
              !tab.resultRows.isEmpty
        else { return nil }

        let columns = tab.resultColumns
        let rows = tab.resultRows
        let maxRows = 10
        let displayRows = Array(rows.prefix(maxRows))

        var lines: [String] = []
        lines.append(columns.joined(separator: " | "))

        for row in displayRows {
            let values = columns.indices.map { i in
                i < row.count ? (row[i] ?? "NULL") : "NULL"
            }
            lines.append(values.joined(separator: " | "))
        }

        if rows.count > maxRows {
            lines.append("(showing \(maxRows) of \(rows.count) rows)")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Toolbar Tint Modifier

/// Applies a subtle color tint to the window toolbar when a connection color is set.
private struct ToolbarTintModifier: ViewModifier {
    let connectionColor: ConnectionColor

    @ViewBuilder
    func body(content: Content) -> some View {
        if connectionColor.isDefault {
            content
        } else {
            content
                .toolbarBackground(connectionColor.color.opacity(0.12), for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
        }
    }
}

// MARK: - Focused Command Actions Modifier

/// Conditionally publishes `MainContentCommandActions` as a focused scene value.
/// `focusedSceneValue` requires a non-optional value, so this modifier
/// only applies it when the actions object has been created.
private struct FocusedCommandActionsModifier: ViewModifier {
    let actions: MainContentCommandActions?

    func body(content: Content) -> some View {
        if let actions {
            content.focusedSceneValue(\.commandActions, actions)
        } else {
            content
        }
    }
}

// MARK: - Preview

#Preview("With Connection") {
    let state = SessionStateFactory.create(
        connection: DatabaseConnection.sampleConnections[0],
        payload: nil
    )
    MainContentView(
        connection: DatabaseConnection.sampleConnections[0],
        payload: nil,
        windowTitle: .constant("SQL Query"),
        tables: .constant([]),
        sidebarState: SharedSidebarState(),
        pendingTruncates: .constant([]),
        pendingDeletes: .constant([]),
        tableOperationOptions: .constant([:]),
        inspectorContext: .constant(.empty),
        rightPanelState: RightPanelState(),
        tabManager: state.tabManager,
        changeManager: state.changeManager,
        filterStateManager: state.filterStateManager,
        toolbarState: state.toolbarState,
        coordinator: state.coordinator
    )
    .frame(width: 1_000, height: 600)
}
