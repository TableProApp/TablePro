//
//  MainEditorContentView.swift
//  TablePro
//
//  Main editor content view containing tab bar and tab content.
//  Extracted from MainContentView for better separation.
//

import AppKit
import SwiftUI
import TableProEditorKit
import TableProPluginKit

// Only a tab showing rows reruns: an error, a plan or a write's count is not a view of the new database's data.
@MainActor
internal enum ContainerChangeRerunPolicy {
    internal static func reruns(showing activeResult: ResultSet?) -> Bool {
        guard let activeResult else { return false }
        return activeResult.errorMessage == nil
            && !activeResult.isExplainResult
            && !activeResult.resultColumns.isEmpty
    }
}

struct MainEditorContentView: View {
    @ObservedObject private var schemaService = SchemaService.shared
    @ObservedObject private var featureAccess = FeatureAccess.shared
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    // Must clear the nested editor/results split's required minimums, or dragging the drawer asks AppKit for an unreachable height.
    static let tabContentMinimumHeight = CollapsibleSplitController.combinedMinimumThickness

    // MARK: - Dependencies

    @ObservedObject var tabManager: QueryTabManager
    @ObservedObject var coordinator: MainContentCoordinator

    // Handed in, not resolved in `body` where nothing would observe it: the drawer state is a per-connection singleton.
    @ObservedObject var historyState: HistoryPanelState
    @ObservedObject var changeManager: DataChangeManager
    let connection: DatabaseConnection
    let windowId: UUID
    let connectionId: UUID

    // MARK: - Callbacks

    let onFirstPage: () -> Void
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let onLastPage: () -> Void
    let onPageSizeChange: (Int) -> Void
    let onShowAll: () -> Void
    let onGoToPage: (Int) -> Void

    @State private var queryPlanViewStates = QueryPlanViewStateStore()
    @State private var serverDashboardViewModels: [UUID: ServerDashboardViewModel] = [:]
    @State private var usersRolesViewModels: [UUID: UsersRolesViewModel] = [:]
    @State private var queryInsightsViewModels: [UUID: QueryInsightsViewModel] = [:]
    @State private var tableListingModels = TableListingModelStore()

    @ObservedObject private var treeService = DatabaseTreeMetadataService.shared
    // Table highlight rules live here, not on the tab; unobserved, Add Rule on a table tab changed nothing on screen.
    @ObservedObject private var highlightRuleStorage = HighlightRuleStorage.shared

    // The tip is answered once history has been on screen, now the trailing pane rather than a drawer under the editor.
    private var showsHistoryTip: Bool {
        let historyState = HistoryPanelState.forConnection(connectionId)
        return !historyState.isVisible && !historyState.isCapturePaused
    }

    // MARK: - Body

    var body: some View {
        EditorAreaHost(input: EditorAreaInput(
            content: editorAreaContent,
            history: AnyView(HistoryPanelView(coordinator: coordinator)),
            isHistoryCollapsed: Binding(
                get: { !historyState.isVisible },
                set: { historyState.isVisible = !$0 }
            ),
            historyAutosaveName: SplitViewAutosaveName.historyDrawer(connectionId: connectionId),
            contentMinimumHeight: Self.tabContentMinimumHeight
        ))
        .onAppear {
            if let tabId = selectedQueryTab?.id {
                coordinator.clearRestoredCursor(for: tabId)
            }
        }
        // The editor applies a tab's saved selection when the query tab appears; it is then spent.
        .onChange(of: selectedQueryTab?.id == nil) { isNotQuery in
            guard !isNotQuery, let tabId = selectedQueryTab?.id else { return }
            coordinator.clearRestoredCursor(for: tabId)
        }
        .task(id: selectedQueryScope) {
            guard let selectedQueryScope else { return }
            await SchemaProviderRegistry.shared.prepare(
                for: selectedQueryScope,
                connection: coordinator.connection
            )
        }
        .onAppear {
            if historyState.isVisible {
                if #available(macOS 14.0, *) {
                    FeatureTipSignals.queryHistoryShown()
                }
            }
        }
        .onChange(of: historyState.isVisible) { isVisible in
            if isVisible {
                if #available(macOS 14.0, *) {
                    FeatureTipSignals.queryHistoryShown()
                }
            }
        }
        .sheet(item: Binding(
            get: { coordinator.favoriteDialogQuery },
            set: { coordinator.favoriteDialogQuery = $0 }
        )) { item in
            FavoriteEditDialog(
                connectionId: connectionId,
                favorite: nil,
                initialQuery: item.query,
                folders: []
            )
        }
        .sheet(item: Binding(
            get: { coordinator.fileConflictRequest },
            set: { coordinator.fileConflictRequest = $0 }
        )) { request in
            FileConflictDiffSheet(
                fileName: request.url.lastPathComponent,
                mineContent: request.mineContent,
                diskContent: request.diskContent,
                onKeepMine: {
                    coordinator.commandActions?.writeTabContent(
                        tabId: request.tabId,
                        content: request.mineContent,
                        to: request.url
                    )
                    coordinator.fileConflictRequest = nil
                },
                onReload: {
                    coordinator.commandActions?.reloadFileFromDisk(tabId: request.tabId, url: request.url)
                    coordinator.fileConflictRequest = nil
                },
                onCancel: {
                    coordinator.fileConflictRequest = nil
                }
            )
        }
        .onChange(of: tabManager.tabStructureVersion) { _ in
            let openTabIds = Set(tabManager.tabIds)
            coordinator.cleanupTabCaches(openTabIds: openTabIds)
            queryPlanViewStates.retainTabs(openTabIds)
            serverDashboardViewModels = serverDashboardViewModels.filter { openTabIds.contains($0.key) }
            usersRolesViewModels = usersRolesViewModels.filter { openTabIds.contains($0.key) }
            queryInsightsViewModels = queryInsightsViewModels.filter { openTabIds.contains($0.key) }
            tableListingModels.retainTabs(openTabIds)
            SchemaProviderRegistry.shared.reclaimUnheldProviders(for: connectionId)
        }
        .onChange(of: tabManager.selectedTabId) { _ in
            updateHasQueryText()
        }
        .onAppear {
            updateHasQueryText()
        }
        .task(id: tabManager.selectedTabId) {
            coordinator.lazyLoadCurrentTabIfNeeded()
        }
    }

    // MARK: - Tab Content

    private var selectedQueryTab: QueryTab? {
        guard let tab = tabManager.selectedTab, tab.tabType == .query else { return nil }
        return tab
    }

    private var selectedQueryScope: DatabaseScope? {
        selectedQueryTab.flatMap { coordinator.scope(for: $0) }
    }

    private var editorAreaContent: EditorAreaContent {
        guard let tab = tabManager.selectedTab else { return .view(AnyView(emptyStateView)) }
        if tab.tabType == .query {
            return .query(queryTabInput(tab: tab))
        }
        return .view(AnyView(tabContent(for: tab)))
    }

    @ViewBuilder
    private func tabContent(for tab: QueryTab) -> some View {
        switch tab.tabType {
        case .query:
            EmptyView()
        case .table:
            tableTabContent(tab: tab)
        case .createTable:
            createTableContent(tab: tab)
        case .erDiagram:
            erDiagramContent(tab: tab)
        case .serverDashboard:
            serverDashboardContent(tab: tab)
        case .usersRoles:
            usersRolesContent(tab: tab)
        case .insights:
            queryInsightsContent(tab: tab)
        case .objectSource:
            objectSourceContent(tab: tab)
        case .versionHistory:
            versionHistoryContent(tab: tab)
        case .tableListing:
            tableListingContent(tab: tab)
        case .routineDebug:
            RoutineDebugTabContent(tabId: tab.id, databaseType: connection.type)
                .id(tab.id)
        }
    }

    // MARK: - Table Listing Tab Content

    private func tableListingContent(tab: QueryTab) -> some View {
        let model = tableListingModels.model(forTab: tab.id) {
            TableListingViewModel(
                tabId: tab.id,
                scope: DatabaseScope(
                    connectionId: connection.id,
                    database: tab.tableContext.databaseName,
                    schema: tab.tableContext.schemaName
                ),
                loader: TableListingLoader(
                    databaseType: connection.type,
                    slot: EngineNamespaceSlot(databaseType: connection.type)
                )
            )
        }
        return TableListingTabView(model: model, databaseType: connection.type)
            .id(tab.id)
    }

    // MARK: - Version History Tab Content

    @ViewBuilder
    private func versionHistoryContent(tab: QueryTab) -> some View {
        if let subject = tab.display.versionHistorySubject {
            VersionHistoryTabView(
                tabId: tab.id,
                subject: subject,
                databaseType: connection.type,
                exportFileName: Self.versionHistoryExportName(for: subject, title: tab.title),
                onOpenInEditor: { content in
                    coordinator.openVersionInEditor(content)
                }
            )
            .id(subject)
        } else {
            UnavailableStateView(
                String(localized: "No History"),
                systemImage: "clock.arrow.circlepath"
            )
        }
    }

    private static func versionHistoryExportName(for subject: VersionHistorySubject, title: String) -> String {
        switch subject {
        case .linkedFile(let url):
            return url.lastPathComponent
        case .savedQuery:
            return "query.sql"
        }
    }

    // MARK: - Object Source Tab Content

    @ViewBuilder
    private func objectSourceContent(tab: QueryTab) -> some View {
        if let objectRef = tab.display.objectRef, objectRef.kind == .userType {
            userTypeContent(tab: tab, objectRef: objectRef)
        } else if let objectRef = tab.display.objectRef {
            ObjectSourceTabView(
                connectionId: connection.id,
                databaseType: connection.type,
                objectRef: objectRef,
                onOpenInEditor: { source in
                    coordinator.openObjectSourceInEditor(objectRef, source: source)
                }
            )
            .id(objectRef)
        } else {
            UnavailableStateView(
                String(localized: "No Object"),
                systemImage: "questionmark.square.dashed"
            )
        }
    }

    // MARK: - Query Insights Tab Content

    private func queryInsightsContent(tab: QueryTab) -> some View {
        Group {
            if let vm = queryInsightsViewModels[tab.id] {
                QueryInsightsView(viewModel: vm, coordinator: coordinator)
            } else {
                ProgressView(String(localized: "Loading insights…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        guard queryInsightsViewModels[tab.id] == nil else { return }
                        queryInsightsViewModels[tab.id] = QueryInsightsViewModel(
                            connectionId: connection.id,
                            history: QueryHistoryManager.shared
                        )
                    }
            }
        }
        .id(tab.id)
    }

    // MARK: - Users & Roles Tab Content

    @ViewBuilder
    private func usersRolesContent(tab: QueryTab) -> some View {
        Group {
            if let vm = usersRolesViewModels[tab.id] {
                UsersRolesTabView(viewModel: vm, coordinator: coordinator, tabID: tab.id)
            } else {
                ProgressView(String(localized: "Loading users and roles…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        guard usersRolesViewModels[tab.id] == nil else { return }
                        let vm = UsersRolesViewModel(
                            connectionId: connection.id,
                            databaseType: connection.type
                        )
                        usersRolesViewModels[tab.id] = vm
                    }
            }
        }
        .id(tab.id)
    }

    // MARK: - Server Dashboard Tab Content

    @ViewBuilder
    private func serverDashboardContent(tab: QueryTab) -> some View {
        Group {
            if let vm = serverDashboardViewModels[tab.id] {
                ServerDashboardView(viewModel: vm)
            } else {
                ProgressView(String(localized: "Loading dashboard…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        guard serverDashboardViewModels[tab.id] == nil else { return }
                        let vm = ServerDashboardViewModel(
                            connectionId: connection.id,
                            databaseType: connection.type
                        )
                        serverDashboardViewModels[tab.id] = vm
                    }
            }
        }
        .id(tab.id)
    }

    // MARK: - ER Diagram Tab Content

    @ViewBuilder
    private func erDiagramContent(tab: QueryTab) -> some View {
        Group {
            if let vm = coordinator.erDiagramModels[tab.id] {
                ERDiagramView(viewModel: vm, onBuildJoinQuery: buildJoinQuery(from: vm))
            } else {
                ProgressView(String(localized: "Loading schema…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        guard coordinator.erDiagramModels[tab.id] == nil else { return }
                        let vm = ERDiagramViewModel(
                            connectionId: connection.id,
                            databaseName: tab.tableContext.databaseName,
                            schemaKey: tab.display.erDiagramSchemaKey ?? tab.tableContext.databaseName,
                            connection: connection
                        )
                        vm.coordinator = coordinator
                        vm.tabId = tab.id
                        coordinator.erDiagramModels[tab.id] = vm
                    }
            }
        }
        .id(tab.id)
    }

    private func buildJoinQuery(from diagram: ERDiagramViewModel) -> (([String]) -> Void)? {
        guard coordinator.canBuildJoinQuery else { return nil }
        let coordinator = coordinator
        return { tables in
            coordinator.openJoinBuilder(database: diagram.databaseName, schema: diagram.schemaName, tables: tables)
        }
    }

    // MARK: - Per-tab container picker

    private var containerSwitchTarget: ContainerSwitchTarget? {
        PluginManager.shared.containerSwitchTarget(for: connection.type)
    }

    private func containerDatabases(for tab: QueryTab) -> [DatabaseMetadata] {
        switch containerSwitchTarget {
        case .database:
            return DatabaseSwitchList.sections(
                databases: treeService.databases(for: connectionId),
                selected: SharedSidebarState.forConnection(connectionId).databaseFilterSelected,
                activeDatabase: containerName(for: tab)
            ).all
        case .schema:
            return schemaService.schemas(for: connectionId).map { DatabaseMetadata.minimal(name: $0) }
        case nil:
            return []
        }
    }

    private var isContainerSwitchReadOnly: Bool {
        guard containerSwitchTarget == .database else { return false }
        return PluginManager.shared.requiresReconnectForDatabaseSwitch(for: connection.type)
    }

    private var containerEntityName: String {
        PluginManager.shared.containerEntityName(for: connection.type)
    }

    // Read from the tab's own scope, which completion also resolves against, so the two never name different databases.
    private func containerName(for tab: QueryTab) -> String {
        if containerSwitchTarget == .schema {
            return coordinator.scope(for: tab)?.schema ?? tab.tableContext.schemaName ?? ""
        }
        if let scoped = coordinator.scope(for: tab)?.database, !scoped.isEmpty { return scoped }
        let bound = tab.tableContext.databaseName
        return bound.isEmpty ? coordinator.browseDatabaseName : bound
    }

    // Only beside a database: where the container is the schema, the picker already names it.
    private func containerSchemaName(for tab: QueryTab) -> String? {
        guard containerSwitchTarget == .database else { return nil }
        return coordinator.scope(for: tab)?.schema
    }

    // The tab owns the new container for life, so it moves to that entry and the window follows, like selecting its tab.
    private func changeContainer(for tab: QueryTab, to name: String) {
        let tabId = tab.id
        guard tabManager.containerName(of: tab) != name,
              tabManager.mutate(tabId: tabId, { tab in
                  QueryContainerRebinding.rebind(&tab.tableContext, to: name, target: containerSwitchTarget)
              }) else { return }
        tabManager.markTabRenamed(tabId)
        SchemaProviderRegistry.shared.reclaimUnheldProviders(for: connectionId)
        guard tabManager.selectedTabId == tabId,
              ContainerChangeRerunPolicy.reruns(showing: tabManager.selectedTab?.display.activeResultSet) else { return }
        // The statement at the caret may not be the one that produced the rows, so a write asks first.
        coordinator.runQuery(viewport: .firstRow, extraCapabilities: .confirmsWrites)
    }

    private func dismissDiskChangeBanner(tabId: UUID) {
        coordinator.tabManager.mutate(tabId: tabId) { FileTabBaseline.dismissDiskChange(in: &$0.content) }
    }

    // Two facts, not one: the window's toolbar outlives every tab, so unlike the old in-view button it cannot assume a query tab.
    private func updateHasQueryText() {
        coordinator.syncQueryToolbarStateForSelectedTab()
    }

    private func queryTextBinding(for tab: QueryTab) -> Binding<String> {
        let tabId = tab.id
        let fallbackQuery = tab.content.query
        return Binding(
            get: {
                tabManager.tabs.first(where: { $0.id == tabId })?.content.query ?? fallbackQuery
            },
            set: { newValue in
                // By ID: mid-switch, flushTextUpdate() fires for the old tab while selectedTabIndex already points to the new one.
                guard tabManager.mutate(tabId: tabId, { $0.content.query = newValue }) else { return }

                coordinator.scheduleDraftSave()

                // Scratch tabs dirty too. Only this tab's window: a background window tab's editor stays mounted and can fire here.
                guard tabId == tabManager.selectedTabId,
                      let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
                      let window = coordinator.contentWindow else { return }
                let showsIndicator = coordinator.showsUnsavedIndicator(for: tabManager.tabs[index])
                Task { @MainActor in
                    window.isDocumentEdited = showsIndicator
                }
            }
        )
    }

    private func parameterBinding(for tab: QueryTab) -> Binding<[QueryParameter]> {
        let tabId = tab.id
        return Binding(
            get: { tab.content.queryParameters },
            set: { newValue in
                tabManager.mutate(tabId: tabId) { $0.content.queryParameters = newValue }
            }
        )
    }

    private func parameterVisibilityBinding(for tab: QueryTab) -> Binding<Bool> {
        let tabId = tab.id
        return Binding(
            get: { tab.content.isParameterPanelVisible },
            set: { newValue in
                tabManager.mutate(tabId: tabId) { $0.content.isParameterPanelVisible = newValue }
            }
        )
    }

    // MARK: - Table Tab Content

    @ViewBuilder
    private func tableTabContent(tab: QueryTab) -> some View {
        VStack(spacing: 0) {
            if tab.isPreview, #available(macOS 14.0, *) {
                FeatureTipInline(tip: KeepTableOpenTip())
            }
            resultsSection(tab: tab)
        }
    }

    // MARK: - Results Section

    @ViewBuilder
    private func executionErrorBanner(tab: QueryTab) -> some View {
        if let error = tab.display.activeResultSet?.errorMessage ?? tab.execution.errorMessage {
            InlineErrorBanner(
                message: error,
                onFixWithAI: coordinator.aiQueryActionAvailability(for: tab).isVisible
                    ? { coordinator.fixErrorWithAI(query: tab.execution.errorQuery ?? tab.content.query, error: error) }
                    : nil,
                onDismiss: {
                    tabManager.mutate(tabId: tab.id) {
                        $0.display.activeResultSet?.errorMessage = nil
                        $0.execution.errorMessage = nil
                        $0.execution.errorQuery = nil
                    }
                }
            )
            Divider()
        }
    }

    private func structureScope(for tab: QueryTab) -> DatabaseScope? {
        coordinator.scope(for: tab)
    }

    // The draft is cached here because the view is destroyed as soon as the tab is deselected.
    @ViewBuilder
    private func createTableContent(tab: QueryTab) -> some View {
        Group {
            if let draft = coordinator.createTableDrafts[tab.id] {
                CreateTableView(
                    connection: connection,
                    scope: structureScope(for: tab),
                    coordinator: coordinator,
                    draft: draft
                )
            } else {
                Color.clear
                    .onAppear { coordinator.createTableDrafts[tab.id] = CreateTableDraft() }
            }
        }
        .id(tab.id)
    }

    // Session cached by tab.id (a table-name key let two tabs share @State); the identity check forces a remount on retarget.
    @ViewBuilder
    private func structureContent(tab: QueryTab, tableName: String) -> some View {
        let scope = structureScope(for: tab)
        let binding = scope?.isSessionBound == true ? "#session" : ""
        let identity = "\(scope?.qualifiedDescription ?? "").\(tableName)\(binding)"
        Group {
            if let session = coordinator.structureSessions[tab.id], session.identity == identity {
                TableStructureView(
                    tableName: tableName,
                    connection: connection,
                    databaseName: scope?.database ?? "",
                    schemaName: scope?.schema,
                    toolbarState: coordinator.toolbarState,
                    coordinator: coordinator,
                    session: session
                )
            } else {
                Color.clear
                    .onAppear {
                        coordinator.structureSessions[tab.id] = StructureEditingSession(
                            identity: identity,
                            connection: connection,
                            databaseName: scope?.database ?? "",
                            schemaName: scope?.schema,
                            isSessionBound: scope?.isSessionBound ?? false,
                            tableName: tableName,
                            objectKind: tab.tableContext.resolvedObjectKind(),
                            serverSupport: StructureServerSupport.forConnection(connection.id)
                        )
                    }
            }
        }
        .id(tab.id)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func resultsSection(tab: QueryTab) -> some View {
        let rows = resolvedTableRows(for: tab)
        let presentation = resultPresentation(for: tab, rows: rows)

        VStack(spacing: 0) {
            if presentation.showsErrorBanner {
                executionErrorBanner(tab: tab)
            }

            if presentation.showsFilterChrome {
                rowFilterChrome(tab: tab, rows: rows)
            }

            resultContent(presentation.content, tab: tab, rows: rows)
                .gridStandInBackground(isActive: presentation.content.standsInForGrid)

            if presentation.showsStatusBar {
                if let model = coordinator.activeGridModel {
                    DataGridModelReader(model: model) { model in
                        statusBar(tab: tab, selectedRowCount: model.selection.affectedRows.count)
                    }
                } else {
                    statusBar(tab: tab, selectedRowCount: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func resultContent(
        _ content: QueryResultContent,
        tab: QueryTab,
        rows: TableRows
    ) -> some View {
        switch content {
        case .idle:
            Color.clear
        case .executing:
            ExecutingResultPane()
        case let .structure(tableName):
            structureContent(tab: tab, tableName: tableName)
        case .queryPlan:
            if let explain = tab.display.activeExplainResult {
                queryPlanResultView(for: explain, in: tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .chart:
            if let resultSet = tab.display.activeResultSet {
                ResultChartView(
                    configuration: chartConfigurationBinding(for: tab),
                    tableRows: rows,
                    primaryKeyColumns: Set(tab.tableContext.primaryKeyColumns),
                    tabId: tab.id,
                    resultSetId: resultSet.id,
                    dataRevision: coordinator.tabSessionRegistry.session(for: tab.id)?.dataRevision ?? 0,
                    isUnlocked: featureAccess.isAvailable(.resultCharts)
                )
            }
        case .map:
            if let resultSet = tab.display.activeResultSet {
                DataGridModelReader(model: coordinator.gridModel(forTab: tab.id)) { model in
                    ResultMapView(
                        configuration: mapConfigurationBinding(for: tab),
                        columns: tab.display.spatialColumns,
                        tableRows: rows,
                        displayIDs: model.displayedRowIDs,
                        selectedRowIDs: Set(model.selectedRowIDs),
                        tabId: tab.id,
                        resultSetId: resultSet.id,
                        dataRevision: coordinator.tabSessionRegistry.session(for: tab.id)?.dataRevision ?? 0,
                        displayRevision: coordinator.gridDisplayRevision,
                        onSelectRow: { rowID in
                            if let rowID {
                                model.selectRows([rowID])
                            } else {
                                model.clearSelection()
                            }
                        }
                    )
                }
                .id(tab.id)
            }
        case .json:
            DataGridModelReader(model: coordinator.gridModel(forTab: tab.id)) { model in
                ResultsJsonView(
                    tableRows: rows,
                    selectedRowIDs: Set(model.selectedRowIDs),
                    displayIDs: model.displayedRowIDs,
                    deletedRowIDs: changeManager.deletedRowIDs,
                    valueFilter: tab.valueFilter,
                    dataRevision: coordinator.tabSessionRegistry.session(for: tab.id)?.dataRevision ?? 0,
                    displayRevision: coordinator.gridDisplayRevision,
                    columnLayout: tab.columnLayout
                )
            }
            .id(tab.id)
        case .grid:
            dataGridView(tab: tab)
        case let .noRows(executionTime):
            emptyResultView(executionTime: executionTime)
        case let .statementSucceeded(rowsAffected, executionTime, statusMessage, serverOutput):
            ResultSuccessView(
                rowsAffected: rowsAffected,
                executionTime: executionTime,
                statusMessage: statusMessage,
                serverOutput: serverOutput
            )
        case let .serverOutput(output):
            ServerOutputView(output: output)
        case let .unavailable(mode):
            unavailableModeView(mode)
        }
    }

    private func unavailableModeView(_ mode: ResultsViewMode) -> some View {
        UnavailableStateView(
            String(localized: "No Data"),
            systemImage: mode == .map ? "map" : "chart.bar.xaxis",
            description: Text(mode == .map
                ? String(localized: "Execute a query to map its loaded rows.")
                : String(localized: "Execute a query to chart its loaded rows."))
        )
    }

    // The one place tab state is read for this decision, so the conditions cannot drift apart again.
    private func resultPresentation(for tab: QueryTab, rows: TableRows) -> QueryResultPresentation {
        let activeResultSet = tab.display.activeResultSet
        var inputs = QueryResultInputs()
        inputs.tabType = tab.tabType
        inputs.viewMode = tab.display.resultsViewMode
        inputs.tableName = tab.tableContext.tableName
        inputs.isExecuting = coordinator.tabExecution.isExecuting(tab.id)
        inputs.hasExecuted = tab.execution.lastExecutedAt != nil
        inputs.isExplainResult = tab.display.activeExplainResult != nil
        inputs.hasActiveResultSet = activeResultSet != nil
        inputs.resultSetCount = tab.display.resultSets.count
        inputs.activeResultHasColumns = !(activeResultSet?.resultColumns.isEmpty ?? true)
        inputs.activeResultRowsAffected = activeResultSet?.rowsAffected ?? 0
        inputs.activeResultExecutionTime = activeResultSet?.executionTime
        inputs.activeResultStatusMessage = activeResultSet?.statusMessage
        inputs.activeResultServerOutput = activeResultSet?.serverOutput ?? .none
        inputs.activeResultErrorMessage = activeResultSet?.errorMessage
        inputs.loadedColumnCount = rows.columns.count
        inputs.loadedRowCount = rows.rows.count
        inputs.executionErrorMessage = tab.execution.errorMessage
        inputs.executionRowsAffected = tab.execution.rowsAffected
        inputs.executionTime = tab.execution.executionTime
        inputs.executionStatusMessage = tab.execution.statusMessage
        inputs.hasAppliedFilters = tab.filterState.hasAppliedFilters
        inputs.isFilterPanelVisible = tab.filterState.isVisible
        return QueryResultPresentation(inputs: inputs)
    }

    // Filtering rebuilds and reruns the query, so a mode showing this panel gets filtered rows without knowing.
    @ViewBuilder
    private func rowFilterChrome(tab: QueryTab, rows: TableRows) -> some View {
        if tab.filterState.isVisible && tab.tabType == .table
            && tab.display.resultsViewMode.showsRowFilters
        {
            if let descriptor = coordinator.browseFilterDescriptor {
                KeyPatternSearchBar(coordinator: coordinator, descriptor: descriptor)
            } else {
                QueryTabFilterPanel(
                    coordinator: coordinator,
                    tabManager: tabManager,
                    columns: rows.columns,
                    primaryKeyColumn: changeManager.primaryKeyColumn,
                    databaseType: connection.type,
                    enumValuesByColumn: rows.columnEnumValues
                )
            }
            Divider()
        }
    }

    // Identified by its result set so one plan's selection, zoom and scroll never carry onto the next.
    private func queryPlanResultView(for resultSet: ResultSet, in tab: QueryTab) -> some View {
        QueryPlanResultView(
            rawText: resultSet.explainRawText ?? "",
            executionTime: resultSet.executionTime,
            plan: resultSet.queryPlan,
            planContext: resultSet.explainPlanContext,
            tabState: queryPlanViewStates.tabState(forTab: tab.id),
            planState: queryPlanViewStates.planState(
                forResultSet: resultSet.id,
                inTab: tab.id,
                liveResultSetIds: Set(tab.display.resultSets.map(\.id))
            )
        )
        .id(resultSet.id)
    }

    // Asked of the resolver so it cannot disagree with what was rendered, as a hand-written copy once did.
    private func showsGrid(tab: QueryTab, rows: TableRows) -> Bool {
        resultPresentation(for: tab, rows: rows).content == .grid
    }

    private func emptyResultView(executionTime: TimeInterval?) -> some View {
        let description: String? = executionTime.map { String(format: "%.3fs", $0) }
        return UnavailableStateView {
            Label(String(localized: "No rows returned"), systemImage: "tray")
        } description: {
            if let description {
                Text(description)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Configuration is applied outside the update pass: the model publishes when it changes.
    @ViewBuilder
    private func dataGridView(tab: QueryTab) -> some View {
        let model = displayedGridModel(for: tab)
        let configuration = coordinator.gridConfiguration(for: tab)
        let highlightRules = coordinator.highlightRules(for: tab)
        DataGridView(model: model)
            .id(tab.id)
            .frame(maxHeight: .infinity, alignment: .top)
            .onAppear {
                model.configuration = configuration
                focusGridIfRequested(model)
            }
            .onChange(of: configuration) { model.configuration = $0 }
            .onChange(of: highlightRules) { _ in
                model.display.cache.clearHighlights()
                model.repaintAllRows()
            }
    }

    private func displayedGridModel(for tab: QueryTab) -> DataGridModel {
        let model = coordinator.gridModel(forTab: tab.id)
        coordinator.prepareGridModelForDisplay(forTab: tab.id)
        return model
    }

    // An explicit open asks for the keyboard; the grid is in its window once this turn ends.
    private func focusGridIfRequested(_ model: DataGridModel) {
        guard coordinator.consumePendingGridFocus() else { return }
        Task { @MainActor in
            model.focus()
        }
    }

    private func resolvedTableRows(for tab: QueryTab) -> TableRows {
        coordinator.tabSessionRegistry.existingTableRows(for: tab.id) ?? TableRows()
    }

    // Owned by the tab: a page turn, sort or rerun builds a new `ResultSet`, and the axes must outlive it.
    private func chartConfigurationBinding(for tab: QueryTab) -> Binding<ResultChartConfiguration> {
        Binding(
            get: { tab.chartConfiguration },
            set: { newValue in
                if let index = tabManager.selectedTabIndex {
                    tabManager.mutate(at: index) { $0.chartConfiguration = newValue }
                }
            }
        )
    }

    // Owned by the tab like the chart's: a page turn, sort or rerun builds a new `ResultSet`, and the column must outlive it.
    private func mapConfigurationBinding(for tab: QueryTab) -> Binding<ResultMapConfiguration> {
        let tabId = tab.id
        return Binding(
            get: { tab.mapConfiguration },
            set: { newValue in
                tabManager.mutate(tabId: tabId) { $0.mapConfiguration = newValue }
            }
        )
    }

    // MARK: - Status Bar

    private func statusBar(tab: QueryTab, selectedRowCount: Int) -> some View {
        let resolvedRows = resolvedTableRows(for: tab)
        let structureFooter = coordinator.structureSessions[tab.id]?.footer ?? StructureFooterCapability()
        let isExecuting = coordinator.tabExecution.isBusy(tab.id)
        let snapshot = StatusBarSnapshot(
            tab: tab,
            tableRows: resolvedRows,
            displayRowCount: coordinator.displayIDs(forTab: tab.id)?.count,
            isFetching: isExecuting,
            hasStructureActions: structureFooter.isActive,
            isQueryPlan: tab.display.activeExplainResult != nil,
            paginationCapability: coordinator.paginationCapability,
            hasServerOutput: !(tab.display.activeResultSet?.serverOutput.isEmpty ?? true),
            activeResultStatusMessage: tab.display.activeResultSet?.statusMessage
        )
        return ResultStatusBar(
            model: ResultStatusModel(
                snapshot: snapshot,
                viewMode: tab.display.resultsViewMode,
                selectedRowCount: selectedRowCount
            ),
            snapshot: snapshot,
            filterState: tab.filterState,
            columnState: StatusBarColumnState(
                hidden: tab.columnLayout.hiddenColumns,
                columns: coordinator.columnCatalog(for: tab, resultRows: resolvedRows),
                onToggle: { coordinator.toggleColumnVisibility($0) },
                onShowAll: { coordinator.showAllColumns() },
                onHideAll: { coordinator.hideAllColumns($0) },
                onReset: { coordinator.resetColumns() },
                onJumpToColumn: !tab.display.isResultsCollapsed
                    && showsGrid(tab: tab, rows: resolvedRows)
                    ? { coordinator.showColumnJump(seededWith: $0) }
                    : nil
            ),
            highlightState: StatusBarHighlightState(
                rules: coordinator.highlightRules(for: tab),
                columns: resolvedRows.columns,
                isPersisted: coordinator.highlightRuleScope(for: tab) != nil,
                presentationRequest: tab.display.highlightRulesPresentationRequest,
                onChange: { [coordinator, tabId = tab.id] rules in
                    coordinator.setHighlightRules(rules, forTab: tabId)
                },
                onDismiss: { [coordinator] tabId in
                    coordinator.discardIncompleteHighlightRules(forTab: tabId)
                }
            ),
            paginationCallbacks: PaginationCallbacks(
                onFirst: onFirstPage,
                onPrevious: onPreviousPage,
                onNext: onNextPage,
                onLast: onLastPage,
                onPageSizeChange: onPageSizeChange,
                onShowAll: onShowAll,
                onGoToPage: onGoToPage,
                onRequestExactCount: { coordinator.paginationCoordinator.requestExactRowCount() }
            ),
            structureFooter: structureFooter,
            execution: ExecutionReadout(
                tabId: tab.id,
                execution: coordinator.tabExecution,
                lastTiming: coordinator.toolbarState.queryTiming(forTab: tab.id),
                onCancel: { coordinator.stopExecution(for: tab.id) }
            ),
            selectionSummary: coordinator.selectionSummary,
            isRefreshingSchema: schemaService.isRefreshing(connectionId: connectionId),
            viewMode: resultsViewModeBinding(for: tab),
            resultSetMenu: resultSetMenuModel(for: tab),
            onActivateResultSet: { coordinator.switchActiveResultSet(to: $0, in: tab.id) },
            onToggleResultSetPin: { coordinator.togglePinResultSet(id: $0) },
            onCompareResultSet: { coordinator.compareResultSet(id: $0) },
            onCloseResultSet: { coordinator.closeResultSet(id: $0) },
            onCloseOtherResultSets: { keptId in
                for other in tab.display.resultSets where other.id != keptId && !other.isPinned {
                    coordinator.closeResultSet(id: other.id)
                }
            },
            onToggleFilters: { coordinator.toggleFilterPanel() },
            onFetchAll: { coordinator.fetchAllRows() },
            onStructureAdd: { coordinator.structureActions?.addRow?() },
            onStructureRemove: { coordinator.structureActions?.removeRow?() }
        )
    }

    // Only the three deciding fields, not a full `resultPresentation`, which would pull the whole row buffer for a row-free answer.
    private func resultSetMenuModel(for tab: QueryTab) -> ResultSetMenuModel {
        var selectorInputs = QueryResultInputs()
        selectorInputs.tabType = tab.tabType
        selectorInputs.viewMode = tab.display.resultsViewMode
        selectorInputs.resultSetCount = tab.display.resultSets.count
        guard QueryResultPresentation(inputs: selectorInputs).showsResultSetSelector else {
            return ResultSetMenuModel(entries: [], activeOrdinal: 0, total: 0)
        }
        let activeId = tab.display.activeResultSet?.id
        let entries = tab.display.resultSets.enumerated().map { index, resultSet in
            ResultSetMenuEntry(
                id: resultSet.id,
                label: resultSet.label,
                isPinned: resultSet.isPinned,
                isActive: resultSet.id == activeId,
                ordinal: index + 1,
                isComparable: coordinator.isComparable(resultSet, in: tab)
            )
        }
        return ResultSetMenuModel(
            entries: entries,
            activeOrdinal: entries.first(where: \.isActive)?.ordinal ?? entries.count,
            total: entries.count
        )
    }

    private func resultsViewModeBinding(for tab: QueryTab) -> Binding<ResultsViewMode> {
        Binding(
            get: { tab.display.resultsViewMode },
            set: { newValue in
                Task { @MainActor in
                    if let index = tabManager.selectedTabIndex {
                        coordinator.commitActiveGridEdit()
                        tabManager.mutate(at: index) { $0.display.resultsViewMode = newValue }
                    }
                }
            }
        )
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "tablecells")
                .font(.largeTitle)
                .imageScale(.large)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.quaternary)

            Text("No tabs open")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("⌘T")
                        .font(.callout.monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: .quaternaryLabelColor))
                        )
                    Text(
                        "Open \(PluginManager.shared.queryLanguageName(for: connection.type)) Editor"
                    )
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                }

                HStack(spacing: 6) {
                    Text("Click a table")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                    Text("to view data")
                        .font(.callout)
                        .foregroundStyle(.quaternary)
                }

                if PluginManager.shared.supportsContainerSwitching(for: connection.type) {
                    HStack(spacing: 6) {
                        Text("⌘K")
                            .font(.callout.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: .quaternaryLabelColor))
                            )
                        Text(String(
                            format: String(localized: "Switch %@"),
                            PluginManager.shared.containerEntityName(for: connection.type)
                        ))
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// The toolbar models, kept out of the view body's type so it stays under the length limit.
extension MainEditorContentView {
    private func scopeBarModel(for tab: QueryTab) -> QueryScopeBarModel {
        QueryScopeBarModel(
            containers: containerDatabases(for: tab),
            selectedName: containerName(for: tab),
            entityName: containerEntityName,
            isReadOnly: isContainerSwitchReadOnly,
            schemaName: containerSchemaName(for: tab)
        )
    }

    private func commandAvailability(for tab: QueryTab) -> QueryCommandAvailability {
        QueryCommandAvailability(
            isConnected: MainWindowToolbar.hasLiveSession(coordinator.toolbarState.connectionState),
            hasQueryText: tab.hasQueryText,
            isExecuting: coordinator.tabExecution.isExecuting(tab.id),
            isStoppable: coordinator.tabExecution.isStoppable(tab.id),
            hasResults: coordinator.canClearActiveQueryResults,
            explainVariants: coordinator.connection.type.explainVariants,
            supportsFormatting: QueryFormatterFactory.supportsFormatting(coordinator.connection.type),
            aiActions: coordinator.aiQueryActionAvailability(for: tab),
            shortcutHint: { label, action in
                settingsManager.keyboard.shortcutHint(label, for: action)
            }
        )
    }
}

fileprivate extension MainEditorContentView {
    // Keyed by tab id, not type name, so a rename that retitles the tab keeps its queue.
    @ViewBuilder
    func userTypeContent(tab: QueryTab, objectRef: DatabaseObjectRef) -> some View {
        Group {
            if let model = coordinator.userTypeEditors[tab.id] {
                UserTypeTabView(
                    model: model,
                    databaseType: connection.type,
                    isReadOnly: coordinator.safeModeLevel.blocksAllWrites,
                    onOpenInEditor: { source in
                        coordinator.openObjectSourceInEditor(model.objectRef, source: source)
                    },
                    onChangeStateChanged: { hasChanges in
                        coordinator.publishUserTypeEditorState(tabId: tab.id, hasChanges: hasChanges)
                    },
                    onLeave: { coordinator.releaseUserTypeEditorState(tabId: tab.id) },
                    onPreviewSQL: { coordinator.previewUserTypeChanges(tabId: tab.id) },
                    onSave: { coordinator.saveUserTypeChanges(tabId: tab.id) }
                )
            } else {
                Color.clear
                    .onAppear {
                        guard coordinator.userTypeEditors[tab.id] == nil else { return }
                        coordinator.userTypeEditors[tab.id] = coordinator.makeUserTypeEditor(for: objectRef, tabId: tab.id)
                    }
            }
        }
        .id(tab.id)
    }
}

// MARK: - Query Tab Content

extension MainEditorContentView {
    private func queryTabInput(tab: QueryTab) -> QueryTabInput {
        let claimFocus = coordinator.tabManager.pendingFocusTabId == tab.id
        let queryScope = coordinator.scope(for: tab)
        let scope = scopeBarModel(for: tab)
        let commands = commandAvailability(for: tab)
        let isExecuting = coordinator.tabExecution.isExecuting(tab.id)
        let showsHistoryTip = showsHistoryTip
        let parameters = parameterBinding(for: tab)
        let isParameterPanelVisible = parameterVisibilityBinding(for: tab)
        let header: (VimMode?) -> AnyView = { vimMode in
            AnyView(VStack(alignment: .leading, spacing: 0) {
                if let change = tab.content.diskChange,
                   let url = tab.content.sourceFileURL {
                    SourceFileDiskChangeBanner(
                        fileName: url.lastPathComponent,
                        change: change,
                        onReload: { coordinator.commandActions?.reloadFileFromDisk(tabId: tab.id, url: url) },
                        onSaveAs: { coordinator.commandActions?.saveFileAs() },
                        onDismiss: { dismissDiskChangeBanner(tabId: tab.id) }
                    )
                    Divider()
                }
                QueryEditorBar(
                    scope: scope,
                    commands: commands,
                    isExecuting: isExecuting,
                    vimMode: vimMode,
                    showsHistoryTip: showsHistoryTip,
                    onAIAction: { action in coordinator.runAIQueryAction(action, target: .selectionOrStatementAtCursor) },
                    onRun: { coordinator.runQuery(viewport: .firstRow) },
                    onRunAllStatements: { coordinator.runAllStatements() },
                    onRunWithoutLimit: { coordinator.runQuery(viewport: .firstRow, bypassRowLimit: true) },
                    onStop: { coordinator.stopExecution(for: tab.id) },
                    onExplain: { variant in coordinator.runExplain(variant: variant) },
                    onFormat: { EditorEventRouter.shared.performFormatSQLForKeyWindow() },
                    onSaveAsFavorite: { coordinator.saveCurrentQueryAsFavorite() },
                    onClearQuery: { coordinator.commandActions?.clearQuery() },
                    onClearResults: { coordinator.clearActiveQueryResults() },
                    onContainerChanged: { name in changeContainer(for: tab, to: name) }
                )
                Divider()
                if isParameterPanelVisible.wrappedValue && !parameters.wrappedValue.isEmpty {
                    QueryParameterPanelView(
                        parameters: parameters,
                        onDismiss: { isParameterPanelVisible.wrappedValue = false }
                    )
                    Divider()
                }
            })
        }
        let editor = SQLEditorInput(
            text: queryTextBinding(for: tab),
            cursorPositions: $coordinator.cursorPositions,
            schemaProvider: queryScope.map { SchemaProviderRegistry.shared.getOrCreate(for: $0) },
            databaseType: coordinator.connection.type,
            databaseScope: queryScope,
            connectionId: coordinator.connection.id,
            tabID: tab.id,
            sourceFileURL: tab.content.sourceFileURL,
            claimFocusOnAppear: claimFocus,
            onFocusClaimed: {
                if coordinator.tabManager.pendingFocusTabId == tab.id {
                    coordinator.tabManager.pendingFocusTabId = nil
                }
            },
            restoredCursorRange: coordinator.restoredCursorRange(for: tab.id),
            pendingStatementJump: coordinator.pendingStatementJump(for: tab.id),
            onStatementJumpHandled: { coordinator.clearPendingStatementJump(for: tab.id) },
            restoredFoldRanges: coordinator.foldRanges(for: tab.id),
            onFoldRangesChanged: { ranges in
                coordinator.recordFoldRanges(ranges, for: tab.id)
            },
            onCloseTab: {
                coordinator.commandActions?.closeTab()
            },
            onExecuteQuery: { coordinator.runQuery(viewport: .firstRow) },
            onSelectTab: { number in coordinator.commandActions?.selectTab(number: number) },
            onSelectAdjacentTab: { offset in coordinator.commandActions?.selectTab(offsetBy: offset) },
            tabCount: { coordinator.tabManager.visibleTabs.count },
            onRunStatement: { sql, offset in coordinator.runStatement(sql, sourceOffset: offset) },
            isExecuting: isExecuting,
            currentAIAvailability: { coordinator.aiQueryActionAvailability },
            onAIAction: { action, target in coordinator.runAIQueryAction(action, target: target) },
            onSaveAsFavorite: { text in
                guard !text.isEmpty else { return }
                coordinator.favoriteDialogQuery = FavoriteDialogQuery(query: text)
            }
        )
        return QueryTabInput(
            pane: QueryEditorPaneInput(header: header, editor: editor),
            results: AnyView(resultsSection(tab: tab).frame(maxWidth: .infinity, maxHeight: .infinity)),
            isResultsCollapsed: Binding(
                get: { tab.display.isResultsCollapsed },
                set: { collapsed in
                    _ = coordinator.tabManager.mutate(tabId: tab.id) { $0.display.isResultsCollapsed = collapsed }
                }
            ),
            resultsAutosaveName: SplitViewAutosaveName.querySplit(connectionId: connectionId)
        )
    }
}
