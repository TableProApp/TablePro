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

struct MainEditorContentView: View {
    // MARK: - Dependencies

    var tabManager: QueryTabManager
    var coordinator: MainContentCoordinator
    var changeManager: DataChangeManager
    var filterStateManager: FilterStateManager
    var columnVisibilityManager: ColumnVisibilityManager
    let connection: DatabaseConnection
    let windowId: UUID
    let connectionId: UUID

    // MARK: - Selection State

    let selectionState: GridSelectionState

    // MARK: - Callbacks

    let onCellEdit: (Int, Int, String?) -> Void
    let onSort: (Int, Bool, Bool) -> Void
    let onClearSort: () -> Void
    let onRemoveSortColumn: (Int) -> Void
    let onAddRow: () -> Void
    let onUndoInsert: (Int) -> Void
    let onSelectionChange: (Set<Int>) -> Void
    let onFilterColumn: (String) -> Void
    let onApplyFilters: ([TableFilter]) -> Void
    let onClearFilters: () -> Void
    let onRefresh: () -> Void

    // Pagination callbacks
    let onFirstPage: () -> Void
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let onLastPage: () -> Void
    let onLimitChange: (Int) -> Void
    let onOffsetChange: (Int) -> Void
    let onPaginationGo: () -> Void

    @State private var cachedChangeManager: AnyChangeManager?
    @State private var erDiagramViewModels: [UUID: ERDiagramViewModel] = [:]
    @State private var serverDashboardViewModels: [UUID: ServerDashboardViewModel] = [:]
    @State private var favoriteDialogQuery: FavoriteDialogQuery?
    @State private var dataTabDelegate = DataTabGridDelegate()

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
        let isHistoryVisible = coordinator.toolbarState.isHistoryPanelVisible

        VStack(spacing: 0) {
            // Native macOS window tabs replace the custom tab bar.
            // Each window-tab contains a single tab — no ZStack keep-alive needed.
            if let tab = tabManager.selectedTab {
                tabContent(for: tab)
            } else {
                emptyStateView
            }

            // Global History Panel
            if isHistoryVisible {
                Divider()
                HistoryPanelView(connectionId: connectionId)
                    .frame(height: 300)
            }
        }
        .background(.background)
        .sheet(item: $favoriteDialogQuery) { item in
            FavoriteEditDialog(
                connectionId: connectionId,
                favorite: nil,
                initialQuery: item.query,
                folders: []
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveAsFavoriteRequested)) { notification in
            guard let query = notification.userInfo?["query"] as? String else { return }
            favoriteDialogQuery = FavoriteDialogQuery(query: query)
        }
        .onChange(of: tabManager.tabStructureVersion) { _, _ in
            let openTabIds = Set(tabManager.tabIds)
            coordinator.cleanupSortCache(openTabIds: openTabIds)
            erDiagramViewModels = erDiagramViewModels.filter { openTabIds.contains($0.key) }
            serverDashboardViewModels = serverDashboardViewModels.filter { openTabIds.contains($0.key) }
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
            coordinator.onTeardown = { [self] in
                cachedChangeManager = nil
                coordinator.dataTabDelegate = nil
            }
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
        dataTabDelegate.columnVisibilityManager = columnVisibilityManager
        dataTabDelegate.selectionState = selectionState
        dataTabDelegate.onCellEdit = onCellEdit
        dataTabDelegate.onSort = onSort
        dataTabDelegate.onClearSort = onClearSort
        dataTabDelegate.onRemoveSortColumn = onRemoveSortColumn
        dataTabDelegate.onUndoInsert = onUndoInsert
        dataTabDelegate.onFilterColumn = onFilterColumn
        dataTabDelegate.onRefresh = onRefresh
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
            CreateTableView(
                connection: connection,
                coordinator: coordinator
            )
        case .erDiagram:
            erDiagramContent(tab: tab)
        case .serverDashboard:
            serverDashboardContent(tab: tab)
        case .terminal:
            terminalTabContent(tab: tab)
        }
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

    // MARK: - Terminal Tab Content

    @ViewBuilder
    private func terminalTabContent(tab: QueryTab) -> some View {
        TerminalTabContentView(
            tab: tab,
            connection: connection,
            connectionId: connectionId
        )
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
                            schemaKey: tab.display.erDiagramSchemaKey ?? tab.tableContext.databaseName
                        )
                        erDiagramViewModels[tab.id] = vm
                    }
            }
        }
        .id(tab.id)
    }

    // MARK: - Query Tab Content

    @ViewBuilder
    private func queryTabContent(tab: QueryTab) -> some View {
        @Bindable var bindableCoordinator = coordinator
        QuerySplitView(
            isBottomCollapsed: tab.display.isResultsCollapsed,
            autosaveName: "QuerySplit-\(connectionId)-\(tab.id)",
            topContent: {
                VStack(spacing: 0) {
                    QueryEditorView(
                        queryText: queryTextBinding(for: tab),
                        cursorPositions: $bindableCoordinator.cursorPositions,
                        parameters: parameterBinding(for: tab),
                        isParameterPanelVisible: parameterVisibilityBinding(for: tab),
                        onExecute: { coordinator.runQuery() },
                        schemaProvider: coordinator.schemaProvider,
                        databaseType: coordinator.connection.type,
                        connectionId: coordinator.connection.id,
                        connectionAIPolicy: coordinator.connection.aiPolicy ?? AppSettingsManager.shared.ai.defaultConnectionPolicy,
                        tabID: tab.id,
                        onCloseTab: {
                            NSApp.keyWindow?.close()
                        },
                        onExecuteQuery: { coordinator.runQuery() },
                        onExplain: { variant in
                            if let variant {
                                coordinator.runClickHouseExplain(variant: variant)
                            } else {
                                coordinator.runExplainQuery()
                            }
                        },
                        onExplainVariant: { variant in
                            coordinator.runVariantExplain(variant)
                        },
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
                            favoriteDialogQuery = FavoriteDialogQuery(query: text)
                        }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            },
            bottomContent: {
                resultsSection(tab: tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        )
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
        return Binding(
            get: { tab.content.query },
            set: { newValue in
                // Find this tab by ID, not by selectedTabIndex. During tab switch,
                // flushTextUpdate() fires on the OLD tab's EditorCoordinator when
                // selectedTabIndex already points to the NEW tab — writing to
                // selectedTabIndex would overwrite the new tab's query.
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
                    index < tabManager.tabs.count
                else { return }

                tabManager.tabs[index].content.query = newValue

                if tabManager.tabs[index].content.sourceFileURL != nil {
                    let isDirty = tabManager.tabs[index].content.isFileDirty
                    Task { @MainActor in
                        if let window = NSApp.keyWindow {
                            window.isDocumentEdited = isDirty
                        }
                    }
                }
            }
        )
    }

    private func parameterBinding(for tab: QueryTab) -> Binding<[QueryParameter]> {
        let tabId = tab.id
        return Binding(
            get: { tab.content.queryParameters },
            set: { newValue in
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
                tabManager.tabs[index].content.queryParameters = newValue
            }
        )
    }

    private func parameterVisibilityBinding(for tab: QueryTab) -> Binding<Bool> {
        let tabId = tab.id
        return Binding(
            get: { tab.content.isParameterPanelVisible },
            set: { newValue in
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
                tabManager.tabs[index].content.isParameterPanelVisible = newValue
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
    private func resultsSection(tab: QueryTab) -> some View {
        VStack(spacing: 0) {
            switch tab.display.resultsViewMode {
            case .structure:
                if let tableName = tab.tableContext.tableName {
                    TableStructureView(
                        tableName: tableName, connection: connection,
                        toolbarState: coordinator.toolbarState, coordinator: coordinator
                    )
                    .id(tableName)
                    .frame(maxHeight: .infinity)
                }
            case .json:
                ResultsJsonView(
                    tableRows: resolvedTableRows(for: tab),
                    selectedRowIndices: selectionState.indices
                )
            case .data:
                if let explainText = tab.display.explainText {
                    ExplainResultView(text: explainText, executionTime: tab.display.explainExecutionTime, plan: tab.display.explainPlan)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    if tab.display.resultSets.count > 1 {
                        resultTabBar(tab: tab)
                        Divider()
                    }

                    if let error = tab.display.activeResultSet?.errorMessage {
                        InlineErrorBanner(
                            message: error,
                            onDismiss: { tab.display.activeResultSet?.errorMessage = nil }
                        )
                        Divider()
                    }

                    let resolvedRows = resolvedTableRows(for: tab)
                    if let rs = tab.display.activeResultSet, rs.resultColumns.isEmpty,
                       rs.errorMessage == nil, tab.execution.lastExecutedAt != nil, !tab.execution.isExecuting
                    {
                        ResultSuccessView(
                            rowsAffected: rs.rowsAffected,
                            executionTime: rs.executionTime,
                            statusMessage: rs.statusMessage
                        )
                    } else if resolvedRows.columns.isEmpty && tab.execution.errorMessage == nil
                        && tab.execution.lastExecutedAt != nil && !tab.execution.isExecuting
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
                        if filterStateManager.isVisible && tab.tabType == .table {
                            FilterPanelView(
                                filterState: filterStateManager,
                                columns: resolvedRows.columns,
                                primaryKeyColumn: changeManager.primaryKeyColumn,
                                databaseType: connection.type,
                                onApply: onApplyFilters,
                                onUnset: onClearFilters
                            )
                            Divider()
                        }

                        if tab.tabType == .query && !resolvedRows.columns.isEmpty
                            && resolvedRows.rows.isEmpty && tab.execution.lastExecutedAt != nil
                            && !tab.execution.isExecuting && !filterStateManager.hasAppliedFilters
                        {
                            emptyResultView(executionTime: tab.display.activeResultSet?.executionTime ?? tab.execution.executionTime)
                        } else {
                            dataGridView(tab: tab)
                        }
                    }
                }
            }

            if tab.display.explainText == nil {
                statusBar(tab: tab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            onPin: { id in
                guard let tabIdx = coordinator.tabManager.selectedTabIndex else { return }
                coordinator.tabManager.tabs[tabIdx].display.resultSets.first { $0.id == id }?.isPinned.toggle()
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
                coordinator.tableRowsStore.existingTableRows(for: tabId) ?? TableRows()
            },
            tableRowsMutator: { [coordinator] mutate in
                coordinator.mutateActiveTableRows(for: tabId) { rows in
                    mutate(&rows)
                    return .none
                }
            },
            changeManager: currentChangeManager,
            isEditable: isEditable,
            configuration: DataGridConfiguration(
                connectionId: connection.id,
                databaseType: connection.type,
                tableName: tab.tableContext.tableName,
                primaryKeyColumns: changeManager.primaryKeyColumns,
                tabType: tab.tabType,
                showRowNumbers: AppSettingsManager.shared.dataGrid.showRowNumbers,
                hiddenColumns: columnVisibilityManager.hiddenColumns
            ),
            sortedIDs: sortedIDsForTab(tab),
            displayFormats: displayFormats(for: tab),
            delegate: dataTabDelegate,
            selectedRowIndices: Binding(
                get: { selectionState.indices },
                set: { selectionState.indices = $0 }
            ),
            sortState: sortStateBinding(for: tab),
            columnLayout: columnLayoutBinding(for: tab)
        )
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func resolvedTableRows(for tab: QueryTab) -> TableRows {
        coordinator.tableRowsStore.existingTableRows(for: tab.id) ?? TableRows()
    }

    private func displayFormats(for tab: QueryTab) -> [ValueDisplayFormat?] {
        let settings = AppSettingsManager.shared.dataGrid
        let service = ValueDisplayFormatService.shared
        let smartDetectionEnabled = settings.enableSmartValueDetection
        let overridesVersion = service.overridesVersion

        if let cached = coordinator.displayFormatsCache[tab.id],
           cached.schemaVersion == tab.schemaVersion,
           cached.smartDetectionEnabled == smartDetectionEnabled,
           cached.overridesVersion == overridesVersion {
            return cached.formats
        }

        let tableRows = coordinator.tableRowsStore.existingTableRows(for: tab.id)
        let columns = tableRows?.columns ?? []
        let columnTypes = tableRows?.columnTypes ?? []
        guard !columns.isEmpty else { return [] }

        var detected: [ValueDisplayFormat?] = Array(repeating: nil, count: columns.count)
        if smartDetectionEnabled {
            let sampleRows: [[String?]]? = {
                let rows = tableRows?.rows.prefix(10).map(\.values) ?? []
                return rows.isEmpty ? nil : Array(rows)
            }()
            detected = ValueDisplayDetector.detect(
                columns: columns,
                columnTypes: columnTypes,
                sampleValues: sampleRows
            )

            var autoMap: [String: ValueDisplayFormat] = [:]
            for (i, format) in detected.enumerated() where i < columns.count {
                if let format {
                    autoMap[columns[i]] = format
                }
            }
            service.setAutoDetectedFormats(autoMap, connectionId: connectionId, tableName: tab.tableContext.tableName)
        } else {
            service.clearAutoDetectedFormats(connectionId: connectionId, tableName: tab.tableContext.tableName)
        }

        let connId = connectionId
        let tblName = tab.tableContext.tableName
        var merged = detected

        if let tblName {
            if let overrides = ValueDisplayFormatStorage.shared.load(for: tblName, connectionId: connId) {
                for (i, colName) in columns.enumerated() {
                    if let overrideFormat = overrides[colName] {
                        while merged.count <= i { merged.append(nil) }
                        merged[i] = overrideFormat
                    }
                }
            }
        }

        let result = merged.contains(where: { $0 != nil }) ? merged : []
        coordinator.displayFormatsCache[tab.id] = DisplayFormatsCacheEntry(
            schemaVersion: tab.schemaVersion,
            smartDetectionEnabled: smartDetectionEnabled,
            overridesVersion: overridesVersion,
            formats: result
        )
        return result
    }

    /// Returns the display order as a permutation of `RowID`, or nil when no sort applies.
    /// For table tabs, sorting is handled server-side via SQL ORDER BY.
    private func sortedIDsForTab(_ tab: QueryTab) -> [RowID]? {
        if tab.tabType == .table {
            return nil
        }

        guard tab.sortState.isSorting else {
            return nil
        }

        let resolvedRows = resolvedTableRows(for: tab)
        guard !resolvedRows.rows.isEmpty else {
            return nil
        }
        let colTypes = resolvedRows.columnTypes

        if let cached = coordinator.querySortCache[tab.id],
            cached.columnIndex == (tab.sortState.columnIndex ?? -1),
            cached.direction == tab.sortState.direction,
            cached.schemaVersion == tab.schemaVersion
        {
            return cached.sortedIDs
        }

        if resolvedRows.rows.count > 1_000 {
            return nil
        }

        let sortColumns = tab.sortState.columns
        let storageRows = resolvedRows.rows
        let sortedIndices = Array(storageRows.indices).sorted { idx1, idx2 in
            let row1 = storageRows[idx1].values
            let row2 = storageRows[idx2].values
            for sortCol in sortColumns {
                let val1 = sortCol.columnIndex < row1.count
                    ? (row1[sortCol.columnIndex] ?? "") : ""
                let val2 = sortCol.columnIndex < row2.count
                    ? (row2[sortCol.columnIndex] ?? "") : ""
                let colType = sortCol.columnIndex < colTypes.count
                    ? colTypes[sortCol.columnIndex] : nil
                let result = RowSortComparator.compare(val1, val2, columnType: colType)
                if result == .orderedSame { continue }
                return sortCol.direction == .ascending
                    ? result == .orderedAscending
                    : result == .orderedDescending
            }
            return false
        }
        let sortedIDs = sortedIndices.map { storageRows[$0].id }

        coordinator.querySortCache[tab.id] = QuerySortCacheEntry(
            sortedIDs: sortedIDs,
            columnIndex: tab.sortState.columnIndex ?? -1,
            direction: tab.sortState.direction,
            schemaVersion: tab.schemaVersion
        )

        return sortedIDs
    }

    private func sortStateBinding(for tab: QueryTab) -> Binding<SortState> {
        Binding(
            get: { tab.sortState },
            set: { newValue in
                if let index = tabManager.selectedTabIndex {
                    tabManager.tabs[index].sortState = newValue
                }
            }
        )
    }

    private func columnLayoutBinding(for tab: QueryTab) -> Binding<ColumnLayoutState> {
        Binding(
            get: { tab.columnLayout },
            set: { newValue in
                coordinator.isUpdatingColumnLayout = true
                if let index = tabManager.selectedTabIndex {
                    tabManager.tabs[index].columnLayout = newValue
                }
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
            filterStateManager: filterStateManager,
            columnVisibilityManager: columnVisibilityManager,
            allColumns: resolvedRows.columns,
            selectedRowIndices: selectionState.indices,
            viewMode: resultsViewModeBinding(for: tab),
            onFirstPage: onFirstPage,
            onPreviousPage: onPreviousPage,
            onNextPage: onNextPage,
            onLastPage: onLastPage,
            onLimitChange: onLimitChange,
            onOffsetChange: onOffsetChange,
            onPaginationGo: onPaginationGo,
            onLoadMore: { coordinator.loadMoreRows() },
            onFetchAll: { coordinator.fetchAllRows() }
        )
    }

    private func resultsViewModeBinding(for tab: QueryTab) -> Binding<ResultsViewMode> {
        Binding(
            get: { tab.display.resultsViewMode },
            set: { newValue in
                Task { @MainActor in
                    if let index = tabManager.selectedTabIndex {
                        tabManager.tabs[index].display.resultsViewMode = newValue
                    }
                }
            }
        )
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            // Icon
            Image(systemName: "tablecells")
                .font(.system(size: 56))
                .foregroundStyle(.quaternary)
                .symbolRenderingMode(.hierarchical)

            // Title
            Text("No tabs open")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            // Helpful instructions with keyboard shortcuts
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

                if PluginManager.shared.supportsDatabaseSwitching(for: connection.type) {
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
                        Text("Switch Database")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
