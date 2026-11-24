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

    // MARK: - Applying

    func applyCheckedFilters() {
        changeSelectedTab { $0.applyingCheckedRows() }
    }

    func applyFiltersInCurrentMode() {
        changeSelectedTab { $0.applyingCurrentMode() }
    }

    func applyFilterAlone(_ filterID: UUID) {
        changeSelectedTab { $0.applyingAlone(filterID) }
    }

    func turnOffFilters() {
        changeSelectedTab { $0.turningOff() }
    }

    func removeAllFilters() {
        changeSelectedTab { $0.removingAllFilters() }
    }

    // A row that is not running leaves the rows alone, so it needs no reload and no discard guard.
    func removeFilter(_ filterID: UUID) {
        guard let state = parent.tabManager.selectedTab?.filterState else { return }
        guard state.removingFilter(filterID).applied == state.applied else {
            changeSelectedTab { $0.removingFilter(filterID) }
            return
        }
        mutateSelectedTabFilterState { $0 = $0.removingFilter(filterID) }
    }

    // The search takes the panel's rows, so it runs only on an empty panel; a row added since the offer stays.
    func applyCrossColumnSearch(term: String, columns: [String], forTab tabId: UUID) {
        guard !columns.isEmpty, parent.supportsMatchAnyFilters || columns.count == 1 else { return }
        change(ofTab: tabId) { state in
            state.filters.isEmpty ? state.searchingAllRows(term: term, columns: columns) : nil
        }
    }

    // The caller holds the discard guard: it also records the view the tab leaves, and both land on one side of a refusal.
    func commitReferenceFilter(_ filter: TableFilter, forTab tabId: UUID) {
        guard let tab = existingTab(tabId), let tableName = tab.tableContext.tableName else { return }
        var next = tab.filterState
        next.setReferenceFilter(filter)
        commit(next, forTab: tabId, tableName: tableName)
    }

    private func changeSelectedTab(_ transition: @escaping (TabFilterState) -> TabFilterState?) {
        guard let tabId = parent.tabManager.selectedTab?.id else { return }
        change(ofTab: tabId, transition)
    }

    // Every change to what the grid runs: the discard guard first, then the state, query, save and reload together.
    private func change(ofTab tabId: UUID, _ transition: @escaping (TabFilterState) -> TabFilterState?) {
        guard let tableName = existingTab(tabId)?.tableContext.tableName else { return }
        parent.confirmDiscardChangesIfNeeded(forTab: tabId, action: .filter) { [weak self] confirmed in
            guard let self, confirmed,
                  let state = existingTab(tabId)?.filterState,
                  let next = transition(state) else { return }
            commit(next, forTab: tabId, tableName: tableName)
        }
    }

    // Builds the query before writing the state, so a refusal leaves the panel and the rows as they were.
    private func commit(_ proposed: TabFilterState, forTab tabId: UUID, tableName: String) {
        guard let tab = existingTab(tabId) else { return }
        var next = proposed
        if !parent.supportsMatchAnyFilters {
            next.filterLogicMode = .and
            next.applied = next.applied?.withLogicMode(.and)
        }

        let columns = parent.tableQueryColumns(for: tab)
        let query: String
        if let applied = next.applied {
            guard let filtered = parent.queryBuilder.buildFilteredQuery(
                tableName: tableName,
                schemaName: tab.tableContext.schemaName,
                filters: applied.filters,
                logicMode: applied.logicMode,
                sortState: querySortState(for: tab),
                columns: columns.columns,
                columnTypes: columns.columnTypes,
                selectColumns: columns.selectColumns,
                unloadedValues: columns.unloadedValues,
                limit: tab.pagination.pageSize,
                offset: 0
            ) else {
                let message = FilterSQLGenerator.refusalMessage(for: applied.filters, databaseType: parent.connection.type)
                    ?? String(localized: "This database cannot filter rows with these conditions.")
                parent.tabManager.mutate(tabId: tabId) {
                    $0.execution.errorMessage = message
                }
                return
            }
            query = filtered
        } else {
            query = parent.queryBuilder.buildBaseQuery(
                tableName: tableName,
                schemaName: tab.tableContext.schemaName,
                sortState: querySortState(for: tab),
                columns: columns.columns,
                selectColumns: columns.selectColumns,
                unloadedValues: columns.unloadedValues,
                limit: tab.pagination.pageSize,
                offset: 0
            )
        }

        parent.tabManager.mutate(tabId: tabId) {
            $0.pagination.reset()
            $0.content.query = query
            $0.filterState = next
        }
        if let committed = existingTab(tabId) {
            saveLastFilters(of: committed)
        }
        parent.runQuery(onTab: tabId, viewport: .firstRow)
    }

    func restoreFiltersForSelectedTab() {
        guard let index = parent.tabManager.selectedTabIndex else { return }
        restoreFilters(forTabAt: index)
    }

    // Only the selected tab rebuilds its query: an unselected tab has no schema columns to type its
    // values yet, and its first selection runs the first load, which builds the query properly.
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

    // A filter the engine cannot build stops counting as applied, so the panel never shows one the rows lack.
    func rebuildTableQuery(at tabIndex: Int, builtOn schema: SchemaColumnStore.Entry? = nil) {
        guard tabIndex < parent.tabManager.tabs.count,
              let tableName = parent.tabManager.tabs[tabIndex].tableContext.tableName else { return }
        normalizeLogicModeIfNeeded(at: tabIndex)

        let tab = parent.tabManager.tabs[tabIndex]
        let built = tableQuery(
            for: tab,
            tableName: tableName,
            limit: tab.pagination.pageSize,
            offset: tab.pagination.currentOffset,
            columns: schema.map { parent.tableQueryColumns(for: tab, builtOn: $0) } ?? parent.tableQueryColumns(for: tab)
        )

        parent.tabManager.mutate(at: tabIndex) {
            $0.content.query = built.query
            if built.isRefused {
                $0.filterState.applied = nil
            }
        }
    }

    func rebuildTableQuery(forTab tabId: UUID, builtOn schema: SchemaColumnStore.Entry? = nil) {
        guard let index = parent.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        rebuildTableQuery(at: index, builtOn: schema)
    }

    // The table tab's view, its filters, search and sort, read from the first row: what Share Result reads.
    func viewQuery(for tab: QueryTab, limit: Int) -> String? {
        guard let tableName = tab.tableContext.tableName else { return nil }
        return tableQuery(
            for: tab, tableName: tableName, limit: limit, offset: 0, columns: parent.tableQueryColumns(for: tab)
        ).query
    }

    // The page the tab asks for, built on this column list alone, not on the cached one or the loaded rows.
    func pageQuery(for tab: QueryTab, builtOn schema: SchemaColumnStore.Entry) -> String? {
        guard let tableName = tab.tableContext.tableName else { return nil }
        return tableQuery(
            for: tab,
            tableName: tableName,
            limit: tab.pagination.pageSize,
            offset: tab.pagination.currentOffset,
            columns: parent.tableQueryColumns(for: tab, builtOn: schema)
        ).query
    }

    // The same view with no LIMIT or OFFSET, as a shared link shows it; nil when the host cannot write it as SQL.
    func viewSQL(for tab: QueryTab) -> String? {
        guard parent.queryBuilder.writesSQL,
              let tableName = tab.tableContext.tableName,
              activeBrowseSearch(for: tab.filterState) == nil
        else { return nil }
        let (columns, columnTypes) = parent.queryColumns(for: tab)
        guard let applied = tab.filterState.applied else {
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
            filters: applied.filters,
            logicMode: parent.supportsMatchAnyFilters ? applied.logicMode : .and,
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
        offset: Int,
        columns built: TableQueryColumns
    ) -> (query: String, isRefused: Bool) {
        let applied = tab.filterState.applied
        let (columns, columnTypes) = (built.columns, built.columnTypes)

        let filteredQuery: String?
        if let search = activeBrowseSearch(for: tab.filterState) {
            filteredQuery = parent.queryBuilder.buildKeyPatternBrowseQuery(
                tableName: tableName,
                schemaName: tab.tableContext.schemaName,
                pattern: search.pattern,
                typeScope: search.typeScope,
                sortState: querySortState(for: tab),
                columns: columns,
                selectColumns: built.selectColumns,
                unloadedValues: built.unloadedValues,
                limit: limit,
                offset: offset
            )
        } else if let applied {
            filteredQuery = parent.queryBuilder.buildFilteredQuery(
                tableName: tableName,
                schemaName: tab.tableContext.schemaName,
                filters: applied.filters,
                logicMode: parent.supportsMatchAnyFilters ? applied.logicMode : .and,
                sortState: querySortState(for: tab),
                columns: columns,
                columnTypes: columnTypes,
                selectColumns: built.selectColumns,
                unloadedValues: built.unloadedValues,
                limit: limit,
                offset: offset
            )
        } else {
            filteredQuery = nil
        }
        let isRefused = filteredQuery == nil && applied != nil
        let query = filteredQuery ?? parent.queryBuilder.buildBaseQuery(
            tableName: tableName,
            schemaName: tab.tableContext.schemaName,
            sortState: querySortState(for: tab),
            columns: columns,
            selectColumns: built.selectColumns,
            unloadedValues: built.unloadedValues,
            limit: limit,
            offset: offset
        )
        return (query, isRefused)
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

    // An engine that cannot order a table by a column gets no sort, so a stale one cannot fail every load.
    private func querySortState(for tab: QueryTab) -> SortState? {
        parent.supportsColumnSort ? tab.sortState : nil
    }

    // Only a mode restored from before the engine dropped Match any can hold one; the rows, the count and
    // the cell filters must agree on what the filters mean.
    private func normalizeLogicModeIfNeeded(at tabIndex: Int) {
        let state = parent.tabManager.tabs[tabIndex].filterState
        guard !parent.supportsMatchAnyFilters,
              state.filterLogicMode != .and || state.applied.map({ $0.logicMode != .and }) == true else { return }
        parent.tabManager.mutate(at: tabIndex) {
            $0.filterState.filterLogicMode = .and
            $0.filterState.applied = $0.filterState.applied?.withLogicMode(.and)
        }
    }

    func addFilterForColumn(_ columnName: String) {
        let settings = FilterSettingsStorage.shared.loadSettings()
        mutateSelectedTabFilterState { state in
            state.addFilter(forColumn: columnName, settings: settings)
        }
    }

    // A table tab showing its rows, on an engine that filters by column rather than by a key pattern.
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
        change(ofTab: tabId) { TabFilterState.cellFilterState($0, adding: filter) }
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

    // The rows come back with their checkboxes, and run only as the grid last showed them.
    static func resolvedRestoredState(
        settings: FilterSettings,
        saved: PersistedFilterState,
        current: TabFilterState
    ) -> TabFilterState {
        var state = current
        let restored = settings.restoreBehavior.savesToDisk ? saved.filters : []
        let appliesRestored = settings.restoreBehavior == .restoreAndApply && !restored.isEmpty
        state.filters = restored
        state.applied = appliesRestored ? saved.restoredApplication : nil
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
            return "-- " + String(localized: "This database filters rows without SQL.")
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

        if filtersToPreview.isEmpty {
            return "-- " + String(localized: "No checked filter is complete. Choose a column and enter a value.")
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

    func openFilterSettings() {
        WindowOpener.shared.openSettings(SettingsLocation(page: .filters))
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
