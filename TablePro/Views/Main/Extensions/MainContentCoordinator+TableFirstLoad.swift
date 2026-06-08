//
//  MainContentCoordinator+TableFirstLoad.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    func openTableTabQuery(tabId: UUID) async {
        guard await prepareTableTabFirstLoad(tabId: tabId) else { return }
        executeTableTabQueryDirectly()
    }

    @discardableResult
    func prepareTableTabFirstLoad(tabId: UUID) async -> Bool {
        guard tabManager.selectedTabId == tabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              tab.tabType == .table,
              let tableName = tab.tableContext.tableName, !tableName.isEmpty else { return false }

        let hint = PluginManager.shared.defaultSortHint(for: connection.type, table: tableName)
        guard firstLoadNeedsSchemaColumns(for: tab, hint: hint) else { return true }

        await loadSchemaColumns(for: tableName, schema: tab.tableContext.schemaName)

        guard !Task.isCancelled,
              tabManager.selectedTabId == tabId,
              let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              tabManager.tabs[index].tableContext.tableName == tableName else { return false }

        let sortApplied = applyResolvedDefaultSort(at: index, hint: hint)
        if sortApplied || !tabManager.tabs[index].columnLayout.hiddenColumns.isEmpty {
            filterCoordinator.rebuildTableQuery(at: index)
        }
        return true
    }

    func firstLoadNeedsSchemaColumns(for tab: QueryTab, hint: DefaultSortHint) -> Bool {
        wantsDefaultSort(for: tab, hint: hint) || !tab.columnLayout.hiddenColumns.isEmpty
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
