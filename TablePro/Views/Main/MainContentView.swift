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
import os
import SwiftUI
import TableProPluginKit

/// Main content view - thin presentation layer
struct MainContentView: View {
    static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

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
    @State var editingCell: CellPosition?
    @State var commandActions: MainContentCommandActions?
    @State var queryResultsSummaryCache: (tabId: UUID, version: Int, summary: String?)?
    @State var inspectorUpdateTask: Task<Void, Never>?
    @State var lazyLoadTask: Task<Void, Never>?
    /// Stable identifier for this window in WindowLifecycleMonitor
    @State var windowId = UUID()
    @State var hasInitialized = false
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
                let fileName = tab.tableName ?? "query_results"
                if tab.pagination.hasMoreRows, let baseQuery = tab.pagination.baseQueryForMore {
                    ExportDialog(
                        isPresented: dismissBinding,
                        mode: .streamingQuery(
                            connection: connectionWithCurrentDatabase,
                            query: baseQuery,
                            suggestedFileName: fileName
                        )
                    )
                } else {
                    ExportDialog(
                        isPresented: dismissBinding,
                        mode: .queryResults(
                            connection: connectionWithCurrentDatabase,
                            rowBuffer: tab.rowBuffer,
                            suggestedFileName: fileName
                        )
                    )
                }
            }
        case .importDialog:
            let importDismiss = Binding<Bool>(
                get: { coordinator.activeSheet != nil },
                set: { if !$0 {
                    coordinator.activeSheet = nil
                    coordinator.importFileURL = nil
                }}
            )
            ImportDialog(
                isPresented: importDismiss,
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
                let start = Date()
                Self.lifecycleLogger.info(
                    "[open] MainContentView.onAppear start windowId=\(windowId, privacy: .public) connId=\(connection.id, privacy: .public) tabs=\(tabManager.tabs.count)"
                )
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

                // (NSToolbar install moved to `configureWindow(_:)` — at onAppear
                // time `viewWindow` is still nil because WindowAccessor fires its
                // callback on viewDidMoveToWindow, which runs AFTER SwiftUI's
                // onAppear in NSHostingView-hosted content.)

                // Wire view-layer callbacks invoked by TabWindowController's
                // NSWindowDelegate → coordinator lifecycle methods. The closures
                // capture SwiftUI-scoped state (tables binding, sidebarState,
                // rightPanelState) that the coordinator can't reach directly.
                let connectionId = connection.id
                coordinator.onWindowBecameKey = { [tabManager, sidebarState] in
                    // Read tables fresh from DatabaseManager every invocation —
                    // capturing the @Binding's wrappedValue (or `tables`
                    // shorthand) snapshots an empty array at onAppear time
                    // because the schema load is async, and the closure is
                    // installed once but invoked on every windowDidBecomeKey.
                    let liveTables = DatabaseManager.shared
                        .session(for: connectionId)?.tables ?? []
                    let target: Set<TableInfo>
                    if let currentTableName = tabManager.selectedTab?.tableName,
                       let match = liveTables.first(where: { $0.name == currentTableName }) {
                        target = [match]
                    } else {
                        target = []
                    }
                    if sidebarState.selectedTables != target {
                        // Don't clear sidebar selection while tables still loading —
                        // avoids double-navigation race against SidebarSyncAction.
                        if target.isEmpty && liveTables.isEmpty { return }
                        sidebarState.selectedTables = target
                    }
                }
                coordinator.onWindowWillClose = { [rightPanelState] in
                    rightPanelState.teardown()
                }

                Self.lifecycleLogger.info(
                    "[open] MainContentView.onAppear done windowId=\(windowId, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
                )
            }
            .onChange(of: pendingChangeTrigger) {
                updateToolbarPendingState()
            }
    }

    private var bodyContentCore: some View {
        mainContentView
            // Phase 3: SwiftUI `.toolbar { ... }` removed — NSToolbar is now
            // installed directly on NSWindow by TabWindowController (see
            // `MainWindowToolbar`). Reuses every existing SwiftUI subview
            // (ConnectionStatusView, SafeModeBadgeView, popovers, etc.) via
            // `NSHostingView` inside `NSToolbarItem.view`. Connection color
            // tint is not yet ported; `ToolbarTintModifier` no-ops under
            // NSHostingView so leaving the modifier off has no visible loss.
            .task {
                let start = Date()
                Self.lifecycleLogger.info(
                    "[open] bodyContentCore.task initializeAndRestoreTabs start windowId=\(windowId, privacy: .public)"
                )
                await initializeAndRestoreTabs()
                Self.lifecycleLogger.info(
                    "[open] bodyContentCore.task initializeAndRestoreTabs done windowId=\(windowId, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
                )
            }
            .onChange(of: tabManager.selectedTabId) { oldTabId, newTabId in
                guard !coordinator.isTearingDown else {
                    Self.lifecycleLogger.debug("[switch] selectedTabId SKIPPED (tearingDown) to=\(newTabId?.uuidString ?? "nil", privacy: .public) windowId=\(windowId, privacy: .public)")
                    return
                }
                guard oldTabId != nil || newTabId != nil else {
                    Self.lifecycleLogger.debug("[switch] selectedTabId SKIPPED (nil→nil) windowId=\(windowId, privacy: .public)")
                    return
                }
                let seq = MainContentCoordinator.nextSwitchSeq()
                Self.lifecycleLogger.debug(
                    "[switch] selectedTabId changed seq=\(seq) from=\(oldTabId?.uuidString ?? "nil", privacy: .public) to=\(newTabId?.uuidString ?? "nil", privacy: .public) windowId=\(windowId, privacy: .public)"
                )
                (viewWindow?.windowController as? TabWindowController)?.refreshUserActivity()
                handleTabSelectionChange(from: oldTabId, to: newTabId)
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

            .onChange(of: sidebarState.selectedTables) { oldTables, newTables in
                guard !coordinator.isTearingDown else {
                    Self.lifecycleLogger.debug("[switch] sidebarState.selectedTables SKIPPED (tearingDown) windowId=\(windowId, privacy: .public)")
                    return
                }
                handleTableSelectionChange(from: oldTables, to: newTables)
            }
            // Phase 2: NSWindow.didBecomeKey / .didResignKey observers removed.
            // TabWindowController's NSWindowDelegate dispatches to
            // MainContentCoordinator.handleWindowDidBecomeKey / handleWindowDidResignKey
            // directly — window-scoped, fires once per focus change.
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
