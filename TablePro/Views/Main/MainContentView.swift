//
//  MainContentView.swift
//  TablePro
//
//  Main content view combining query editor and results table.
//  Refactored to use coordinator pattern for business logic separation.
//
//  Extensions:
//  - MainContentView+Bindings.swift — computed bindings and trigger types
//  - MainContentView+EventHandlers.swift — tab/table selection, sidebar edit handling
//  - MainContentView+Setup.swift — initialization, command actions, database switching
//  - MainContentView+Helpers.swift — helper methods, inspector context
//  - MainContentView+Modifiers.swift — toolbar tint, focused command actions, preview
//

import Combine
import SwiftUI
import TableProPluginKit

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
    @State var previousSelectedTabId: UUID?
    @State var previousSelectedTables: Set<TableInfo> = []
    @State var editingCell: CellPosition?
    @State var commandActions: MainContentCommandActions?
    @State var queryResultsSummaryCache: (tabId: UUID, version: Int, summary: String?)?
    @State var inspectorUpdateTask: Task<Void, Never>?
    @State var lazyLoadTask: Task<Void, Never>?
    // pendingTabSwitch removed — tab switch is synchronous (2ms), no debounce needed
    // evictionTask removed — eviction only on memory pressure, not window resign
    /// Stable identifier for this window in WindowLifecycleMonitor
    @State var windowId = UUID()
    @State var hasInitialized = false
    /// Tracks whether this view's window is the key (focused) window
    @State var isKeyWindow = false
    @State var lastResignKeyDate = Date.distantPast
    /// Reference to this view's NSWindow for filtering notifications
    @State var viewWindow: NSWindow?

    // MARK: - Environment


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

    /// Connection with the active database from the current session,
    /// so export/import dialogs see the database the user actually switched to.
    private var connectionWithCurrentDatabase: DatabaseConnection {
        var conn = connection
        if let currentDB = DatabaseManager.shared.session(for: connection.id)?.currentDatabase {
            conn.database = currentDB
        }
        return conn
    }

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
            let currentSelection =
                PluginManager.shared.supportsSchemaSwitching(for: connection.type)
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
            let exportConnection = connectionWithCurrentDatabase
            ExportDialog(
                isPresented: dismissBinding,
                mode: .tables(
                    connection: exportConnection,
                    preselectedTables: Set(sidebarState.selectedTables.map(\.name))
                ),
                sidebarTables: tables
            )
        case .exportQueryResults:
            if let tab = coordinator.tabManager.selectedTab {
                ExportDialog(
                    isPresented: dismissBinding,
                    mode: .queryResults(
                        connection: connectionWithCurrentDatabase,
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
        case .maintenance(let operation, let tableName):
            MaintenanceSheet(
                operation: operation,
                tableName: tableName,
                databaseType: connection.type,
                onExecute: coordinator.executeMaintenance
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
            hasStructureChanges: toolbarState.hasStructureChanges,
            isFileDirty: tabManager.selectedTab?.isFileDirty ?? false
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
            // Metadata loading moved to query completion (executeQueryInternal)
            // and Phase 2 tab switch settlement. Removed .task(id: currentTab?.tableName)
            // which created N queued tasks during rapid Cmd+1/2/3 switching.
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
                coordinator.onTabSwitchSettled = {
                    // Capture reference types explicitly — MainContentView is a struct,
                    // but @State/@Binding storage is reference-stable.
                    self.selectedRowIndices = []
                    self.updateWindowTitleAndFileState()
                    self.syncSidebarToCurrentTab()
                    guard !self.coordinator.isTearingDown else { return }
                    self.coordinator.persistence.saveNow(
                        tabs: self.tabManager.tabs,
                        selectedTabId: self.tabManager.selectedTabId
                    )
                    if let tab = self.tabManager.selectedTab, tab.lastExecutedAt != nil {
                        Task { await self.loadTableMetadataIfNeeded() }
                    }
                }

                // Window registration is handled by WindowAccessor in .background
            }
            .onDisappear {
                // No teardown here. Coordinator and panel cleanup is handled by
                // WindowLifecycleMonitor.handleWindowClose (NSWindow.willCloseNotification)
                // — a deterministic AppKit signal. SwiftUI's onDisappear fires transiently
                // during view hierarchy reconstruction and is not reliable for resource cleanup.
            }
            .onChange(of: pendingChangeTrigger) {
                updateToolbarPendingState()
            }
            .userActivity("com.TablePro.viewConnection") { activity in
                activity.title = connection.name.isEmpty
                    ? connection.host
                    : connection.name
                activity.isEligibleForHandoff = true
                activity.userInfo = ["connectionId": connection.id.uuidString]
            }
            .userActivity("com.TablePro.viewTable") { activity in
                guard let tableName = tabManager.selectedTab?.tableName else {
                    activity.invalidate()
                    return
                }
                activity.title = tableName
                activity.isEligibleForHandoff = true
                activity.userInfo = [
                    "connectionId": connection.id.uuidString,
                    "tableName": tableName
                ]
            }
    }

    private var bodyContentCore: some View {
        mainContentView
            .openTableToolbar(state: toolbarState)
            .modifier(ToolbarTintModifier(connectionColor: connection.color))
            .task { await initializeAndRestoreTabs() }
            .onChange(of: tabManager.selectedTabId) { _, newTabId in
                // ZStack opacity flip happens automatically from selectedTabId binding.
                // ALL work is deferred to Phase 2 (handleTabChange's Task) which
                // coalesces rapid Cmd+1/2/3 switches via tabSwitchTask cancellation.
                // No synchronous mutations here — avoids triggering body re-evals
                // that block the main thread during keyboard repeat spam.
                coordinator.scheduleTabSwitch(from: previousSelectedTabId, to: newTabId)
                previousSelectedTabId = newTabId
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
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification))
        { notification in
            guard let notificationWindow = notification.object as? NSWindow,
                notificationWindow === viewWindow
            else { return }
            isKeyWindow = true
            Task { @MainActor in
                syncSidebarToCurrentTab()
            }
            // Lazy-load: execute query for restored tabs that skipped auto-execute,
            // or re-query tabs whose row data was evicted while inactive.
            // Skip if the user has unsaved changes (in-memory or tab-level).
            let hasPendingEdits =
                changeManager.hasChanges
                || (tabManager.selectedTab?.pendingChanges.hasChanges ?? false)
            let isConnected =
                DatabaseManager.shared.activeSessions[connection.id]?.isConnected ?? false
            let needsLazyLoad =
                tabManager.selectedTab.map { tab in
                    tab.tabType == .table
                        && (tab.resultRows.isEmpty || tab.rowBuffer.isEvicted)
                        && (tab.lastExecutedAt == nil || tab.rowBuffer.isEvicted)
                        && tab.errorMessage == nil
                        && !tab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                } ?? false
            // Skip lazy-load if this is a menu-interaction bounce (resign+become within 200ms)
            let isMenuBounce = Date().timeIntervalSince(lastResignKeyDate) < 0.2
            if needsLazyLoad && !hasPendingEdits && isConnected && !isMenuBounce {
                coordinator.runQuery()
            }

            // Auto-refresh schema for file-based connections (SQLite, DuckDB)
            // when window regains focus — catches external modifications.
            if PluginManager.shared.connectionMode(for: connection.type) == .fileBased && isConnected {
                Task { await coordinator.refreshTablesIfStale() }
            }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification))
        { notification in
            guard let notificationWindow = notification.object as? NSWindow,
                notificationWindow === viewWindow
            else { return }
            isKeyWindow = false
            lastResignKeyDate = Date()

            // Row data eviction only happens under system memory pressure
            // (via MemoryPressureAdvisor), not on window resign. Other DB clients
            // (Beekeeper, DataGrip, TablePlus) keep data in memory until close.
            // Evicting on resign caused re-fetch delays when switching back.
            }
            .onChange(of: tables) { _, newTables in
                let syncAction = SidebarSyncAction.resolveOnTablesLoad(
                    newTables: newTables,
                    selectedTables: sidebarState.selectedTables,
                    currentTabTableName: tabManager.selectedTab?.tableName
                )
                if case .select(let tableName) = syncAction,
                    let match = newTables.first(where: { $0.name == tableName })
                {
                    sidebarState.selectedTables = [match]
                }
            }
            .onChange(of: selectedRowIndices) { _, newIndices in
                if !newIndices.isEmpty,
                    AppSettingsManager.shared.dataGrid.autoShowInspector,
                    tabManager.selectedTab?.tabType == .table
                {
                    RightPanelVisibility.shared.isPresented = true
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
}
