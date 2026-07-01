//
//  MainContentCoordinator+TableFirstLoad.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    func openTableTabQuery(tabId: UUID, trigger: TableLoadTrigger = .userInitiated) async {
        guard await prepareTableTabFirstLoad(tabId: tabId) else { return }
        executeTableTabQueryDirectly(trigger: trigger)
    }

    @discardableResult
    func prepareTableTabFirstLoad(tabId: UUID) async -> Bool {
        guard tabManager.selectedTabId == tabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              tab.tabType == .table,
              let tableName = tab.tableContext.tableName, !tableName.isEmpty else { return false }

        let hint = PluginManager.shared.defaultSortHint(for: connection.type, table: tableName)
        guard firstLoadNeedsSchemaColumns(for: tab, hint: hint) else {
            if let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                filterCoordinator.rebuildTableQuery(at: index)
            }
            return true
        }

        await loadSchemaColumns(for: tableName, schema: tab.tableContext.schemaName)

        guard !Task.isCancelled,
              tabManager.selectedTabId == tabId,
              let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              tabManager.tabs[index].tableContext.tableName == tableName else { return false }

        let restoreApplied = applyPendingRestoredViewState(at: index)
        let sortApplied = restoreApplied ? false : applyResolvedDefaultSort(at: index, hint: hint)
        if restoreApplied || sortApplied || !tabManager.tabs[index].columnLayout.hiddenColumns.isEmpty {
            filterCoordinator.rebuildTableQuery(at: index)
        }
        return true
    }

    func firstLoadNeedsSchemaColumns(for tab: QueryTab, hint: DefaultSortHint) -> Bool {
        wantsDefaultSort(for: tab, hint: hint)
            || !tab.columnLayout.hiddenColumns.isEmpty
            || tab.pendingRestoredSort != nil
            || tab.restoredPage != nil
    }

    private func applyPendingRestoredViewState(at index: Int) -> Bool {
        let tab = tabManager.tabs[index]
        guard tab.pendingRestoredSort != nil || tab.restoredPage != nil else { return false }

        let resolvedSort = MainContentCoordinator.resolveRestoredSortColumns(
            tab.pendingRestoredSort ?? [],
            in: effectiveResultColumns(for: tab)
        )
        let pageSize = AppSettingsManager.shared.dataGrid.defaultPageSize
        let page = max(1, tab.restoredPage ?? 1)

        tabManager.mutate(at: index) { tab in
            tab.pendingRestoredSort = nil
            tab.restoredPage = nil
            if !resolvedSort.isEmpty {
                tab.sortState = SortState(columns: resolvedSort, source: .user)
            }
            tab.pagination.pageSize = pageSize
            tab.pagination.currentPage = page
            tab.pagination.currentOffset = (page - 1) * pageSize
        }
        return !resolvedSort.isEmpty || page > 1
    }

    func wantsDefaultSort(for tab: QueryTab, hint: DefaultSortHint) -> Bool {
        guard tab.tabType == .table,
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
