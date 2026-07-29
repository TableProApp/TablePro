//
//  FilterCoordinator.swift
//  TablePro
//

import Foundation
import os
import SwiftUI

private let filterStateLog = Logger(subsystem: "com.TablePro", category: "FilterState")

@MainActor @Observable
final class FilterCoordinator {
    @ObservationIgnored unowned let parent: MainContentCoordinator

    init(parent: MainContentCoordinator) {
        self.parent = parent
    }

    // MARK: - Filtering

    func applyFilters(_ filters: [TableFilter]) {
        guard let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              let tableName = tab.tableContext.tableName else { return }

        let capturedTabIndex = tabIndex
        let capturedTableName = tableName
        let capturedFilters = filters
        parent.confirmDiscardChangesIfNeeded(action: .filter) { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard capturedTabIndex < parent.tabManager.tabs.count else { return }

            parent.tabManager.mutate(at: capturedTabIndex) { $0.pagination.reset() }

            let tab = parent.tabManager.tabs[capturedTabIndex]
            let buffer = parent.tabSessionRegistry.tableRows(for: tab.id)
            let newQuery = parent.queryBuilder.buildFilteredQuery(
                tableName: capturedTableName,
                schemaName: tab.tableContext.schemaName,
                filters: capturedFilters,
                logicMode: tab.filterState.filterLogicMode,
                sortState: tab.sortState,
                columns: buffer.columns,
                selectColumns: parent.selectColumns(for: tab),
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset
            )

            parent.tabManager.mutate(at: capturedTabIndex) { $0.content.query = newQuery }
            saveLastFilters(for: capturedTableName)
            parent.runQuery()
        }
    }

    func clearFiltersAndReload() {
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

            parent.tabManager.mutate(at: capturedTabIndex) { $0.content.query = newQuery }
            clearLastFilters(for: capturedTableName)
            parent.runQuery()
        }
    }

    func restoreFiltersForTable(_ tableName: String) {
        restoreLastFilters(for: tableName)
        restoreBrowseSearch(for: tableName)
        guard let (_, tabIndex) = parent.tabManager.selectedTabAndIndex else { return }
        let state = parent.tabManager.tabs[tabIndex].filterState
        if state.hasAppliedFilters || state.hasActiveBrowseSearch {
            rebuildTableQuery(at: tabIndex)
        }
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
            parent.runQuery()
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
            parent.runQuery()
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

    private func restoreBrowseSearch(for tableName: String) {
        guard usesBrowseSearch, let tab = parent.tabManager.selectedTab else { return }
        let saved = FilterSettingsStorage.shared.loadBrowseSearch(
            for: tableName,
            connectionId: parent.connectionId,
            databaseName: tab.tableContext.databaseName,
            schemaName: tab.tableContext.schemaName
        )
        mutateSelectedTabFilterState { state in
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
        let buffer = parent.tabSessionRegistry.tableRows(for: tab.id)
        let hasFilters = tab.filterState.hasAppliedFilters
        let columns = buffer.columns.isEmpty
            ? parent.effectiveResultColumns(for: tab)
            : buffer.columns

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

        parent.tabManager.mutate(at: tabIndex) { $0.content.query = newQuery }
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
            clearFiltersAndReload()
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
        mutateSelectedTabFilterState { state in
            state.commit = .all
        }
        saveLastFiltersForActiveTable()
    }

    func applySoloFilter(_ filter: TableFilter) {
        guard filter.isValid else { return }
        mutateSelectedTabFilterState { state in
            state.commit = .solo(filter.id)
        }
        saveLastFiltersForActiveTable()
    }

    func clearAppliedFilters() {
        mutateSelectedTabFilterState { state in
            state.commit = nil
        }
    }

    // MARK: - Panel Visibility

    func toggleFilterPanel() {
        withAnimation(.easeInOut(duration: 0.15)) {
            mutateSelectedTabFilterState { state in
                state.isVisible.toggle()
            }
        }
    }

    func showFilterPanel() {
        withAnimation(.easeInOut(duration: 0.15)) {
            mutateSelectedTabFilterState { state in
                state.isVisible = true
            }
        }
    }

    func closeFilterPanel() {
        withAnimation(.easeInOut(duration: 0.15)) {
            mutateSelectedTabFilterState { state in
                state.isVisible = false
            }
        }
    }

    // MARK: - Persistence

    func saveLastFiltersForActiveTable() {
        guard let tab = parent.tabManager.selectedTab,
              let tableName = tab.tableContext.tableName else { return }
        FilterSettingsStorage.shared.saveLastFilters(
            tab.filterState.filters.filter(\.isValid),
            logicMode: tab.filterState.filterLogicMode,
            for: tableName,
            connectionId: parent.connectionId,
            databaseName: tab.tableContext.databaseName,
            schemaName: tab.tableContext.schemaName
        )
    }

    func saveLastFilters(for tableName: String) {
        guard let tab = parent.tabManager.selectedTab else { return }
        FilterSettingsStorage.shared.saveLastFilters(
            tab.filterState.filters.filter(\.isValid),
            logicMode: tab.filterState.filterLogicMode,
            for: tableName,
            connectionId: parent.connectionId,
            databaseName: tab.tableContext.databaseName,
            schemaName: tab.tableContext.schemaName
        )
    }

    func clearLastFilters(for tableName: String) {
        guard let tab = parent.tabManager.selectedTab else { return }
        FilterSettingsStorage.shared.clearLastFilters(
            for: tableName,
            connectionId: parent.connectionId,
            databaseName: tab.tableContext.databaseName,
            schemaName: tab.tableContext.schemaName
        )
    }

    func restoreLastFilters(for tableName: String) {
        let settings = FilterSettingsStorage.shared.loadSettings()
        guard let tab = parent.tabManager.selectedTab else { return }

        let saved: PersistedFilterState
        if settings.panelState == .alwaysHide {
            saved = PersistedFilterState(filters: [])
        } else {
            saved = FilterSettingsStorage.shared.loadLastFilterState(
                for: tableName,
                connectionId: parent.connectionId,
                databaseName: tab.tableContext.databaseName,
                schemaName: tab.tableContext.schemaName
            )
        }
        mutateSelectedTabFilterState { state in
            state = Self.resolvedRestoredState(
                panelState: settings.panelState,
                saved: saved.filters,
                savedLogicMode: saved.logicMode,
                current: state
            )
        }
    }

    static func resolvedRestoredState(
        panelState: FilterPanelDefaultState,
        saved: [TableFilter],
        savedLogicMode: FilterLogicMode = .and,
        current: TabFilterState
    ) -> TabFilterState {
        var state = current
        switch panelState {
        case .alwaysHide:
            state.filters = []
            state.commit = nil
            state.isVisible = false
        case .alwaysShow:
            state.filters = saved
            state.commit = .all
            state.isVisible = true
            state.filterLogicMode = savedLogicMode
        case .restoreLast:
            state.filters = saved
            state.commit = .all
            state.isVisible = !saved.isEmpty
            state.filterLogicMode = savedLogicMode
        }
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
        let generator = FilterSQLGenerator(dialect: dialect)
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
        var newState = parent.tabManager.tabs[index].filterState
        mutate(&newState)
        parent.tabManager.mutate(at: index) { $0.filterState = newState }
        let tabId = parent.tabManager.tabs[index].id
        if let session = parent.tabSessionRegistry.session(for: tabId) {
            session.filterState = newState
        } else {
            filterStateLog.error(
                "TabSession missing for selected tab \(tabId, privacy: .public); QueryTab updated but session mirror skipped"
            )
            assertionFailure("TabSession missing for selected tab: registry sync regression")
        }
    }
}
