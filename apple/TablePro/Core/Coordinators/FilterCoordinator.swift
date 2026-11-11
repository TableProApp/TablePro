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

    func applyFilters(_ filters: [TableFilter], logicMode: FilterLogicMode? = nil) {
        guard let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              let tableName = tab.tableContext.tableName else { return }

        let capturedTabIndex = tabIndex
        let capturedTableName = tableName
        let capturedFilters = filters
        let capturedLogicMode = logicMode
        parent.confirmDiscardChangesIfNeeded(action: .filter) { [weak self] confirmed in
            guard let self, confirmed else { return }
            commitFilters(
                capturedFilters,
                logicMode: capturedLogicMode,
                tabIndex: capturedTabIndex,
                tableName: capturedTableName
            )
        }
    }

    /// Writes the one predicate a reference jump carries and re-queries for it.
    ///
    /// The caller has already taken the discard guard, because it also records the view the tab is
    /// leaving and both have to land on the same side of a refusal.
    func commitReferenceFilter(_ filter: TableFilter) {
        guard let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              let tableName = tab.tableContext.tableName else { return }
        setFKFilter(filter)
        commitFilters([filter], logicMode: nil, tabIndex: tabIndex, tableName: tableName)
    }

    /// Builds the query first and writes the filter state only once it exists, so a refusal leaves
    /// the panel, the commit, the sort and the rows on screen as they were, with the reason in their
    /// place. A `sort` is written with the filters, so both land in the one reload or neither does.
    private func commitFilters(
        _ filters: [TableFilter],
        logicMode: FilterLogicMode?,
        tabIndex: Int,
        tableName: String,
        adopting proposed: TabFilterState? = nil,
        sort: SortState? = nil
    ) {
        guard tabIndex < parent.tabManager.tabs.count else { return }

        var tab = parent.tabManager.tabs[tabIndex]
        if let sort {
            tab.sortState = sort
        }
        var next = proposed ?? tab.filterState
        if let logicMode {
            next.filterLogicMode = logicMode
            next.isVisible = true
        }
        if !parent.supportsMatchAnyFilters {
            next.filterLogicMode = .and
        }

        let queryColumns = parent.queryColumns(for: tab)
        guard let newQuery = filteredOrBaseQuery(
            filters,
            logicMode: next.filterLogicMode,
            tab: tab,
            tableName: tableName,
            queryColumns: queryColumns
        ) else {
            let message = FilterSQLGenerator.refusalMessage(for: filters, databaseType: parent.connection.type)
                ?? String(localized: "This database cannot filter rows with these conditions.")
            parent.tabManager.mutate(at: tabIndex) {
                $0.execution.errorMessage = message
            }
            return
        }

        next.executedFilters = filters
        next.executedLogicMode = next.filterLogicMode
        parent.tabManager.mutate(at: tabIndex) {
            $0.pagination.reset()
            $0.content.query = newQuery
            $0.filterState = next
            if let sort {
                $0.sortState = sort
                $0.hasUserInteraction = true
            }
        }
        if sort != nil {
            parent.existingGridModel(forTab: tab.id)?.sortStateDidChange()
        }
        saveLastFilters(of: parent.tabManager.tabs[tabIndex])
        parent.runQuery(viewport: .firstRow)
    }

    /// No rows to run is the table's plain query, which Apply Filter & Sort reaches to change the
    /// sort alone: a driver that builds its own filtered queries may refuse an empty set.
    private func filteredOrBaseQuery(
        _ filters: [TableFilter],
        logicMode: FilterLogicMode,
        tab: QueryTab,
        tableName: String,
        queryColumns: (columns: [String], columnTypes: [ColumnType])
    ) -> String? {
        guard !filters.isEmpty else {
            return parent.queryBuilder.buildBaseQuery(
                tableName: tableName,
                schemaName: tab.tableContext.schemaName,
                sortState: querySortState(for: tab),
                columns: queryColumns.columns,
                selectColumns: parent.selectColumns(for: tab),
                unloadedValues: parent.unloadedValuePlan(for: tab),
                limit: tab.pagination.pageSize,
                offset: 0
            )
        }
        return parent.queryBuilder.buildFilteredQuery(
            tableName: tableName,
            schemaName: tab.tableContext.schemaName,
            filters: filters,
            logicMode: logicMode,
            sortState: querySortState(for: tab),
            columns: queryColumns.columns,
            columnTypes: queryColumns.columnTypes,
            selectColumns: parent.selectColumns(for: tab),
            unloadedValues: parent.unloadedValuePlan(for: tab),
            limit: tab.pagination.pageSize,
            offset: 0
        )
    }

    /// Apply Filter & Sort: every enabled, complete row and the Sort By draft, in one reload behind
    /// one discard guard. With no row to run, the filters stop and the rows stay in the panel, as
    /// Clear leaves them. A draft equal to the tab's sort writes nothing, so a default sort keeps
    /// its source.
    func applyFiltersAndSort() {
        guard let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              let tableName = tab.tableContext.tableName else { return }

        let capturedTabIndex = tabIndex
        let capturedTableName = tableName
        parent.confirmDiscardChangesIfNeeded(action: .filter) { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard capturedTabIndex < parent.tabManager.tabs.count else { return }
            let current = parent.tabManager.tabs[capturedTabIndex]
            var next = current.filterState
            next.commit = TabFilterState.resolve(.all, in: next.filters).isEmpty ? nil : .all
            let sort = sortToApply(next.sortDraft, for: current)
            next.sortDraft = nil
            commitFilters(
                next.appliedFilters,
                logicMode: nil,
                tabIndex: capturedTabIndex,
                tableName: capturedTableName,
                adopting: next,
                sort: sort
            )
        }
    }

    /// The sort a draft asks for, or nil when it changes nothing or the engine cannot sort a table.
    private func sortToApply(_ draft: [FilterSortCriterion]?, for tab: QueryTab) -> SortState? {
        guard let draft, parent.supportsColumnSort else { return nil }
        let columns = parent.queryColumns(for: tab).columns
        guard draft != TabFilterState.sortCriteria(from: tab.sortState, columns: columns) else { return nil }
        return TabFilterState.sortState(from: draft, columns: columns)
    }

    /// The tab's sort as the Sort By section shows it.
    var selectedTabAppliedSortCriteria: [FilterSortCriterion] {
        guard let tab = parent.tabManager.selectedTab else { return [] }
        return TabFilterState.sortCriteria(from: tab.sortState, columns: parent.queryColumns(for: tab).columns)
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
        guard let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              let tableName = tab.tableContext.tableName else { return }

        let capturedTabIndex = tabIndex
        let capturedTableName = tableName
        parent.confirmDiscardChangesIfNeeded(action: .filter) { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard capturedTabIndex < parent.tabManager.tabs.count else { return }

            parent.tabManager.mutate(at: capturedTabIndex) { $0.pagination.reset() }

            let tab = parent.tabManager.tabs[capturedTabIndex]
            let buffer = parent.tabSessionRegistry.tableRows(for: tab.id)
            let newQuery = parent.queryBuilder.buildBaseQuery(
                tableName: capturedTableName,
                schemaName: tab.tableContext.schemaName,
                sortState: querySortState(for: tab),
                columns: buffer.columns,
                selectColumns: parent.selectColumns(for: tab),
                unloadedValues: parent.unloadedValuePlan(for: tab),
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset
            )

            parent.tabManager.mutate(at: capturedTabIndex) {
                $0.content.query = newQuery
                $0.filterState.commit = nil
                $0.filterState.executedFilters = []
                $0.filterState.executedLogicMode = nil
                if removingRows {
                    $0.filterState.filters = []
                    $0.filterState.leaveTextMode()
                }
            }
            /// Saved rather than deleted, because the rows left in the panel are still the table's
            /// working set and reopening it should bring them back with nothing running. Removing
            /// the rows empties that set, and an empty set is what the storage reads as a delete.
            saveLastFilters(of: parent.tabManager.tabs[capturedTabIndex])
            parent.runQuery(viewport: .firstRow)
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
        guard let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              let tableName = tab.tableContext.tableName else { return }

        let capturedTabIndex = tabIndex
        let capturedTableName = tableName
        parent.confirmDiscardChangesIfNeeded(action: .filter) { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard capturedTabIndex < parent.tabManager.tabs.count else { return }

            mutateSelectedTabFilterState { state in
                state.browseSearch = search
                state.isVisible = true
            }
            /// The total on screen counted the previous search's keys, or the whole database. An
            /// exact one is never replaced by a later estimate, so left in place it would go on
            /// describing this search.
            parent.tabManager.mutate(at: capturedTabIndex) { tab in
                tab.pagination.reset()
                tab.pagination.retireDerivedRowCount()
            }
            rebuildTableQuery(at: capturedTabIndex)
            saveBrowseSearch(for: capturedTableName)
            parent.runQuery(viewport: .firstRow)
        }
    }

    func clearBrowseSearchAndReload() {
        guard let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              let tableName = tab.tableContext.tableName else { return }

        let capturedTabIndex = tabIndex
        let capturedTableName = tableName
        parent.confirmDiscardChangesIfNeeded(action: .filter) { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard capturedTabIndex < parent.tabManager.tabs.count else { return }

            mutateSelectedTabFilterState { state in
                state.browseSearch = BrowseSearchState()
            }
            /// A total counted for the search does not describe the whole database.
            parent.tabManager.mutate(at: capturedTabIndex) { tab in
                tab.pagination.reset()
                tab.pagination.retireDerivedRowCount()
            }
            rebuildTableQuery(at: capturedTabIndex)
            saveBrowseSearch(for: capturedTableName)
            parent.runQuery(viewport: .firstRow)
        }
    }

    func saveBrowseSearch(for tableName: String) {
        guard let tab = parent.tabManager.selectedTab else { return }
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
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset
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
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset
            )
        }
        let isRefused = filteredQuery == nil && !rerun.filters.isEmpty
        if isRefused {
            executed = []
        }
        let newQuery = filteredQuery ?? parent.queryBuilder.buildBaseQuery(
            tableName: tableName,
            schemaName: tab.tableContext.schemaName,
            sortState: querySortState(for: tab),
            columns: columns,
            selectColumns: parent.selectColumns(for: tab),
            unloadedValues: parent.unloadedValuePlan(for: tab),
            limit: tab.pagination.pageSize,
            offset: tab.pagination.currentOffset
        )

        parent.tabManager.mutate(at: tabIndex) {
            $0.content.query = newQuery
            if isRefused {
                $0.filterState.commit = nil
            }
            $0.filterState.executedFilters = executed
            $0.filterState.executedLogicMode = $0.filterState.commit == nil ? nil : logicMode
        }
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
    func applyCrossColumnSearch(term: String, columns: [String]) {
        guard !columns.isEmpty, parent.supportsMatchAnyFilters || columns.count == 1 else { return }
        applyFilters(TabFilterState.crossColumnSearchFilters(term: term, columns: columns), logicMode: .or)
    }

    func addFilterForColumn(_ columnName: String) {
        let settings = FilterSettingsStorage.shared.loadSettings()
        mutateSelectedTabFilterState { state in
            state.addFilter(forColumn: columnName, settings: settings)
        }
    }

    func setFKFilter(_ filter: TableFilter) {
        mutateSelectedTabFilterState { state in
            state.setReferenceFilter(filter)
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

    /// Narrows what the grid shows by one more condition, which a cell's Filter menu offers.
    func applyCellFilter(_ filter: TableFilter) {
        guard canFilterRows, filter.isValid,
              !TabFilterState.isRunning(filter, in: selectedTabFilterState) else { return }
        applyTransition { state in
            state = TabFilterState.cellFilterState(state, adding: filter)
        }
    }

    /// Writes the commit, persists it and re-queries, all behind the discard guard.
    ///
    /// Behind it, because `commit` is the record of what the rows on screen were fetched with.
    /// Setting it first and taking the guard afterwards left a declined apply reporting a filter
    /// the grid had never run, saved to disk, and re-run by the next page turn.
    private func applyCommit(_ commit: FilterCommit) {
        applyTransition { $0.commit = commit }
    }

    private func applyTransition(_ transition: @escaping (inout TabFilterState) -> Void) {
        guard let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              let tableName = tab.tableContext.tableName else { return }

        let capturedTabIndex = tabIndex
        let capturedTableName = tableName
        parent.confirmDiscardChangesIfNeeded(action: .filter) { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard capturedTabIndex < parent.tabManager.tabs.count else { return }
            var next = parent.tabManager.tabs[capturedTabIndex].filterState
            transition(&next)
            commitFilters(
                next.appliedFilters,
                logicMode: nil,
                tabIndex: capturedTabIndex,
                tableName: capturedTableName,
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
        let opensPanel = AppSettingsManager.shared.dataGrid.opensFilterPanelForTables
        mutateFilterState(at: index) { state in
            state = Self.resolvedRestoredState(settings: settings, saved: saved, current: state, opensPanel: opensPanel)
        }
    }

    /// What a table's filter state becomes when the table opens.
    ///
    /// The commit is never fabricated. Setting it to `.all` regardless of what was saved is what
    /// made a row the reader typed and did not apply count as applied the moment it became valid,
    /// so the status bar reported it and the next page turn ran it.
    ///
    /// `opensPanel` is `DataGridSettings.opensFilterPanelForTables`. This runs as a table opens, never
    /// on a tab switch, so the panel opens once and stays closed if the reader closes it.
    static func resolvedRestoredState(
        settings: FilterSettings,
        saved: PersistedFilterState,
        current: TabFilterState,
        opensPanel: Bool = false
    ) -> TabFilterState {
        var state = current
        let restored = settings.restoreBehavior.savesToDisk ? saved.filters : []
        let appliesRestored = settings.restoreBehavior == .restoreAndApply && saved.isApplied
        state.filters = restored
        state.commit = restored.isEmpty || !appliesRestored ? nil : .all
        state.executedFilters = []
        state.executedLogicMode = nil
        state.isVisible = settings.alwaysShowPanel || opensPanel || !restored.isEmpty
        state.filterLogicMode = restored.isEmpty ? state.filterLogicMode : saved.logicMode
        state.textModeOrigin = nil
        state.editMode = restored.isEmpty ? .builder : saved.editMode
        state.sortDraft = nil
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
        guard let generator = filterSQLGenerator(databaseType: databaseType) else {
            return "-- Filters are applied natively"
        }
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

    /// The generator the preview uses, typed from the selected tab's columns. Nil on an engine that
    /// does not filter with SQL.
    private func filterSQLGenerator(databaseType: DatabaseType) -> FilterSQLGenerator? {
        guard let dialect = PluginManager.shared.sqlDialect(for: databaseType) else { return nil }
        let queryColumns = parent.tabManager.selectedTab.map { parent.queryColumns(for: $0) }
        return FilterSQLGenerator(
            dialect: dialect,
            columns: queryColumns?.columns ?? [],
            columnTypes: queryColumns?.columnTypes ?? [],
            stringLiteralPrefix: SQLStringLiteralPrefix.forDatabaseType(databaseType),
            databaseType: databaseType,
            stringEscapes: SQLLexicalResolver.stringEscapes(for: databaseType, connectionId: parent.connectionId)
        )
    }

    /// What the selected tab's rows were fetched with, written the way Text mode writes it, so text
    /// left as Builder to Text wrote it reads as unedited. Nil outside Text mode, which compares rows.
    var selectedTabRunningCondition: String? {
        guard let tab = parent.tabManager.selectedTab, tab.filterState.effectiveEditMode == .text else { return nil }
        let rerun = tab.filterState.rerunFilters
        return filterConditionText(for: rerun.filters, logicMode: parent.supportsMatchAnyFilters ? rerun.logicMode : .and)
    }

    /// The preview's WHERE clause for the enabled rows, without its keyword, for Text mode to start from.
    func filterConditionText(for filters: [TableFilter], logicMode: FilterLogicMode) -> String? {
        guard let generator = filterSQLGenerator(databaseType: parent.connection.type),
              let whereClause = generator.generateWhereClause(
                  from: filters.filter(\.isEnabled),
                  logicMode: logicMode
              ) else { return nil }
        let keyword = "WHERE "
        return whereClause.hasPrefix(keyword) ? String(whereClause.dropFirst(keyword.count)) : whereClause
    }

    // MARK: - Private

    private func mutateSelectedTabFilterState(_ mutate: (inout TabFilterState) -> Void) {
        guard let index = parent.tabManager.selectedTabIndex else { return }
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

extension FilterCoordinator: FilterCriteriaActions {}

extension FilterCoordinator: FilterSQLPreviewing {
    var filterPreviewDatabaseType: DatabaseType {
        parent.connection.type
    }

    func filterPreviewSQL() -> String {
        generateFilterPreviewSQL(databaseType: filterPreviewDatabaseType)
    }
}
