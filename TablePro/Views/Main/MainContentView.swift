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
    @Binding var windowSubtitle: String
    @Bindable var schemaService = SchemaService.shared
    var sidebarState: SharedSidebarState
    @Binding var pendingTruncates: Set<String>
    @Binding var pendingDeletes: Set<String>
    @Binding var tableOperationOptions: [String: TableOperationOptions]
    var rightPanelState: RightPanelState

    private var tables: [TableInfo] {
        schemaService.tables(for: connection.id)
    }

    // MARK: - State Objects

    let tabManager: QueryTabManager
    let changeManager: DataChangeManager
    let toolbarState: ConnectionToolbarState
    let coordinator: MainContentCoordinator

    // MARK: - Local State

    @State var commandActions: MainContentCommandActions?
    @State var queryResultsSummaryCache: (tabId: UUID, version: Int, summary: String?)?
    @State var inspectorUpdateTask: Task<Void, Never>?
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
        windowSubtitle: Binding<String>,
        sidebarState: SharedSidebarState,
        pendingTruncates: Binding<Set<String>>,
        pendingDeletes: Binding<Set<String>>,
        tableOperationOptions: Binding<[String: TableOperationOptions]>,
        rightPanelState: RightPanelState,
        tabManager: QueryTabManager,
        changeManager: DataChangeManager,
        toolbarState: ConnectionToolbarState,
        coordinator: MainContentCoordinator
    ) {
        self.connection = connection
        self.payload = payload
        self._windowTitle = windowTitle
        self._windowSubtitle = windowSubtitle
        self.sidebarState = sidebarState
        self._pendingTruncates = pendingTruncates
        self._pendingDeletes = pendingDeletes
        self._tableOperationOptions = tableOperationOptions
        self.rightPanelState = rightPanelState
        self.tabManager = tabManager
        self.changeManager = changeManager
        self.toolbarState = toolbarState
        self.coordinator = coordinator
    }

    // MARK: - Body

    var body: some View {
        bodyContent
            .sheet(item: Bindable(coordinator).activeSheet) { sheet in
                sheetContent(for: sheet)
            }
            .confirmationDialog(
                coordinator.containerDropRequest?.title ?? "",
                isPresented: dropConfirmationBinding,
                titleVisibility: .visible,
                presenting: coordinator.containerDropRequest
            ) { request in
                Button(request.confirmButtonTitle, role: .destructive) {
                    Task { await dropContainers(request) }
                }
                Button(String(localized: "Cancel"), role: .cancel) {
                    coordinator.containerDropRequest = nil
                }
            } message: { request in
                Text(request.message)
            }
    }

    private var dropConfirmationBinding: Binding<Bool> {
        Binding(
            get: { coordinator.containerDropRequest != nil },
            set: { newValue in
                if !newValue { coordinator.containerDropRequest = nil }
            }
        )
    }

    private func dropContainers(_ request: DatabaseDropRequest) async {
        await coordinator.dropContainers(request)
        coordinator.containerDropRequest = nil
    }

    // MARK: - Sheet Content

    /// Connection with the active database from the current session,
    /// so export/import dialogs see the database the user actually switched to.
    private var connectionWithCurrentDatabase: DatabaseConnection {
        var conn = connection
        if let currentDB = DatabaseManager.shared.session(for: connection.id)?.browseDatabase {
            conn.database = currentDB
        }
        return conn
    }

    /// Exporting a container names the database that container lives in, which is not always the
    /// one being browsed. The dialog scopes every list and the export itself to this connection's
    /// database, so naming it here is what makes exporting another database show that database.
    private var exportConnection: DatabaseConnection {
        var conn = connectionWithCurrentDatabase
        if let scoped = coordinator.exportPreselection?.scopedDatabase, !scoped.isEmpty {
            conn.database = scoped
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
            set: {
                if !$0 {
                    coordinator.activeSheet = nil
                    coordinator.exportPreselection = nil
                }
            }
        )

        switch sheet {
        case .createDatabase:
            let viewModel = DatabaseSwitcherViewModel(
                connectionId: connection.id,
                currentDatabase: nil,
                databaseType: connection.type
            )
            CreateDatabaseSheet(
                databaseType: connection.type,
                viewModel: viewModel,
                onCreated: { newDatabaseName in
                    Task { await coordinator.switchContainer(to: newDatabaseName) }
                }
            )
        case .exportDialog:
            let exportConnection = exportConnection
            ExportDialog(
                isPresented: dismissBinding,
                mode: .tables(
                    connection: exportConnection,
                    preselection: coordinator.exportPreselection
                        ?? .tables(Set(coordinator.windowSidebarState.selectedTables.map(\.name)))
                ),
                sidebarTables: tables
            )
        case .exportQueryResults:
            if let tab = coordinator.tabManager.selectedTab {
                let fileName = tab.tableContext.tableName ?? "query_results"
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
                            tableRows: coordinator.tabSessionRegistry.tableRows(for: tab.id),
                            suggestedFileName: fileName
                        )
                    )
                }
            }
        case .importDialog(let formatId):
            let importDismiss = Binding<Bool>(
                get: { coordinator.activeSheet != nil },
                set: { if !$0 {
                    coordinator.activeSheet = nil
                    coordinator.importFileURL = nil
                }
                }
            )
            ImportDialog(
                isPresented: importDismiss,
                connection: connection,
                initialFileURL: coordinator.importFileURL,
                initialFormatId: formatId
            )
        case .rowImport(let formatId):
            let rowDismiss = Binding<Bool>(
                get: { coordinator.activeSheet != nil },
                set: { if !$0 {
                    coordinator.activeSheet = nil
                    coordinator.importFileURL = nil
                }
                }
            )
            if let url = coordinator.importFileURL {
                RowImportSheet(
                    isPresented: rowDismiss,
                    connection: connection,
                    fileURL: url,
                    formatId: formatId
                )
            }
        case .backupDatabase:
            BackupDatabaseFlow(
                isPresented: dismissBinding,
                connection: connectionWithCurrentDatabase,
                initialDatabase: DatabaseManager.shared.session(for: connection.id)?.browseDatabase
                    ?? connection.database
            )
        case .restoreDatabase(let fileURL):
            RestoreDatabaseFlow(
                isPresented: dismissBinding,
                connection: connectionWithCurrentDatabase,
                initialDatabase: DatabaseManager.shared.session(for: connection.id)?.browseDatabase
                    ?? connection.database,
                sourceURL: fileURL
            )
        case .maintenance(let operation, let tableName):
            MaintenanceSheet(
                operation: operation,
                tableName: tableName,
                databaseType: connection.type,
                onExecute: coordinator.executeMaintenance
            )
        case .sqlPreview:
            SQLReviewSheet(
                isPresented: dismissBinding,
                statements: coordinator.toolbarState.previewStatements,
                databaseType: coordinator.toolbarState.databaseType
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
            isFileDirty: tabManager.selectedTab?.content.isFileDirty ?? false,
            hasCreateTablePending: toolbarState.hasCreateTablePending
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
            .task(id: currentTab?.tableContext.tableName) {
                guard currentTab?.execution.lastExecutedAt != nil else { return }
                await loadTableMetadataIfNeeded()
                scheduleInspectorUpdate()
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
                setupCommandActions()
                updateToolbarPendingState()
                updateInspectorContext()
                coordinator.aiViewModel = rightPanelState.aiViewModel
                coordinator.rightPanelState = rightPanelState

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
            .onChange(of: tabManager.tabStructureVersion) { _, _ in
                handleStructureChange()
            }
            .onChange(of: currentTab?.schemaVersion) { _, _ in
                let columns = currentTab.map { coordinator.tabSessionRegistry.tableRows(for: $0.id).columns }
                handleColumnsChange(newColumns: columns)
            }
            .task { handleConnectionStatusChange() }
            .onReceive(
                AppEvents.shared.connectionStatusChanged
                    .filter { $0.connectionId == connection.id }
            ) { _ in
                handleConnectionStatusChange()
            }

            .onChange(of: coordinator.windowSidebarState.selectedTables) { oldTables, newTables in
                guard !coordinator.isTearingDown else {
                    Self.lifecycleLogger.debug("[switch] windowSidebarState.selectedTables SKIPPED (tearingDown) windowId=\(windowId, privacy: .public)")
                    return
                }
                handleTableSelectionChange(from: oldTables, to: newTables)
            }
            /// A background reload of the same container must not take a selection out from under
            /// the user. Every other input re-asserts unconditionally: a container switch above all,
            /// because a selection made in the container being left is not one in the container
            /// arriving.
            .onChange(of: tables) { _, _ in
                guard coordinator.windowSidebarState.acceptsObjectMarkRefresh else { return }
                coordinator.syncSidebarObjectSelection()
            }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContentView: some View {
        MainEditorContentView(
            tabManager: tabManager,
            coordinator: coordinator,
            changeManager: changeManager,
            connection: connection,
            windowId: windowId,
            connectionId: connection.id,
            selectionState: coordinator.selectionState,
            onCellEdit: { rowIndex, colIndex, value in
                coordinator.updateCellInTab(
                    rowIndex: rowIndex, columnIndex: colIndex, value: value)
                scheduleInspectorUpdate()
            },
            onSortStateChanged: { newState in
                coordinator.handleSortStateChanged(newState)
            },
            onAddRow: {
                coordinator.addNewRow()
            },
            onUndoInsert: { rowIndex in
                coordinator.undoInsertRow(at: rowIndex)
            },
            onSelectionChange: { newIndices in
                if !newIndices.isEmpty,
                    AppSettingsManager.shared.dataGrid.autoShowInspector,
                    tabManager.selectedTab?.tabType == .table
                {
                    coordinator.inspectorProxy?.showInspector()
                }
                scheduleInspectorUpdate()
            },
            onFilterColumn: { columnName in
                coordinator.addFilterForColumn(columnName)
            },
            onApplyFilters: { filters in
                coordinator.applyFilters(filters)
            },
            onClearFilters: {
                coordinator.clearFiltersAndReload()
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
            onPageSizeChange: { newSize in
                coordinator.updatePageSize(newSize)
            },
            onShowAll: {
                coordinator.showAllRows()
            },
            onGoToPage: { page in
                coordinator.goToPage(page)
            }
        )
    }
}
