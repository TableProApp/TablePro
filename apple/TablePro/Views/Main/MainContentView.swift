//
//  MainContentView.swift
//  TablePro
//

import Combine
import os
import SwiftUI
import TableProPluginKit

struct MainContentView: View {
    nonisolated static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    // MARK: - Properties

    let connection: DatabaseConnection
    // nil means the default query tab.
    let payload: EditorTabPayload?

    // Shared state from parent
    @Binding var windowTitle: String
    @Binding var windowSubtitle: String
    @Binding var windowRepresentedURL: URL?
    @ObservedObject var schemaService = SchemaService.shared
    @ObservedObject var sidebarState: SharedSidebarState
    @Binding var pendingTruncates: Set<DatabaseTreeTableRef>
    @Binding var pendingDeletes: Set<DatabaseTreeTableRef>
    @Binding var tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions]
    @ObservedObject var trailingPaneState: TrailingPaneState

    var tables: [TableInfo] {
        schemaService.tables(for: connection.id)
    }

    // MARK: - State Objects

    @ObservedObject var tabManager: QueryTabManager
    @ObservedObject var changeManager: DataChangeManager
    @ObservedObject var toolbarState: ConnectionToolbarState
    @ObservedObject var coordinator: MainContentCoordinator

    // MARK: - Local State

    @State var commandActions: MainContentCommandActions?
    @State var queryResultsSummaryCache: (tabId: UUID, version: Int, summary: String?)?
    @State var inspectorUpdateTask: Task<Void, Never>?
    @State var inspectorContextRefreshTask: Task<Void, Never>?
    @State var windowId = UUID()
    @State var viewWindow: NSWindow?

    // MARK: - Environment


    // MARK: - Initialization

    init(
        connection: DatabaseConnection,
        payload: EditorTabPayload?,
        windowTitle: Binding<String>,
        windowSubtitle: Binding<String>,
        windowRepresentedURL: Binding<URL?>,
        sidebarState: SharedSidebarState,
        pendingTruncates: Binding<Set<DatabaseTreeTableRef>>,
        pendingDeletes: Binding<Set<DatabaseTreeTableRef>>,
        tableOperationOptions: Binding<[DatabaseTreeTableRef: TableOperationOptions]>,
        trailingPaneState: TrailingPaneState,
        tabManager: QueryTabManager,
        changeManager: DataChangeManager,
        toolbarState: ConnectionToolbarState,
        coordinator: MainContentCoordinator
    ) {
        self.connection = connection
        self.payload = payload
        self._windowTitle = windowTitle
        self._windowSubtitle = windowSubtitle
        self._windowRepresentedURL = windowRepresentedURL
        self.sidebarState = sidebarState
        self._pendingTruncates = pendingTruncates
        self._pendingDeletes = pendingDeletes
        self._tableOperationOptions = tableOperationOptions
        self.trailingPaneState = trailingPaneState
        self.tabManager = tabManager
        self.changeManager = changeManager
        self.toolbarState = toolbarState
        self.coordinator = coordinator
    }

    // MARK: - Body

    var body: some View {
        bodyContent
            .sheet(item: $coordinator.activeSheet) { sheet in
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

    // Export and import dialogs need the database the user switched to, not the saved one.
    var connectionWithCurrentDatabase: DatabaseConnection {
        var conn = connection
        if let currentDB = DatabaseManager.shared.session(for: connection.id)?.browseDatabase {
            conn.database = currentDB
        }
        return conn
    }

    // Exporting another database's container has to name that database; the dialog scopes everything to this one.
    var exportConnection: DatabaseConnection {
        var conn = connectionWithCurrentDatabase
        if let scoped = coordinator.exportPreselection?.scopedDatabase, !scoped.isEmpty {
            conn.database = scoped
        }
        return conn
    }

    // Its own function: sheetContent(for:) switches over every sheet and is already at the function length limit.
    @ViewBuilder
    func transferSheet(tables: Set<String>, schema: String?, dismiss: Binding<Bool>) -> some View {
        TableTransferSheet(
            isPresented: dismiss,
            sourceConnection: connectionWithCurrentDatabase,
            preselectedTables: tables,
            preselectedSchema: schema
        )
    }

    @ViewBuilder
    private func sheetContent(for sheet: ActiveSheet) -> some View {
        let dismissBinding = Binding<Bool>(
            get: { coordinator.activeSheet != nil },
            set: {
                if !$0 {
                    coordinator.activeSheet = nil
                    coordinator.exportPreselection = nil
                    coordinator.exportFormatId = nil
                    // Cleared on every dismissal: the request's closure holds this coordinator, so a kept one leaks and offers a stale plan.
                    coordinator.tableRebuildRequest = nil
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
        case .createSchema(let database):
            SchemaEditorSheet(
                model: SchemaEditorViewModel(
                    mode: .create,
                    connectionId: connection.id,
                    databaseType: connection.type,
                    database: database ?? coordinator.browseDatabaseName,
                    services: coordinator.services
                ),
                onCompleted: { newSchemaName in
                    Task { await coordinator.switchSchemaAfterCreate(in: database, to: newSchemaName) }
                }
            )
        case .editSchema(let container):
            SchemaEditorSheet(
                model: SchemaEditorViewModel(
                    mode: .edit(container.schema ?? container.name),
                    connectionId: connection.id,
                    databaseType: connection.type,
                    database: container.database ?? coordinator.browseDatabaseName,
                    services: coordinator.services
                ),
                onCompleted: { editedSchemaName in
                    Task { await coordinator.adoptSchemaEdit(container, renamedTo: editedSchemaName) }
                }
            )
        case .copyObjects(let launch):
            CopyObjectsSheet(launch: launch, connection: connection)
        case .editObjectComment(let target):
            ObjectCommentSheet(target: target, connection: connection)
        case .setSequenceNextValue(let target):
            SetSequenceValueSheet(target: target, connection: connection)
        case .editSequence(let target):
            EditSequenceSheet(target: target, connection: connection)
        case .documentEditor(let request):
            DocumentEditorSheet(request: request, databaseType: connection.type)
        case .createUserType(let database, let schema):
            CreateUserTypeSheet(
                connection: connection,
                database: database ?? coordinator.browseDatabaseName,
                schema: schema,
                onCreated: { definition in
                    coordinator.openCreatedUserType(definition, database: database ?? coordinator.browseDatabaseName)
                }
            )
        case .searchDatabase(let session):
            DatabaseSearchSheet(session: session) { result in
                coordinator.openDatabaseSearchResult(result, in: session)
            }
        case .joinBuilder(let launch):
            JoinBuilderSheet(model: JoinBuilderViewModel(launch: launch, connection: connection)) { sql in
                coordinator.openJoinQuery(sql, database: launch.database)
            }
        case .generateRows(let session):
            GenerateRowsSheet(session: session)
        case .exportDialog, .exportQueryResults, .importDialog, .rowImport, .rowImportBatch,
             .transferTables, .backupDatabase, .restoreDatabase:
            transferSheetContent(for: sheet, dismiss: dismissBinding)
        case .maintenance(let operation, let tableName, let database, let schema):
            MaintenanceSheet(
                operation: operation,
                tableName: tableName,
                databaseName: database ?? coordinator.browseDatabaseName,
                databaseType: connection.type,
                preview: { options in
                    coordinator.maintenancePreview(
                        operation: operation,
                        tableName: tableName,
                        schema: schema,
                        options: options
                    )
                },
                onExecute: { options in
                    coordinator.executeMaintenance(
                        operation: operation,
                        tableName: tableName,
                        options: options,
                        database: database,
                        schema: schema
                    )
                }
            )
        case .sqlPreview:
            sqlPreviewSheet(dismiss: dismissBinding)
        case .rewind:
            if let plan = coordinator.rewindPlan {
                RewindReviewSheet(plan: plan) {
                    await coordinator.applyRewind()
                }
            }
        case .tableRebuildReview:
            if let request = coordinator.tableRebuildRequest {
                SQLReviewSheet(
                    isPresented: dismissBinding,
                    statements: request.scriptStatements,
                    databaseType: connection.type,
                    title: request.confirmationTitle,
                    subtitle: request.confirmationSubtitle(connectionName: connection.name),
                    showsStatementsVerbatim: request.showsStatementsVerbatim,
                    warning: request.warning,
                    primaryAction: request.runnableAction.map { action in
                        SQLReviewSheet.PrimaryAction(
                            title: action.title,
                            isDestructive: true,
                            perform: {
                                await action.perform()
                                coordinator.tableRebuildRequest = nil
                                coordinator.activeSheet = nil
                            }
                        )
                    },
                    onOpenInEditor: {
                        coordinator.openTableRebuildScriptInEditor(request)
                    }
                )
            }
        }
    }

    // A structure session's preview offers its Save; a grid preview only shows what Save would write.
    private func sqlPreviewSheet(dismiss: Binding<Bool>) -> SQLReviewSheet {
        SQLReviewSheet(
            isPresented: dismiss,
            statements: coordinator.toolbarState.previewStatements,
            databaseType: coordinator.toolbarState.databaseType,
            primaryAction: coordinator.activeStructureSession.flatMap { session -> SQLReviewSheet.PrimaryAction? in
                guard session.hasChanges else { return nil }
                return SQLReviewSheet.PrimaryAction(
                    title: String(localized: "Save Changes"),
                    isDestructive: false,
                    work: .immediate {
                        coordinator.activeSheet = nil
                        session.save()
                    }
                )
            }
        )
    }

    private var pendingChangeTrigger: PendingChangeTrigger {
        PendingChangeTrigger(
            hasDataChanges: changeManager.hasChanges,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            hasStructureChanges: selectedStructureSession?.hasChanges ?? false,
            diagramEditsRevision: toolbarState.diagramEditsRevision,
            selectedTabId: tabManager.selectedTabId,
            isFileDirty: tabManager.selectedTab?.content.isFileDirty ?? false,
            hasCreateTablePending: toolbarState.hasCreateTablePending,
            hasPrincipalChanges: toolbarState.hasPrincipalChanges,
            hasTypeChanges: toolbarState.hasTypeChanges
        )
    }

    // Split in two to help the Swift type checker with the long modifier chain.
    private var bodyContent: some View {
        bodyContentCore
            .background {
                WindowAccessor { window in
                    configureWindow(window)
                }
            }
            .modifier(TableInfoLoadModifier(
                inspector: trailingPaneState.inspector,
                tab: currentTab,
                table: currentTab.flatMap { coordinator.tableInfoIdentity(of: $0) }
            ) { [coordinator] tab in
                await coordinator.loadTableMetadata(for: tab)
            })
            .modifier(InspectorValueLoadModifier(
                inspector: trailingPaneState.inspector,
                model: gridSelectionOwner == .dataGrid ? coordinator.activeGridModel : nil,
                tabId: currentTab?.id,
                contentVersion: currentTab?.schemaVersion ?? 0
            ) { [coordinator] tabId, rowID in
                await coordinator.loadInspectorRowValues(tabId: tabId, rowID: rowID)
            })
            .background {
                if let model = coordinator.activeGridModel {
                    GridSelectionWatcher(
                        model: model,
                        onAttach: { scheduleInspectorUpdate() },
                        onChange: { rowsChanged in handleGridSelectionChange(rowsChanged: rowsChanged) }
                    )
                    .id(ObjectIdentifier(model))
                }
            }
            .background {
                if let session = selectedStructureSession {
                    StructureChangeWatcher(session: session) {
                        updateToolbarPendingState()
                        coordinator.refreshUnsavedIndicator()
                    }
                    .id(ObjectIdentifier(session))
                }
            }
            .onReceive(coordinator.gridCellsEdited) { _ in
                scheduleInspectorUpdate()
            }
            // Keyed on the connection alone: Snowflake, the only driver that answers, pays two round trips for it.
            .task(id: coordinator.toolbarState.connectionState) {
                await coordinator.loadSessionContexts()
            }
            .onChange(of: inspectorTrigger) { _ in
                scheduleInspectorUpdate()
            }
            // Only the snapshot: rebuilding the edit state would end a typed undo run.
            .onChange(of: tableMetadataForCurrentTab) { _ in
                updateInspectorContext()
            }
            // An edit in the fields rendering moves nothing InspectorTrigger watches; the two renderings are never on screen together.
            .onValueChange(of: \.viewMode, in: trailingPaneState.inspector) { _, _ in
                updateInspectorContext()
            }
            // Debounced: a detached value window commits per keystroke, and rebuilding the JSON tree cancels the reader's fetches.
            .onReceive(coordinator.inspectorRowContentChanged) { _ in
                scheduleInspectorContextRefresh()
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
                coordinator.trailingPaneState = trailingPaneState
                trailingPaneState.assistant.editorSnapshot = { [weak coordinator = self.coordinator] in
                    coordinator?.assistantEditorSnapshot ?? .empty
                }

                Self.lifecycleLogger.info(
                    "[open] MainContentView.onAppear done windowId=\(windowId, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
                )
            }
            .onChange(of: trailingPaneState.assistant.isActivated) { _ in
                updateAssistantContext()
            }
            .onChange(of: pendingChangeTrigger) { _ in
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
            .onValueChange(of: tabManager.selectedTabId) { oldTabId, newTabId in
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
            .onChange(of: tabManager.tabStructureVersion) { _ in
                handleStructureChange()
            }
            .onChange(of: currentTab?.schemaVersion) { _ in
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

            .onValueChange(of: \.selectedTables, in: coordinator.windowSidebarState) { oldTables, newTables in
                guard !coordinator.isTearingDown else {
                    Self.lifecycleLogger.debug("[switch] windowSidebarState.selectedTables SKIPPED (tearingDown) windowId=\(windowId, privacy: .public)")
                    return
                }
                handleTableSelectionChange(from: oldTables, to: newTables)
            }
            // A background reload of the same container must not take the selection out from under the user.
            .onChange(of: tables) { _ in
                guard coordinator.windowSidebarState.acceptsObjectMarkRefresh else { return }
                coordinator.syncSidebarObjectSelection()
            }
    }

    // Any grid's selection counts, a query result's as much as a table's: the setting is "on row select", not on cursor moves.
    private func handleGridSelectionChange(rowsChanged: Bool) {
        if rowsChanged,
           coordinator.activeGridModel?.selection.isEmpty == false,
           AppSettingsManager.shared.dataGrid.autoShowInspector {
            coordinator.trailingPaneProxy?.revealInspectorForSelection()
        }
        scheduleInspectorUpdate()
    }

    // MARK: - Main Content

    private var mainContentView: some View {
        VStack(spacing: 0) {
            if let warning = toolbarState.connectionWarning {
                ConnectionWarningBanner(message: warning) {
                    DatabaseManager.shared.dismissConnectionWarning(for: connection.id)
                }
                Divider()
            }
            ConnectionTransactionBar(
                connectionId: connection.id,
                transactions: DatabaseManager.shared.sessionTransactions,
                databaseManager: DatabaseManager.shared
            )
            editorContentView
        }
        .onChange(of: toolbarState.connectionWarning) { warning in
            announceConnectionWarning(warning)
        }
    }

    @ViewBuilder
    private var editorContentView: some View {
        MainEditorContentView(
            tabManager: tabManager,
            coordinator: coordinator,
            historyState: HistoryPanelState.forConnection(connection.id),
            changeManager: changeManager,
            connection: connection,
            windowId: windowId,
            connectionId: connection.id,
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

// No view of this window observes a session whose Structure view is not on screen, yet Discard and Save change it there.
private struct StructureChangeWatcher: View {
    @ObservedObject var session: StructureEditingSession
    let onChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: session.hasChanges) { _ in onChange() }
    }
}
