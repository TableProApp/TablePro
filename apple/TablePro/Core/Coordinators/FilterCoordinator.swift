//
//  FilterCoordinator.swift
//  TablePro
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class FilterCoordinator: ObservableObject {
    unowned let parent: MainContentCoordinator

    init(parent: MainContentCoordinator) {
        self.parent = parent
    }

    // MARK: - Filtering

    func applyFilters(_ filters: [TableFilter], logicMode: FilterLogicMode? = nil, forTab tabId: UUID) {
        guard let tableName = existingTab(tabId)?.tableContext.tableName else { return }
        parent.confirmDiscardChangesIfNeeded(forTab: tabId, action: .filter) { [weak self] confirmed in
            guard let self, confirmed else { return }
            commitFilters(filters, logicMode: logicMode, tabId: tabId, tableName: tableName)
        }
    }

    // The caller holds the discard guard: it also records the view the tab leaves, and both land on one side of a refusal.
    func commitReferenceFilter(_ filter: TableFilter, forTab tabId: UUID) {
        guard let tableName = existingTab(tabId)?.tableContext.tableName else { return }
        mutateFilterState(ofTab: tabId) { $0.setReferenceFilter(filter) }
        commitFilters([filter], logicMode: nil, tabId: tabId, tableName: tableName)
    }

    // Builds the query before writing the filter state, so a refusal leaves the panel, commit and rows as they were.
    private func commitFilters(
        _ filters: [TableFilter],
        logicMode: FilterLogicMode?,
        tabId: UUID,
        tableName: String,
        adopting proposed: TabFilterState? = nil
    ) {
        guard let tab = existingTab(tabId) else { return }
        var next = proposed ?? tab.filterState
        if let logicMode {
            next.filterLogicMode = logicMode
            next.isVisible = true
        }
        if !parent.supportsMatchAnyFilters {
            next.filterLogicMode = .and
        }

        let queryColumns = parent.queryColumns(for: tab)
        guard let newQuery = parent.queryBuilder.buildFilteredQuery(
            tableName: tableName,
            schemaName: tab.tableContext.schemaName,
            filters: filters,
            logicMode: next.filterLogicMode,
            sortState: querySortState(for: tab),
            columns: queryColumns.columns,
            columnTypes: queryColumns.columnTypes,
            selectColumns: parent.selectColumns(for: tab),
            unloadedValues: parent.unloadedValuePlan(for: tab),
            limit: tab.pagination.pageSize,
            offset: 0
        ) else {
            let message = FilterSQLGenerator.refusalMessage(for: filters, databaseType: parent.connection.type)
                ?? String(localized: "This database cannot filter rows with these conditions.")
            parent.tabManager.mutate(tabId: tabId) {
                $0.execution.errorMessage = message
            }
            return
        }

        next.executedFilters = filters
        next.executedLogicMode = next.filterLogicMode
        parent.tabManager.mutate(tabId: tabId) {
            $0.pagination.reset()
            $0.content.query = newQuery
            $0.filterState = next
        }
        if let committed = existingTab(tabId) {
            saveLastFilters(of: committed)
        }
        parent.runQuery(onTab: tabId, viewport: .firstRow)
    }

    /// Stops filtering and keeps the rows in the panel, so Apply brings them back.
    func clearAppliedFiltersAndReload() {
        unsetFilters(removingRows: false)
    }

    /// Drops the table's filter rows along with the query they were running, which an empty save
    /// then reads as a delete. `FilterRestoreBehavior.dontSave` writes nothing either way, so a
    /// file saved before the setting was turned off outlives this.
    func removeAllFiltersAndReload() {
        unsetFilters(removingRows: true)
    }

    private func unsetFilters(removingRows: Bool) {
        guard let (selected, _) = parent.tabManager.selectedTabAndIndex,
              let tableName = selected.tableContext.tableName else { return }

        let tabId = selected.id
        parent.confirmDiscardChangesIfNeeded(forTab: tabId, action: .filter) { [weak self] confirmed in
            guard let self, confirmed,
                  parent.tabManager.mutate(tabId: tabId, { $0.pagination.reset() }),
                  let tab = existingTab(tabId) else { return }

            let buffer = parent.tabSessionRegistry.tableRows(for: tabId)
            let newQuery = parent.queryBuilder.buildBaseQuery(
                tableName: tableName,
                schemaName: tab.tableContext.schemaName,
                sortState: querySortState(for: tab),
                columns: buffer.columns,
                selectColumns: parent.selectColumns(for: tab),
                unloadedValues: parent.unloadedValuePlan(for: tab),
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset
            )

            parent.tabManager.mutate(tabId: tabId) {
                $0.content.query = newQuery
                $0.filterState.commit = nil
                $0.filterState.executedFilters = []
                $0.filterState.executedLogicMode = nil
                if removingRows {
                    $0.filterState.filters = []
                }
            }
            // Saved, not deleted: the rows left in the panel are the table's working set, and an empty set reads as a delete.
            if let unset = existingTab(tabId) {
                saveLastFilters(of: unset)
            }
            parent.runQuery(onTab: tabId, viewport: .firstRow)
        }
    }

    func restoreFiltersForSelectedTab() {
        guard let index = parent.tabManager.selectedTabIndex else { return }
        restoreFilters(forTabAt: index)
    }

    /// Loads a tab's saved filters into it, whether or not it is the selected tab.
    ///
    /// The selected tab also has its query rebuilt, because the query is derived from the filters
    /// and the tab may be carrying one built from a different set. A tab reopened from the recently
    /// closed history carries the last *filtered* SQL it ran, which would otherwise keep running
    /// while the panel reported nothing applied. A session restore is already safe, because
    /// `handleRestoreOrDefault` rewrites every table tab's query to a base query first.
    ///
    /// A tab that is not selected gets its filter state and nothing else. Its schema columns are
    /// not loaded yet (`prepareTableTabFirstLoad` gates that on selection) so a query built now
    /// would type its values by guessing at their text, and `rebuildTableQuery` writes
    /// `executedFilters`, which is the record of what the rows on screen were fetched with. That
    /// tab has no rows. Its first selection runs the first load, which rebuilds the query properly.
    func restoreFilters(forTabAt index: Int) {
        // Saved filters are keyed by name, which a temporary table shares with the permanent table it hides.
        guard index < parent.tabManager.tabs.count,
              !parent.tabManager.tabs[index].tableContext.isTemporary,
              let tableName = parent.tabManager.tabs[index].tableContext.tableName else { return }
        restoreLastFilters(for: tableName, at: index)
        restoreBrowseSearch(for: tableName, at: index)
        guard parent.tabManager.selectedTabIndex == index else { return }
        rebuildTableQuery(at: index)
    }

    var usesBrowseSearch: Bool {
        PluginManager.shared.browseFilterDescriptor(for: parent.connection.type) != nil
    }

    /// The search a tab's browse runs instead of its table filters. The browse query, the automatic
    /// row count and `Count Exactly` all read it here, so each describes the keys the grid lists.
    func activeBrowseSearch(for filterState: TabFilterState) -> BrowseSearchState? {
        filterState.activeBrowseSearch(isSupported: usesBrowseSearch)
    }

    func applyBrowseSearch(_ search: BrowseSearchState) {
        guard let (selected, _) = parent.tabManager.selectedTabAndIndex,
              let tableName = selected.tableContext.tableName else { return }

        let tabId = selected.id
        parent.confirmDiscardChangesIfNeeded(forTab: tabId, action: .filter) { [weak self] confirmed in
            guard let self, confirmed, existingTab(tabId) != nil else { return }

            mutateFilterState(ofTab: tabId) { state in
                state.browseSearch = search
                state.isVisible = true
            }
            // An exact total is never replaced by a later estimate, so the previous search's would describe this one.
            parent.tabManager.mutate(tabId: tabId) { tab in
                tab.pagination.reset()
                tab.pagination.retireDerivedRowCount()
            }
            rebuildTableQuery(forTab: tabId)
            saveBrowseSearch(for: tableName, ofTab: tabId)
            parent.runQuery(onTab: tabId, viewport: .firstRow)
        }
    }

    func clearBrowseSearchAndReload() {
        guard let (selected, _) = parent.tabManager.selectedTabAndIndex,
              let tableName = selected.tableContext.tableName else { return }

        let tabId = selected.id
        parent.confirmDiscardChangesIfNeeded(forTab: tabId, action: .filter) { [weak self] confirmed in
            guard let self, confirmed, existingTab(tabId) != nil else { return }

            mutateFilterState(ofTab: tabId) { state in
                state.browseSearch = BrowseSearchState()
            }
            // A total counted for the search does not describe the whole database.
            parent.tabManager.mutate(tabId: tabId) { tab in
                tab.pagination.reset()
                tab.pagination.retireDerivedRowCount()
            }
            rebuildTableQuery(forTab: tabId)
            saveBrowseSearch(for: tableName, ofTab: tabId)
            parent.runQuery(onTab: tabId, viewport: .firstRow)
        }
    }

    func saveBrowseSearch(for tableName: String, ofTab tabId: UUID) {
        guard let tab = existingTab(tabId) else { return }
        FilterSettingsStorage.shared.saveBrowseSearch(
            tab.filterState.browseSearch,
            for: tableName,
            connectionId: parent.connectionId,
            databaseName: tab.tableContext.databaseName,
            schemaName: tab.tableContext.schemaName
        )
    }

    private func restoreBrowseSearch(for tableName: String, at index: Int) {
        guard usesBrowseSearch, index < parent.tabManager.tabs.count else { return }
        let tab = parent.tabManager.tabs[index]
        let saved = FilterSettingsStorage.shared.loadBrowseSearch(
            for: tableName,
            connectionId: parent.connectionId,
            databaseName: tab.tableContext.databaseName,
            schemaName: tab.tableContext.schemaName
        )
        mutateFilterState(at: index) { state in
            state.browseSearch = saved
            if saved.isActive {
                state.isVisible = true
            }
        }
    }

    /// Rebuilds the tab's query for a page turn, sort, refresh or first load from the filters
    /// running on it, never from an edit the reader has not applied.
    ///
    /// Filters that cannot be built for this engine stop counting as applied, and the table loads
    /// without them, so the panel never reports a filter the rows were not fetched with.
    func rebuildTableQuery(at tabIndex: Int) {
        guard tabIndex < parent.tabManager.tabs.count,
              let tableName = parent.tabManager.tabs[tabIndex].tableContext.tableName else { return }
        normalizeLogicModeIfNeeded(at: tabIndex)

        let tab = parent.tabManager.tabs[tabIndex]
        let built = tableQuery(
            for: tab,
            tableName: tableName,
            limit: tab.pagination.pageSize,
            offset: tab.pagination.currentOffset
        )

        parent.tabManager.mutate(at: tabIndex) {
            $0.content.query = built.query
            if built.isRefused {
                $0.filterState.commit = nil
            }
            $0.filterState.executedFilters = built.executed
            $0.filterState.executedLogicMode = $0.filterState.commit == nil ? nil : built.logicMode
        }
    }

    func rebuildTableQuery(forTab tabId: UUID) {
        guard let index = parent.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        rebuildTableQuery(at: index)
    }

    // The table tab's view, its filters, search and sort, read from the first row: what Share Result reads.
    func viewQuery(for tab: QueryTab, limit: Int) -> String? {
        guard let tableName = tab.tableContext.tableName else { return nil }
        return tableQuery(for: tab, tableName: tableName, limit: limit, offset: 0).query
    }

    // The same view with no LIMIT or OFFSET, as a shared link shows it; nil when the host cannot write it as SQL.
    func viewSQL(for tab: QueryTab) -> String? {
        guard parent.queryBuilder.writesSQL,
              let tableName = tab.tableContext.tableName,
              activeBrowseSearch(for: tab.filterState) == nil
        else { return nil }
        let rerun = tab.filterState.rerunFilters
        let (columns, columnTypes) = parent.queryColumns(for: tab)
        guard !rerun.filters.isEmpty else {
            return parent.queryBuilder.buildBaseQuery(
                tableName: tableName,
                schemaName: tab.tableContext.schemaName,
                sortState: querySortState(for: tab),
                columns: columns,
                selectColumns: parent.selectColumns(for: tab),
                window: false
            )
        }
        return parent.queryBuilder.buildFilteredQuery(
            tableName: tableName,
            schemaName: tab.tableContext.schemaName,
            filters: rerun.filters,
            logicMode: parent.supportsMatchAnyFilters ? rerun.logicMode : .and,
            sortState: querySortState(for: tab),
            columns: columns,
            columnTypes: columnTypes,
            selectColumns: parent.selectColumns(for: tab),
            window: false
        )
    }

    private func tableQuery(
        for tab: QueryTab,
        tableName: String,
        limit: Int,
        offset: Int
    ) -> (query: String, executed: [TableFilter], isRefused: Bool, logicMode: FilterLogicMode) {
        let rerun = tab.filterState.rerunFilters
        let logicMode = parent.supportsMatchAnyFilters ? rerun.logicMode : .and
        let (columns, columnTypes) = parent.queryColumns(for: tab)

        let filteredQuery: String?
        var executed = rerun.filters
        if let search = activeBrowseSearch(for: tab.filterState) {
            filteredQuery = parent.queryBuilder.buildKeyPatternBrowseQuery(
                tableName: tableName,
                schemaName: tab.tableContext.schemaName,
                pattern: search.pattern,
                typeScope: search.typeScope,
                sortState: querySortState(for: tab),
                columns: columns,
                selectColumns: parent.selectColumns(for: tab),
                unloadedValues: parent.unloadedValuePlan(for: tab),
                limit: limit,
                offset: offset
            )
        } else if rerun.filters.isEmpty {
            filteredQuery = nil
        } else {
            filteredQuery = parent.queryBuilder.buildFilteredQuery(
                tableName: tableName,
                schemaName: tab.tableContext.schemaName,
                filters: rerun.filters,
                logicMode: logicMode,
                sortState: querySortState(for: tab),
                columns: columns,
                columnTypes: columnTypes,
                selectColumns: parent.selectColumns(for: tab),
                unloadedValues: parent.unloadedValuePlan(for: tab),
                limit: limit,
                offset: offset
            )
        }
        let isRefused = filteredQuery == nil && !rerun.filters.isEmpty
        if isRefused {
            executed = []
        }
        let query = filteredQuery ?? parent.queryBuilder.buildBaseQuery(
            tableName: tableName,
            schemaName: tab.tableContext.schemaName,
            sortState: querySortState(for: tab),
            columns: columns,
            selectColumns: parent.selectColumns(for: tab),
            unloadedValues: parent.unloadedValuePlan(for: tab),
            limit: limit,
            offset: offset
        )
        return (query, executed, isRefused, logicMode)
    }

    // MARK: - Filter State

    var selectedTabFilterState: TabFilterState {
        parent.tabManager.selectedTab?.filterState ?? TabFilterState()
    }

    var selectedTabFilterStateBinding: Binding<TabFilterState> {
        Binding(
            get: { [weak self] in
                self?.selectedTabFilterState ?? TabFilterState()
            },
            set: { [weak self] newValue in
                self?.mutateSelectedTabFilterState { $0 = newValue }
            }
        )
    }

    // MARK: - Filter Management

    /// The sort a table query carries. An engine that cannot order a table by a column gets none, so a sort
    /// restored from before the engine said so, or carried in by a stale tab, cannot turn every load into an error.
    private func querySortState(for tab: QueryTab) -> SortState? {
        parent.supportsColumnSort ? tab.sortState : nil
    }

    /// An engine whose filters cannot match any one of several conditions offers no Match Any, so only a logic
    /// restored from before the engine said so can hold one. It is written back as Match All before anything reads
    /// it, so the rows, the count and the cell filters all agree on what the filters mean.
    private func normalizeLogicModeIfNeeded(at tabIndex: Int) {
        guard !parent.supportsMatchAnyFilters,
              parent.tabManager.tabs[tabIndex].filterState.filterLogicMode != .and else { return }
        parent.tabManager.mutate(at: tabIndex) { $0.filterState.filterLogicMode = .and }
    }

    /// One CONTAINS row per searchable column, joined with OR, replacing the filter set. Only the
    /// find bar calls this, and only when no filters are applied, because `filterLogicMode` is one
    /// mode for the whole array: switching it to OR would silently loosen filters the user wrote.
    func applyCrossColumnSearch(term: String, columns: [String], forTab tabId: UUID) {
        guard !columns.isEmpty, parent.supportsMatchAnyFilters || columns.count == 1 else { return }
        applyFilters(TabFilterState.crossColumnSearchFilters(term: term, columns: columns), logicMode: .or, forTab: tabId)
    }

    func addFilterForColumn(_ columnName: String) {
        let settings = FilterSettingsStorage.shared.loadSettings()
        mutateSelectedTabFilterState { state in
            state.addFilter(forColumn: columnName, settings: settings)
        }
    }

    // MARK: - Apply

    func applySingleFilter(_ filter: TableFilter) {
        guard filter.isValid else { return }
        mutateSelectedTabFilterState { state in
            state.applySingleFilter(filter)
        }
    }

    func applyAllFilters() {
        applyCommit(.all)
    }

    func applySoloFilter(_ filter: TableFilter) {
        guard filter.isValid else { return }
        applyCommit(.solo(filter.id))
    }

    /// Whether the selected tab's rows can be filtered from the grid: a table tab showing its rows,
    /// on an engine that filters by column rather than by a key pattern.
    var canFilterRows: Bool {
        guard let tab = parent.tabManager.selectedTab,
              tab.tabType == .table,
              tab.tableContext.tableName != nil,
              tab.display.resultsViewMode.showsRowFilters else { return false }
        return !usesBrowseSearch
    }

    // A cell's Filter menu: narrows the grid by one more condition.
    func applyCellFilter(_ filter: TableFilter, forTab tabId: UUID) {
        guard canFilterRows, filter.isValid,
              let tab = existingTab(tabId),
              !TabFilterState.isRunning(filter, in: tab.filterState) else { return }
        applyTransition(forTab: tabId) { state in
            state = TabFilterState.cellFilterState(state, adding: filter)
        }
    }

    // Behind the discard guard: `commit` records what the rows on screen were fetched with, so a declined apply must not write it.
    private func applyCommit(_ commit: FilterCommit) {
        guard let tabId = parent.tabManager.selectedTabAndIndex?.tab.id else { return }
        applyTransition(forTab: tabId) { $0.commit = commit }
    }

    private func applyTransition(forTab tabId: UUID, _ transition: @escaping (inout TabFilterState) -> Void) {
        guard let tableName = existingTab(tabId)?.tableContext.tableName else { return }
        parent.confirmDiscardChangesIfNeeded(forTab: tabId, action: .filter) { [weak self] confirmed in
            guard let self, confirmed, var next = existingTab(tabId)?.filterState else { return }
            transition(&next)
            commitFilters(
                next.appliedFilters,
                logicMode: nil,
                tabId: tabId,
                tableName: tableName,
                adopting: next
            )
        }
    }

    // MARK: - Panel Visibility

    func toggleFilterPanel() {
        withMotion(.easeInOut(duration: 0.15)) {
            mutateSelectedTabFilterState { state in
                state.isVisible.toggle()
            }
        }
    }

    func showFilterPanel() {
        withMotion(.easeInOut(duration: 0.15)) {
            mutateSelectedTabFilterState { state in
                state.isVisible = true
            }
        }
    }

    func closeFilterPanel() {
        withMotion(.easeInOut(duration: 0.15)) {
            mutateSelectedTabFilterState { state in
                state.isVisible = false
            }
        }
    }

    // MARK: - Persistence

    /// The one writer of a table's saved filters, so every path saves the same shape.
    ///
    /// Takes the tab rather than reading the selection: a tab switch saves the outgoing tab after
    /// the selection has already moved to the incoming one.
    func saveLastFilters(of tab: QueryTab) {
        guard !tab.tableContext.isTemporary, let tableName = tab.tableContext.tableName else { return }
        /// Turning saving off stops writing, and leaves what is already on disk alone. Falling
        /// through to an empty write would delete it, so the setting could never be turned back on.
        guard FilterSettingsStorage.shared.loadSettings().restoreBehavior.savesToDisk else { return }
        let persisted = tab.filterState.persistedState
        FilterSettingsStorage.shared.saveLastFilters(
            persisted,
            for: tableName,
            connectionId: parent.connectionId,
            databaseName: tab.tableContext.databaseName,
            schemaName: tab.tableContext.schemaName
        )
    }

    private func restoreLastFilters(for tableName: String, at index: Int) {
        let settings = FilterSettingsStorage.shared.loadSettings()
        guard index < parent.tabManager.tabs.count else { return }
        let tab = parent.tabManager.tabs[index]

        let saved: PersistedFilterState
        if settings.restoreBehavior.savesToDisk {
            saved = FilterSettingsStorage.shared.loadLastFilterState(
                for: tableName,
                connectionId: parent.connectionId,
                databaseName: tab.tableContext.databaseName,
                schemaName: tab.tableContext.schemaName
            )
        } else {
            saved = PersistedFilterState(filters: [], isApplied: false)
        }
        mutateFilterState(at: index) { state in
            state = Self.resolvedRestoredState(settings: settings, saved: saved, current: state)
        }
    }

    /// What a table's filter state becomes when the table opens.
    ///
    /// The commit is never fabricated. Setting it to `.all` regardless of what was saved is what
    /// made a row the reader typed and did not apply count as applied the moment it became valid,
    /// so the status bar reported it and the next page turn ran it.
    static func resolvedRestoredState(
        settings: FilterSettings,
        saved: PersistedFilterState,
        current: TabFilterState
    ) -> TabFilterState {
        var state = current
        let restored = settings.restoreBehavior.savesToDisk ? saved.filters : []
        let appliesRestored = settings.restoreBehavior == .restoreAndApply && saved.isApplied
        state.filters = restored
        state.commit = restored.isEmpty || !appliesRestored ? nil : .all
        state.executedFilters = []
        state.executedLogicMode = nil
        state.isVisible = settings.alwaysShowPanel || !restored.isEmpty
        state.filterLogicMode = restored.isEmpty ? state.filterLogicMode : saved.logicMode
        return state
    }

    func clearFilterState() {
        mutateSelectedTabFilterState { state in
            state.clearFilters()
        }
    }

    // MARK: - SQL Preview

    func generateFilterPreviewSQL(databaseType: DatabaseType) -> String {
        let state = selectedTabFilterState
        guard let dialect = PluginManager.shared.sqlDialect(for: databaseType) else {
            return "-- Filters are applied natively"
        }
        let queryColumns = parent.tabManager.selectedTab.map { parent.queryColumns(for: $0) }
        let generator = FilterSQLGenerator(
            dialect: dialect,
            columns: queryColumns?.columns ?? [],
            columnTypes: queryColumns?.columnTypes ?? [],
            stringLiteralPrefix: SQLStringLiteralPrefix.forDatabaseType(databaseType),
            databaseType: databaseType,
            stringEscapes: SQLLexicalResolver.stringEscapes(for: databaseType, connectionId: parent.connectionId)
        )
        let filtersToPreview = filtersForPreview(in: state)

        if filtersToPreview.isEmpty && !state.filters.isEmpty {
            let invalidCount = state.filters.count(where: { !$0.isValid })
            if invalidCount > 0 {
                return "-- No valid filters to preview\n-- Complete \(invalidCount) filter(s) by:\n--   • Selecting a column\n--   • Entering a value (if required)\n--   • Filling in second value for BETWEEN"
            }
        }

        guard let whereClause = generator.generateWhereClause(from: filtersToPreview, logicMode: state.filterLogicMode)
        else {
            let message = FilterSQLGenerator.refusalMessage(for: filtersToPreview, databaseType: databaseType)
                ?? String(localized: "This database cannot filter rows with these conditions.")
            return "-- \(message)"
        }
        return whereClause
    }

    private func filtersForPreview(in state: TabFilterState) -> [TableFilter] {
        state.filters.filter { $0.isEnabled && $0.isValid }
    }

    // MARK: - Private

    private func existingTab(_ tabId: UUID) -> QueryTab? {
        parent.tabManager.tabs.first { $0.id == tabId }
    }

    private func mutateSelectedTabFilterState(_ mutate: (inout TabFilterState) -> Void) {
        guard let index = parent.tabManager.selectedTabIndex else { return }
        mutateFilterState(at: index, mutate)
    }

    private func mutateFilterState(ofTab tabId: UUID, _ mutate: (inout TabFilterState) -> Void) {
        guard let index = parent.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        mutateFilterState(at: index, mutate)
    }

    private func mutateFilterState(at index: Int, _ mutate: (inout TabFilterState) -> Void) {
        guard index < parent.tabManager.tabs.count else { return }
        var newState = parent.tabManager.tabs[index].filterState
        mutate(&newState)
        parent.tabManager.mutate(at: index) { $0.filterState = newState }
    }
}

extension FilterCoordinator: FilterPanelActions {
    func focusGrid() {
        parent.focusActiveGrid()
    }
}

extension FilterCoordinator: FilterSQLPreviewing {
    var filterPreviewDatabaseType: DatabaseType {
        parent.connection.type
    }

    func filterPreviewSQL() -> String {
        generateFilterPreviewSQL(databaseType: filterPreviewDatabaseType)
    }
}
