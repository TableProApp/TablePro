//
//  MainContentCoordinator+TableFirstLoad.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    func openTableTabQuery(tabId: UUID, trigger: TableLoadTrigger = .userInitiated) async {
        let tracer = TableLoadTracer.shared
        let token = tracer.activeToken(for: tabId)
        if let token { tracer.stage(.prepareFirstLoad, token: token) }

        guard await prepareTableTabFirstLoad(tabId: tabId) else {
            if let token {
                tracer.anomaly(
                    .preparationAbandoned,
                    token: token,
                    detail: "cancelled=\(Task.isCancelled)"
                )
                tracer.finish(token: token, outcome: .prepareAbandoned)
            }
            return
        }
        executeTableTabQueryDirectly(trigger: trigger)
    }

    @discardableResult
    func prepareTableTabFirstLoad(tabId: UUID) async -> Bool {
        guard tabManager.selectedTabId == tabId,
              var tab = tabManager.tabs.first(where: { $0.id == tabId }),
              tab.tabType == .table,
              let tableName = tab.tableContext.tableName, !tableName.isEmpty else { return false }

        if resolveTableTabSchemaIfNeeded(tabId: tabId),
           let resolvedTab = tabManager.tabs.first(where: { $0.id == tabId }) {
            tab = resolvedTab
        }

        let hint = PluginManager.shared.defaultSortHint(for: connection.type, table: tableName)
        guard firstLoadNeedsSchemaColumns(for: tab, hint: hint) else {
            if let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                filterCoordinator.rebuildTableQuery(at: index)
            }
            return true
        }

        let tracer = TableLoadTracer.shared
        let token = tracer.activeToken(for: tabId)
        let schemaName = tab.tableContext.schemaName
        if let token { tracer.stage(.schemaColumnsBegin, token: token) }
        await loadSchemaColumns(for: tableName, scope: scope(for: tab))
        if let token { tracer.stage(.schemaColumnsEnd, token: token) }

        guard !Task.isCancelled,
              tabManager.selectedTabId == tabId,
              let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              tabManager.tabs[index].tableContext.tableName == tableName,
              tabManager.tabs[index].tableContext.schemaName == schemaName else { return false }

        let restoreApplied = applyPendingRestoredViewState(at: index)
        let sortApplied = restoreApplied ? false : applyResolvedDefaultSort(at: index, hint: hint)
        let loadedTab = tabManager.tabs[index]
        if restoreApplied || sortApplied
            || !loadedTab.columnLayout.hiddenColumns.isEmpty
            || loadedTab.filterState.hasAppliedFilters {
            filterCoordinator.rebuildTableQuery(at: index)
        }
        return true
    }

    @discardableResult
    func resolveTableTabSchemaIfNeeded(tabId: UUID) -> Bool {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              tabManager.tabs[index].tabType == .table,
              tabManager.tabs[index].tableContext.schemaName == nil,
              let resolvedSchema = DatabaseManager.shared.resolvedSchemaName(nil, for: connectionId)
        else { return false }

        tabManager.mutate(at: index) { $0.tableContext.schemaName = resolvedSchema }
        filterCoordinator.rebuildTableQuery(at: index)
        return true
    }

    /// Applied filters wait for the schema because no rows have arrived to type their values, and
    /// an untyped value is guessed from its text: `123` goes to a text column as a number, which
    /// PostgreSQL rejects and MySQL answers by comparing numerically.
    func firstLoadNeedsSchemaColumns(for tab: QueryTab, hint: DefaultSortHint) -> Bool {
        wantsDefaultSort(for: tab, hint: hint)
            || !tab.columnLayout.hiddenColumns.isEmpty
            || tab.filterState.hasAppliedFilters
            || tab.pendingRestoredSort != nil
            || tab.restoredPage != nil
    }

    private func applyPendingRestoredViewState(at index: Int) -> Bool {
        let tab = tabManager.tabs[index]
        guard tab.pendingRestoredSort != nil || tab.restoredPage != nil else { return false }

        let pendingSort = tab.pendingRestoredSort ?? []
        /// Against the full schema, not the scoped selection. `selectColumns` retains only the
        /// columns the *live* sort names, and a restored sort is still sitting in
        /// `pendingRestoredSort`, so a saved sort on a hidden column resolved to nothing and the
        /// next save wrote the loss to disk.
        let resolvedSort = MainContentCoordinator.resolveRestoredSortColumns(
            pendingSort,
            in: cachedSchemaColumns(for: tab)?.columns ?? effectiveResultColumns(for: tab)
        )
        /// A sort that resolved to nothing has not been consumed, it has failed to resolve, which is
        /// what an empty column list looks like when the schema fetch did not land. Clearing it
        /// anyway threw the saved sort away and the next save wrote the loss to disk.
        let sortWasConsumed = pendingSort.isEmpty || !resolvedSort.isEmpty
        // The persisted page index counts pages of the size it was taken in, so reading it in
        // today's default would land the tab on rows it was never showing.
        let pageSize = paginationCapability.clampedRowCount(
            tab.restoredPageSize ?? AppSettingsManager.shared.dataGrid.defaultPageSize
        )
        let page = paginationCapability.allowsSeeking ? max(1, tab.restoredPage ?? 1) : 1

        tabManager.mutate(at: index) { tab in
            if sortWasConsumed {
                tab.pendingRestoredSort = nil
            }
            tab.restoredPage = nil
            tab.restoredPageSize = nil
            if !resolvedSort.isEmpty {
                tab.sortState = SortState(columns: resolvedSort, source: tab.restoredSortSource)
            }
            tab.pagination.pageSize = pageSize
            tab.pagination.currentPage = page
            tab.pagination.currentOffset = (page - 1) * pageSize
        }
        return !resolvedSort.isEmpty || page > 1
    }

    /// The app default applies only while nothing has decided the order.
    ///
    /// `isSorting` alone cannot gate this: an empty sort the user chose through Don't Sort looks
    /// exactly like a tab that has never sorted, so the default was written straight back over it on
    /// the next first load, and Don't Sort could never stick.
    func wantsDefaultSort(for tab: QueryTab, hint: DefaultSortHint) -> Bool {
        guard tab.tabType == .table,
              tab.sortState.source == .unset,
              !tab.sortState.isSorting,
              let tableName = tab.tableContext.tableName, !tableName.isEmpty else {
            return false
        }

        switch hint {
        case .suppress:
            return false
        case .forceColumns:
            return true
        case .useAppDefault:
            return AppSettingsManager.shared.dataGrid.defaultSortBehavior != .none
        }
    }

    private func applyResolvedDefaultSort(at index: Int, hint: DefaultSortHint) -> Bool {
        let tab = tabManager.tabs[index]
        guard wantsDefaultSort(for: tab, hint: hint) else { return false }

        let resolved = DefaultSortResolver.resolveSortState(
            behavior: AppSettingsManager.shared.dataGrid.defaultSortBehavior,
            direction: AppSettingsManager.shared.dataGrid.defaultSortDirection,
            pluginHint: hint,
            primaryKeyColumns: resolvedPrimaryKeyColumns(for: tab),
            allColumns: effectiveResultColumns(for: tab)
        )
        guard resolved.isSorting else { return false }

        tabManager.mutate(at: index) {
            $0.sortState = resolved
            $0.pagination.reset()
        }
        return true
    }

    private func resolvedPrimaryKeyColumns(for tab: QueryTab) -> [String] {
        if let pks = cachedSchemaColumns(for: tab)?.primaryKeys, !pks.isEmpty {
            return pks
        }
        if let defaultPK = PluginManager.shared.defaultPrimaryKeyColumn(for: connection.type) {
            return [defaultPK]
        }
        return []
    }
}
