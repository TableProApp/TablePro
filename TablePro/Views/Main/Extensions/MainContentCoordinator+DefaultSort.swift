//
//  MainContentCoordinator+DefaultSort.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    func shouldResolveDefaultSort(for tab: QueryTab) -> Bool {
        guard tab.tabType == .table,
              !tab.execution.didEvaluateDefaultSort,
              !tab.sortState.isSorting,
              let tableName = tab.tableContext.tableName, !tableName.isEmpty else {
            return false
        }

        switch PluginManager.shared.defaultSortHint(for: connection.type, table: tableName) {
        case .suppress:
            return false
        case .forceColumns:
            return true
        case .useAppDefault:
            return AppSettingsManager.shared.dataGrid.defaultSortBehavior != .none
        }
    }

    func resolveDefaultSortThenExecuteTableQuery(tabId: UUID) async {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              let tableName = tab.tableContext.tableName else { return }

        await loadSchemaColumns(for: tableName, schema: tab.tableContext.schemaName)

        guard !Task.isCancelled,
              let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let currentTab = tabManager.tabs[index]

        let resolved = DefaultSortResolver.resolveSortState(
            behavior: AppSettingsManager.shared.dataGrid.defaultSortBehavior,
            pluginHint: PluginManager.shared.defaultSortHint(for: connection.type, table: tableName),
            primaryKeyColumns: resolvedPrimaryKeyColumns(for: currentTab),
            allColumns: effectiveResultColumns(for: currentTab)
        )

        if resolved.isSorting {
            tabManager.mutate(at: index) { tab in
                tab.sortState = resolved
                tab.pagination.reset()
            }
            filterCoordinator.rebuildTableQuery(at: index)
        }

        runQuery()
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
