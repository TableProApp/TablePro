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

    private func commitFilters(
        _ filters: [TableFilter],
        logicMode: FilterLogicMode?,
        tabIndex: Int,
        tableName: String
    ) {
        guard tabIndex < parent.tabManager.tabs.count else { return }

        if let logicMode {
            parent.tabManager.mutate(at: tabIndex) {
                $0.filterState.filterLogicMode = logicMode
                $0.filterState.isVisible = true
            }
        }
        parent.tabManager.mutate(at: tabIndex) { $0.pagination.reset() }

        let tab = parent.tabManager.tabs[tabIndex]
        let queryColumns = parent.queryColumns(for: tab)
        let newQuery = parent.queryBuilder.buildFilteredQuery(
            tableName: tableName,
            schemaName: tab.tableContext.schemaName,
            filters: filters,
            logicMode: tab.filterState.filterLogicMode,
            sortState: tab.sortState,
            columns: queryColumns.columns,
            columnTypes: queryColumns.columnTypes,
            selectColumns: parent.selectColumns(for: tab),
            limit: tab.pagination.pageSize,
            offset: tab.pagination.currentOffset
        )

        parent.tabManager.mutate(at: tabIndex) {
            $0.content.query = newQuery
            $0.filterState.executedFilters = filters
        }
        saveLastFilters(of: parent.tabManager.tabs[tabIndex])
        parent.runQuery(viewport: .firstRow)
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
                sortState: tab.sortState,
                columns: buffer.columns,
                selectColumns: parent.selectColumns(for: tab),
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset
            )

            parent.tabManager.mutate(at: capturedTabIndex) {
                $0.content.query = newQuery
                $0.filterState.commit = nil
                $0.filterState.executedFilters = []
                if removingRows {
                    $0.filterState.filters = []
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
        guard index < parent.tabManager.tabs.count,
              let tableName = parent.tabManager.tabs[index].tableContext.tableName else { return }
        restoreLastFilters(for: tableName, at: index)
        restoreBrowseSearch(for: tableName, at: index)
        guard parent.tabManager.selectedTabIndex == index else { return }
        rebuildTableQuery(at: index)
    }

    var usesBrowseSearch: Bool {
        PluginManager.shared.browseFilterDescriptor(for: parent.connection.type) != nil
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
            parent.tabManager.mutate(at: capturedTabIndex) { $0.pagination.reset() }
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
            parent.tabManager.mutate(at: capturedTabIndex) { $0.pagination.reset() }
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

    func rebuildTableQuery(at tabIndex: Int) {
        guard tabIndex < parent.tabManager.tabs.count,
              let tableName = parent.tabManager.tabs[tabIndex].tableContext.tableName else { return }

        let tab = parent.tabManager.tabs[tabIndex]
        let hasFilters = tab.filterState.hasAppliedFilters
        let (columns, columnTypes) = parent.queryColumns(for: tab)

        let newQuery: String
        if usesBrowseSearch, tab.filterState.hasActiveBrowseSearch {
            let search = tab.filterState.browseSearch
            newQuery = parent.queryBuilder.buildKeyPatternBrowseQuery(
                tableName: tableName,
                schemaName: tab.tableContext.schemaName,
                pattern: search.pattern,
                typeScope: search.typeScope,
                sortState: tab.sortState,
                columns: columns,
                selectColumns: parent.selectColumns(for: tab),
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset
            )
        } else if hasFilters {
            newQuery = parent.queryBuilder.buildFilteredQuery(
                tableName: tableName,
                schemaName: tab.tableContext.schemaName,
                filters: tab.filterState.appliedFilters,
                logicMode: tab.filterState.filterLogicMode,
                sortState: tab.sortState,
                columns: columns,
                columnTypes: columnTypes,
                selectColumns: parent.selectColumns(for: tab),
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset
            )
        } else {
            newQuery = parent.queryBuilder.buildBaseQuery(
                tableName: tableName,
                schemaName: tab.tableContext.schemaName,
                sortState: tab.sortState,
                columns: columns,
                selectColumns: parent.selectColumns(for: tab),
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset
            )
        }

        let executed = hasFilters ? tab.filterState.appliedFilters : []
        parent.tabManager.mutate(at: tabIndex) {
            $0.content.query = newQuery
            $0.filterState.executedFilters = executed
        }
    }

    // MARK: - Filter State

    var selectedTabFilterState: TabFilterState {
        parent.tabManager.selectedTab?.filterState ?? TabFilterState()
    }

    // MARK: - Filter Management

    func addFilter(columns: [String] = [], primaryKeyColumn: String? = nil) {
        let settings = FilterSettingsStorage.shared.loadSettings()
        var newFilter = TableFilter()

        switch settings.defaultColumn {
        case .rawSQL:
            newFilter.columnName = TableFilter.rawSQLColumn
        case .primaryKey:
            if let pk = primaryKeyColumn {
                newFilter.columnName = pk
            } else if let firstColumn = columns.first {
                newFilter.columnName = firstColumn
            }
        case .anyColumn:
            if let firstColumn = columns.first {
                newFilter.columnName = firstColumn
            }
        }

        newFilter.filterOperator = settings.defaultOperator.toFilterOperator()

        mutateSelectedTabFilterState { state in
            state.filters.append(newFilter)
        }
    }

    /// One CONTAINS row per searchable column, joined with OR, replacing the filter set. Only the
    /// find bar calls this, and only when no filters are applied, because `filterLogicMode` is one
    /// mode for the whole array: switching it to OR would silently loosen filters the user wrote.
    func applyCrossColumnSearch(term: String, columns: [String]) {
        guard !columns.isEmpty else { return }

        let filters = columns.map { column in
            var filter = TableFilter()
            filter.columnName = column
            filter.filterOperator = .contains
            filter.value = term
            filter.isEnabled = true
            return filter
        }

        applyFilters(filters, logicMode: .or)
    }

    func addFilterForColumn(_ columnName: String) {
        let settings = FilterSettingsStorage.shared.loadSettings()
        var newFilter = TableFilter()
        newFilter.columnName = columnName
        newFilter.filterOperator = settings.defaultOperator.toFilterOperator()

        mutateSelectedTabFilterState { state in
            state.filters.append(newFilter)
            if !state.isVisible {
                state.isVisible = true
            }
        }
    }

    func setFKFilter(_ filter: TableFilter) {
        mutateSelectedTabFilterState { state in
            state.filters = [filter]
            state.commit = .all
            state.isVisible = true
            state.filterLogicMode = .and
        }
    }

    func duplicateFilter(_ filter: TableFilter) {
        let copy = TableFilter(
            id: UUID(),
            columnName: filter.columnName,
            filterOperator: filter.filterOperator,
            value: filter.value,
            secondValue: filter.secondValue,
            isEnabled: filter.isEnabled,
            rawSQL: filter.rawSQL
        )
        mutateSelectedTabFilterState { state in
            if let index = state.filters.firstIndex(where: { $0.id == filter.id }) {
                state.filters.insert(copy, at: index + 1)
            } else {
                state.filters.append(copy)
            }
        }
    }

    func removeFilter(_ filter: TableFilter) {
        mutateSelectedTabFilterState { state in
            state.filters.removeAll { $0.id == filter.id }
            if case .solo(let id) = state.commit, id == filter.id {
                state.commit = nil
            }
        }
    }

    enum RemoveFilterOutcome: Equatable {
        case noChange
        case clear
        case reapply([TableFilter])
    }

    static func removeFilterOutcome(
        removing filter: TableFilter,
        from appliedFilters: [TableFilter]
    ) -> RemoveFilterOutcome {
        guard appliedFilters.contains(where: { $0.id == filter.id }) else { return .noChange }
        let remaining = appliedFilters.filter { $0.id != filter.id }
        return remaining.isEmpty ? .clear : .reapply(remaining)
    }

    func removeFilterAndReload(_ filter: TableFilter) {
        let outcome = Self.removeFilterOutcome(
            removing: filter,
            from: selectedTabFilterState.appliedFilters
        )
        removeFilter(filter)
        switch outcome {
        case .noChange:
            break
        case .clear:
            clearAppliedFiltersAndReload()
        case .reapply(let remaining):
            applyFilters(remaining)
        }
    }

    func updateFilter(_ filter: TableFilter) {
        mutateSelectedTabFilterState { state in
            if let index = state.filters.firstIndex(where: { $0.id == filter.id }) {
                state.filters[index] = filter
            }
        }
    }

    enum FilterMoveDirection {
        case up
        case down
    }

    struct FilterMove: Equatable {
        let source: IndexSet
        let destination: Int
    }

    static func filterMove(
        in filters: [TableFilter],
        moving draggedID: UUID,
        onto targetID: UUID
    ) -> FilterMove? {
        guard draggedID != targetID,
              let from = filters.firstIndex(where: { $0.id == draggedID }),
              let target = filters.firstIndex(where: { $0.id == targetID }) else { return nil }
        return FilterMove(source: IndexSet(integer: from), destination: from < target ? target + 1 : target)
    }

    static func filterMove(
        in filters: [TableFilter],
        moving filterID: UUID,
        direction: FilterMoveDirection
    ) -> FilterMove? {
        guard let from = filters.firstIndex(where: { $0.id == filterID }) else { return nil }
        switch direction {
        case .up:
            guard from > 0 else { return nil }
            return FilterMove(source: IndexSet(integer: from), destination: from - 1)
        case .down:
            guard from < filters.count - 1 else { return nil }
            return FilterMove(source: IndexSet(integer: from), destination: from + 2)
        }
    }

    func moveFilter(_ draggedID: UUID, onto targetID: UUID) {
        guard let move = Self.filterMove(
            in: selectedTabFilterState.filters,
            moving: draggedID,
            onto: targetID
        ) else { return }
        applyFilterMove(move)
    }

    func moveFilter(_ filterID: UUID, direction: FilterMoveDirection) {
        guard let move = Self.filterMove(
            in: selectedTabFilterState.filters,
            moving: filterID,
            direction: direction
        ) else { return }
        applyFilterMove(move)
    }

    func canMoveFilter(_ filterID: UUID, direction: FilterMoveDirection) -> Bool {
        Self.filterMove(in: selectedTabFilterState.filters, moving: filterID, direction: direction) != nil
    }

    private func applyFilterMove(_ move: FilterMove) {
        mutateSelectedTabFilterState { state in
            state.filters.move(fromOffsets: move.source, toOffset: move.destination)
        }
    }

    func filterBinding(for filter: TableFilter) -> Binding<TableFilter> {
        Binding(
            get: { [weak self] in
                self?.selectedTabFilterState.filters.first { $0.id == filter.id } ?? filter
            },
            set: { [weak self] newValue in
                self?.updateFilter(newValue)
            }
        )
    }

    func filterLogicModeBinding() -> Binding<FilterLogicMode> {
        Binding(
            get: { [weak self] in
                self?.selectedTabFilterState.filterLogicMode ?? .and
            },
            set: { [weak self] newValue in
                self?.mutateSelectedTabFilterState { $0.filterLogicMode = newValue }
            }
        )
    }

    // MARK: - Apply

    func applySingleFilter(_ filter: TableFilter) {
        guard filter.isValid else { return }
        mutateSelectedTabFilterState { state in
            state.filters = [filter]
            state.commit = .all
            state.isVisible = true
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
              !Self.isRunning(filter, in: selectedTabFilterState) else { return }
        applyTransition { state in
            state = Self.cellFilterState(state, adding: filter)
        }
    }

    /// Whether the rows on screen were already fetched with this condition, so adding it would
    /// change nothing but the page.
    static func isRunning(_ filter: TableFilter, in state: TabFilterState) -> Bool {
        guard state.executedFilters.contains(where: { $0.hasSameCondition(as: filter) }) else { return false }
        return state.filterLogicMode == .and || state.executedFilters.count == 1
    }

    /// The filter state that shows what the grid showed, and only rows matching `filter` too.
    ///
    /// What the grid showed is `executedFilters`, never `appliedFilters`: rows typed and never
    /// applied, and rows left in the panel by Clear, resolve as applied under `.all` without having
    /// run. So a row stays checked only when it is running, every other row is unchecked rather than
    /// removed, and the commit becomes `.all` over exactly the checked rows, which is also what the
    /// saved state restores. A row that already holds the condition is checked instead of repeated.
    ///
    /// Under Match any, a condition can only be added to one running row or none, where the two
    /// modes agree and the mode becomes Match all. With two or more running rows the condition
    /// cannot join them, so it runs alone.
    static func cellFilterState(_ state: TabFilterState, adding filter: TableFilter) -> TabFilterState {
        let executedIDs = Set(state.executedFilters.map(\.id))
        let runningIDs = Set(state.filters.lazy.map(\.id).filter(executedIDs.contains))
        let keepsRunningRows = state.filterLogicMode == .and || runningIDs.count <= 1
        let keptIDs = keepsRunningRows ? runningIDs : []
        let existingID = state.filters.first { $0.hasSameCondition(as: filter) }?.id

        var next = state
        next.filters = state.filters.map { row in
            var row = row
            row.isEnabled = keptIDs.contains(row.id) || row.id == existingID
            return row
        }
        if existingID == nil {
            var added = filter
            added.isEnabled = true
            next.filters.append(added)
        }
        if keepsRunningRows {
            next.filterLogicMode = .and
        }
        next.commit = .all
        next.isVisible = true
        return next
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
            mutateFilterState(at: capturedTabIndex, transition)
            commitFilters(
                parent.tabManager.tabs[capturedTabIndex].filterState.appliedFilters,
                logicMode: nil,
                tabIndex: capturedTabIndex,
                tableName: capturedTableName
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
        guard let tableName = tab.tableContext.tableName else { return }
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
        state.isVisible = settings.alwaysShowPanel || !restored.isEmpty
        state.filterLogicMode = restored.isEmpty ? state.filterLogicMode : saved.logicMode
        return state
    }

    func clearFilterState() {
        mutateSelectedTabFilterState { state in
            state.filters = []
            state.commit = nil
        }
    }

    // MARK: - Filter Presets

    func saveFilterPreset(name: String) {
        let preset = FilterPreset(name: name, filters: selectedTabFilterState.filters)
        FilterPresetStorage.shared.savePreset(preset)
    }

    func loadFilterPreset(_ preset: FilterPreset) {
        mutateSelectedTabFilterState { state in
            state.filters = preset.filters
        }
    }

    func loadAllFilterPresets() -> [FilterPreset] {
        FilterPresetStorage.shared.loadAllPresets()
    }

    func deleteFilterPreset(_ preset: FilterPreset) {
        FilterPresetStorage.shared.deletePreset(preset)
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
            stringLiteralPrefix: SQLStringLiteralPrefix.forDatabaseType(databaseType)
        )
        let filtersToPreview = filtersForPreview(in: state)

        if filtersToPreview.isEmpty && !state.filters.isEmpty {
            let invalidCount = state.filters.count(where: { !$0.isValid })
            if invalidCount > 0 {
                return "-- No valid filters to preview\n-- Complete \(invalidCount) filter(s) by:\n--   • Selecting a column\n--   • Entering a value (if required)\n--   • Filling in second value for BETWEEN"
            }
        }

        return generator.generateWhereClause(from: filtersToPreview, logicMode: state.filterLogicMode)
    }

    private func filtersForPreview(in state: TabFilterState) -> [TableFilter] {
        state.filters.filter { $0.isEnabled && $0.isValid }
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
