//
//  MainContentCoordinator+ColumnFetchScope.swift
//  TablePro
//

import Foundation
import os

private let columnScopeLog = Logger(subsystem: "com.TablePro", category: "ColumnFetchScope")

extension MainContentCoordinator {
    func selectColumns(for tab: QueryTab) -> [String]? {
        guard tab.tabType == .table,
              let tableName = tab.tableContext.tableName,
              !tab.columnLayout.hiddenColumns.isEmpty,
              let schema = schemaColumns.cached(schemaColumnsKey(tableName, schema: tab.tableContext.schemaName)) else { return nil }

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
            guard await self.rebuildSelectedTableColumnScopedQuery() else { return }
            self.runQuery()
        }
    }

    @discardableResult
    func rebuildSelectedTableColumnScopedQuery() async -> Bool {
        guard let (tab, tabIndex) = tabManager.selectedTabAndIndex,
              tab.tabType == .table,
              let tableName = tab.tableContext.tableName else { return false }
        await loadSchemaColumns(for: tableName, schema: tab.tableContext.schemaName)
        guard !Task.isCancelled, tabIndex < tabManager.tabs.count else { return false }
        filterCoordinator.rebuildTableQuery(at: tabIndex)
        return true
    }

    func loadSchemaColumns(for tableName: String, schema: String?) async {
        let key = schemaColumnsKey(tableName, schema: schema)
        await schemaColumns.load(key) { [services, connectionId] in
            do {
                let columns = try await services.databaseManager.withMetadataDriver(connectionId: connectionId) { driver in
                    try await driver.fetchColumns(table: tableName, schema: schema)
                }
                guard !columns.isEmpty else {
                    columnScopeLog.error("loadSchemaColumns: 0 columns for table=\(tableName, privacy: .public); cannot scope")
                    return nil
                }
                return (columns.map(\.name), columns.filter(\.isPrimaryKey).map(\.name))
            } catch {
                columnScopeLog.error("loadSchemaColumns: fetchColumns failed for table=\(tableName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    func columnsForVisibilityPicker(for tab: QueryTab, resultColumns: [String]) -> [String] {
        guard tab.tabType == .table, let tableName = tab.tableContext.tableName else { return resultColumns }
        if let schema = schemaColumns.cached(schemaColumnsKey(tableName, schema: tab.tableContext.schemaName)), !schema.columns.isEmpty {
            return schema.columns
        }
        let missingHidden = tab.columnLayout.hiddenColumns.subtracting(resultColumns)
        return missingHidden.isEmpty ? resultColumns : resultColumns + missingHidden.sorted()
    }

    func selectedTabSchemaColumns() -> [String]? {
        guard let tab = tabManager.selectedTab,
              let tableName = tab.tableContext.tableName,
              let schema = schemaColumns.cached(schemaColumnsKey(tableName, schema: tab.tableContext.schemaName)),
              !schema.columns.isEmpty else { return nil }
        return schema.columns
    }

    func cachedSchemaColumns(for tab: QueryTab) -> (columns: [String], primaryKeys: [String])? {
        guard let tableName = tab.tableContext.tableName else { return nil }
        return schemaColumns.cached(schemaColumnsKey(tableName, schema: tab.tableContext.schemaName))
    }

    func effectiveResultColumns(for tab: QueryTab) -> [String] {
        selectColumns(for: tab) ?? cachedSchemaColumns(for: tab)?.columns ?? []
    }

    func schemaColumnsKey(_ tableName: String, schema: String?) -> String {
        "\(connectionId):\(activeDatabaseName):\(schema ?? ""):\(tableName)"
    }
}
