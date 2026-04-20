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

/// Cache for sorted query result rows to avoid re-sorting on every SwiftUI body evaluation
private struct SortedRowsCache {
    let sortedIndices: [Int]
    let columnIndex: Int
    let direction: SortDirection
    let resultVersion: Int
}

/// Per-tab row provider cache entry — groups all cache-invalidation keys together
private struct RowProviderCacheEntry {
    let provider: InMemoryRowProvider
    let resultVersion: Int
    let metadataVersion: Int
    let sortState: SortState
}

/// Main editor content with tab bar and content switching
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

    // MARK: - Bindings

    @Binding var selectedRowIndices: Set<Int>
    @Binding var editingCell: CellPosition?

    // MARK: - Callbacks

    let onCellEdit: (Int, Int, String?) -> Void
    let onSort: (Int, Bool, Bool) -> Void
    let onAddRow: () -> Void
    let onUndoInsert: (Int) -> Void
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

    // MARK: - Sort Cache

    @State private var sortCache: [UUID: SortedRowsCache] = [:]

    // Per-tab row provider cache — avoids recreation on every SwiftUI render.
    @State private var tabProviderCache: [UUID: RowProviderCacheEntry] = [:]
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
        return AnyChangeManager(dataManager: changeManager)
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
        .onChange(of: tabManager.tabIds) { _, newIds in
            guard !sortCache.isEmpty || !tabProviderCache.isEmpty || !erDiagramViewModels.isEmpty
                || !serverDashboardViewModels.isEmpty else {
                coordinator.cleanupSortCache(openTabIds: Set(newIds))
                return
            }
            let openTabIds = Set(newIds)
            sortCache = sortCache.filter { openTabIds.contains($0.key) }
            coordinator.cleanupSortCache(openTabIds: openTabIds)
            tabProviderCache = tabProviderCache.filter { openTabIds.contains($0.key) }
            erDiagramViewModels = erDiagramViewModels.filter { openTabIds.contains($0.key) }
            serverDashboardViewModels = serverDashboardViewModels.filter { openTabIds.contains($0.key) }
        }
        .onChange(of: tabManager.selectedTabId) { _, newId in
            updateHasQueryText()

            guard let newId, let tab = tabManager.selectedTab else { return }
            let cached = tabProviderCache[newId]
            if cached?.resultVersion != tab.resultVersion
                || cached?.metadataVersion != tab.metadataVersion
            {
                cacheRowProvider(for: tab)
            }
        }
        .onAppear {
            updateHasQueryText()
            cachedChangeManager = AnyChangeManager(dataManager: changeManager)
            if let tab = tabManager.selectedTab {
                cacheRowProvider(for: tab)
            }
            coordinator.onTeardown = { [self] in
                tabProviderCache.removeAll()
                sortCache.removeAll()
                cachedChangeManager = nil
            }
        }
        .onChange(of: tabManager.selectedTab?.resultVersion) { _, newVersion in
            guard let tab = tabManager.selectedTab, newVersion != nil else { return }
            cacheRowProvider(for: tab)
        }
        .onChange(of: tabManager.selectedTab?.metadataVersion) { _, _ in
            guard let tab = tabManager.selectedTab else { return }
            cacheRowProvider(for: tab)
        }
        .onChange(of: tabManager.selectedTab?.activeResultSetId) { _, _ in
            guard let tab = tabManager.selectedTab else { return }
            cacheRowProvider(for: tab)
        }
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
                            schemaKey: tab.erDiagramSchemaKey ?? tab.databaseName
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
            isBottomCollapsed: tab.isResultsCollapsed,
            autosaveName: "QuerySplit-\(connectionId)-\(tab.id)",
            topContent: {
                VStack(spacing: 0) {
                    QueryEditorView(
                        queryText: queryTextBinding(for: tab),
                        cursorPositions: $bindableCoordinator.cursorPositions,
                        onExecute: { coordinator.runQuery() },
                        schemaProvider: coordinator.schemaProvider,
                        databaseType: coordinator.connection.type,
                        connectionId: coordinator.connection.id,
                        connectionAIPolicy: coordinator.connection.aiPolicy ?? AppSettingsManager.shared.ai.defaultConnectionPolicy,
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
            coordinator.toolbarState.hasQueryText = !tab.query.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        } else {
            coordinator.toolbarState.hasQueryText = false
        }
    }

    private func queryTextBinding(for tab: QueryTab) -> Binding<String> {
        let tabId = tab.id
        return Binding(
            get: { tab.query },
            set: { newValue in
                // Find this tab by ID, not by selectedTabIndex. During tab switch,
                // flushTextUpdate() fires on the OLD tab's EditorCoordinator when
                // selectedTabIndex already points to the NEW tab — writing to
                // selectedTabIndex would overwrite the new tab's query.
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
                    index < tabManager.tabs.count
                else { return }

                tabManager.tabs[index].query = newValue

                // Update window dirty indicator and toolbar for file-backed tabs
                if tabManager.tabs[index].sourceFileURL != nil {
                    let isDirty = tabManager.tabs[index].isFileDirty
                    Task { @MainActor in
                        if let window = NSApp.keyWindow {
                            window.isDocumentEdited = isDirty
                        }
                    }
                }

                // Skip persistence for very large queries (e.g., imported SQL dumps).
                // JSON-encoding 40MB freezes the main thread.
                let queryLength = (newValue as NSString).length
                guard queryLength < QueryTab.maxPersistableQuerySize else { return }

                coordinator.persistence.saveLastQuery(newValue)
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
            if tab.showStructure, let tableName = tab.tableName {
                TableStructureView(
                    tableName: tableName, connection: connection,
                    toolbarState: coordinator.toolbarState, coordinator: coordinator
                )
                .id(tableName)
                .frame(maxHeight: .infinity)
            } else if let explainText = tab.explainText {
                ExplainResultView(text: explainText, executionTime: tab.explainExecutionTime, plan: tab.explainPlan)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Result tab bar (when multiple result sets)
                if tab.resultSets.count > 1 {
                    resultTabBar(tab: tab)
                    Divider()
                }

                // Inline error banner (when active result set has error)
                if let error = tab.activeResultSet?.errorMessage {
                    InlineErrorBanner(
                        message: error,
                        onDismiss: { tab.activeResultSet?.errorMessage = nil }
                    )
                    Divider()
                }

                // Content: success view OR filter+grid
                if let rs = tab.activeResultSet, rs.resultColumns.isEmpty,
                   rs.errorMessage == nil, tab.lastExecutedAt != nil, !tab.isExecuting
                {
                    ResultSuccessView(
                        rowsAffected: rs.rowsAffected,
                        executionTime: rs.executionTime,
                        statusMessage: rs.statusMessage
                    )
                } else if tab.resultColumns.isEmpty && tab.errorMessage == nil
                    && tab.lastExecutedAt != nil && !tab.isExecuting
                {
                    if tab.resultSets.isEmpty {
                        Spacer()
                    } else {
                        ResultSuccessView(
                            rowsAffected: tab.rowsAffected,
                            executionTime: tab.executionTime,
                            statusMessage: tab.statusMessage
                        )
                    }
                } else {
                    // Filter panel (collapsible, above data grid)
                    if filterStateManager.isVisible && tab.tabType == .table {
                        FilterPanelView(
                            filterState: filterStateManager,
                            columns: tab.resultColumns,
                            primaryKeyColumn: changeManager.primaryKeyColumn,
                            databaseType: connection.type,
                            onApply: onApplyFilters,
                            onUnset: onClearFilters
                        )
                        Divider()
                    }

                    if tab.tabType == .query && !tab.resultColumns.isEmpty
                        && tab.resultRows.isEmpty && tab.lastExecutedAt != nil
                        && !tab.isExecuting && !filterStateManager.hasAppliedFilters
                    {
                        emptyResultView(executionTime: tab.activeResultSet?.executionTime ?? tab.executionTime)
                    } else {
                        dataGridView(tab: tab)
                    }
                }
            }

            if tab.explainText == nil {
                statusBar(tab: tab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultTabBar(tab: QueryTab) -> some View {
        ResultTabBar(
            resultSets: tab.resultSets,
            activeResultSetId: Binding(
                get: { tab.activeResultSetId },
                set: { newId in
                    if let tabIdx = coordinator.tabManager.selectedTabIndex {
                        coordinator.tabManager.tabs[tabIdx].activeResultSetId = newId
                    }
                }
            ),
            onClose: { id in
                coordinator.closeResultSet(id: id)
            },
            onPin: { id in
                guard let tabIdx = coordinator.tabManager.selectedTabIndex else { return }
                coordinator.tabManager.tabs[tabIdx].resultSets.first { $0.id == id }?.isPinned.toggle()
                coordinator.tabManager.tabs[tabIdx].resultVersion += 1
            }
        )
    }

    private func emptyResultView(executionTime: TimeInterval?) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No rows returned")
                .font(.body.weight(.medium))
            if let time = executionTime {
                Text(String(format: "%.3fs", time))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func dataGridView(tab: QueryTab) -> some View {
        let isEditable = tab.isEditable && !tab.isView && !coordinator.safeModeLevel.blocksAllWrites
        let showEmptySpaceMenu = isEditable && tab.tableName != nil

        // Update delegate state for current render
        let _ = { // swiftlint:disable:this redundant_discardable_let
            dataTabDelegate.coordinator = coordinator
            dataTabDelegate.columnVisibilityManager = columnVisibilityManager
            dataTabDelegate.selectedRowIndices = $selectedRowIndices
            dataTabDelegate.editingCell = $editingCell
            dataTabDelegate.onCellEdit = onCellEdit
            dataTabDelegate.onSort = onSort
            dataTabDelegate.onAddRow = showEmptySpaceMenu ? onAddRow : nil
            dataTabDelegate.onUndoInsert = onUndoInsert
            dataTabDelegate.onFilterColumn = onFilterColumn
            dataTabDelegate.onRefresh = onRefresh
        }()

        DataGridView(
            rowProvider: rowProvider(for: tab),
            changeManager: currentChangeManager,
            resultVersion: tab.resultVersion,
            metadataVersion: tab.metadataVersion,
            paginationVersion: tab.paginationVersion,
            isEditable: isEditable,
            configuration: DataGridConfiguration(
                connectionId: connection.id,
                databaseType: connection.type,
                tableName: tab.tableName,
                primaryKeyColumns: changeManager.primaryKeyColumns,
                tabType: tab.tabType,
                showRowNumbers: AppSettingsManager.shared.dataGrid.showRowNumbers,
                hiddenColumns: columnVisibilityManager.hiddenColumns
            ),
            delegate: dataTabDelegate,
            selectedRowIndices: $selectedRowIndices,
            sortState: sortStateBinding(for: tab),
            editingCell: $editingCell,
            columnLayout: columnLayoutBinding(for: tab)
        )
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func rowProvider(for tab: QueryTab) -> InMemoryRowProvider {
        if tab.rowBuffer.isEvicted {
            Task { @MainActor in tabProviderCache.removeValue(forKey: tab.id) }
            return makeRowProvider(for: tab)
        }
        if let entry = tabProviderCache[tab.id],
            entry.resultVersion == tab.resultVersion,
            entry.metadataVersion == tab.metadataVersion,
            entry.sortState == tab.sortState
        {
            return entry.provider
        }
        let provider = makeRowProvider(for: tab)
        Task { @MainActor in
            tabProviderCache[tab.id] = RowProviderCacheEntry(
                provider: provider,
                resultVersion: tab.resultVersion,
                metadataVersion: tab.metadataVersion,
                sortState: tab.sortState
            )
        }
        return provider
    }

    private func cacheRowProvider(for tab: QueryTab) {
        let provider = makeRowProvider(for: tab)
        tabProviderCache[tab.id] = RowProviderCacheEntry(
            provider: provider,
            resultVersion: tab.resultVersion,
            metadataVersion: tab.metadataVersion,
            sortState: tab.sortState
        )
    }

    private func makeRowProvider(for tab: QueryTab) -> InMemoryRowProvider {
        let provider: InMemoryRowProvider

        // Use active ResultSet data when available (multi-statement results)
        if let rs = tab.activeResultSet, !rs.resultColumns.isEmpty {
            provider = InMemoryRowProvider(
                rowBuffer: rs.rowBuffer,
                sortIndices: sortIndicesForTab(tab),
                columns: rs.resultColumns,
                columnDefaults: rs.columnDefaults,
                columnTypes: rs.columnTypes,
                columnForeignKeys: rs.columnForeignKeys,
                columnEnumValues: rs.columnEnumValues,
                columnNullable: rs.columnNullable
            )
        } else {
            provider = InMemoryRowProvider(
                rowBuffer: tab.rowBuffer,
                sortIndices: sortIndicesForTab(tab),
                columns: tab.resultColumns,
                columnDefaults: tab.columnDefaults,
                columnTypes: tab.columnTypes,
                columnForeignKeys: tab.columnForeignKeys,
                columnEnumValues: tab.columnEnumValues,
                columnNullable: tab.columnNullable
            )
        }

        applyDisplayFormats(to: provider, tab: tab)
        return provider
    }

    private func applyDisplayFormats(to provider: InMemoryRowProvider, tab: QueryTab) {
        let columns = provider.columns
        let columnTypes = provider.columnTypes
        guard !columns.isEmpty else { return }

        let settings = AppSettingsManager.shared.dataGrid
        let service = ValueDisplayFormatService.shared

        // Auto-detect formats when the setting is enabled
        var detected: [ValueDisplayFormat?] = Array(repeating: nil, count: columns.count)
        if settings.enableSmartValueDetection {
            let sampleRows: [[String?]]? = {
                let rows = tab.activeResultSet?.resultRows ?? tab.resultRows
                return rows.isEmpty ? nil : Array(rows.prefix(10))
            }()
            detected = ValueDisplayDetector.detect(
                columns: columns,
                columnTypes: columnTypes,
                sampleValues: sampleRows
            )

            // Update service's auto-detected formats
            var autoMap: [String: ValueDisplayFormat] = [:]
            for (i, format) in detected.enumerated() where i < columns.count {
                if let format {
                    autoMap[columns[i]] = format
                }
            }
            service.setAutoDetectedFormats(autoMap, connectionId: connectionId, tableName: tab.tableName)
        } else {
            service.clearAutoDetectedFormats(connectionId: connectionId, tableName: tab.tableName)
        }

        // Merge with stored overrides (override > detection > nil)
        let connId = connectionId
        let tblName = tab.tableName
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

        // Only set if there's at least one non-nil format
        if merged.contains(where: { $0 != nil }) {
            provider.updateDisplayFormats(merged)
        }
    }

    /// Returns sort index permutation for a tab, or nil if no sorting is needed.
    /// For table tabs, sorting is handled server-side via SQL ORDER BY.
    private func sortIndicesForTab(_ tab: QueryTab) -> [Int]? {
        // Resolve data source: active ResultSet or tab-level fallback
        let rowBuffer: RowBuffer
        let rows: [[String?]]
        let colTypes: [ColumnType]
        if let rs = tab.activeResultSet, !rs.resultColumns.isEmpty {
            rowBuffer = rs.rowBuffer
            rows = rs.resultRows
            colTypes = rs.columnTypes
        } else {
            rowBuffer = tab.rowBuffer
            rows = tab.resultRows
            colTypes = tab.columnTypes
        }

        guard !rowBuffer.isEvicted else { return nil }

        // Table tabs: no client-side sorting
        if tab.tabType == .table {
            return nil
        }

        // Query tabs: apply client-side sorting
        guard tab.sortState.isSorting else {
            return nil
        }

        // Check coordinator's async sort cache (for large datasets sorted on background thread)
        if let cached = coordinator.querySortCache[tab.id],
            cached.columnIndex == (tab.sortState.columnIndex ?? -1),
            cached.direction == tab.sortState.direction,
            cached.resultVersion == tab.resultVersion
        {
            return cached.sortedIndices
        }

        // For datasets sorted async, return nil (unsorted) until cache is ready
        if rows.count > 1_000 {
            return nil
        }

        // Small dataset: sort synchronously with view-level cache
        if let cached = sortCache[tab.id],
            cached.columnIndex == (tab.sortState.columnIndex ?? -1),
            cached.direction == tab.sortState.direction,
            cached.resultVersion == tab.resultVersion
        {
            return cached.sortedIndices
        }

        let sortColumns = tab.sortState.columns
        let indices = Array(rows.indices)
        let sortedIndices = indices.sorted { idx1, idx2 in
            let row1 = rows[idx1]
            let row2 = rows[idx2]
            for sortCol in sortColumns {
                let val1 =
                    sortCol.columnIndex < row1.count
                    ? (row1[sortCol.columnIndex] ?? "") : ""
                let val2 =
                    sortCol.columnIndex < row2.count
                    ? (row2[sortCol.columnIndex] ?? "") : ""
                let colType =
                    sortCol.columnIndex < colTypes.count
                    ? colTypes[sortCol.columnIndex] : nil
                let result = RowSortComparator.compare(val1, val2, columnType: colType)
                if result == .orderedSame { continue }
                return sortCol.direction == .ascending
                    ? result == .orderedAscending
                    : result == .orderedDescending
            }
            return false
        }

        // Cache the result
        sortCache[tab.id] = SortedRowsCache(
            sortedIndices: sortedIndices,
            columnIndex: tab.sortState.columnIndex ?? -1,
            direction: tab.sortState.direction,
            resultVersion: tab.resultVersion
        )

        return sortedIndices
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
                    coordinator.saveColumnLayoutForTable()
                }
            }
        )
    }

    // MARK: - Status Bar

    private func statusBar(tab: QueryTab) -> some View {
        MainStatusBarView(
            tab: tab,
            filterStateManager: filterStateManager,
            columnVisibilityManager: columnVisibilityManager,
            allColumns: tab.resultColumns,
            selectedRowIndices: selectedRowIndices,
            showStructure: showStructureBinding(for: tab),
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

    private func showStructureBinding(for tab: QueryTab) -> Binding<Bool> {
        Binding(
            get: { tab.showStructure },
            set: { newValue in
                Task { @MainActor in
                    if let index = tabManager.selectedTabIndex {
                        tabManager.tabs[index].showStructure = newValue
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
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)

            // Helpful instructions with keyboard shortcuts
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("⌘T")
                        .font(.system(size: 13, design: .monospaced))
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

                HStack(spacing: 6) {
                    Text("⌘K")
                        .font(.system(size: 13, design: .monospaced))
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
