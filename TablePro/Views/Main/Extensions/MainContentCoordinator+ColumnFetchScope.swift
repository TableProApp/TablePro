//
//  MainContentCoordinator+ColumnFetchScope.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func selectColumns(for tab: QueryTab) -> [String]? {
        guard tab.tabType == .table,
              let tableName = tab.tableContext.tableName,
              !tab.columnLayout.hiddenColumns.isEmpty,
              let schema = schemaColumnsCache[schemaColumnsKey(tableName)] else { return nil }

        return ColumnFetchScope.selectColumns(
            schemaColumns: schema.columns,
            hiddenColumns: tab.columnLayout.hiddenColumns,
            primaryKeyColumns: schema.primaryKeys
        )
    }

    func requeryWithColumnScope(debounced: Bool = false) {
        columnScopeRequeryTask?.cancel()
        columnScopeRequeryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if debounced {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            guard let (tab, tabIndex) = self.tabManager.selectedTabAndIndex,
                  tab.tabType == .table,
                  let tableName = tab.tableContext.tableName else { return }
            await self.loadSchemaColumns(for: tableName)
            guard !Task.isCancelled, tabIndex < self.tabManager.tabs.count else { return }
            self.filterCoordinator.rebuildTableQuery(at: tabIndex)
            self.runQuery()
        }
    }

    func loadSchemaColumns(for tableName: String) async {
        let key = schemaColumnsKey(tableName)
        guard schemaColumnsCache[key] == nil else { return }
        guard let provider = services.schemaProviderRegistry.provider(for: connectionId) else { return }
        let columns = await provider.getColumns(for: tableName)
        guard !columns.isEmpty else { return }
        schemaColumnsCache[key] = (columns.map(\.name), columns.filter(\.isPrimaryKey).map(\.name))
    }

    func columnsForVisibilityPicker(for tab: QueryTab, resultColumns: [String]) -> [String] {
        guard tab.tabType == .table, let tableName = tab.tableContext.tableName else { return resultColumns }
        if let schema = schemaColumnsCache[schemaColumnsKey(tableName)], !schema.columns.isEmpty {
            return schema.columns
        }
        let missingHidden = tab.columnLayout.hiddenColumns.subtracting(resultColumns)
        return missingHidden.isEmpty ? resultColumns : resultColumns + missingHidden.sorted()
    }

    private func schemaColumnsKey(_ tableName: String) -> String {
        "\(connectionId):\(activeDatabaseName):\(tableName)"
    }
}
