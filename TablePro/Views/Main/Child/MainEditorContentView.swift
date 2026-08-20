//
//  MainEditorContentView.swift
//  TablePro
//
//  Main editor content view containing tab bar and tab content.
//  Extracted from MainContentView for better separation.
//

import AppKit
import CodeEditSourceEditor
import SwiftUI
import TableProPluginKit

/// Identity for the visibility-scoped lazy-load `.task(id:)` modifier on
/// `MainEditorContentView`. Changes to either field cancel the previous
/// task and start a new one — exactly the rapid-switch coalescing semantic
/// we want for Cmd+Number tab navigation.
private struct TabLoadKey: Hashable {
    let tabId: UUID?
    let loadEpoch: Int
}

struct MainEditorContentView: View {
    /// A query tab nests its own editor/results split, whose two minimums are required constraints.
    /// The drawer's own minimum has to clear their sum, or dragging the drawer down asks AppKit to
    /// satisfy a height the content it contains cannot reach.
    static let tabContentMinimumHeight = VerticalCollapsibleSplitView<EmptyView, EmptyView>.combinedMinimumThickness

    // MARK: - Dependencies

    var tabManager: QueryTabManager
    var coordinator: MainContentCoordinator
    var changeManager: DataChangeManager
    let connection: DatabaseConnection
    let windowId: UUID
    let connectionId: UUID

    // MARK: - Selection State

    let selectionState: GridSelectionState

    // MARK: - Callbacks

    let onCellEdit: (Int, Int, String?) -> Void
    let onSortStateChanged: (SortState) -> Void
    let onAddRow: () -> Void
    let onUndoInsert: (Int) -> Void
    let onSelectionChange: (Set<Int>) -> Void
    let onFilterColumn: (String) -> Void
    let onApplyFilters: ([TableFilter]) -> Void
    let onClearFilters: () -> Void

    let onFirstPage: () -> Void
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let onLastPage: () -> Void
    let onPageSizeChange: (Int) -> Void
    let onShowAll: () -> Void
    let onGoToPage: (Int) -> Void

    @State private var cachedChangeManager: AnyChangeManager?
    @State private var erDiagramViewModels: [UUID: ERDiagramViewModel] = [:]
    @State private var serverDashboardViewModels: [UUID: ServerDashboardViewModel] = [:]
    @State private var usersRolesViewModels: [UUID: UsersRolesViewModel] = [:]
    @State private var queryInsightsViewModels: [UUID: QueryInsightsViewModel] = [:]
    @State private var dataTabDelegate = DataTabGridDelegate()

    @Bindable private var treeService = DatabaseTreeMetadataService.shared

    // Native macOS window tabs — no LRU tracking needed (single tab per window)

    // MARK: - Environment


    /// Returns the cached AnyChangeManager, creating it on first access.
    private var currentChangeManager: AnyChangeManager {
        if let existing = cachedChangeManager {
            return existing
        }
        // Fallback before onAppear initializes cachedChangeManager.
        // Safe: onAppear fires before any user interaction needs it.
        return AnyChangeManager(changeManager)
    }

    // MARK: - Body

    var body: some View {
        @Bindable var historyState = HistoryPanelState.forConnection(connectionId)

        VerticalCollapsibleSplitView(
            isBottomCollapsed: Binding(
                get: { !historyState.isVisible },
                set: { historyState.isVisible = !$0 }
            ),
            autosaveName: "HistoryDrawer-\(connectionId)",
            topMinimumThickness: Self.tabContentMinimumHeight,
            bottomMinimumThickness: 180,
            topContent: {
                // Native macOS window tabs replace the custom tab bar.
                // Each window-tab contains a single tab, so no ZStack keep-alive is needed.
                if let tab = tabManager.selectedTab {
                    tabContent(for: tab)
                } else {
                    emptyStateView
                }
            },
            bottomContent: {
                HistoryPanelView(coordinator: coordinator)
            }
        )
        .background(.background)
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
        .onChange(of: tabManager.tabStructureVersion) { _, _ in
            let openTabIds = Set(tabManager.tabIds)
            coordinator.cleanupTabCaches(openTabIds: openTabIds)
            erDiagramViewModels = erDiagramViewModels.filter { openTabIds.contains($0.key) }
            serverDashboardViewModels = serverDashboardViewModels.filter { openTabIds.contains($0.key) }
            usersRolesViewModels = usersRolesViewModels.filter { openTabIds.contains($0.key) }
            queryInsightsViewModels = queryInsightsViewModels.filter { openTabIds.contains($0.key) }
        }
        .onChange(of: tabManager.selectedTabId) { _, _ in
            updateHasQueryText()
        }
        .onAppear {
            updateHasQueryText()
            cachedChangeManager = AnyChangeManager(changeManager)
            wireDataTabDelegateStableRefs()
            refreshDataTabDelegateMutableRefs()
            coordinator.dataTabDelegate = dataTabDelegate
        }
        .onDisappear {
            cachedChangeManager = nil
        }
        .task(id: TabLoadKey(
            tabId: tabManager.selectedTabId,
            loadEpoch: tabManager.selectedTab?.loadEpoch ?? 0
        )) {
            coordinator.lazyLoadCurrentTabIfNeeded()
        }
        .onChange(of: selectionState.indices) { _, newIndices in
            onSelectionChange(newIndices)
        }
        .onChange(of: tabManager.selectedTab?.tableContext.isEditable) { _, _ in
            refreshDataTabDelegateMutableRefs()
        }
        .onChange(of: tabManager.selectedTab?.tableContext.isView) { _, _ in
            refreshDataTabDelegateMutableRefs()
        }
        .onChange(of: tabManager.selectedTab?.tableContext.tableName) { _, _ in
            refreshDataTabDelegateMutableRefs()
        }
        .onChange(of: coordinator.safeModeLevel) { _, _ in
            refreshDataTabDelegateMutableRefs()
        }
    }

    private func wireDataTabDelegateStableRefs() {
        dataTabDelegate.coordinator = coordinator
        dataTabDelegate.selectionState = selectionState
        dataTabDelegate.onCellEdit = onCellEdit
        dataTabDelegate.onSortStateChanged = onSortStateChanged
        dataTabDelegate.onUndoInsert = onUndoInsert
        dataTabDelegate.onFilterColumn = onFilterColumn
    }

    private func refreshDataTabDelegateMutableRefs() {
        dataTabDelegate.onAddRow = currentTabAllowsAddRow ? onAddRow : nil
    }

    private var currentTabAllowsAddRow: Bool {
        guard let tab = tabManager.selectedTab else { return false }
        let isEditable = tab.tableContext.isEditable
            && !tab.tableContext.isView
            && !coordinator.safeModeLevel.blocksAllWrites
        return isEditable && tab.tableContext.tableName != nil
    }

    // MARK: - Tab Content

    @ViewBuilder
    private func tabContent(for tab: QueryTab) -> some View {
        switch tab.tabType {
        case .query:
            queryTabContent(tab: tab)
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
        }
    }

    // MARK: - Query Insights Tab Content

    @ViewBuilder
    private func queryInsightsContent(tab: QueryTab) -> some View {
        Group {
            if let vm = queryInsightsViewModels[tab.id] {
                QueryInsightsView(viewModel: vm, coordinator: coordinator)
            } else {
                ProgressView(String(localized: "Loading insights..."))
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
                ProgressView(String(localized: "Loading users and roles..."))
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
                ProgressView(String(localized: "Loading dashboard..."))
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
            if let vm = erDiagramViewModels[tab.id] {
                ERDiagramView(viewModel: vm)
            } else {
                ProgressView(String(localized: "Loading schema..."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        guard erDiagramViewModels[tab.id] == nil else { return }
                        let vm = ERDiagramViewModel(
                            connectionId: connection.id,
                            databaseName: tab.tableContext.databaseName,
                            schemaKey: tab.display.erDiagramSchemaKey ?? tab.tableContext.databaseName
                        )
                        erDiagramViewModels[tab.id] = vm
                    }
            }
        }
        .id(tab.id)
    }

    // MARK: - Per-tab container picker

    private var containerSwitchTarget: ContainerSwitchTarget? {
        PluginManager.shared.containerSwitchTarget(for: connection.type)
    }

    private func containerDatabases(for tab: QueryTab) -> [DatabaseMetadata] {
        guard containerSwitchTarget == .database else { return [] }
        let all = treeService.databases(for: connectionId)
        let selected = SharedSidebarState.forConnection(connectionId).databaseFilterSelected
        return DatabaseTreeVisibility.visible(
            databases: all,
            selected: selected,
            activeDatabase: containerName(for: tab)
        )
    }

    private var isContainerSwitchReadOnly: Bool {
        guard containerSwitchTarget == .database else { return false }
        return PluginManager.shared.requiresReconnectForDatabaseSwitch(for: connection.type)
    }

    private var containerEntityName: String {
        PluginManager.shared.containerEntityName(for: connection.type)
    }

    private func containerName(for tab: QueryTab) -> String {
        let bound = tab.tableContext.databaseName
        return bound.isEmpty ? coordinator.browseDatabaseName : bound
    }

    /// Rebinding the container is a tab-local edit. The tab owns the new database for the
    /// rest of its life and the sidebar's browse cursor stays where the user left it.
    private func changeContainer(for tab: QueryTab, to name: String) {
        let tabId = tab.id
        guard tab.tableContext.databaseName != name,
              tabManager.mutate(tabId: tabId, { $0.tableContext.databaseName = name }) else { return }
        tabManager.markTabRenamed(tabId)
        guard tabManager.selectedTabId == tabId else { return }
        coordinator.runQuery()
    }

    // MARK: - Query Tab Content

    @ViewBuilder
    private func queryTabContent(tab: QueryTab) -> some View {
        @Bindable var bindableCoordinator = coordinator
        let claimFocus = coordinator.tabManager.pendingFocusTabId == tab.id
        VerticalCollapsibleSplitView(
            isBottomCollapsed: Binding(
                get: { tab.display.isResultsCollapsed },
                set: { collapsed in
                    _ = coordinator.tabManager.mutate(tabId: tab.id) { $0.display.isResultsCollapsed = collapsed }
                }
            ),
            autosaveName: "QuerySplit-\(connectionId)-\(tab.id)",
            topContent: {
                VStack(spacing: 0) {
                    if tab.content.externalModificationDetected,
                       let url = tab.content.sourceFileURL {
                        FileModifiedOnDiskBanner(
                            fileName: url.lastPathComponent,
                            onReload: { reloadFileForTab(tabId: tab.id, url: url) },
                            onDismiss: { dismissExternalModBanner(tabId: tab.id) }
                        )
                        Divider()
                    }
                    QueryEditorView(
                        queryText: queryTextBinding(for: tab),
                        cursorPositions: $bindableCoordinator.cursorPositions,
                        parameters: parameterBinding(for: tab),
                        isParameterPanelVisible: parameterVisibilityBinding(for: tab),
                        onExecute: { coordinator.runQuery() },
                        onExecuteWithoutLimit: { coordinator.runQuery(bypassRowLimit: true) },
                        onExecuteAllStatements: { coordinator.runAllStatements() },
                        schemaProvider: SchemaProviderRegistry.shared.getOrCreate(for: coordinator.connection.id),
                        databaseType: coordinator.connection.type,
                        connectionId: coordinator.connection.id,
                        connectionAIPolicy: coordinator.connection.aiPolicy ?? AppSettingsManager.shared.ai.defaultConnectionPolicy,
                        tabID: tab.id,
                        claimFocusOnAppear: claimFocus,
                        onFocusClaimed: {
                            if coordinator.tabManager.pendingFocusTabId == tab.id {
                                coordinator.tabManager.pendingFocusTabId = nil
                            }
                        },
                        restoredCursorRange: coordinator.restoredCursorRange(for: tab.id),
                        restoredFoldRanges: coordinator.foldRanges(for: tab.id),
                        onFoldRangesChanged: { ranges in
                            coordinator.recordFoldRanges(ranges, for: tab.id)
                        },
                        onCloseTab: {
                            coordinator.commandActions?.closeTab()
                        },
                        onExecuteQuery: { coordinator.runQuery() },
                        onExplain: { variant in coordinator.runExplain(variant: variant) },
                        onAIExplain: { text in
                            coordinator.showAIChatPanel()
                            coordinator.aiViewModel?.handleExplainSelection(text)
                        },
                        onAIOptimize: { text in
                            coordinator.showAIChatPanel()
                            coordinator.aiViewModel?.handleOptimizeSelection(text)
                        },
                        onSaveAsFavorite: { text in
                            guard !text.isEmpty else { return }
                            coordinator.favoriteDialogQuery = FavoriteDialogQuery(query: text)
                        },
                        onClearResults: { coordinator.clearActiveQueryResults() },
                        availableContainers: containerDatabases(for: tab),
                        selectedContainerName: containerName(for: tab),
                        containerEntityName: containerEntityName,
                        isContainerSwitchReadOnly: isContainerSwitchReadOnly,
                        onContainerChanged: { name in changeContainer(for: tab, to: name) }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            },
            bottomContent: {
                resultsSection(tab: tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        )
        .onAppear {
            coordinator.clearRestoredCursor(for: tab.id)
        }
    }

    private func reloadFileForTab(tabId: UUID, url: URL) {
        Task {
            guard let loaded = FileTextLoader.load(url) else { return }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            await MainActor.run {
                coordinator.tabManager.mutate(tabId: tabId) { tab in
                    tab.content.query = loaded.content
                    tab.content.savedFileContent = loaded.content
                    tab.content.loadMtime = mtime
                    tab.content.externalModificationDetected = false
                }
            }
        }
    }

    private func dismissExternalModBanner(tabId: UUID) {
        coordinator.tabManager.mutate(tabId: tabId) { $0.content.externalModificationDetected = false }
    }

    private func updateHasQueryText() {
        if let tab = tabManager.selectedTab, tab.tabType == .query {
            coordinator.toolbarState.hasQueryText = !tab.content.query.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        } else {
            coordinator.toolbarState.hasQueryText = false
        }
    }

    private func queryTextBinding(for tab: QueryTab) -> Binding<String> {
        let tabId = tab.id
        let fallbackQuery = tab.content.query
        return Binding(
            get: {
                tabManager.tabs.first(where: { $0.id == tabId })?.content.query ?? fallbackQuery
            },
            set: { newValue in
                // Find this tab by ID, not by selectedTabIndex. During tab switch,
                // flushTextUpdate() fires on the OLD tab's EditorCoordinator when
                // selectedTabIndex already points to the NEW tab — writing to
                // selectedTabIndex would overwrite the new tab's query.
                guard tabManager.mutate(tabId: tabId, { $0.content.query = newValue }) else { return }

                coordinator.scheduleDraftSave()

                // Typing into a scratch tab dirties it too: the text lives nowhere but this tab.
                // The dot belongs to this tab's own window, not whichever window happens to be
                // key, because a background window tab's editor stays mounted and can fire here.
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
        resultsSection(tab: tab)
    }

    // MARK: - Results Section

    @ViewBuilder
    private func executionErrorBanner(tab: QueryTab) -> some View {
        if let error = tab.display.activeResultSet?.errorMessage ?? tab.execution.errorMessage {
            InlineErrorBanner(
                message: error,
                onFixWithAI: AppSettingsManager.shared.ai.enabled && tab.tabType == .query
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

    /// A Create Table tab holds nothing but unsaved work, so its draft is cached here rather than
    /// left in the view, which is destroyed the moment the tab is deselected.
    @ViewBuilder
    private func createTableContent(tab: QueryTab) -> some View {
        Group {
            if let draft = coordinator.createTableDrafts[tab.id] {
                CreateTableView(
                    connection: connection,
                    coordinator: coordinator,
                    selectionState: selectionState,
                    draft: draft
                )
            } else {
                Color.clear
                    .onAppear { coordinator.createTableDrafts[tab.id] = CreateTableDraft() }
            }
        }
        .id(tab.id)
    }

    /// The structure editor is rebuilt whenever the tab is deselected or switched to Data, so its
    /// staged ALTERs live in a session cached here by tab, the same way the Users & Roles, ER
    /// diagram and dashboard view models do. Creating it in `onAppear` rather than inline keeps the
    /// write out of the view-update pass.
    @ViewBuilder
    private func structureContent(tab: QueryTab, tableName: String) -> some View {
        let scope = structureScope(for: tab)
        let identity = "\(scope?.qualifiedDescription ?? "").\(tableName)"
        Group {
            if let session = coordinator.structureSessions[tab.id], session.identity == identity {
                TableStructureView(
                    tableName: tableName,
                    connection: connection,
                    databaseName: scope?.database ?? "",
                    schemaName: scope?.schema,
                    toolbarState: coordinator.toolbarState,
                    coordinator: coordinator,
                    selectionState: selectionState,
                    session: session
                )
                .id(identity)
            } else {
                Color.clear
                    .onAppear {
                        coordinator.structureSessions[tab.id] = StructureEditingSession(identity: identity)
                    }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func resultsSection(tab: QueryTab) -> some View {
        VStack(spacing: 0) {
            executionErrorBanner(tab: tab)
            switch tab.display.resultsViewMode {
            case .structure:
                if let tableName = tab.tableContext.tableName {
                    structureContent(tab: tab, tableName: tableName)
                }
            case .json:
                resultTabBarSection(tab: tab)
                rowFilterChrome(tab: tab, rows: resolvedTableRows(for: tab))
                ResultsJsonView(
                    tableRows: resolvedTableRows(for: tab),
                    selectedRowIndices: selectionState.indices,
                    displayIDs: coordinator.displayIDs(forTab: tab.id),
                    deletedRowIndices: changeManager.deletedRowIndices,
                    valueFilter: tab.valueFilter,
                    dataRevision: coordinator.tabSessionRegistry.session(for: tab.id)?.dataRevision ?? 0,
                    displayRevision: coordinator.gridDisplayRevision,
                    columnLayout: tab.columnLayout
                )
                .id(tab.id)
            case .chart:
                resultTabBarSection(tab: tab)
                if let explain = tab.display.activeExplainResult {
                    QueryPlanResultView(
                        rawText: explain.explainRawText ?? "",
                        executionTime: explain.executionTime,
                        plan: explain.queryPlan
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let resultSet = tab.display.activeResultSet {
                    ResultChartView(
                        configuration: chartConfigurationBinding(for: tab),
                        tableRows: resolvedTableRows(for: tab),
                        primaryKeyColumns: Set(tab.tableContext.primaryKeyColumns),
                        tabId: tab.id,
                        resultSetId: resultSet.id,
                        dataRevision: coordinator.tabSessionRegistry.session(for: tab.id)?.dataRevision ?? 0,
                        isUnlocked: LicenseManager.shared.isFeatureAvailable(.resultCharts)
                    )
                } else {
                    ContentUnavailableView(
                        String(localized: "No Data"),
                        systemImage: "chart.bar.xaxis",
                        description: Text(String(localized: "Execute a query to chart its loaded rows."))
                    )
                }
            case .data:
                resultTabBarSection(tab: tab)

                if let explain = tab.display.activeExplainResult {
                    QueryPlanResultView(
                        rawText: explain.explainRawText ?? "",
                        executionTime: explain.executionTime,
                        plan: explain.queryPlan
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let resolvedRows = resolvedTableRows(for: tab)
                    if let rs = tab.display.activeResultSet, rs.resultColumns.isEmpty,
                       rs.errorMessage == nil, tab.execution.lastExecutedAt != nil,
                       !coordinator.tabExecution.isExecuting(tab.id)
                    {
                        ResultSuccessView(
                            rowsAffected: rs.rowsAffected,
                            executionTime: rs.executionTime,
                            statusMessage: rs.statusMessage
                        )
                    } else if resolvedRows.columns.isEmpty && tab.execution.errorMessage == nil
                        && tab.execution.lastExecutedAt != nil && !coordinator.tabExecution.isExecuting(tab.id)
                    {
                        if tab.display.resultSets.isEmpty {
                            Spacer()
                        } else {
                            ResultSuccessView(
                                rowsAffected: tab.execution.rowsAffected,
                                executionTime: tab.execution.executionTime,
                                statusMessage: tab.execution.statusMessage
                            )
                        }
                    } else {
                        rowFilterChrome(tab: tab, rows: resolvedRows)

                        if tab.findState.isVisible && tab.tabType == .table {
                            FindBarView(
                                coordinator: coordinator,
                                findState: tab.findState,
                                rowsRevision: tab.loadEpoch
                                    &+ tab.pagination.currentPage
                                    &+ tab.paginationVersion
                                    &+ resolvedRows.rows.count,
                                onSearchAllRows: { coordinator.findCoordinator.escalateToAllRows() }
                            )
                            Divider()
                        }

                        if tab.tabType == .query && !resolvedRows.columns.isEmpty
                            && resolvedRows.rows.isEmpty && tab.execution.lastExecutedAt != nil
                            && !coordinator.tabExecution.isExecuting(tab.id) && !tab.filterState.hasAppliedFilters
                        {
                            emptyResultView(executionTime: tab.display.activeResultSet?.executionTime ?? tab.execution.executionTime)
                        } else {
                            dataGridView(tab: tab)
                        }
                    }
                }
            }

            if tab.display.activeExplainResult == nil {
                Divider()
                statusBar(tab: tab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shared by every mode whose `showsRowFilters` is true. Filtering rebuilds the query and
    /// re-runs it, so a mode that renders this panel shows filtered rows without knowing about it.
    @ViewBuilder
    private func rowFilterChrome(tab: QueryTab, rows: TableRows) -> some View {
        if tab.filterState.isVisible && tab.tabType == .table
            && tab.display.resultsViewMode.showsRowFilters
        {
            if let descriptor = coordinator.browseFilterDescriptor {
                KeyPatternSearchBar(coordinator: coordinator, descriptor: descriptor)
            } else {
                FilterPanelView(
                    coordinator: coordinator,
                    columns: rows.columns,
                    primaryKeyColumn: changeManager.primaryKeyColumn,
                    databaseType: connection.type,
                    enumValuesByColumn: rows.columnEnumValues,
                    onApply: onApplyFilters,
                    onUnset: onClearFilters
                )
            }
            Divider()
        }
    }

    @ViewBuilder
    private func resultTabBarSection(tab: QueryTab) -> some View {
        if ResultTabBarPolicy.showsTabBar(tabType: tab.tabType, display: tab.display) {
            resultTabBar(tab: tab)
            Divider()
        }
    }

    private func resultTabBar(tab: QueryTab) -> some View {
        ResultTabBar(
            resultSets: tab.display.resultSets,
            activeResultSetId: Binding(
                get: { tab.display.activeResultSetId },
                set: { newId in
                    coordinator.switchActiveResultSet(to: newId, in: tab.id)
                }
            ),
            onClose: { id in
                coordinator.closeResultSet(id: id)
            },
            onTogglePin: { id in
                coordinator.togglePinResultSet(id: id)
            }
        )
    }

    private func emptyResultView(executionTime: TimeInterval?) -> some View {
        let description: String? = executionTime.map { String(format: "%.3fs", $0) }
        return ContentUnavailableView {
            Label(String(localized: "No rows returned"), systemImage: "tray")
        } description: {
            if let description {
                Text(description)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func dataGridView(tab: QueryTab) -> some View {
        let isEditable = tab.tableContext.isEditable && !tab.tableContext.isView && !coordinator.safeModeLevel.blocksAllWrites

        let tabId = tab.id
        DataGridView(
            tableRowsProvider: { [coordinator] in
                coordinator.tabSessionRegistry.existingTableRows(for: tabId) ?? TableRows()
            },
            tableRowsMutator: { [coordinator] mutate in
                coordinator.mutateActiveTableRows(for: tabId) { rows in
                    mutate(&rows)
                    return .none
                }
            },
            paginationOffsetProvider: { [coordinator] in
                coordinator.tabManager.tabs.first(where: { $0.id == tabId })?.pagination.currentOffset ?? 0
            },
            changeManager: currentChangeManager,
            isEditable: isEditable,
            configuration: DataGridConfiguration(
                connectionId: connection.id,
                databaseType: connection.type,
                tableName: tab.tableContext.tableName,
                databaseName: tab.tableContext.databaseName,
                schemaName: tab.tableContext.schemaName,
                primaryKeyColumns: changeManager.primaryKeyColumns,
                tabType: tab.tabType,
                showRowNumbers: AppSettingsManager.shared.dataGrid.showRowNumbers,
                hiddenColumns: tab.columnLayout.hiddenColumns
            ),
            displayFormats: coordinator.displayFormats(for: tab),
            delegate: dataTabDelegate,
            selectedRowIndices: Binding(
                get: { selectionState.indices },
                set: { selectionState.indices = $0 }
            ),
            sortState: sortStateBinding(for: tab),
            columnLayout: columnLayoutBinding(for: tab),
            valueFilter: valueFilterBinding(for: tab)
        )
        .id(tabId)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func resolvedTableRows(for tab: QueryTab) -> TableRows {
        coordinator.tabSessionRegistry.existingTableRows(for: tab.id) ?? TableRows()
    }

    private func valueFilterBinding(for tab: QueryTab) -> Binding<GridValueFilterState> {
        let tabId = tab.id
        return Binding(
            get: { tab.valueFilter },
            set: { coordinator.setValueFilter($0, forTab: tabId) }
        )
    }

    private func sortStateBinding(for tab: QueryTab) -> Binding<SortState> {
        Binding(
            get: { tab.sortState },
            set: { newValue in
                if let index = tabManager.selectedTabIndex {
                    tabManager.mutate(at: index) { $0.sortState = newValue }
                }
            }
        )
    }

    /// The chart's choices belong to the tab, not to the result set: a page turn, a sort or a
    /// re-execute builds a new `ResultSet`, and the axes have to outlive it.
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

    private func columnLayoutBinding(for tab: QueryTab) -> Binding<ColumnLayoutState> {
        let tabId = tab.id
        return Binding(
            get: { tab.columnLayout },
            set: { newValue in
                coordinator.isUpdatingColumnLayout = true
                coordinator.applyColumnGeometry(from: newValue, toTabId: tabId)
                Task { @MainActor in
                    coordinator.isUpdatingColumnLayout = false
                }
            }
        )
    }

    // MARK: - Status Bar

    private func statusBar(tab: QueryTab) -> some View {
        let resolvedRows = resolvedTableRows(for: tab)
        return MainStatusBarView(
            snapshot: StatusBarSnapshot(tab: tab, tableRows: resolvedRows),
            filterState: tab.filterState,
            selectedRowIndices: selectionState.indices,
            viewMode: resultsViewModeBinding(for: tab),
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
            columnState: StatusBarColumnState(
                hidden: tab.columnLayout.hiddenColumns,
                all: coordinator.columnsForVisibilityPicker(for: tab, resultColumns: resolvedRows.columns),
                onToggle: { coordinator.toggleColumnVisibility($0) },
                onShowAll: { coordinator.showAllColumns() },
                onHideAll: { coordinator.hideAllColumns($0) },
                onReset: { coordinator.resetColumns() }
            ),
            structureState: StatusBarStructureState(
                footer: coordinator.structureFooterState,
                onAdd: { coordinator.structureActions?.addRow?() },
                onRemove: { coordinator.structureActions?.removeRow?() }
            ),
            onToggleFilters: { coordinator.toggleFilterPanel() },
            onFetchAll: { coordinator.fetchAllRows() },
            onAddRow: currentTabAllowsAddRow ? { onAddRow() } : nil
        )
    }

    private func resultsViewModeBinding(for tab: QueryTab) -> Binding<ResultsViewMode> {
        Binding(
            get: { tab.display.resultsViewMode },
            set: { newValue in
                Task { @MainActor in
                    if let index = tabManager.selectedTabIndex {
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
